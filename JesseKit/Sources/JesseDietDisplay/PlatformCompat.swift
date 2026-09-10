import SwiftUI

// The small cross-platform seam the shared dashboard needs so ONE view layer renders on
// both iOS and macOS. Every iOS-only API the display used (UIKit dynamic colors, the
// systemFill/systemBackground semantic colors, and the navigation-bar title mode) is
// funneled through here, with the iOS branch kept byte-for-byte identical to the old
// code so the iPhone renders exactly as before, and an AppKit branch supplying the macOS
// equivalent. Nothing platform-specific leaks into the view files themselves.

#if canImport(UIKit)
import UIKit
/// The platform's concrete color type: `UIColor` on iOS, `NSColor` on macOS.
public typealias PlatformColor = UIColor
#elseif canImport(AppKit)
import AppKit
public typealias PlatformColor = NSColor
#endif

// MARK: - Dynamic (per color scheme) colors

extension Color {
    /// A `Color` that resolves to a different platform color in light vs dark, built on
    /// the platform's own dynamic provider (`UIColor(dynamicProvider:)` on iOS,
    /// `NSColor(name:dynamicProvider:)` on macOS) so it tracks the active appearance
    /// live rather than snapshotting one scheme.
    static func dietDynamic(_ resolve: @escaping (_ isDark: Bool) -> PlatformColor) -> Color {
        #if canImport(UIKit)
        return Color(UIColor { traits in resolve(traits.userInterfaceStyle == .dark) })
        #elseif canImport(AppKit)
        return Color(nsColor: NSColor(name: nil) { appearance in
            resolve(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        })
        #endif
    }

    /// Resolve this `Color` to a concrete platform color for the given scheme, used to
    /// derive one macro color from another (resolve the parent, then lighten it).
    func dietPlatformResolved(isDark: Bool) -> PlatformColor {
        #if canImport(UIKit)
        return UIColor(self).resolvedColor(with: UITraitCollection(userInterfaceStyle: isDark ? .dark : .light))
        #elseif canImport(AppKit)
        let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        var resolved = NSColor(self)
        appearance?.performAsCurrentDrawingAppearance {
            resolved = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        }
        return resolved
        #endif
    }
}

extension PlatformColor {
    /// This color blended toward white by `fraction` (0 = unchanged, 1 = white), staying
    /// fully opaque. Component blend in the resolved sRGB space. A faithful port of the
    /// iOS-only `UIColor.lightenedTowardWhite` the fiber shade used.
    func dietLightenedTowardWhite(by fraction: CGFloat) -> PlatformColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if canImport(AppKit)
        let src = usingColorSpace(.sRGB) ?? self
        src.getRed(&r, green: &g, blue: &b, alpha: &a)
        #else
        getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif
        let f = min(max(fraction, 0), 1)
        return PlatformColor(red: r + (1 - r) * f,
                             green: g + (1 - g) * f,
                             blue: b + (1 - b) * f,
                             alpha: 1)
    }
}

// MARK: - Semantic fills

extension Color {
    /// The subtle chip / capsule fill. iOS keeps the exact system tertiary fill; macOS,
    /// which has no systemFill hierarchy, uses the closest neutral translucent label.
    static var dietSubtleFill: Color {
        #if canImport(UIKit)
        return Color(uiColor: .tertiarySystemFill)
        #elseif canImport(AppKit)
        return Color(nsColor: .quaternaryLabelColor)
        #endif
    }

    /// The window/base background, used as a contrasting glyph fill on a chart point.
    static var dietBackground: Color {
        #if canImport(UIKit)
        return Color(uiColor: .systemBackground)
        #elseif canImport(AppKit)
        return Color(nsColor: .windowBackgroundColor)
        #endif
    }

    /// The raised card background (a group section sitting on the base background).
    static var dietGroupedBackground: Color {
        #if canImport(UIKit)
        return Color(uiColor: .secondarySystemGroupedBackground)
        #elseif canImport(AppKit)
        return Color(nsColor: .controlBackgroundColor)
        #endif
    }

    /// The tertiary label color, used to de-emphasize the fiber sub-total caption.
    static var dietTertiaryLabel: Color {
        #if canImport(UIKit)
        return Color(uiColor: .tertiaryLabel)
        #elseif canImport(AppKit)
        return Color(nsColor: .tertiaryLabelColor)
        #endif
    }
}

// MARK: - Toolbar placement

extension ToolbarItemPlacement {
    /// A leading-edge toolbar slot: iOS's `.topBarLeading`, or `.automatic` on macOS
    /// (which has no top-bar concept), so a shared toolbar compiles on both.
    static var dietLeading: ToolbarItemPlacement {
        #if os(iOS)
        return .topBarLeading
        #else
        return .automatic
        #endif
    }
}

// MARK: - Navigation title mode

/// The two navigation-title sizes the dashboard uses. On iOS each maps to the matching
/// `navigationBarTitleDisplayMode`; on macOS (which has no such modifier) it is a no-op.
enum DietNavTitleMode {
    case inline, large
}

extension View {
    func dietNavTitle(_ mode: DietNavTitleMode) -> some View {
        #if os(iOS)
        return navigationBarTitleDisplayMode(mode == .inline ? .inline : .large)
        #else
        return self
        #endif
    }
}

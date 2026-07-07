import UIKit

// Inline markdown → `NSAttributedString` with *concrete* UIKit fonts and colors.
//
// `AttributedString(markdown:)` records bold / italic / code only as SEMANTIC
// `inlinePresentationIntent` runs — it does not set a bold `UIFont`. SwiftUI's
// `Text` resolves those intents itself, but a `UITextView` (which we use for
// native, granular text selection) needs real font attributes. This resolves the
// intents to actual `UIFont` traits + link attributes so a text view renders the
// same bold/italic/`code`/links a `Text` would.
//
// Pure and side-effect-free (the font/color resolution is the testable core).
enum MarkdownInline {
    /// One inline-markdown string as an `NSAttributedString` styled with `font`
    /// (the base body/heading font) and `color`. Bold/italic/`code`/links are
    /// resolved to concrete attributes; on a parse failure the raw string is
    /// returned with the base attributes so text is never lost.
    static func attributed(_ s: String, font: UIFont, color: UIColor) -> NSAttributedString {
        guard let parsed = try? AttributedString(
            markdown: s,
            options: .init(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible)) else {
            return NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
        }

        let result = NSMutableAttributedString()
        for run in parsed.runs {
            let text = String(parsed[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            var attrs: [NSAttributedString.Key: Any] = [
                .font: resolvedFont(base: font, intent: intent),
                .foregroundColor: color,
            ]
            if let link = run.link {
                // The text view colors links via its `tintColor`; the attribute
                // just makes the run a tappable link.
                attrs[.link] = link
            }
            result.append(NSAttributedString(string: text, attributes: attrs))
        }
        return result
    }

    /// A list item (`•` / `1.`) as an `NSAttributedString` with a hanging indent,
    /// so wrapped lines align under the text rather than under the marker —
    /// matching the SwiftUI bullet/number column layout.
    static func listItem(marker: String, text: String, font: UIFont,
                         color: UIColor, indent: CGFloat = 20) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.headIndent = indent
        style.firstLineHeadIndent = 0
        style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
        style.defaultTabInterval = indent

        let result = NSMutableAttributedString(
            string: "\(marker)\t", attributes: [.font: font, .foregroundColor: color])
        result.append(attributed(text, font: font, color: color))
        result.addAttribute(.paragraphStyle, value: style,
                            range: NSRange(location: 0, length: result.length))
        return result
    }

    /// The base `font` with the bold/italic/monospaced traits implied by `intent`.
    /// `code` switches to a monospaced face at the same point size (carrying any
    /// bold/italic that is also set); otherwise bold/italic are layered onto the
    /// base descriptor's existing traits.
    static func resolvedFont(base: UIFont, intent: InlinePresentationIntent) -> UIFont {
        var traits: UIFontDescriptor.SymbolicTraits = []
        if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
        if intent.contains(.emphasized) { traits.insert(.traitItalic) }

        if intent.contains(.code) {
            var mono = UIFont.monospacedSystemFont(ofSize: base.pointSize, weight: .regular)
            if !traits.isEmpty,
               let descriptor = mono.fontDescriptor.withSymbolicTraits(traits) {
                mono = UIFont(descriptor: descriptor, size: base.pointSize)
            }
            return mono
        }

        guard !traits.isEmpty else { return base }
        let merged = base.fontDescriptor.symbolicTraits.union(traits)
        if let descriptor = base.fontDescriptor.withSymbolicTraits(merged) {
            return UIFont(descriptor: descriptor, size: base.pointSize)
        }
        return base
    }
}

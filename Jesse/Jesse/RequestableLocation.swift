import Foundation

// The app half of the JESSE_NEEDS_LOCATION channel: the fixed whitelists a directive
// may name, the VALIDATED decode of a request, and the pure formatter that renders a
// reading into the attached block. CoreLocation itself lives in
// `LocationContextProvider`; everything here is Foundation-only and unit-tested.
//
// The sibling of `RequestableMetric.swift`, deliberately shaped the same way, with one
// difference that is not cosmetic: EVERY key is required. A needs-health directive may
// omit `metrics` and still be a meaningful request; a needs-location directive that
// omits `precision` is not, because precision is the one field on this channel with a
// privacy consequence and a default would decide it silently on the model's behalf.
//
// Correctness: a request is either fully valid or unfulfillable — an off-whitelist
// field, an unknown precision, or an out-of-range age rejects the WHOLE request (the
// coordinator then answers through the unavailable path). We never partially fulfill.

/// The fixed whitelist of fields a `JESSE_NEEDS_LOCATION` directive may request.
/// **MUST stay in exact sync with the bridge's `NEEDS_LOCATION_FIELDS`** — and unlike
/// the health whitelist, that is now checked rather than asserted in a comment:
/// `scripts/ci-guards.sh` parses this enum and the Rust const and fails on drift.
nonisolated enum RequestableLocationField: String, CaseIterable, Sendable, Equatable {
    /// Latitude and longitude, at the granted precision.
    case coordinates
    /// A reverse-geocoded human place — locality, admin area, postcode, country.
    case placemark
    /// The horizontal accuracy radius of the fix, in metres.
    case accuracy
}

/// How precise a reading the directive asked for. **Kept in sync with the bridge's
/// `NEEDS_LOCATION_PRECISIONS`**, checked by the same CI guard.
nonisolated enum LocationPrecision: String, CaseIterable, Sendable, Equatable {
    /// The reduced accuracy CoreLocation already provides through
    /// `CLLocationManager.accuracyAuthorization` — roughly a 1–3 km circle, and no
    /// additional prompt for the owner.
    case coarse
    /// Full accuracy. On a device that granted reduced accuracy only this costs a
    /// temporary full-accuracy prompt mid-turn, which is why the model has to ask for
    /// it explicitly rather than getting it by default.
    case precise
}

/// The app-side, fully **validated** needs-location request, built from the wire
/// `directives.needs_location`. `validated` returns nil for anything the contract
/// rejects (so the caller treats it as unfulfillable), never a partial request.
nonisolated struct NeedsLocationRequest: Equatable, Sendable {
    let fields: [RequestableLocationField]
    let precision: LocationPrecision
    /// How stale a cached fix the agent will accept, in seconds. Guaranteed 0...900.
    let maxAgeSeconds: Int

    static let maxFields = RequestableLocationField.allCases.count
    static let maxAgeRange = 0...900

    /// Validate a decoded directive against the contract. Returns nil if `fields` is
    /// empty, over `maxFields`, or names anything off the whitelist; if `precision` is
    /// missing or unknown; or if `maxAgeSeconds` is missing or out of range. All three
    /// are required — there is no default for any of them, matching the bridge.
    static func validated(fields: [String]?,
                          precision: String?,
                          maxAgeSeconds: Int?) -> NeedsLocationRequest? {
        guard let fields, !fields.isEmpty, fields.count <= maxFields else { return nil }
        var validFields: [RequestableLocationField] = []
        for raw in fields {
            guard let field = RequestableLocationField(rawValue: raw) else { return nil }
            validFields.append(field)
        }
        guard let precision, let validPrecision = LocationPrecision(rawValue: precision) else {
            return nil
        }
        guard let maxAgeSeconds, maxAgeRange.contains(maxAgeSeconds) else { return nil }
        return NeedsLocationRequest(fields: validFields,
                                    precision: validPrecision,
                                    maxAgeSeconds: maxAgeSeconds)
    }
}

// MARK: - The reading (pure value)

/// One place, as the device reported it. Every part is optional because every part can
/// independently be missing: a fix with no reverse-geocode (offline, or mid-ocean) still
/// has coordinates, and a fix whose geocode succeeded still has an accuracy worth
/// stating. The provider fills what it got; the formatter renders what was asked for.
nonisolated struct LocationReading: Equatable, Sendable {
    var latitude: Double?
    var longitude: Double?
    /// Horizontal accuracy radius in metres, as CoreLocation reports it.
    var accuracyMeters: Double?
    /// A human place line assembled from the reverse geocode — "Fountainbridge,
    /// Edinburgh EH3, United Kingdom". Nil when the geocode failed or was not asked for.
    var placemark: String?
    /// When the fix was taken, for the staleness line.
    var timestamp: Date?

    static let empty = LocationReading()

    /// Whether there is anything at all worth rendering.
    var isEmpty: Bool {
        latitude == nil && longitude == nil && accuracyMeters == nil && placemark == nil
    }
}

// MARK: - Fulfillment assembler (pure)

/// Assembles the `location_context` block that answers a validated needs-location
/// request. Pure given its inputs (the provider supplies the live reading), so the
/// composition, the coordinate rounding and the 1 KiB cap are unit-tested. Returns nil
/// when nothing could be gathered — the coordinator then treats it as unfulfillable.
nonisolated enum LocationRequestFulfiller {
    /// App-side cap on a fulfilled block. This one is NOT under the bridge's ceiling
    /// the way the health cap is — it IS the bridge's ceiling (1 KiB), because a
    /// location block is three lines and there is no headroom to want.
    static let maxBytes = 1024

    /// Decimal places kept on a COARSE coordinate. Three places is ~110 m, comfortably
    /// inside the 1–3 km circle reduced accuracy already gives, and it stops the block
    /// from printing fifteen digits of false precision for a fix that does not have
    /// them. `precise` keeps five (~1 m), which is the useful limit for "how far".
    static let coarseDecimals = 3
    static let preciseDecimals = 5

    /// Hard clamp on the rendered placemark, applied BEFORE the whole-block cap.
    ///
    /// The block cap truncates on whole-line boundaries, so a single line longer than
    /// the cap keeps nothing — and the placemark is the one line whose length comes
    /// from outside this app (a reverse-geocode response). Without this, one absurd
    /// place name would drop the coordinates and the accuracy along with it, turning a
    /// perfectly good fix into an unfulfillable request. 200 characters is far more
    /// than any real "sub-locality, town, postcode, country" needs.
    static let maxPlacemarkChars = 200

    static func block(request: NeedsLocationRequest,
                      reading: LocationReading,
                      now: Date = Date(),
                      timeZone: TimeZone = .current) -> String? {
        guard !reading.isEmpty else { return nil }
        var lines: [String] = []

        if request.fields.contains(.placemark), let place = reading.placemark {
            let trimmed = place.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                lines.append("Near: \(trimmed.prefix(maxPlacemarkChars))")
            }
        }
        if request.fields.contains(.coordinates),
           let lat = reading.latitude, let lon = reading.longitude {
            let places = request.precision == .precise ? preciseDecimals : coarseDecimals
            lines.append("Coordinates (\(request.precision.rawValue)): "
                         + "\(round(lat, places)), \(round(lon, places))")
        }
        if request.fields.contains(.accuracy), let acc = reading.accuracyMeters, acc >= 0 {
            lines.append("Accuracy: within about \(metres(acc))")
        }
        // The age of the fix rides along whenever there is anything to date. It is not
        // a requestable field: a reading with no age is a reading the agent cannot
        // reason about ("is he still there?"), and making that optional would let a
        // request produce a confidently stale answer.
        if let stamp = reading.timestamp, !lines.isEmpty {
            lines.append("Taken: \(clock(stamp, timeZone)) (\(age(stamp, now)) ago)")
        }

        guard !lines.isEmpty else { return nil }
        let capped = HealthRequestFulfiller.capWholeLines(lines.joined(separator: "\n"),
                                                          maxBytes: maxBytes)
        return capped.isEmpty ? nil : capped
    }

    /// A coordinate rounded to `places` decimals, rendered without exponent notation.
    static func round(_ value: Double, _ places: Int) -> String {
        String(format: "%.\(places)f", value)
    }

    /// An accuracy radius as a human distance — metres under a kilometre, else km with
    /// one decimal, because "within about 1800 m" reads as false precision for what is
    /// a coarse circle.
    static func metres(_ value: Double) -> String {
        if value < 1000 { return "\(String(format: "%.0f", value)) m" }
        return "\(String(format: "%.1f", value / 1000)) km"
    }

    /// How long ago the fix was taken, to the coarsest useful unit.
    static func age(_ stamp: Date, _ now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(stamp)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h"
    }

    private static func clock(_ date: Date, _ timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}

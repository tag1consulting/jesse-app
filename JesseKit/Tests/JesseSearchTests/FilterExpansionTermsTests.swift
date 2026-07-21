import XCTest
@testable import JesseSearch

// Tests the PURE result-filtering helper of the Foundation Models expander. The
// real on-device model is unavailable in CI / the Simulator, so the model call
// itself isn't exercised here; `filterExpansionTerms` is the deterministic core
// that shapes whatever the model returns. These assertions never touch a model.
final class FilterExpansionTermsTests: XCTestCase {

    func testTrimsAndDropsBlanks() {
        let out = filterExpansionTerms(["  span  ", "", "   ", "overpass"], original: "bridge")
        XCTAssertEqual(out, ["span", "overpass"])
    }

    func testDropsTermEqualToOriginalCaseInsensitively() {
        let out = filterExpansionTerms(["Bridge", "span", "BRIDGE"], original: "bridge")
        XCTAssertEqual(out, ["span"], "a term that just echoes the query adds nothing")
    }

    func testDeduplicatesCaseInsensitively() {
        let out = filterExpansionTerms(["span", "Span", "SPAN", "overpass"], original: "bridge")
        XCTAssertEqual(out, ["span", "overpass"])
    }

    func testCapsAtMax() {
        let out = filterExpansionTerms(["a1", "b2", "c3", "d4", "e5", "f6"],
                                       original: "bridge", maxTerms: 4)
        XCTAssertEqual(out, ["a1", "b2", "c3", "d4"])
    }

    func testEmptyInEmptyOut() {
        XCTAssertEqual(filterExpansionTerms([], original: "bridge"), [])
    }

    func testAllBlankOrEchoInEmptyOut() {
        XCTAssertEqual(filterExpansionTerms(["", "  ", "bridge", "Bridge"], original: "bridge"), [])
    }
}

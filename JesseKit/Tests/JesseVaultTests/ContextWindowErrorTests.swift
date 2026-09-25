import Foundation
import FoundationModels
import XCTest
@testable import JesseVault

// The one generation error the answerer retries on, recognised in both SDK vintages
// without naming a type either SDK lacks or deprecates.
//
// The 26 spelling is the REAL error, built from the SDK, because what can go wrong with
// it is reflection on Apple's type rather than on one of ours. The 27 spelling cannot be
// built by any toolchain this repository compiles with, so it is a double carrying the
// same type name and case name, in both shapes the case could have: with an associated
// value and without one.
final class ContextWindowErrorTests: XCTestCase {

    // Deprecated so that building the older enum's cases stays silent under the 27 SDK,
    // which deprecates every one of them. A deprecated declaration may use deprecated API.
    @available(*, deprecated, message: "builds LanguageModelSession.GenerationError cases")
    func testTheSDK26ContextWindowErrorIsAContextWindow() {
        let context = LanguageModelSession.GenerationError.Context(debugDescription: "too long")
        let error: any Error = LanguageModelSession.GenerationError.exceededContextWindowSize(context)
        XCTAssertEqual(FoundationVaultAnswerSession.caseName(of: error), "exceededContextWindowSize",
                       "Mirror must report the case label of the real SDK error")
        XCTAssertTrue(FoundationVaultAnswerSession.isContextWindow(error))
    }

    @available(*, deprecated, message: "builds LanguageModelSession.GenerationError cases")
    func testAnotherSDK26GenerationErrorIsNot() {
        let context = LanguageModelSession.GenerationError.Context(debugDescription: "slow down")
        let error: any Error = LanguageModelSession.GenerationError.rateLimited(context)
        XCTAssertFalse(FoundationVaultAnswerSession.isContextWindow(error))
    }

    func testTheSDK27ContextWindowErrorIsAContextWindowWithoutAPayload() {
        let error: any Error = BarePayload.LanguageModelError.contextSizeExceeded
        XCTAssertTrue(FoundationVaultAnswerSession.isContextWindow(error))
    }

    func testTheSDK27ContextWindowErrorIsAContextWindowWithAPayload() {
        let error: any Error = WithPayload.LanguageModelError.contextSizeExceeded("too long")
        XCTAssertTrue(FoundationVaultAnswerSession.isContextWindow(error))
    }

    func testAnotherSDK27ErrorIsNot() {
        XCTAssertFalse(FoundationVaultAnswerSession.isContextWindow(
            BarePayload.LanguageModelError.guardrailViolation))
        XCTAssertFalse(FoundationVaultAnswerSession.isContextWindow(
            WithPayload.LanguageModelError.guardrailViolation("no")))
    }

    func testTheCaseNameAloneOnAnUnrelatedTypeIsNot() {
        XCTAssertFalse(FoundationVaultAnswerSession.isContextWindow(
            UnrelatedError.contextSizeExceeded))
    }

    func testAnErrorThatIsNotAnEnumIsNot() {
        XCTAssertFalse(FoundationVaultAnswerSession.isContextWindow(
            NSError(domain: "LanguageModelError", code: 1)))
        XCTAssertFalse(FoundationVaultAnswerSession.isContextWindow(CocoaError(.fileNoSuchFile)))
    }

    func testAnEnumWithItsOwnDescriptionIsNotReadByDescription() {
        XCTAssertNil(FoundationVaultAnswerSession.caseName(of: DescribedError.contextSizeExceeded))
    }
}

// Two shapes of the SDK 27 error. Each is named `LanguageModelError`, as the real one is,
// because the type's name is half of what is matched.
private enum BarePayload {
    enum LanguageModelError: Error {
        case contextSizeExceeded
        case guardrailViolation
    }
}

private enum WithPayload {
    enum LanguageModelError: Error {
        case contextSizeExceeded(String)
        case guardrailViolation(String)
    }
}

private enum UnrelatedError: Error {
    case contextSizeExceeded
}

private enum DescribedError: Error, CustomStringConvertible {
    case contextSizeExceeded
    var description: String { "The prompt did not fit." }
}

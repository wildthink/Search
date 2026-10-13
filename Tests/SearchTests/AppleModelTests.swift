import XCTest
#if canImport(FoundationModels)
import FoundationModels
#endif
@testable import Search

/// Apple's model on this Mac as an AI provider (AppleModel.swift): how much
/// of a page it is given, what its errors say, and — where this Mac has it
/// — an answer and a conversation too long for it.
final class AppleModelTests: XCTestCase {
    func testItIsGivenLessOfAPageThanTheOthers() {
        XCTAssertTrue(AIProvider.apple.isLocal)
        XCTAssertTrue(AIProvider.apple.isBuiltIn)
        XCTAssertEqual(AIProvider.apple.host, "this Mac")
        XCTAssertLessThan(AIProvider.apple.pageLimit, AIPage.limit)
        XCTAssertEqual(AIProvider.anthropic.pageLimit, AIPage.limit)

        let page = String(repeating: "word ", count: 4_000)
        let cut = AIPage.shaped(title: "T", url: nil, text: page, links: [], limit: AIProvider.apple.pageLimit)
        XCTAssertTrue(cut.cut)
        XCTAssertLessThanOrEqual(cut.text.count, AIProvider.apple.pageLimit + 20, "the start and the end, and the mark between")
        XCTAssertFalse(AIPage.shaped(title: "T", url: nil, text: page, links: []).cut, "20,000 characters fit the others")
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    func testItsErrorsAreSaidPlainly() {
        typealias Old = LanguageModelSession.GenerationError
        let context = Old.Context(debugDescription: "test")
        XCTAssertEqual(AppleModel.reason(Old.exceededContextWindowSize(context)), AppleModel.tooLong)
        XCTAssertEqual(AppleModel.reason(Old.guardrailViolation(context)), AppleModel.refused)
        XCTAssertEqual(AppleModel.reason(Old.unsupportedLanguageOrLocale(context)), AppleModel.language)
        XCTAssertEqual(AppleModel.reason(Old.rateLimited(context)), AppleModel.busy)
        XCTAssertEqual(AppleModel.reason(CocoaError(.fileNoSuchFile)), AppleModel.failed)
        if #available(macOS 27.0, *) {
            let over = LanguageModelError.contextSizeExceeded(.init(contextSize: 4096, tokenCount: 5000, debugDescription: "test"))
            XCTAssertEqual(AppleModel.reason(over), AppleModel.tooLong)
        }
    }

    /// Asked for real, where this Mac has the model; skipped where it doesn't.
    func testItAnswersAndSaysWhenAConversationIsTooLong() async throws {
        try XCTSkipUnless(AppleModel.state == .ready, "Apple's model isn't ready on this Mac: \(AppleModel.said)")
        var answer = ""
        for try await piece in AppleModel.stream(system: "Answer in one short sentence.",
                                                 messages: [AIMessage(role: .user, text: "What colour is the sky on a clear day?")]) {
            answer += piece
        }
        XCTAssertFalse(answer.isEmpty)

        // The conversation so far goes with the question.
        var followUp = ""
        for try await piece in AppleModel.stream(system: "Answer in one word.", messages: [
            AIMessage(role: .user, text: "Remember the word: lantern."),
            AIMessage(role: .assistant, text: "Remembered."),
            AIMessage(role: .user, text: "Which word did I ask you to remember?"),
        ]) {
            followUp += piece
        }
        XCTAssertTrue(followUp.lowercased().contains("lantern"), followUp)

        let tooMuch = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 1_500)
        do {
            for try await _ in AppleModel.stream(system: "Answer briefly.", messages: [AIMessage(role: .user, text: tooMuch)]) {}
            XCTFail("more than it holds")
        } catch {
            XCTAssertEqual(error.localizedDescription, AppleModel.tooLong)
        }
    }
    #endif
}

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// "Apple Intelligence": the model macOS keeps on this Mac (Foundation
// Models), on macOS 26 and later with Apple Intelligence turned on. Nothing
// is downloaded by Search and nothing leaves the Mac — the same promise as
// Search's own engine (AIEngine), with none of its download, on Macs that
// have it. Every use of the framework waits on macOS 26 (#available), so
// it is linked weakly, and on macOS 14 and 15, where it isn't, Search still
// opens and this provider simply isn't offered. build.sh refuses a build
// where it isn't weak.
//
// Its window is small — 4,096 tokens for the page, the question and the
// answer together — so a page is cut sooner for it (AIProvider.pageLimit),
// and a conversation that outgrows it says so rather than failing quietly.
//
// Apple's model on its servers (Private Cloud Compute) is not used here: it
// needs an entitlement Apple grants, and a build without one that asks for
// it is stopped by the framework itself (13 Oct 2026).

enum AppleModel {
    enum State: Equatable {
        case ready
        /// Apple Intelligence is off in System Settings.
        case off
        /// Its model is still being downloaded or prepared by macOS.
        case preparing
        /// This Mac can't run it.
        case ineligible
        /// Before macOS 26: no Foundation Models at all.
        case unsupported
    }

    static var state: State {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return .ready
            case .unavailable(.appleIntelligenceNotEnabled): return .off
            case .unavailable(.modelNotReady): return .preparing
            case .unavailable: return .ineligible
            }
        }
        #endif
        return .unsupported
    }

    /// What Settings says about it, by state.
    static var said: String {
        switch state {
        case .ready: return "Apple's model, kept on this Mac by macOS. Nothing leaves it"
        case .off: return "Turn on Apple Intelligence in System Settings to use it"
        case .preparing: return "macOS is still getting its model ready. Try again in a while"
        case .ineligible: return "This Mac can't run Apple's model"
        case .unsupported: return "Needs macOS 26 or later"
        }
    }

    /// The answer, a piece at a time, to the last of `messages`; the ones
    /// before it are the conversation so far.
    static func stream(system: String, messages: [AIMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            #if canImport(FoundationModels)
            guard #available(macOS 26.0, *), let last = messages.last, last.role == .user else {
                continuation.finish(throwing: AIError.unreachable(said))
                return
            }
            let task = Task {
                do {
                    let session = LanguageModelSession(model: .default, tools: [], transcript: transcript(system, Array(messages.dropLast())))
                    // Each step is the whole answer so far: handed on as
                    // what it adds, the way every other provider sends it.
                    var sent = 0
                    for try await snapshot in session.streamResponse(to: last.text) {
                        let text = snapshot.content
                        guard text.count > sent else { continue }
                        continuation.yield(String(text.dropFirst(sent)))
                        sent = text.count
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: AIError.unreachable(reason(error)))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
            #else
            continuation.finish(throwing: AIError.unreachable(said))
            #endif
        }
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func transcript(_ system: String, _ earlier: [AIMessage]) -> Transcript {
        let text = { (words: String) in [Transcript.Segment.text(Transcript.TextSegment(content: words))] }
        var entries: [Transcript.Entry] = [.instructions(Transcript.Instructions(segments: text(system), toolDefinitions: []))]
        for message in earlier {
            switch message.role {
            case .user: entries.append(.prompt(Transcript.Prompt(segments: text(message.text))))
            case .assistant: entries.append(.response(Transcript.Response(assetIDs: [], segments: text(message.text))))
            }
        }
        return Transcript(entries: entries)
    }

    /// What went wrong, said for the panel. macOS 27 names its errors
    /// anew; macOS 26 still throws the old ones.
    @available(macOS 26.0, *)
    static func reason(_ error: Error) -> String {
        if #available(macOS 27.0, *), let error = error as? LanguageModelError {
            switch error {
            case .contextSizeExceeded: return tooLong
            case .guardrailViolation, .refusal: return refused
            case .unsupportedLanguageOrLocale: return language
            case .rateLimited: return busy
            default: return failed
            }
        }
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize: return tooLong
            case .guardrailViolation, .refusal: return refused
            case .unsupportedLanguageOrLocale: return language
            case .rateLimited: return busy
            case .assetsUnavailable: return said
            default: return failed
            }
        }
        return failed
    }
    #endif

    static let tooLong = "This is more than Apple's model on this Mac can hold at once. Close the panel and ask again, or choose another provider in Settings › AI."
    static let refused = "Apple's model wouldn't answer about this page."
    static let language = "Apple's model doesn't work in this page's language yet."
    static let busy = "Apple's model is busy. Try again in a moment."
    static let failed = "Apple's model couldn't answer."
}

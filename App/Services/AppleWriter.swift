import AppKit
import Foundation
import FoundationModels
import NaturalLanguage

// Why Apple's writer didn't write. Each reads as one line where the task
// shows its errors; a chosen fallback writes instead.
enum AppleWriterIssue: Error, LocalizedError, Equatable, Sendable {
    case unavailable(CoreAppleWriterAvailability)
    case unsupportedLanguage(String?)
    case declined
    case tooLong
    // Any other generation failure (busy, rate limited…), in the system's words.
    case failed(String)
    var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        case .unavailable(let reason): return AppleWriterPresentation.error(reason)
        case .unsupportedLanguage(let name):
            return name.map { L10n.format("Apple’s model can’t write in %@.", $0) }
                ?? L10n.tr("Apple’s model can’t write in this language.")
        case .declined: return L10n.tr("Apple’s model declined this text.")
        case .tooLong: return L10n.tr("This text is too long to refine in one request.")
        }
    }
}

// The model behind the writer. The system one is Apple's; tests use fakes.
struct AppleWriterBackend: Sendable {
    var availability: @Sendable () -> CoreAppleWriterAvailability
    // Whether the model writes this language (an ISO 639 code such as "en").
    var supports: @Sendable (String) -> Bool
    // One request: the instructions, a short lead naming the task, then the text.
    var respond: @Sendable (String, String, String) async throws -> String
    // Tokens the model reads at once, instructions and answer included.
    var contextSize: @Sendable () -> Int = { CoreAppleWriterPlan.defaultContextSize }
    // The model's own count where it has one; otherwise a careful estimate.
    var count: @Sendable (String) async -> Int = { CoreAppleWriterPlan.estimatedTokens($0) }
    // The same request after one worked example, as a prior turn.
    // Edit with voice: the request after an optional worked example, in the
    // session warmed while the person spoke.
    var respondEdit: (@Sendable (String, CoreVoiceEditExamples.Example?, String, String) async throws -> String)? = nil

    static let system = AppleWriterBackend(
        availability: { AppleWriterSystem.availability() },
        supports: { AppleWriterSystem.supports($0) },
        respond: { try await AppleWriterSystem.respond(instructions: $0, lead: $1, text: $2) },
        contextSize: { AppleWriterSystem.contextSize() },
        count: { await AppleWriterSystem.count($0) },
        respondEdit: { try await AppleWriterSystem.respond(instructions: $0, lead: $2, text: $3, example: $1) })
}

enum AppleWriter {
    // Writes the text as the style asks. Text that fits the model's window is
    // one request; longer text in a format written paragraph by paragraph goes
    // in parts sized to leave room for their answers, each told how the part
    // before it ended, joined in order. Nothing is returned until every part is
    // written, so a failure never leaves half a result. Nothing is sent when
    // the model can't run or doesn't write the output language.
    static func write(
        text: String, style: RewriteStyle, requirements: CoreWritingRequirements, instructions: String?,
        backend: AppleWriterBackend = .system
    ) async throws -> String {
        let availability = backend.availability()
        guard availability == .available else { throw AppleWriterIssue.unavailable(availability) }
        let language = outputLanguage(requirements: requirements, text: text)
        if let language, !backend.supports(language.id) { throw AppleWriterIssue.unsupportedLanguage(language.name) }
        // A small model keeps the text's language only when it is named.
        let instruction = CoreAppleWriterPrompt.instruction(
            style: style, requirements: requirements, instructions: instructions, language: language?.name,
            languageID: language?.id)
        let instructionTokens = await backend.count(instruction)
        let budget = CoreAppleWriterPlan.inputBudget(
            contextSize: backend.contextSize(), instructionTokens: instructionTokens)
        let tokens = await backend.count(text)
        // A small model follows a short lead beside the text more closely than long instructions.
        let lead = CoreAppleWriterPlan.lead(language: language?.name)
        // The speaker's final choice must survive; otherwise write once more keeping everything said.
        let safe = CoreAppleWriterPrompt.instruction(
            style: style, requirements: requirements, instructions: instructions, language: language?.name,
            languageID: language?.id, keepingCorrections: true)
        // Then Cleaned up, keeping everything said: plain, but nothing lost.
        let plain = CoreAppleWriterPrompt.instruction(
            style: .light, requirements: requirements, language: language?.name, languageID: language?.id,
            keepingCorrections: true)
        // A translation shares no words with what was said, so the word checks can't apply.
        let translating = requirements.outputLanguage != nil && language?.id != Self.textLanguage(text)
        // An answer that missed a correction ("tuesday no wednesday" written "Tuesday") is asked for once
        // more, with the correction named in the speaker's own words; once per text, never per attempt.
        let guarded: (String, String, Bool) async throws -> String = { instruction, text, named in
            var queue: [(prompt: String, format: RewriteStyle, hint: String?)] = [
                (instruction, style, nil), (safe, style, nil), (plain, .light, nil)
            ]
            var hinted = named
            while !queue.isEmpty {
                let (prompt, format, hint) = queue.removeFirst()
                var written = CoreAppleWriterCorrection.realBreaks(
                    try await backend.respond(prompt, hint.map { lead + " " + $0 } ?? lead, text), input: text)
                if format == .bullets { written = CoreAppleWriterCorrection.tidyBullets(written) }
                if translating || CoreAppleWriterCorrection.keeps(input: text, output: written, style: format) {
                    return written
                }
                if !hinted, prompt == instruction,
                    let found = CoreAppleWriterCorrection.correctionLead(input: text, output: written)
                {
                    hinted = true
                    queue.insert((instruction, style, found), at: 0)
                }
            }
            // Losing what was meant, or who it's for, is worse than any wording: then the words stay as
            // said, made readable (no filler, a capital, a final mark).
            return CoreAppleWriterCorrection.readable(text)
        }
        if tokens <= budget {
            var hinted = false
            // First, the format after one worked example in the text's language: a dictation and
            // how a strong writer wrote it in this format.
            if !translating, CorePresetInstructions.normalized(instructions) == nil,
                let example = CoreFormatExamples.example(style: style, languageID: language?.id, lead: lead),
                let respondEdit = backend.respondEdit
            {
                var hint: String?
                repeat {
                    var written = CoreAppleWriterCorrection.realBreaks(
                        try await respondEdit(instruction, example, hint.map { lead + " " + $0 } ?? lead, text),
                        input: text)
                    if style == .bullets { written = CoreAppleWriterCorrection.tidyBullets(written) }
                    if CoreAppleWriterCorrection.keeps(input: text, output: written, style: style) { return written }
                    hint = hinted ? nil : CoreAppleWriterCorrection.correctionLead(input: text, output: written)
                    hinted = true
                } while hint != nil
            }
            // Email keeps the speaker's words: their text cleaned up, laid out as a letter by code.
            // Only when nothing else asks for the model: personal instructions and a sign-off name need it.
            if style == .email, requirements.outputLanguage == nil, requirements.signOffName == nil,
                CorePresetInstructions.normalized(instructions) == nil
            {
                let light = CoreAppleWriterPrompt.instruction(
                    style: .light, requirements: requirements, language: language?.name, languageID: language?.id)
                let cleaned = CoreAppleWriterCorrection.realBreaks(
                    try await backend.respond(light, lead, text), input: text)
                if CoreAppleWriterCorrection.keeps(input: text, output: cleaned, style: .light),
                    let letter = CoreAppleWriterLetter.layout(cleaned, names: CoreAppleWriterCorrection.names(in: text))
                {
                    return letter
                }
            }
            return try await guarded(instruction, text, hinted)
        }
        // Letters and other framed formats read as one whole; they don't split.
        guard CoreAppleWriterPlan.splits(style) else { throw AppleWriterIssue.tooLong }
        // Parts also carry how the part before them ended.
        let partBudget = CoreAppleWriterPlan.inputBudget(
            contextSize: backend.contextSize(),
            instructionTokens: instructionTokens + CoreAppleWriterPlan.continuityTokens)
        let limit = max(1, text.count * partBudget / max(tokens, 1))
        var output = ""
        var previous: String?
        var queue = CoreAppleWriterPlan.pieces(text, limit: limit)[...]
        while let piece = queue.popFirst() {
            try Task.checkCancellation()
            if piece.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                output += piece.text + piece.separator
                continue
            }
            // A part denser than the text as a whole is split again until it fits.
            let pieceTokens = await backend.count(piece.text)
            if pieceTokens > partBudget {
                let smaller = min(piece.text.count - 1, piece.text.count * partBudget / pieceTokens)
                guard smaller > 0 else { throw AppleWriterIssue.tooLong }
                var parts = CoreAppleWriterPlan.pieces(piece.text, limit: smaller)
                parts[parts.count - 1].separator += piece.separator
                queue = parts[...] + queue
                continue
            }
            let written = try await guarded(
                CoreAppleWriterPlan.continuing(instruction, after: previous), piece.text, false
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
            // A part cut inside a paragraph keeps the spaces around it.
            let leading = piece.text.prefix { $0.isWhitespace }
            let trailing = String(piece.text.reversed().prefix { $0.isWhitespace }.reversed())
            output += leading + written + trailing + piece.separator
            previous = written
        }
        return output
    }

    // Edit with voice on Apple's model: one request with the same instruction
    // and data as any writer, only when it fits the model's window. Names in
    // the selection stay unless the instruction names them; one stricter try
    // keeps them, otherwise the edit is declined so a chosen writer can do it.
    static func voiceEdit(
        source: String, instruction: String, terms: [CoreVocabularyTranslationTerm],
        backend: AppleWriterBackend = .system
    ) async throws -> String {
        let availability = backend.availability()
        guard availability == .available else { throw AppleWriterIssue.unavailable(availability) }
        let language = outputLanguage(requirements: .standard, text: source)
        if let language, !backend.supports(language.id) { throw AppleWriterIssue.unsupportedLanguage(language.name) }
        try CoreVoiceEditPrompt.validateInputs(source: source, instruction: instruction)
        // A small model follows a short change before the text more closely
        // than the text and request packed together.
        let spellings = terms.map(\.target).filter { !$0.isEmpty }
        let lead =
            CoreVoiceEditPrompt.localLead(instruction, language: language?.name, languageID: language?.id)
            + (spellings.isEmpty ? "" : "\nSpell these as written: " + spellings.joined(separator: ", "))
        let budget = CoreAppleWriterPlan.inputBudget(
            contextSize: backend.contextSize(),
            instructionTokens: await backend.count(CoreVoiceEditPrompt.localInstruction) + (await backend.count(lead)))
        guard await backend.count(source) <= budget else { throw AppleWriterIssue.tooLong }
        let kept = CoreAppleWriterCorrection.names(in: source).filter { !instruction.contains($0) }
        // When the first answer changed nothing, one firmer try; an edit that
        // still changes nothing returns the text as it was.
        // Feedback gets one worked example in the text's language, where there is one.
        let example = CoreVoiceEditExamples.example(for: instruction, languageID: language?.id)
        func ask(_ prompt: String) async throws -> String {
            if let respondEdit = backend.respondEdit { return try await respondEdit(prompt, example, lead, source) }
            return try await backend.respond(prompt, lead, source)
        }
        // One more try at most: when the answer changed nothing, or a request to shorten
        // barely shortened. An answer that only repeated the request means it wasn't
        // about the text, so the text stays.
        let original = source.trimmingCharacters(in: .whitespacesAndNewlines)
        var prompt = CoreVoiceEditPrompt.localInstruction
        var fallback: String?
        for attempt in 0..<2 {
            try Task.checkCancellation()
            let raw = CoreAppleWriterCorrection.realBreaks(try await ask(prompt), input: source)
            let written = CoreVoiceEditPrompt.cleanedResult(source: source, instruction: instruction, result: raw)
            let usable =
                (try? CoreVoiceEditPrompt.validateResult(source: source, instruction: instruction, result: written))
                != nil && kept.allSatisfy({ written.contains($0) })
            guard usable else {
                if attempt == 0 {
                    prompt = CoreVoiceEditPrompt.localRetry
                    continue
                }
                break
            }
            if attempt == 1 { return written == original ? (fallback ?? source) : written }
            switch CoreVoiceEditPrompt.followUp(source: source, instruction: instruction, raw: raw, cleaned: written) {
            case .accept: return written
            case .keepSource: return source
            case .retry(let next):
                fallback = written == original ? source : written
                prompt = next
            }
        }
        if let fallback { return fallback }
        throw AppleWriterIssue.declined
    }

    // The language the result is written in: the row's, else the text's own.
    static func textLanguage(_ text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(2_000)))
        return recognizer.dominantLanguage.map { Language.canonicalCode($0.rawValue) }
    }

    static func outputLanguage(requirements: CoreWritingRequirements, text: String) -> (id: String, name: String)? {
        if let name = requirements.outputLanguage {
            let id = Language.catalog.first { $0.subtitle == name }?.id ?? name
            return (Language.canonicalCode(id), name)
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(2_000)))
        guard let code = recognizer.dominantLanguage?.rawValue else { return nil }
        let id = Language.canonicalCode(code)
        return (
            id,
            Language.catalog.first { $0.id == id }?.subtitle ?? Locale(identifier: "en").localizedString(
                forIdentifier: code) ?? code
        )
    }
}

// What Settings shows; tests and renders set another state.
@MainActor enum AppleWriterStatus {
    static var availability: () -> CoreAppleWriterAvailability = AppleWriterSystem.availability
}

// The wording for each state, shared by Write with, the chooser and errors.
enum AppleWriterPresentation {
    static func status(_ availability: CoreAppleWriterAvailability) -> String? {
        switch availability {
        case .available: return nil
        case .deviceNotEligible: return L10n.tr("Not available on this Mac")
        case .intelligenceOff: return L10n.tr("Apple Intelligence is off")
        case .modelNotReady: return L10n.tr("Apple’s model is downloading")
        case .regionUnavailable: return L10n.tr("Apple Intelligence isn’t available in your region")
        case .unknown: return L10n.tr("Not available on this Mac")
        }
    }
    static func error(_ availability: CoreAppleWriterAvailability) -> String {
        switch availability {
        case .intelligenceOff: return L10n.tr("Apple Intelligence is off")
        case .modelNotReady: return L10n.tr("Apple’s model is still downloading. Try again soon.")
        default: return L10n.tr("Apple’s model isn’t available on this Mac.")
        }
    }
    // Apple Intelligence & Siri in System Settings.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!
}

enum AppleWriterSystem {
    static func availability() -> CoreAppleWriterAvailability {
        let reported: CoreAppleWriterAvailability
        switch SystemLanguageModel.default.availability {
        case .available: reported = .available
        case .unavailable(.deviceNotEligible): reported = .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled): reported = .intelligenceOff
        case .unavailable(.modelNotReady): reported = .modelNotReady
        case .unavailable: reported = .unknown
        }
        return .resolve(reported, region: Locale.current.region?.identifier)
    }
    static func supports(_ code: String) -> Bool {
        let wanted = Locale.Language(identifier: code).languageCode?.identifier
        return SystemLanguageModel.default.supportedLanguages.contains { $0.languageCode?.identifier == wanted }
    }
    static func contextSize() -> Int {
        if #available(macOS 27.0, *) { return SystemLanguageModel.default.contextSize }
        return CoreAppleWriterPlan.defaultContextSize
    }
    static func count(_ text: String) async -> Int {
        if #available(macOS 26.4, *), let value = try? await SystemLanguageModel.default.tokenCount(for: text) {
            return value
        }
        return CoreAppleWriterPlan.estimatedTokens(text)
    }
    // macOS 26 reports generation errors as LanguageModelSession.GenerationError,
    // macOS 27 as LanguageModelError. Both are enums whose case names say what
    // happened, so they are read by name and neither type is named here.
    static func issue(_ error: Error) -> Error {
        switch Mirror(reflecting: error).children.first?.label ?? "" {
        case "exceededContextWindowSize", "contextSizeExceeded": return AppleWriterIssue.tooLong
        case "guardrailViolation", "refusal": return AppleWriterIssue.declined
        case "unsupportedLanguageOrLocale": return AppleWriterIssue.unsupportedLanguage(nil)
        case "assetsUnavailable": return AppleWriterIssue.unavailable(.modelNotReady)
        // Every other generation error is still Apple's model not writing, so
        // a chosen fallback writer runs; cancellation stays cancellation.
        default: return error is CancellationError ? error : AppleWriterIssue.failed(error.localizedDescription)
        }
    }
    static func respond(
        instructions: String, lead: String, text: String, example: CoreVoiceEditExamples.Example? = nil
    ) async throws -> String {
        var session =
            AppleWriterWarmSession.shared.take(instructions) ?? LanguageModelSession(instructions: instructions)
        if let example {
            func segment(_ value: String) -> Transcript.Segment { .text(Transcript.TextSegment(content: value)) }
            session = LanguageModelSession(
                transcript: Transcript(entries: [
                    .instructions(Transcript.Instructions(segments: [segment(instructions)], toolDefinitions: [])),
                    .prompt(Transcript.Prompt(segments: [segment(example.lead + "\n\n" + example.text)])),
                    .response(Transcript.Response(assetIDs: [], segments: [segment(example.result)]))
                ]))
        }
        do {
            return try await session.respond(to: lead + "\n\n" + text).content
        } catch {
            throw issue(error)
        }
    }
}

// One Apple session made while the person is still speaking, so the model is
// loaded, and its instructions read, by the time their words are. Taken once by
// the next request with the same instructions within two minutes; otherwise the
// warm-up has still loaded the model.
final class AppleWriterWarmSession: @unchecked Sendable {
    static let shared = AppleWriterWarmSession()
    private let lock = NSLock()
    private var session: AnyObject?
    private var instructions = ""
    private var made = Date.distantPast

    // Not while the model is unavailable or still downloading, in Low Power Mode, or
    // when the Mac is hot: then the request simply loads the model when it comes.
    func prewarm(_ instructions: String) {
        let process = ProcessInfo.processInfo
        guard SystemLanguageModel.default.availability == .available, !process.isLowPowerModeEnabled,
            process.thermalState == .nominal || process.thermalState == .fair
        else { return }
        let session = LanguageModelSession(instructions: instructions)
        session.prewarm()
        let made = Date()
        lock.withLock {
            self.session = session
            self.instructions = instructions
            self.made = made
        }
        // Unused, it lets go after two minutes, so the system can unload the model.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 120) { [weak self] in
            self?.lock.withLock { if self?.made == made { self?.session = nil } }
        }
    }
    func take(_ instructions: String) -> LanguageModelSession? {
        lock.withLock {
            defer { session = nil }
            guard instructions == self.instructions, Date().timeIntervalSince(made) < 120 else { return nil }
            return session as? LanguageModelSession
        }
    }
}

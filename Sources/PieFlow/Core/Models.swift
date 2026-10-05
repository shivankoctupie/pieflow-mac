import Foundation

enum AppCategory: String, Codable, CaseIterable, Identifiable {
    case aiPrompts, personal, work, email, documents, other
    var id: String { rawValue }

    var label: String {
        switch self {
        case .aiPrompts: return "AI prompts"
        case .personal: return "Personal messages"
        case .work: return "Work messages"
        case .email: return "Emails"
        case .documents: return "Documents"
        case .other: return "Other tasks"
        }
    }

    var icon: String {
        switch self {
        case .aiPrompts: return "cpu"
        case .personal: return "bubble.left"
        case .work: return "text.bubble"
        case .email: return "envelope"
        case .documents: return "doc.text"
        case .other: return "infinity"
        }
    }

    static func from(bundleID: String?, appName: String?) -> AppCategory {
        let b = (bundleID ?? "").lowercased()
        let n = (appName ?? "").lowercased()
        let ai = ["claude", "chatgpt", "openai", "cursor", "vscode", "com.microsoft.vscode", "terminal", "iterm", "warp", "ghostty", "zed", "perplexity", "windsurf", "codex", "xcode"]
        let personal = ["whatsapp", "mobilesms", "messages", "telegram", "discord", "signal", "messenger", "instagram"]
        let work = ["slack", "teams", "zoom", "linear", "lark", "webex"]
        let mail = ["mail", "outlook", "spark", "superhuman", "airmail", "mimestream"]
        let docs = ["notes", "pages", "word", "notion", "obsidian", "bear", "textedit", "craft", "docs", "keynote", "powerpoint"]
        func hit(_ list: [String]) -> Bool { list.contains { b.contains($0) || n.contains($0) } }
        if hit(ai) { return .aiPrompts }
        if hit(personal) { return .personal }
        if hit(work) { return .work }
        if hit(mail) { return .email }
        if hit(docs) { return .documents }
        return .other
    }
}

struct DictationEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var date = Date()
    var rawText: String
    var text: String
    var appName: String?
    var bundleID: String?
    var category: AppCategory = .other
    var durationSec: Double
    var engine: String
    var audioFile: String?
    var flagged = false

    var wordCount: Int { text.split { $0.isWhitespace || $0.isNewline }.count }
}

struct DictionaryWord: Codable, Identifiable, Hashable {
    var id = UUID()
    var word: String
    /// Optional "heard as" variants that get replaced with `word`.
    var misheard: [String] = []
}

struct Snippet: Codable, Identifiable, Hashable {
    var id = UUID()
    var trigger: String
    var expansion: String
}

struct Transform: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var summary: String
    var prompt: String
    var hotkeyDigit: Int?

    static let defaults: [Transform] = [
        Transform(name: "Polish", summary: "Improve clarity and conciseness",
                  prompt: "Rewrite the text to be clearer and more concise. Keep the author's voice, meaning and language. Fix grammar and punctuation. Do not add new ideas.",
                  hotkeyDigit: 1),
        Transform(name: "Prompt Engineer", summary: "Constructs optimal prompts",
                  prompt: "Turn the text into a well structured prompt for an AI assistant. State the goal, the relevant context, constraints and the expected output format. Keep every requirement the author mentioned. Output only the prompt.",
                  hotkeyDigit: 2),
    ]
}

enum StyleTone: String, Codable, CaseIterable, Identifiable {
    case formal, casual, veryCasual
    var id: String { rawValue }
    var label: String {
        switch self {
        case .formal: return "Formal"
        case .casual: return "Casual"
        case .veryCasual: return "Very casual"
        }
    }
    var example: String {
        switch self {
        case .formal: return "Hey, are you free for lunch tomorrow? Let's do 12 if that works for you."
        case .casual: return "Hey are you free for lunch tomorrow? Let's do 12 if that works for you"
        case .veryCasual: return "hey are you free for lunch tomorrow? let's do 12 if that works for you"
        }
    }
    var instruction: String {
        switch self {
        case .formal: return "Use proper capitalization and full punctuation."
        case .casual: return "Use normal capitalization and light punctuation. Drop the final period on short messages."
        case .veryCasual: return "Use all lowercase and minimal punctuation, like a quick text message. Keep question marks."
        }
    }
}

struct Note: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String = "Untitled"
    var body: String = ""
    var updated = Date()
}

struct TranscriptSegment: Codable, Hashable {
    var start: Double
    var end: Double
    var speaker: String
    var text: String
}

struct Meeting: Codable, Identifiable, Hashable {
    enum Status: String, Codable { case recording, processing, ready, failed }
    var id = UUID()
    var title: String
    var started = Date()
    var durationSec: Double = 0
    var status: Status = .recording
    var segments: [TranscriptSegment] = []
    var summary: String = ""
    var errorMessage: String?
    var audioFolder: String?

    var transcriptText: String {
        segments.map { "[\(Meeting.clock($0.start))] \($0.speaker): \($0.text)" }.joined(separator: "\n")
    }

    static func clock(_ s: Double) -> String {
        let t = Int(s)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60)
                         : String(format: "%02d:%02d", t / 60, t % 60)
    }
}

enum STTProvider: String, Codable, CaseIterable, Identifiable {
    case grok, groq, local
    var id: String { rawValue }
    var label: String {
        switch self {
        case .grok: return "Grok (xAI)"
        case .groq: return "Groq"
        case .local: return "Local Whisper"
        }
    }
}

enum HotkeyChoice: String, Codable, CaseIterable, Identifiable {
    case fn, rightOption, rightCommand, rightControl
    var id: String { rawValue }
    var label: String {
        switch self {
        case .fn: return "fn"
        case .rightOption: return "Right ⌥"
        case .rightCommand: return "Right ⌘"
        case .rightControl: return "Right ⌃"
        }
    }
    var keyCode: Int64 {
        switch self {
        case .fn: return 63
        case .rightOption: return 61
        case .rightCommand: return 54
        case .rightControl: return 62
        }
    }
}

struct LocalModel: Identifiable, Hashable {
    let id: String
    let label: String
    let sizeMB: Int
    var file: String { "ggml-\(id).bin" }
    var url: URL { URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(file)")! }

    static let all: [LocalModel] = [
        LocalModel(id: "base.en", label: "Base (English, fast)", sizeMB: 142),
        LocalModel(id: "small.en", label: "Small (English, better)", sizeMB: 466),
        LocalModel(id: "large-v3-turbo-q5_0", label: "Large v3 Turbo (multilingual, best)", sizeMB: 547),
    ]
}

struct Settings: Codable {
    var onboarded = false
    var userName = NSFullUserName().split(separator: " ").first.map(String.init) ?? "there"
    var hotkey: HotkeyChoice = .fn
    var microphoneUID: String?            // nil = system default
    var language = "en"                   // "auto" or ISO code
    var providerOrder: [STTProvider] = [.grok, .groq, .local]
    var localModel = "base.en"
    var aiCleanup = true
    var cleanupModelGroq = "openai/gpt-oss-120b"
    var cleanupModelXAI = "grok-4-fast-non-reasoning"
    var launchAtLogin = false
    var showFlowBar = true
    var showInDock = true
    var sounds = true
    var muteWhileDictating = false
    var voiceIsolation = true
    var transformsEnabled = true
    var autoApplyTransform = false
    var autoApplyTransformID: UUID?
    var styles: [String: StyleTone] = [
        AppCategory.personal.rawValue: .casual,
        AppCategory.work.rawValue: .formal,
        AppCategory.email.rawValue: .formal,
        AppCategory.other.rawValue: .formal,
    ]
    var keepAudioDays = 7
    var notetakerSystemAudio = true
    var dismissedHero: [String] = []
    var scratchpadInFlowBar = false

    init() {}

    // Decode tolerantly so new fields never wipe old settings.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: k)) ?? nil) ?? def }
        onboarded = v(.onboarded, d.onboarded)
        userName = v(.userName, d.userName)
        hotkey = v(.hotkey, d.hotkey)
        microphoneUID = v(.microphoneUID, d.microphoneUID)
        language = v(.language, d.language)
        providerOrder = v(.providerOrder, d.providerOrder)
        localModel = v(.localModel, d.localModel)
        aiCleanup = v(.aiCleanup, d.aiCleanup)
        cleanupModelGroq = v(.cleanupModelGroq, d.cleanupModelGroq)
        // Groq retired its Llama chat models; move old installs to the current default.
        if cleanupModelGroq.hasPrefix("llama-") { cleanupModelGroq = d.cleanupModelGroq }
        cleanupModelXAI = v(.cleanupModelXAI, d.cleanupModelXAI)
        launchAtLogin = v(.launchAtLogin, d.launchAtLogin)
        showFlowBar = v(.showFlowBar, d.showFlowBar)
        showInDock = v(.showInDock, d.showInDock)
        sounds = v(.sounds, d.sounds)
        muteWhileDictating = v(.muteWhileDictating, d.muteWhileDictating)
        voiceIsolation = v(.voiceIsolation, d.voiceIsolation)
        transformsEnabled = v(.transformsEnabled, d.transformsEnabled)
        autoApplyTransform = v(.autoApplyTransform, d.autoApplyTransform)
        autoApplyTransformID = v(.autoApplyTransformID, d.autoApplyTransformID)
        styles = v(.styles, d.styles)
        keepAudioDays = v(.keepAudioDays, d.keepAudioDays)
        notetakerSystemAudio = v(.notetakerSystemAudio, d.notetakerSystemAudio)
        dismissedHero = v(.dismissedHero, d.dismissedHero)
        scratchpadInFlowBar = v(.scratchpadInFlowBar, d.scratchpadInFlowBar)
    }
}

struct APIKeys: Codable {
    var xai = ""
    var groq = ""
}

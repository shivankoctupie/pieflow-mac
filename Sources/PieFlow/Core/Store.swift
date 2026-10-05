import Foundation
import Combine

enum Paths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = base.appendingPathComponent("PieFlow", isDirectory: true)
        if let custom = ProcessInfo.processInfo.environment["PIEFLOW_HOME"], !custom.isEmpty {
            dir = URL(fileURLWithPath: custom, isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    static func dir(_ name: String) -> URL {
        let d = support.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static var audio: URL { dir("audio") }
    static var models: URL { dir("models") }
    static var meetings: URL { dir("meetings") }
    static var logFile: URL { support.appendingPathComponent("pieflow.log") }
}

enum Log {
    private static let queue = DispatchQueue(label: "pieflow.log")
    static func write(_ msg: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(msg)\n"
        queue.async {
            if let h = try? FileHandle(forWritingTo: Paths.logFile) {
                h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
            } else {
                try? line.data(using: .utf8)!.write(to: Paths.logFile)
            }
        }
        #if DEBUG
        print(msg)
        #endif
    }
}

final class Store: ObservableObject {
    static let shared = Store()

    @Published var settings: Settings { didSet { save("settings.json", settings) } }
    @Published var keys: APIKeys { didSet { save("keys.json", keys, secret: true) } }
    @Published var history: [DictationEntry] { didSet { save("history.json", history) } }
    @Published var dictionary: [DictionaryWord] { didSet { save("dictionary.json", dictionary) } }
    @Published var snippets: [Snippet] { didSet { save("snippets.json", snippets) } }
    @Published var transforms: [Transform] { didSet { save("transforms.json", transforms) } }
    @Published var notes: [Note] { didSet { save("notes.json", notes) } }
    @Published var meetings: [Meeting] { didSet { save("meetings.json", meetings) } }
    @Published var fixesCount: Int { didSet { UserDefaults.standard.set(fixesCount, forKey: "fixesCount") } }

    private var pending: [String: DispatchWorkItem] = [:]
    private let ioQueue = DispatchQueue(label: "pieflow.store")

    private init() {
        settings = Store.load("settings.json") ?? Settings()
        keys = Store.load("keys.json") ?? APIKeys()
        history = Store.load("history.json") ?? []
        dictionary = Store.load("dictionary.json") ?? []
        snippets = Store.load("snippets.json") ?? []
        transforms = Store.load("transforms.json") ?? Transform.defaults
        notes = Store.load("notes.json") ?? []
        meetings = Store.load("meetings.json") ?? []
        fixesCount = UserDefaults.standard.integer(forKey: "fixesCount")
        // A meeting that was recording when the app quit can never resume.
        for i in meetings.indices where meetings[i].status == .recording || meetings[i].status == .processing {
            meetings[i].status = .failed
            meetings[i].errorMessage = "PieFlow quit before this meeting finished processing."
        }
    }

    static func load<T: Decodable>(_ name: String) -> T? {
        let url = Paths.support.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        do { return try dec.decode(T.self, from: data) } catch {
            Log.write("load \(name) failed: \(error)")
            try? FileManager.default.copyItem(at: url, to: url.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))"))
            return nil
        }
    }

    private func save<T: Encodable>(_ name: String, _ value: T, secret: Bool = false) {
        pending[name]?.cancel()
        let item = DispatchWorkItem { [ioQueue] in
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? enc.encode(value) else { return }
            ioQueue.async {
                let url = Paths.support.appendingPathComponent(name)
                try? data.write(to: url, options: .atomic)
                if secret { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
            }
        }
        pending[name] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    func flush() {
        for (_, item) in pending { item.perform() }
        pending.removeAll()
        ioQueue.sync {}
    }

    // MARK: derived stats

    var totalWords: Int { history.reduce(0) { $0 + $1.wordCount } }

    var averageWPM: Int {
        let timed = history.filter { $0.durationSec > 1.5 && $0.wordCount > 2 }
        let words = timed.reduce(0) { $0 + $1.wordCount }
        let secs = timed.reduce(0.0) { $0 + $1.durationSec }
        guard secs > 0 else { return 0 }
        return Int((Double(words) / secs * 60).rounded())
    }

    var activeDays: Set<Date> {
        let cal = Calendar.current
        return Set(history.map { cal.startOfDay(for: $0.date) } + meetings.map { cal.startOfDay(for: $0.started) })
    }

    var currentStreak: Int {
        let cal = Calendar.current
        var day = cal.startOfDay(for: Date())
        let days = activeDays
        if !days.contains(day) { day = cal.date(byAdding: .day, value: -1, to: day)! }
        var n = 0
        while days.contains(day) { n += 1; day = cal.date(byAdding: .day, value: -1, to: day)! }
        return n
    }

    var longestStreak: Int {
        let cal = Calendar.current
        let days = activeDays.sorted()
        var best = 0, run = 0
        var prev: Date?
        for d in days {
            if let p = prev, cal.date(byAdding: .day, value: 1, to: p) == d { run += 1 } else { run = 1 }
            best = max(best, run); prev = d
        }
        return best
    }

    var wordsThisMonthChange: Int? {
        let cal = Calendar.current
        let now = Date()
        guard let startThis = cal.date(from: cal.dateComponents([.year, .month], from: now)),
              let startPrev = cal.date(byAdding: .month, value: -1, to: startThis) else { return nil }
        let this = history.filter { $0.date >= startThis }.reduce(0) { $0 + $1.wordCount }
        let prev = history.filter { $0.date >= startPrev && $0.date < startThis }.reduce(0) { $0 + $1.wordCount }
        guard prev > 0 else { return nil }
        return Int((Double(this - prev) / Double(prev) * 100).rounded())
    }

    func pruneAudio() {
        let cutoff = Date().addingTimeInterval(-Double(settings.keepAudioDays) * 86400)
        for i in history.indices where history[i].date < cutoff {
            if let f = history[i].audioFile {
                try? FileManager.default.removeItem(at: Paths.audio.appendingPathComponent(f))
                history[i].audioFile = nil
            }
        }
    }

    func eraseAll() {
        history = []; notes = []; meetings = []; fixesCount = 0
        for d in [Paths.audio, Paths.meetings] { try? FileManager.default.removeItem(at: d) }
    }
}

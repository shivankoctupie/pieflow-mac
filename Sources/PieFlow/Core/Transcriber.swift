import Foundation

struct TranscriptionResult {
    var text: String
    var segments: [TranscriptSegment]
    var engine: String
}

struct PieError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

struct Multipart {
    let boundary = "PieFlow-\(UUID().uuidString)"
    var body = Data()

    mutating func field(_ name: String, _ value: String) {
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
    }
    mutating func file(_ name: String, filename: String, mime: String, data: Data) {
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n".data(using: .utf8)!)
    }
    func finished() -> Data { var b = body; b.append("--\(boundary)--\r\n".data(using: .utf8)!); return b }
}

enum HTTP {
    /// Tests set this to make every request stall, the way a bad connection does.
    static var stallForTests: TimeInterval = 0
    /// Tests set this to make every request fail at once, as if the Mac were offline.
    static var offlineForTests = false

    static func send(_ req: URLRequest) async throws -> [String: Any] {
        if offlineForTests { throw URLError(.notConnectedToInternet) }
        if stallForTests > 0 { try await Task.sleep(nanoseconds: UInt64(stallForTests * 1e9)) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(code) else {
            var msg = String(data: data, encoding: .utf8) ?? ""
            if let e = obj?["error"] as? [String: Any], let m = e["message"] as? String { msg = m }
            else if let m = obj?["error"] as? String { msg = m }
            throw PieError("HTTP \(code): \(msg.prefix(300))")
        }
        guard let obj else { throw PieError("Unreadable response from server") }
        return obj
    }
}

/// A hard limit on the whole of an async call. `URLRequest.timeoutInterval` only measures silence
/// between packets, so a slow trickle can run far past it.
enum Deadline {
    static func run<T>(_ seconds: TimeInterval, _ work: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
                throw PieError(String(format: "no answer in %.1f s", seconds))
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}

/// Remembers that a cloud service just stalled or failed, so the next dictation does not wait on it
/// again. The mark wears off by itself, and a good answer clears it. A network failure counts against
/// everything on that service; an answer like "rate limited" counts only against the part that got it
/// (`use` is "stt" or "chat"), because the other part may be fine.
enum CloudHealth {
    private static let lock = NSLock()
    private static var slowUntil: [String: Date] = [:]

    static func markSlow(_ service: String, use: String, after error: Error? = nil, for seconds: TimeInterval = 30) {
        let wholeService = error == nil || error is URLError
        lock.lock(); slowUntil[wholeService ? service : "\(service)/\(use)"] = Date().addingTimeInterval(seconds); lock.unlock()
    }
    static func markOK(_ service: String, use: String) {
        lock.lock(); slowUntil[service] = nil; slowUntil["\(service)/\(use)"] = nil; lock.unlock()
    }
    static func isSlow(_ service: String, use: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        return (slowUntil[service] ?? .distantPast) > now || (slowUntil["\(service)/\(use)"] ?? .distantPast) > now
    }
}

extension STTProvider {
    /// The service behind the engine, shared with AI cleanup: Groq transcribes and polishes from one host.
    var service: String { self == .grok ? "xai" : rawValue }
}

final class Transcriber {
    let store: Store
    init(store: Store) { self.store = store }

    var localWhisperBinary: URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("bin/whisper-cli"),
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("../../Assets/bin/whisper-cli").standardized,
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Assets/bin/whisper-cli"),
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func localModelURL(_ id: String? = nil) -> URL? {
        let model = LocalModel.all.first { $0.id == (id ?? store.settings.localModel) } ?? LocalModel.all[0]
        let url = Paths.models.appendingPathComponent(model.file)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        // Any downloaded model beats no model.
        for m in LocalModel.all {
            let u = Paths.models.appendingPathComponent(m.file)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    /// The first whisper run on a Mac compiles Metal shaders (10 to 15 s). Do it in the background at launch.
    func warmUpLocal() {
        guard isAvailable(.local) else { return }
        Task.detached(priority: .utility) { [self] in
            _ = try? await self.local(WAV.encode([Float](repeating: 0, count: 8000)))
            Log.write("local whisper warmed up")
        }
    }

    func isAvailable(_ p: STTProvider) -> Bool {
        switch p {
        case .grok: return !store.keys.xai.isEmpty
        case .groq: return !store.keys.groq.isEmpty
        case .local: return localWhisperBinary != nil && localModelURL() != nil
        }
    }

    var vocabulary: [String] { store.dictionary.map(\.word).filter { !$0.isEmpty } }

    /// Tries providers in the user's order, falling back on any failure.
    /// Opens (or refreshes) the HTTPS connection to the first cloud provider so the transcription
    /// request at key release does not pay for DNS plus TLS. Called on every key press.
    private var lastWarm = Date.distantPast
    func warmConnection() {
        guard Date().timeIntervalSince(lastWarm) > 15 else { return }
        lastWarm = Date()
        let url: URL
        if !store.keys.groq.isEmpty, store.settings.providerOrder.first(where: isAvailable) == .groq {
            url = URL(string: "https://api.groq.com/openai/v1/models")!
        } else if !store.keys.xai.isEmpty, store.settings.providerOrder.first(where: isAvailable) == .grok {
            url = URL(string: "https://api.x.ai/v1/models")!
        } else { return }
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.httpMethod = "HEAD"
        URLSession.shared.dataTask(with: req).resume()
    }

    /// Audio for upload: AAC when the encoder works, WAV otherwise.
    struct Upload { let data: Data; let filename: String; let mime: String }
    static func upload(for samples: [Float]) -> Upload {
        if let aac = AAC.encode(samples) { return Upload(data: aac, filename: "audio.m4a", mime: "audio/mp4") }
        return Upload(data: WAV.encode(samples), filename: "audio.wav", mime: "audio/wav")
    }

    func transcribe(_ samples: [Float], timeout: TimeInterval? = nil, only: STTProvider? = nil) async throws -> TranscriptionResult {
        let order = (only.map { [$0] } ?? store.settings.providerOrder).filter(isAvailable)
        let t0 = Date()
        let up = Self.upload(for: samples)
        let job = Job(samples: samples, up: up, encodeMs: Int(Date().timeIntervalSince(t0) * 1000),
                      seconds: Double(samples.count) / MicRecorder.sampleRate)
        // A dictation (no explicit timeout, no fixed engine) with a cloud engine first and a local model
        // on disk never waits out a stalled connection: see `hedged`.
        let cloud = Array(order.prefix { $0 != .local })
        if timeout == nil, only == nil, !cloud.isEmpty, order.contains(.local) {
            return try await hedged(job, cloud: cloud)
        }
        var errors: [String] = []
        for p in order {
            do { return try await run(p, job, timeout: timeout ?? (8 + job.seconds * 0.5)) }
            catch {
                Log.write("stt \(p.rawValue) failed: \(error.localizedDescription)")
                errors.append("\(p.label): \(error.localizedDescription)")
            }
        }
        if errors.isEmpty {
            throw PieError("No transcription engine is set up. Add a Grok or Groq key, or download a local model in Settings.")
        }
        throw PieError(errors.joined(separator: "\n"))
    }

    private struct Job {
        let samples: [Float]
        let up: Upload
        let encodeMs: Int
        let seconds: Double
    }

    /// One engine, one attempt, with the timing line the log is read by.
    private func run(_ p: STTProvider, _ job: Job, timeout: TimeInterval) async throws -> TranscriptionResult {
        let t1 = Date()
        let r: TranscriptionResult
        switch p {
        case .grok: r = try await grok(job.up, timeout: timeout)
        case .groq: r = try await groq(job.up, timeout: timeout)
        case .local: r = try await local(job.up.mime == "audio/wav" ? job.up.data : WAV.encode(job.samples))
        }
        Log.write("stt ok via \(p.rawValue) (\(String(format: "%.1f", job.seconds))s audio, \(job.up.data.count / 1024) KB \(job.up.filename.suffix(3)), encode \(job.encodeMs) ms, request \(Int(Date().timeIntervalSince(t1) * 1000)) ms)")
        return TranscriptionResult(text: Self.clean(r.text), segments: r.segments, engine: r.engine)
    }

    /// How long a dictation waits on the cloud. Measured over 2,050 Groq requests: half answer within
    /// 0.39 s and 99 in 100 within 1.2 s, but the rest stall for up to 13 s on a bad connection, while
    /// the local model answers a short clip in about 0.3 s.
    enum Hedge {
        /// The local model starts this long after the cloud request, so it is ready if the cloud stalls.
        static let startLocal: TimeInterval = 0.7
        /// After this long the local answer is used. Before it, the cloud answer wins: it is more accurate.
        static let patience: TimeInterval = 1.8
        /// The same two limits while the service is marked slow: no head start, and just enough patience
        /// for a healthy answer to show the trouble has passed.
        static let startLocalWhenSlow: TimeInterval = 0
        static let patienceWhenSlow: TimeInterval = 0.9
    }

    private enum Raced {
        case cloud(TranscriptionResult), cloudFailed([String])
        case local(TranscriptionResult), localFailed(String)
        case startLocal, patienceOver
    }

    /// Cloud first, with the local model as a safety net that does not wait for the cloud to give up.
    /// Before this, a stalled Groq request held the text for its whole timeout (9 s or more), and only
    /// then did the local model get its 0.3 s.
    private func hedged(_ job: Job, cloud: [STTProvider]) async throws -> TranscriptionResult {
        let slow = CloudHealth.isSlow(cloud[0].service, use: "stt")
        let startLocal = slow ? Hedge.startLocalWhenSlow : Hedge.startLocal
        let patience = slow ? Hedge.patienceWhenSlow : Hedge.patience
        let began = Date()
        return try await withThrowingTaskGroup(of: Raced.self) { group in
            group.addTask { [self] in
                var errors: [String] = []
                for p in cloud {
                    // A pooled connection the server already closed fails at once; a fresh one usually works.
                    for attempt in 1...2 {
                        do {
                            let r = try await run(p, job, timeout: 8 + job.seconds * 0.5)
                            CloudHealth.markOK(p.service, use: "stt")
                            return .cloud(r)
                        } catch {
                            if Task.isCancelled { return .cloudFailed([]) }
                            if attempt == 1, (error as? URLError)?.code == .networkConnectionLost {
                                Log.write("stt \(p.rawValue): connection was stale, retrying on a fresh one")
                                continue
                            }
                            Log.write("stt \(p.rawValue) failed: \(error.localizedDescription)")
                            errors.append("\(p.label): \(error.localizedDescription)")
                            CloudHealth.markSlow(p.service, use: "stt", after: error)
                            break
                        }
                    }
                }
                return .cloudFailed(errors)
            }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(startLocal * 1e9)); return .startLocal }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(patience * 1e9)); return .patienceOver }
            defer { group.cancelAll() }

            var localStarted = false, patienceOver = false
            var localResult: TranscriptionResult?
            var cloudErrors: [String]?, localError: String?
            func runLocal() {
                guard !localStarted else { return }
                localStarted = true
                group.addTask { [self] in
                    do { return .local(try await run(.local, job, timeout: 0)) }
                    catch { return .localFailed(error.localizedDescription) }
                }
            }
            func allFailed() -> PieError {
                PieError(((cloudErrors ?? []) + [localError.map { "\(STTProvider.local.label): \($0)" }].compactMap { $0 }).joined(separator: "\n"))
            }
            while let event = try await group.next() {
                if Task.isCancelled { throw CancellationError() }
                switch event {
                case .cloud(let r):
                    return r
                case .cloudFailed(let errors):
                    cloudErrors = errors
                    if let localResult { return localResult }
                    if localError != nil { throw allFailed() }
                    runLocal()
                case .startLocal:
                    if cloudErrors == nil { runLocal() }
                case .patienceOver:
                    patienceOver = true
                    if let localResult { return usingLocal(localResult, cloud[0], began, alreadySlow: slow) }
                case .local(let r):
                    if cloudErrors != nil { return r }
                    if patienceOver { return usingLocal(r, cloud[0], began, alreadySlow: slow) }
                    localResult = r
                case .localFailed(let message):
                    localError = message
                    if !Task.isCancelled { Log.write("stt local failed: \(message)") }
                    if cloudErrors != nil { throw allFailed() }
                }
            }
            throw allFailed()
        }
    }

    /// `alreadySlow`: the mark is not renewed while it is set. So on a connection that stays bad, one
    /// dictation every half minute gives the cloud its full patience again, and finds out if it is back.
    private func usingLocal(_ r: TranscriptionResult, _ stalled: STTProvider, _ began: Date, alreadySlow: Bool) -> TranscriptionResult {
        Log.write("stt \(stalled.rawValue) still silent after \(Int(Date().timeIntervalSince(began) * 1000)) ms, using the local answer")
        if !alreadySlow { CloudHealth.markSlow(stalled.service, use: "stt") }
        return r
    }

    static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"\[(BLANK_AUDIO|MUSIC|Music|NOISE|silence|inaudible)[^\]]*\]"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        let junk = ["thank you.", "thanks for watching!", "thank you for watching.", "you", "."]
        if junk.contains(t.lowercased()) { return "" }
        return t
    }

    private var languageCode: String? {
        let l = store.settings.language
        return l == "auto" ? nil : l
    }

    // MARK: Grok (xAI)

    private func grok(_ up: Upload, timeout: TimeInterval) async throws -> TranscriptionResult {
        var mp = Multipart()
        mp.file("file", filename: up.filename, mime: up.mime, data: up.data)
        if let lang = languageCode { mp.field("language", lang); mp.field("format", "true") }
        for term in vocabulary.prefix(100) { mp.field("keyterm", String(term.prefix(50))) }
        var req = URLRequest(url: URL(string: "https://api.x.ai/v1/stt")!, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("Bearer \(store.keys.xai)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(mp.boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = mp.finished()
        let obj = try await HTTP.send(req)
        let text = obj["text"] as? String ?? ""
        var segs: [TranscriptSegment] = []
        if let words = obj["words"] as? [[String: Any]] {
            segs = Self.group(words: words.compactMap { w in
                let t = (w["text"] ?? w["word"]) as? String ?? ""
                let s = Self.num(w["start"] ?? w["start_time"]), e = Self.num(w["end"] ?? w["end_time"])
                return t.isEmpty ? nil : (t, s, e)
            })
        }
        return TranscriptionResult(text: text, segments: segs, engine: "Grok")
    }

    // MARK: Groq

    private func groq(_ up: Upload, timeout: TimeInterval) async throws -> TranscriptionResult {
        var mp = Multipart()
        mp.file("file", filename: up.filename, mime: up.mime, data: up.data)
        mp.field("model", "whisper-large-v3-turbo")
        mp.field("response_format", "verbose_json")
        mp.field("temperature", "0")
        if let lang = languageCode { mp.field("language", lang) }
        if !vocabulary.isEmpty { mp.field("prompt", "Vocabulary: " + vocabulary.prefix(60).joined(separator: ", ") + ".") }
        var req = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("Bearer \(store.keys.groq)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(mp.boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = mp.finished()
        let obj = try await HTTP.send(req)
        let segs = (obj["segments"] as? [[String: Any]] ?? []).compactMap { s -> TranscriptSegment? in
            let t = (s["text"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            if let nsp = s["no_speech_prob"] as? Double, nsp > 0.8 { return nil }
            return t.isEmpty ? nil : TranscriptSegment(start: Self.num(s["start"]), end: Self.num(s["end"]), speaker: "", text: t)
        }
        let text = segs.isEmpty ? (obj["text"] as? String ?? "") : segs.map(\.text).joined(separator: " ")
        return TranscriptionResult(text: text, segments: segs, engine: "Groq")
    }

    // MARK: Local whisper.cpp

    private func local(_ wav: Data) async throws -> TranscriptionResult {
        guard let bin = localWhisperBinary else { throw PieError("Local whisper engine is missing from the app bundle") }
        guard let model = localModelURL() else { throw PieError("No local model downloaded") }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pieflow-\(UUID().uuidString)")
        let wavURL = tmp.appendingPathExtension("wav")
        try wav.write(to: wavURL)
        defer {
            try? FileManager.default.removeItem(at: wavURL)
            try? FileManager.default.removeItem(at: tmp.appendingPathExtension("json"))
        }
        var args = ["-m", model.path, "-f", wavURL.path, "-oj", "-of", tmp.path, "-np", "-nt",
                    "-t", "\(max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))",
                    "-l", languageCode ?? "auto"]
        if !vocabulary.isEmpty { args += ["--prompt", "Vocabulary: " + vocabulary.prefix(40).joined(separator: ", ") + "."] }
        let (code, _, err) = try await Shell.run(bin, args)
        guard code == 0 else { throw PieError("whisper-cli exited \(code): \(err.suffix(300))") }
        let data = try Data(contentsOf: tmp.appendingPathExtension("json"))
        let obj = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let segs = (obj["transcription"] as? [[String: Any]] ?? []).compactMap { s -> TranscriptSegment? in
            let t = (s["text"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let off = s["offsets"] as? [String: Any] ?? [:]
            return t.isEmpty ? nil : TranscriptSegment(start: Self.num(off["from"]) / 1000, end: Self.num(off["to"]) / 1000, speaker: "", text: t)
        }
        return TranscriptionResult(text: segs.map(\.text).joined(separator: " "), segments: segs, engine: "Local")
    }

    // MARK: helpers

    static func num(_ v: Any?) -> Double {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s) ?? 0 }
        return 0
    }

    /// Groups word timings into sentence-like segments split on pauses and punctuation.
    static func group(words: [(String, Double, Double)]) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        var cur: TranscriptSegment?
        for (t, s, e) in words {
            if var c = cur {
                let gap = s - c.end
                if gap > 1.2 || (c.text.count > 120 && c.text.last.map { ".?!".contains($0) } == true) {
                    out.append(c); cur = TranscriptSegment(start: s, end: e, speaker: "", text: t)
                } else {
                    let joiner = t.first.map { ",.?!;:'".contains($0) } == true ? "" : " "
                    c.text += joiner + t; c.end = e; cur = c
                }
            } else { cur = TranscriptSegment(start: s, end: e, speaker: "", text: t) }
        }
        if let c = cur { out.append(c) }
        return out
    }
}

enum Shell {
    /// Runs a process off the main thread and collects its output.
    /// Cancelling the calling task stops the process, so a transcription nobody is waiting for any
    /// more does not keep the CPU busy.
    static func run(_ exe: URL, _ args: [String], stdin: String? = nil, timeout: TimeInterval = 600) async throws -> (Int32, String, String) {
        let p = Process()
        let stop = StopFlag()
        return try await withTaskCancellationHandler {
            try await start(p, stop, exe, args, stdin: stdin, timeout: timeout)
        } onCancel: {
            stop.set()
            if p.isRunning { p.terminate() }
        }
    }

    private final class StopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    private static func start(_ p: Process, _ stop: StopFlag, _ exe: URL, _ args: [String], stdin: String?, timeout: TimeInterval) async throws -> (Int32, String, String) {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                p.executableURL = exe
                p.arguments = args
                var env = ProcessInfo.processInfo.environment
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                env["HOME"] = env["HOME"] ?? home
                env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
                p.environment = env
                let out = Pipe(), err = Pipe()
                p.standardOutput = out; p.standardError = err
                let inPipe = Pipe()
                p.standardInput = inPipe
                var outData = Data(), errData = Data()
                let group = DispatchGroup()
                group.enter(); group.enter()
                DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                do { try p.run() } catch { cont.resume(throwing: error); return }
                if stop.isSet { p.terminate() }   // cancelled before the process existed
                if let stdin { inPipe.fileHandleForWriting.write(stdin.data(using: .utf8)!) }
                try? inPipe.fileHandleForWriting.close()
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                p.waitUntilExit()
                killer.cancel()
                group.wait()
                cont.resume(returning: (p.terminationStatus, String(data: outData, encoding: .utf8) ?? "", String(data: errData, encoding: .utf8) ?? ""))
            }
        }
    }
}

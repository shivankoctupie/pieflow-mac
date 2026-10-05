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
    static func send(_ req: URLRequest) async throws -> [String: Any] {
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
    func transcribe(_ samples: [Float], timeout: TimeInterval? = nil, only: STTProvider? = nil) async throws -> TranscriptionResult {
        let order = only.map { [$0] } ?? store.settings.providerOrder
        let wav = WAV.encode(samples)
        let seconds = Double(samples.count) / MicRecorder.sampleRate
        var errors: [String] = []
        for p in order where isAvailable(p) {
            do {
                let t = timeout ?? (8 + seconds * 0.5)
                let r: TranscriptionResult
                switch p {
                case .grok: r = try await grok(wav, timeout: t)
                case .groq: r = try await groq(wav, timeout: t)
                case .local: r = try await local(wav)
                }
                Log.write("stt ok via \(p.rawValue) (\(String(format: "%.1f", seconds))s audio)")
                return TranscriptionResult(text: Self.clean(r.text), segments: r.segments, engine: r.engine)
            } catch {
                Log.write("stt \(p.rawValue) failed: \(error.localizedDescription)")
                errors.append("\(p.label): \(error.localizedDescription)")
            }
        }
        if errors.isEmpty {
            throw PieError("No transcription engine is set up. Add a Grok or Groq key, or download a local model in Settings.")
        }
        throw PieError(errors.joined(separator: "\n"))
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

    private func grok(_ wav: Data, timeout: TimeInterval) async throws -> TranscriptionResult {
        var mp = Multipart()
        mp.file("file", filename: "audio.wav", mime: "audio/wav", data: wav)
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

    private func groq(_ wav: Data, timeout: TimeInterval) async throws -> TranscriptionResult {
        var mp = Multipart()
        mp.file("file", filename: "audio.wav", mime: "audio/wav", data: wav)
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
    static func run(_ exe: URL, _ args: [String], stdin: String? = nil, timeout: TimeInterval = 600) async throws -> (Int32, String, String) {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = exe
                p.arguments = args
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

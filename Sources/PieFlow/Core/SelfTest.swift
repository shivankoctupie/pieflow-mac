import Foundation
import AppKit
import AVFoundation

/// `PieFlow.app/Contents/MacOS/PieFlow --selftest` exercises every risky native piece and prints PASS lines.
enum SelfTest {
    static var failures = 0

    static func line(_ status: String, _ name: String, _ detail: String = "") {
        print("\(status.padding(toLength: 5, withPad: " ", startingAt: 0)) \(name)\(detail.isEmpty ? "" : ": " + detail)")
        if status == "FAIL" { failures += 1 }
    }

    static func await_<T>(_ f: @escaping () async throws -> T) -> Result<T, Error> {
        let sem = DispatchSemaphore(value: 0)
        var out: Result<T, Error>!
        Task.detached { do { out = .success(try await f()) } catch { out = .failure(error) }; sem.signal() }
        sem.wait()
        return out
    }

    /// `PieFlow --aec-test`: plays a sentence through the speakers while the mic records, once with
    /// voice isolation and once without, and prints what each recording contains.
    static func aecTest() -> Int32 {
        let store = Store.shared
        let transcriber = Transcriber(store: store)
        guard Permissions.microphone else { print("FAIL microphone permission not granted to this process"); Log.write("aec-test FAIL no mic permission"); return 1 }
        var results: [(Bool, Float, String)] = []
        var liveOn = false
        for isolate in [false, true] {
            let mic = MicRecorder()
            do { try mic.start(deviceUID: store.settings.microphoneUID, voiceIsolation: isolate) } catch { print("FAIL mic: \(error)"); return 1 }
            Thread.sleep(forTimeInterval: 0.5)
            let say = Process()
            say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = ["-r", "190", "The quick brown fox jumps over the lazy dog while the speakers are playing."]
            try? say.run(); say.waitUntilExit()
            Thread.sleep(forTimeInterval: 0.4)
            let s = mic.stop()
            let rms = WAV.rms(s)
            let maxAbs = s.map { abs($0) }.max() ?? 0
            let nonZero = Double(s.filter { $0 != 0 }.count) / Double(max(s.count, 1))
            Log.write("aec-test isolation=\(isolate) format=\(mic.inputFormatDescription) samples=\(s.count) maxAbs=\(String(format: "%.5f", maxAbs)) nonZero=\(String(format: "%.2f", nonZero))")
            if isolate { liveOn = s.count > 16_000 && maxAbs > 0 && nonZero > 0.5 }
            var text = ""
            switch await_({ try await transcriber.transcribe(s, timeout: 60, only: .local) }) {
            case .success(let r): text = r.text
            case .failure(let e): text = "(stt error: \(e.localizedDescription))"
            }
            results.append((isolate, rms, text))
            let line = "\(isolate ? "isolation ON " : "isolation OFF") voiceProcessing=\(mic.voiceProcessingActive) rms=\(String(format: "%.4f", rms)) heard=\"\(text)\""
            print(line); Log.write("aec-test " + line)
        }
        let off = results[0], on = results[1]
        let leakOff = off.2.lowercased().contains("fox"), leakOn = on.2.lowercased().contains("fox")
        let ok = liveOn && !leakOn && (on.1 < off.1 * 0.5 || !leakOff)
        let verdict = ok ? "AEC TEST PASS (mic live, speaker audio removed from the mic signal)"
            : !liveOn ? "AEC TEST FAIL (isolated mic signal is dead)" : "AEC TEST FAIL (speaker audio still reaches transcription)"
        print(verdict); Log.write("aec-test " + verdict)
        Thread.sleep(forTimeInterval: 0.5)
        return ok ? 0 : 1
    }

    /// `PieFlow --aec-probe`: records 2 s of room noise with voice processing on, trying several tap
    /// formats, and logs per channel levels so we can see where the processed voice actually lands.
    static func aecProbe() -> Int32 {
        guard Permissions.microphone else { Log.write("aec-probe FAIL no mic permission"); return 1 }
        for variant in ["node", "nil", "mono"] {
            let engine = AVAudioEngine()
            let input = engine.inputNode
            do { try input.setVoiceProcessingEnabled(true) } catch { Log.write("aec-probe setVoiceProcessingEnabled: \(error)"); return 1 }
            let node = input.outputFormat(forBus: 0)
            let tapFormat: AVAudioFormat? = variant == "node" ? node : variant == "nil" ? nil : AVAudioFormat(standardFormatWithSampleRate: node.sampleRate, channels: 1)
            var maxPerCh: [Float] = []
            var frames = 0
            var seenFormat = ""
            let lock = NSLock()
            input.installTap(onBus: 0, bufferSize: 2048, format: tapFormat) { buf, _ in
                lock.lock(); defer { lock.unlock() }
                seenFormat = "\(Int(buf.format.sampleRate))Hz/\(buf.format.channelCount)ch interleaved=\(buf.format.isInterleaved)"
                frames += Int(buf.frameLength)
                guard let ch = buf.floatChannelData else { return }
                if maxPerCh.count < Int(buf.format.channelCount) { maxPerCh = Array(repeating: 0, count: Int(buf.format.channelCount)) }
                for c in 0..<Int(buf.format.channelCount) {
                    let ptr = ch[c]
                    let stride = buf.format.isInterleaved ? Int(buf.format.channelCount) : 1
                    var m: Float = 0
                    var i = 0
                    while i < Int(buf.frameLength) { m = max(m, abs(ptr[i * stride])); i += 1 }
                    maxPerCh[c] = max(maxPerCh[c], m)
                }
            }
            engine.prepare()
            do { try engine.start() } catch { Log.write("aec-probe \(variant) start failed: \(error)"); continue }
            Thread.sleep(forTimeInterval: 2.0)
            input.removeTap(onBus: 0); engine.stop()
            lock.lock()
            Log.write("aec-probe variant=\(variant) nodeFormat=\(Int(node.sampleRate))Hz/\(node.channelCount)ch tap=\(seenFormat) frames=\(frames) maxPerChannel=\(maxPerCh.map { String(format: "%.5f", $0) })")
            lock.unlock()
        }
        Thread.sleep(forTimeInterval: 0.5)
        return 0
    }

    static func run() -> Int32 {
        print("PieFlow self test, version \(AppInfo.version), \(ProcessInfo.processInfo.operatingSystemVersionString)")
        let store = Store.shared
        let transcriber = Transcriber(store: store)

        Theme.registerFonts()
        Theme.fontsAvailable ? line("PASS", "fonts", "Figtree and EB Garamond registered") : line("FAIL", "fonts", "bundled fonts not found")

        let probe = Paths.support.appendingPathComponent(".probe")
        if (try? Data("ok".utf8).write(to: probe)) != nil { line("PASS", "data dir", Paths.support.path); try? FileManager.default.removeItem(at: probe) }
        else { line("FAIL", "data dir", "not writable") }

        if let bin = transcriber.localWhisperBinary {
            switch await_({ try await Shell.run(bin, ["--help"], timeout: 20) }) {
            case .success(let (code, out, err)):
                (code == 0 && (out + err).contains("usage")) ? line("PASS", "whisper-cli", bin.path) : line("FAIL", "whisper-cli", "exit \(code)")
            case .failure(let e): line("FAIL", "whisper-cli", e.localizedDescription)
            }
        } else { line("FAIL", "whisper-cli", "binary missing from bundle") }

        let devices = AudioDevices.inputs()
        devices.isEmpty ? line("FAIL", "audio inputs", "none found") : line("PASS", "audio inputs", devices.map(\.name).joined(separator: ", "))

        if Permissions.microphone {
            let mic = MicRecorder()
            do {
                try mic.start(deviceUID: store.settings.microphoneUID, voiceIsolation: store.settings.voiceIsolation)
                Thread.sleep(forTimeInterval: 1.0)
                let s = mic.stop()
                s.count > 8000 ? line("PASS", "mic capture", "\(s.count) samples at 16 kHz in 1 s") : line("FAIL", "mic capture", "only \(s.count) samples")
            } catch { line("FAIL", "mic capture", error.localizedDescription) }
        } else { line("SKIP", "mic capture", "microphone permission not granted to this binary yet") }

        if Permissions.accessibility {
            let hk = HotkeyMonitor()
            hk.start() ? line("PASS", "event tap", "global \(store.settings.hotkey.label) listener created") : line("FAIL", "event tap", "creation failed")
            hk.stop()
        } else { line("SKIP", "event tap", "Accessibility not granted to this binary yet") }

        line(Permissions.screenRecording ? "PASS" : "SKIP", "screen/system audio permission", Permissions.screenRecording ? "granted" : "not granted (Notetaker records mic only)")

        // Rules engine.
        let eng = TextEngine(store: store, llm: LLM(store: store))
        let r = eng.rules("um so the the plan is new line ship it")
        r == "So the plan is\nship it" ? line("PASS", "rules engine", r.replacingOccurrences(of: "\n", with: "\\n")) : line("FAIL", "rules engine", r)

        // Synthesize speech, then transcribe with every configured engine.
        let aiff = FileManager.default.temporaryDirectory.appendingPathComponent("pieflow-selftest.aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", aiff.path, "Testing PieFlow on this Mac. The quick brown fox jumps over the lazy dog."]
        try? say.run(); say.waitUntilExit()
        guard let samples = try? WAV.readMono16k(aiff), samples.count > 16_000 else {
            line("FAIL", "speech sample", "could not synthesize test audio")
            return finish()
        }
        line("PASS", "speech sample", String(format: "%.1f s synthesized", Double(samples.count) / 16_000))
        for p in STTProvider.allCases {
            guard transcriber.isAvailable(p) else { line("SKIP", "stt \(p.rawValue)", p == .local ? "no model downloaded" : "no key"); continue }
            let t0 = Date()
            switch await_({ try await transcriber.transcribe(samples, timeout: 60, only: p) }) {
            case .success(let res):
                let ok = res.text.lowercased().contains("fox") || res.text.lowercased().contains("lazy")
                line(ok ? "PASS" : "FAIL", "stt \(p.rawValue)", String(format: "%.2fs \"%@\"", Date().timeIntervalSince(t0), res.text))
            case .failure(let e): line("FAIL", "stt \(p.rawValue)", e.localizedDescription)
            }
        }
        let llm = LLM(store: store)
        if llm.hasCloud {
            let t0 = Date()
            switch await_({ await eng.process("um so i think we should uh ship it on tuesday no wait friday", category: .work, appName: "Slack") }) {
            case .success(let s):
                // Must actually be cleaned: correction applied, capitalised, filler gone.
                let ok = s.contains("Friday") && !s.lowercased().contains("tuesday") && !s.lowercased().contains(" uh ")
                    && s.first?.isUppercase == true && s.last.map { ".!?".contains($0) } == true
                line(ok ? "PASS" : "FAIL", "ai cleanup", String(format: "%.2fs \"%@\"%@", Date().timeIntervalSince(t0), s, ok ? "" : " (AI pass did not run, see pieflow.log)"))
            case .failure(let e): line("FAIL", "ai cleanup", e.localizedDescription)
            }
        } else { line("SKIP", "ai cleanup", "no Groq or xAI key") }
        return finish()
    }

    static func finish() -> Int32 {
        print(failures == 0 ? "SELFTEST OK" : "SELFTEST FAILED (\(failures))")
        return failures == 0 ? 0 : 1
    }
}

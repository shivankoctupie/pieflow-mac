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
                try mic.start(deviceUID: store.settings.microphoneUID)
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

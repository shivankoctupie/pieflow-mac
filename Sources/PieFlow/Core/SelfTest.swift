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

    /// `PieFlow --aec-test`: plays a sentence through the speakers while the mic records: once without
    /// voice isolation, once with it, and twice more on the same engine after a stop, the way the app
    /// reuses it between dictations. Prints what each recording contains.
    static func aecTest() -> Int32 {
        let store = Store.shared
        let transcriber = Transcriber(store: store)
        guard Permissions.microphone else { print("FAIL microphone permission not granted to this process"); Log.write("aec-test FAIL no mic permission"); return 1 }
        var results: [(Bool, Float, String)] = []
        var liveOn = true
        let passes: [(String, Bool)] = [("isolation OFF", false), ("isolation ON ", true), ("isolation ON, engine reused", true), ("isolation ON, engine reused again", true)]
        var mic = MicRecorder()
        for (n, (label, isolate)) in passes.enumerated() {
            if n == 1 { mic = MicRecorder() }
            do { try mic.start(deviceUID: store.settings.microphoneUID, voiceIsolation: isolate) } catch { print("FAIL mic: \(error)"); return 1 }
            Thread.sleep(forTimeInterval: 0.5)
            let say = Process()
            say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = ["-r", "190", "The quick brown fox jumps over the lazy dog while the speakers are playing."]
            try? say.run(); say.waitUntilExit()
            Thread.sleep(forTimeInterval: 0.4)
            let s = mic.stop(keepWarm: isolate)
            let rms = WAV.rms(s)
            let maxAbs = s.map { abs($0) }.max() ?? 0
            let nonZero = Double(s.filter { $0 != 0 }.count) / Double(max(s.count, 1))
            Log.write("aec-test \(label) format=\(mic.inputFormatDescription) samples=\(s.count) maxAbs=\(String(format: "%.5f", maxAbs)) nonZero=\(String(format: "%.2f", nonZero))")
            if isolate { liveOn = liveOn && s.count > 16_000 && maxAbs > 0 && nonZero > 0.5 && mic.voiceProcessingActive }
            var text = ""
            switch await_({ try await transcriber.transcribe(s, timeout: 60, only: .local) }) {
            case .success(let r): text = r.text
            case .failure(let e): text = "(stt error: \(e.localizedDescription))"
            }
            results.append((isolate, rms, text))
            let line = "\(label) voiceProcessing=\(mic.voiceProcessingActive) rms=\(String(format: "%.4f", rms)) heard=\"\(text)\""
            print(line); Log.write("aec-test " + line)
        }
        mic.discardWarm()
        let off = results[0], on = results.dropFirst()
        let leakOff = off.2.lowercased().contains("fox"), leakOn = on.contains { $0.2.lowercased().contains("fox") }
        // Judged on what gets transcribed. Loudness is no guide: voice processing applies its own gain,
        // and at a low speaker volume the processed signal can measure louder than the plain one.
        let ok = liveOn && !leakOn
        let verdict = ok ? (leakOff ? "AEC TEST PASS (mic live, speaker audio removed from the mic signal, also on a reused engine)"
                                    : "AEC TEST PASS, but weak: the sentence did not reach the plain microphone either, turn the volume up")
            : !liveOn ? "AEC TEST FAIL (isolated mic signal is dead)" : "AEC TEST FAIL (speaker audio still reaches transcription)"
        print(verdict); Log.write("aec-test " + verdict)
        Thread.sleep(forTimeInterval: 0.5)
        return ok ? 0 : 1
    }

    /// `PieFlow --duck-test`: other apps must keep their volume while PieFlow listens. Plays quiet test
    /// tones from another process, then walks the real microphone path (standby, recording, stop) and
    /// checks at each step whether there is anything left to lift. The microphone itself changes character
    /// while voice processing is on, so steps are compared with their neighbour, not with the first reading.
    static func duckTest() -> Int32 {
        guard Permissions.microphone else { print("FAIL microphone permission not granted to this process"); return 1 }
        guard AudioDevices.outputIsBuiltInSpeakers else { print("SKIP output is not the built in speakers, voice processing stays off there"); return 0 }
        guard let meter = ToneMeter() else { print("FAIL could not open the built in microphone"); return 1 }
        let tone = ToneMeter.playTones(seconds: 40)
        defer { tone?.terminate() }
        // The main thread sleeps instead of running its loop: when the loop services the device change
        // that voice processing causes, the meter's own capture session stops delivering until it ends.
        Thread.sleep(forTimeInterval: 1.5)
        let mic = MicRecorder()
        var rows: [(String, [Double])] = []
        func phase(_ name: String, _ action: () -> Void) {
            action()
            Thread.sleep(forTimeInterval: 0.9)
            let t0 = Date()
            Thread.sleep(forTimeInterval: 1.9)
            rows.append((name, meter.mean(from: t0, to: Date()).tones))
        }
        phase("before") {}
        phase("standby") { mic.prewarm(deviceUID: nil, voiceIsolation: true) }
        phase("standby, lifted by hand") { SystemAudio.setOtherAudioLevel(1) }
        phase("recording") { do { try mic.start(deviceUID: nil, voiceIsolation: true) } catch { print("mic start: \(error.localizedDescription)") } }
        phase("recording, lifted by hand") { SystemAudio.setOtherAudioLevel(1) }
        phase("stopped") { mic.stop(); mic.discardWarm() }
        /// How much louder step `a` is than step `b`, averaged over the tones.
        func gain(_ a: Int, over b: Int) -> Double {
            let d = rows[a].1.indices.map { 20 * log10(max(rows[a].1[$0], 1e-12) / max(rows[b].1[$0], 1e-12)) }
            return d.reduce(0, +) / Double(d.count)
        }
        // If PieFlow already keeps other apps at full volume, lifting them by hand changes nothing.
        // When they are ducked, the same call brings them up by about 9 dB.
        let standby = gain(2, over: 1), recording = gain(4, over: 3)
        let after = 20 * log10(max(rows[5].1[0], 1e-12) / max(rows[0].1[0], 1e-12))
        let lines = [
            String(format: "standby: lifting by hand gains %+.1f dB (pass under 5, about 9 when ducked)", standby),
            String(format: "recording: lifting by hand gains %+.1f dB (pass under 5)", recording),
            String(format: "after stop the 440 Hz tone is %+.1f dB against before (pass within 6)", after),
        ]
        let ok = mic.voiceProcessingActive && standby < 5 && recording < 5 && abs(after) <= 6
        for (name, t) in rows {
            Log.write("duck-test \(name): " + t.map { String(format: "%.1f", 20 * log10(max($0, 1e-12))) }.joined(separator: " ") + " dBFS")
        }
        for l in lines { print(l); Log.write("duck-test " + l) }
        let verdict = ok ? "DUCK TEST PASS (other apps keep their volume)" : !mic.voiceProcessingActive ? "DUCK TEST FAIL (voice processing did not start)" : "DUCK TEST FAIL (other apps are turned down)"
        print(verdict); Log.write("duck-test " + verdict)
        Thread.sleep(forTimeInterval: 0.5)
        return ok ? 0 : 1
    }

    /// `PieFlow --sys-meter <seconds> <file> [amplitude] [marker hz]`: what other apps' audio really does.
    /// Plays test tones from another process and writes the level of the system audio capture (what the
    /// Notetaker hears) four times a second. The capture is digital and sits after macOS ducking, so it
    /// shows a duck or a dropout exactly, with tones too quiet to hear. Runs as its own process: start
    /// it, then run the thing under test (--duck-live, --vp-probe, or the real app while someone dictates).
    /// Trust this over --duck-test, whose microphone based reading goes dead around voice processing.
    static func sysMeter() -> Int32 {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--sys-meter"), i + 2 < args.count, let seconds = Double(args[i + 1]) else { print("usage: --sys-meter <seconds> <file>"); return 1 }
        let capture = SystemAudioCapture()
        var failure: String?
        var started = false
        Task { do { try await capture.start() } catch { failure = error.localizedDescription }; started = true }
        let t0 = Date()
        while !started, Date().timeIntervalSince(t0) < 10 { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        if let failure { try? "FAIL \(failure)\n".write(toFile: args[i + 2], atomically: true, encoding: .utf8); return 1 }
        // The capture is digital, so the tones can be far too quiet to hear: pass an amplitude to say how quiet.
        // A fourth argument asks for one marker tone at that frequency instead, read back on its own, so
        // the meter still works while music plays over it.
        let amplitude = i + 3 < args.count ? Float(args[i + 3]) ?? 0.025 : 0.025
        let marker = i + 4 < args.count ? Double(args[i + 4]) : nil
        let tone = ToneMeter.playTones(seconds: seconds + 2, amplitude: amplitude, frequencies: marker.map { [$0] } ?? ToneMeter.tones)
        defer { tone?.terminate() }
        func level(of hz: Double, in x: ArraySlice<Float>) -> Double {
            let coeff = 2 * cos(2 * Double.pi * hz / 16_000)
            var s1 = 0.0, s2 = 0.0
            for v in x { let s0 = Double(v) + coeff * s1 - s2; s2 = s1; s1 = s0 }
            return x.isEmpty ? 0 : (max(0, s1 * s1 + s2 * s2 - coeff * s1 * s2)).squareRoot() / Double(x.count)
        }
        var out = ""
        var seen = capture.snapshot().count
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            let all = capture.snapshot()
            let fresh = all[min(seen, all.count)...]
            seen = all.count
            var sum = 0.0
            for s in fresh { sum += Double(s) * Double(s) }
            let rms = fresh.isEmpty ? 0 : (sum / Double(fresh.count)).squareRoot()
            let mark = marker.map { String(format: " %.1f", 20 * log10(max(level(of: $0, in: fresh), 1e-12))) } ?? ""
            out += String(format: "%.2f %.1f %d", Date().timeIntervalSince1970, 20 * log10(max(rms, 1e-12)), fresh.count) + mark + "\n"
        }
        try? out.write(toFile: args[i + 2], atomically: true, encoding: .utf8)
        return 0
    }

    /// `PieFlow --duck-live <file>`: standby and three dictations in a row with the main run loop alive,
    /// exactly as the app runs them, writing the time of each step. Each dictation must capture live
    /// audio and give the microphone back. Read together with --sys-meter, which shows whether other
    /// apps' audio was touched meanwhile.
    static func duckLive() -> Int32 {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--duck-live"), i + 1 < args.count else { print("usage: --duck-live <file>"); return 1 }
        guard Permissions.microphone else { print("FAIL microphone permission not granted to this process"); return 1 }
        let mic = MicRecorder()
        var out = ""
        func mark(_ name: String) { out += String(format: "%.2f %@\n", Date().timeIntervalSince1970, name) }
        func spin(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        // The same four second tick the app runs between dictations.
        let tick = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { _ in
            guard !mic.isRunning, ProcessInfo.processInfo.environment["PIEFLOW_NO_ISOLATION"] != "1" else { return }
            mic.prewarm(deviceUID: nil, voiceIsolation: true)
            mic.keepOtherAudioFull()
        }
        var ok = true
        let me = UInt32(ProcessInfo.processInfo.processIdentifier)
        // PIEFLOW_NO_ISOLATION=1 records without echo cancellation, to show what the tone looks like uncancelled.
        let isolate = ProcessInfo.processInfo.environment["PIEFLOW_NO_ISOLATION"] != "1"
        mark("begin"); spin(3)
        mark("standby"); if isolate { tick.fire() }; spin(3)
        for round in 1...3 {
            mark("fn down \(round)")
            do { try mic.start(deviceUID: nil, voiceIsolation: isolate) } catch { mark("start failed: \(error.localizedDescription)"); ok = false }
            let took = Int(mic.startReturnedAt.timeIntervalSince(mic.startCalledAt) * 1000)
            spin(3)
            let s = mic.stop(keepWarm: true)
            let live = Double(s.filter { $0 != 0 }.count) / Double(max(1, s.count))
            spin(0.6)
            let holding = MeetingWatcher.processesUsingMic(excludingPID: 0).contains { $0.pid == me }
            let good = s.count > 32_000 && live > 0.5 && !holding && mic.voiceProcessingActive == isolate
            ok = ok && good
            // How much of a 440 Hz tone played by another app is left in the recording: echo cancellation
            // must remove it just as well on a restarted engine as on a fresh one.
            let coeff = 2 * cos(2 * Double.pi * 440 / MicRecorder.sampleRate)
            var s1 = 0.0, s2 = 0.0
            for v in s { let s0 = Double(v) + coeff * s1 - s2; s2 = s1; s1 = s0 }
            let tone = 20 * log10(max((max(0, s1 * s1 + s2 * s2 - coeff * s1 * s2)).squareRoot() / Double(max(1, s.count)), 1e-12))
            mark(String(format: "fn up %d: %@ start %d ms, %d samples, %.0f%% non zero, mic still held %@, level %.1f dBFS, 440 Hz left %.1f dBFS", round, good ? "PASS" : "FAIL", took, s.count, live * 100, holding ? "yes" : "no", 20 * log10(max(Double(WAV.rms(s)), 1e-12)), tone))
            spin(5.4)
        }
        tick.invalidate()
        mark("teardown"); mic.discardWarm(); spin(2)
        mark(ok ? "end: MIC REUSE PASS" : "end: MIC REUSE FAIL")
        try? out.write(toFile: args[i + 1], atomically: true, encoding: .utf8)
        return ok ? 0 : 1
    }

    /// `PieFlow --vp-probe <file> <release|stop|pause>`: what ending a dictation does to other apps' audio,
    /// for three ways of ending it: throwing the voice processing engine away and building a new one,
    /// stopping it and starting the same one again, or pausing it. Read together with --sys-meter.
    static func vpProbe() -> Int32 {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--vp-probe"), i + 2 < args.count else { print("usage: --vp-probe <file> <release|stop|pause>"); return 1 }
        guard Permissions.microphone else { print("FAIL microphone permission not granted to this process"); return 1 }
        let variant = args[i + 2]
        var out = ""
        func mark(_ name: String) { out += String(format: "%.2f %@\n", Date().timeIntervalSince1970, name) }
        func spin(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        func lift() { SystemAudio.setOtherAudioLevel(1); DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { SystemAudio.setOtherAudioLevel(1) } }
        func build() -> AVAudioEngine? {
            let e = AVAudioEngine()
            do { try e.inputNode.setVoiceProcessingEnabled(true) } catch { mark("voice processing failed: \(error.localizedDescription)"); return nil }
            e.inputNode.isVoiceProcessingAGCEnabled = false
            e.inputNode.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
            e.inputNode.installTap(onBus: 0, bufferSize: 2048, format: nil) { _, _ in }
            e.prepare()
            lift()
            return e
        }
        mark("begin"); spin(3)
        mark("build"); guard var engine = build() else { try? out.write(toFile: args[i + 1], atomically: true, encoding: .utf8); return 1 }
        spin(3)
        for round in 1...2 {
            mark("start \(round)"); do { try engine.start() } catch { mark("start failed: \(error.localizedDescription)") }
            lift(); spin(3)
            switch variant {
            case "pause": mark("pause \(round)"); engine.pause(); lift()
            case "stop": mark("stop \(round)"); engine.stop(); lift()
            default:
                mark("release \(round)"); engine.inputNode.removeTap(onBus: 0); engine.stop(); lift(); spin(3)
                mark("rebuild \(round)"); if let e = build() { engine = e }
            }
            spin(3)
        }
        mark("teardown"); engine.inputNode.removeTap(onBus: 0); engine.stop(); SystemAudio.setOtherAudioLevel(1); spin(2)
        mark("end")
        try? out.write(toFile: args[i + 1], atomically: true, encoding: .utf8)
        return 0
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

    /// `PieFlow --mic-test [deviceUID]`: opens the microphone exactly as a dictation would, records 3 s,
    /// and logs the device chosen, the format, and how long the start of the recording was silent.
    static func micTest() -> Int32 {
        let store = Store.shared
        guard Permissions.microphone else { Log.write("mic-test FAIL no mic permission"); return 1 }
        let args = CommandLine.arguments
        let pinned: String? = args.firstIndex(of: "--mic-test").flatMap { i in i + 1 < args.count && !args[i + 1].hasPrefix("--") ? args[i + 1] : nil }
        let seconds = args.firstIndex(of: "--seconds").flatMap { i in i + 1 < args.count ? Double(args[i + 1]) : nil } ?? 3.0
        let mic = MicRecorder()
        if args.contains("--warm") {
            mic.prewarm(deviceUID: pinned, voiceIsolation: store.settings.voiceIsolation)
            RunLoop.main.run(until: Date().addingTimeInterval(1.0))
            let me = UInt32(ProcessInfo.processInfo.processIdentifier)
            let holding = MeetingWatcher.processesUsingMic(excludingPID: 0).contains { $0.pid == me }
            Log.write("mic-test standby pipeline holds the mic open: \(holding)")
        }
        do { try mic.start(deviceUID: pinned, voiceIsolation: store.settings.voiceIsolation) } catch { Log.write("mic-test FAIL start: \(error)"); return 1 }
        // The engine runs on the main run loop; spin it so taps, the watchdog and config changes fire.
        RunLoop.main.run(until: Date().addingTimeInterval(min(seconds, 1.0)))
        Log.write("mic-test active microphone mode while capturing: \(MicMode.activeName)")
        if args.contains("--pick-mode") {
            MicMode.showPicker()
            if let i = args.firstIndex(of: "--shot"), i + 1 < args.count {
                let path = args[i + 1]
                RunLoop.main.run(until: Date().addingTimeInterval(2.5))
                if let cg = CGDisplayCreateImage(CGMainDisplayID()) {
                    let rep = NSBitmapImageRep(cgImage: cg)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    Log.write("mic-test screenshot saved to \(path)")
                } else { Log.write("mic-test screenshot failed (no screen recording permission?)") }
            }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(max(0, seconds - 1.0)))
        Log.write("mic-test active microphone mode at end of capture: \(MicMode.activeName)")
        let s = mic.stop()
        let firstSound = s.firstIndex { abs($0) > 0.0005 } ?? s.count
        let startMs = Int(mic.startReturnedAt.timeIntervalSince(mic.startCalledAt) * 1000)
        let firstMs = mic.firstBufferAt.map { Int($0.timeIntervalSince(mic.startCalledAt) * 1000) } ?? -1
        let line = String(format: "mic-test %@ samples=%d rms=%.4f leadingSilence=%.2fs nonZero=%.2f startTook=%dms firstAudioAt=%dms",
                          mic.choice?.reason ?? "?", s.count, WAV.rms(s), Double(firstSound) / MicRecorder.sampleRate,
                          Double(s.filter { $0 != 0 }.count) / Double(max(1, s.count)), startMs, firstMs)
        Log.write(line); print(line)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        return s.count > 16_000 ? 0 : 1
    }

    /// `PieFlow --drop-test`: checks the pasteboard reader against the two shapes a screenshot drag has.
    static func dropTest() -> Int32 {
        let img = NSImage(size: NSSize(width: 40, height: 30), flipped: false) { r in NSColor.orange.setFill(); r.fill(); return true }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pieflow-drop-\(UUID().uuidString).png")
        guard let name = NoteImages.save(img) else { print("FAIL save"); return 1 }
        try? FileManager.default.copyItem(at: NoteImages.url(name), to: tmp)
        NoteImages.delete(name)
        var ok = true
        let pb1 = NSPasteboard(name: NSPasteboard.Name("pieflow-test-1")); pb1.clearContents(); pb1.writeObjects([tmp as NSURL])
        let a = NoteImages.pasteboardHasImage(pb1), n1 = NoteImages.images(from: pb1).count
        print("file URL drag: hasImage=\(a) images=\(n1)"); ok = ok && a && n1 == 1
        let pb2 = NSPasteboard(name: NSPasteboard.Name("pieflow-test-2")); pb2.clearContents(); pb2.writeObjects([img])
        let b = NoteImages.pasteboardHasImage(pb2), n2 = NoteImages.images(from: pb2).count
        print("raw image drag: hasImage=\(b) images=\(n2)"); ok = ok && b && n2 == 1
        let pb3 = NSPasteboard(name: NSPasteboard.Name("pieflow-test-3")); pb3.clearContents(); pb3.setString("hello", forType: .string)
        let c = NoteImages.pasteboardHasImage(pb3)
        print("plain text drag: hasImage=\(c) (must be false)"); ok = ok && !c
        try? FileManager.default.removeItem(at: tmp)
        print(ok ? "DROP TEST PASS" : "DROP TEST FAIL"); return ok ? 0 : 1
    }

    /// `--pipeline-test`: a synthesized sentence through upload, transcription and cleanup, with timings.
    static func pipelineTest() -> Int32 {
        let store = Store.shared
        let transcriber = Transcriber(store: store)
        let engine = TextEngine(store: store, llm: LLM(store: store))
        let aiff = FileManager.default.temporaryDirectory.appendingPathComponent("pieflow-pipe.aiff")
        let say = Process(); say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", aiff.path, "um so I think we should uh ship the pricing page on Tuesday, no wait, Friday"]
        try? say.run(); say.waitUntilExit()
        guard let samples = try? WAV.readMono16k(aiff) else { print("FAIL sample"); return 1 }
        let up = Transcriber.upload(for: samples)
        print("audio \(String(format: "%.1f", Double(samples.count) / 16_000)) s, upload \(up.data.count / 1024) KB as \(up.filename)")
        transcriber.warmConnection()
        Thread.sleep(forTimeInterval: 0.5)
        for round in 1...3 {
            let t0 = Date()
            switch await_({ try await transcriber.transcribe(samples) }) {
            case .failure(let e): print("FAIL stt: \(e.localizedDescription)"); return 1
            case .success(let r):
                let t1 = Date()
                let cleaned = await_({ await engine.process(r.text, category: .work, appName: "Slack") })
                let t2 = Date()
                print(String(format: "round %d: stt %d ms, cleanup %d ms, total %d ms  \"%@\"", round,
                             Int(t1.timeIntervalSince(t0) * 1000), Int(t2.timeIntervalSince(t1) * 1000), Int(t2.timeIntervalSince(t0) * 1000),
                             (try? cleaned.get()) ?? ""))
            }
        }
        let short = await_({ await engine.process("Can you send me the deck?", category: .work, appName: "Slack") })
        print("short clean sentence -> \"\((try? short.get()) ?? "")\" (should skip AI, see log)")
        print("PIPELINE TEST DONE"); return 0
    }

    /// `--watcher-test`: bundle id matching for the call detector.
    static func watcherTest() -> Int32 {
        let cases: [(String, String?)] = [("com.google.Chrome.helper", "Chrome"), ("com.google.Chrome", "Chrome"), ("com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan", "Google Meet"),
                                          ("com.apple.Safari", "Safari"), ("com.apple.FaceTime", "FaceTime"), ("com.apple.coreaudiod", nil), ("com.apple.CoreSpeech", nil),
                                          ("us.zoom.xos", "Zoom"), ("com.microsoft.teams2", "Microsoft Teams"), ("net.whatsapp.WhatsApp", "WhatsApp"), ("com.unknown.app", nil)]
        var ok = true
        for (bid, want) in cases {
            let got = MeetingWatcher.knownApp(for: bid)
            print("\(got == want ? "PASS" : "FAIL") \(bid) -> \(got ?? "nil")")
            ok = ok && got == want
        }
        print(ok ? "WATCHER TEST PASS" : "WATCHER TEST FAIL"); return ok ? 0 : 1
    }

    /// `--edit-test`: the correction detector on realistic before and after texts.
    static func editTest() -> Int32 {
        let pasted = "Can we move the design review to Thursday? I need one more day on the on boarding flow."
        let base = "Hello team.\n" + pasted + "\nThanks"
        let cases: [(String, (String, String)?)] = [
            ("Hello team.\n" + pasted.replacingOccurrences(of: "on boarding", with: "onboarding") + "\nThanks", nil),
            ("Hello team.\n" + pasted.replacingOccurrences(of: "Thursday", with: "Tuesday") + "\nThanks", ("Thursday", "Tuesday")),
            ("Hello team.\n" + pasted + " Also ping Priya.\nThanks", nil),
            ("Hello team.\n" + pasted.replacingOccurrences(of: "design", with: "Design") + "\nThanks", nil),
            ("Hello team.\n" + pasted.replacingOccurrences(of: "review", with: "Octupie") + "\nThanks", ("review", "Octupie")),
        ]
        var ok = true
        for (current, want) in cases {
            let got = EditWatcher.correction(baseline: base, current: current, pasted: pasted)
            let match = (got == nil && want == nil) || (got != nil && want != nil && got! == want!)
            print("\(match ? "PASS" : "FAIL") -> \(got.map { "\($0.0) => \($0.1)" } ?? "nil")")
            ok = ok && match
        }
        print(ok ? "EDIT TEST PASS" : "EDIT TEST FAIL"); return ok ? 0 : 1
    }

    /// `--summarize-test`: writes the summary for the newest meeting that has a transcript but no summary.
    static func summarizeTest() -> Int32 {
        let store = Store.shared
        guard let m = store.meetings.first(where: { !$0.segments.isEmpty && $0.summary.isEmpty }) else { print("no meeting needs a summary"); return 0 }
        print("summarising \(m.title), \(m.segments.count) segments, \(m.transcriptText.count) chars")
        let nt = Notetaker(store: store, transcriber: Transcriber(store: store), llm: LLM(store: store))
        let t0 = Date()
        // summarize() is main actor bound, so pump the run loop instead of blocking the main thread.
        var finished = false
        Task { @MainActor in await nt.summarize(m.id); finished = true }
        while !finished, Date().timeIntervalSince(t0) < 1500 { RunLoop.main.run(until: Date().addingTimeInterval(0.5)) }
        let done = store.meetings.first { $0.id == m.id }
        print(String(format: "%.0f s, summary %d chars, error: %@", Date().timeIntervalSince(t0), done?.summary.count ?? 0, done?.errorMessage ?? "none"))
        print((done?.summary ?? "").prefix(600))
        store.flush()
        return (done?.summary.isEmpty == false) ? 0 : 1
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

/// Measures how loud one test tone is at the raw built in microphone (no voice processing), so a test
/// can tell whether other apps' audio got turned down. Uses its own capture session.
final class ToneMeter {
    private let session = AVCaptureSession()
    private var delegate: MicRecorder.CaptureDelegate?
    private let lock = NSLock()
    private var readings: [(Date, [Double], Double)] = []
    /// Several tones at once: real ducking lowers all of them equally, a microphone change does not.
    static let tones: [Double] = [440, 880, 1760, 3100]
    /// A frequency with no tone in it: if this drops too, the microphone changed, not the playback.
    private let reference = 1300.0

    init?() {
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified).devices
        guard let builtIn = AudioDevices.inputs().first(where: { $0.isBuiltIn }),
              let cap = devices.first(where: { $0.uniqueID == builtIn.uid }),
              let input = try? AVCaptureDeviceInput(device: cap), session.canAddInput(input) else { return nil }
        session.addInput(input)
        let out = AVCaptureAudioDataOutput()
        let d = MicRecorder.CaptureDelegate { [weak self] sb in self?.ingest(sb) }
        out.setSampleBufferDelegate(d, queue: DispatchQueue(label: "pieflow.tonemeter"))
        guard session.canAddOutput(out) else { return nil }
        session.addOutput(out)
        delegate = d
        session.startRunning()
    }

    deinit { session.stopRunning() }


    /// Goertzel magnitude of the tone in one buffer.
    private func ingest(_ sb: CMSampleBuffer) {
        guard sb.isValid, let desc = sb.formatDescription, let asbd = desc.audioStreamBasicDescription else { return }
        var copy = asbd
        guard let fmt = AVAudioFormat(streamDescription: &copy) else { return }
        let frames = AVAudioFrameCount(sb.numSamples)
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return }
        pcm.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList) == noErr else { return }
        let n = Int(frames)
        let stride = fmt.isInterleaved ? Int(fmt.channelCount) : 1
        var x = [Double](repeating: 0, count: n)
        for i in 0..<n {
            if let f = pcm.floatChannelData { x[i] = Double(f[0][i * stride]) }
            else if let s16 = pcm.int16ChannelData { x[i] = Double(s16[0][i * stride]) / 32768 }
            else if let s32 = pcm.int32ChannelData { x[i] = Double(s32[0][i * stride]) / 2_147_483_648 }
            else { return }
        }
        func goertzel(_ hz: Double) -> Double {
            let coeff = 2 * cos(2 * Double.pi * hz / fmt.sampleRate)
            var s1 = 0.0, s2 = 0.0
            for v in x { let s0 = v + coeff * s1 - s2; s2 = s1; s1 = s0 }
            return sqrt(max(0, s1 * s1 + s2 * s2 - coeff * s1 * s2)) / Double(n)
        }
        let tone = Self.tones.map(goertzel), noise = goertzel(reference)
        lock.lock(); readings.append((Date(), tone, noise)); lock.unlock()
    }

    /// Mean tone level and mean reference (noise) level over a window, both linear.
    func mean(from: Date, to: Date) -> (tones: [Double], noise: Double) {
        lock.lock(); defer { lock.unlock() }
        let v = readings.filter { $0.0 >= from && $0.0 <= to }
        guard !v.isEmpty else { return (Self.tones.map { _ in 0 }, 0) }
        let t = Self.tones.indices.map { i in v.map { $0.1[i] }.reduce(0, +) / Double(v.count) }
        return (t, v.map(\.2).reduce(0, +) / Double(v.count))
    }

    /// Plays the quiet test tones through the current output from a separate process (so they count as another app's audio).
    static func playTones(seconds: Double, amplitude: Float = 0.025, frequencies: [Double] = tones) -> Process? {
        let rate = 48_000
        var samples = [Float](repeating: 0, count: Int(seconds) * rate)
        for i in samples.indices {
            var v = 0.0
            for f in frequencies { v += sin(2 * Double.pi * f * Double(i) / Double(rate)) }
            samples[i] = amplitude * Float(v)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pieflow-tone.wav")
        guard (try? WAV.encode(samples, sampleRate: rate).write(to: url)) != nil else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        p.arguments = [url.path]
        do { try p.run() } catch { return nil }
        return p
    }
}

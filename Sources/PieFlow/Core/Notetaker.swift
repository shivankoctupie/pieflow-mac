import Foundation
import AVFoundation
import ScreenCaptureKit
import Combine

/// Captures system audio (the other people on a call) via ScreenCaptureKit.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "pieflow.sysaudio")
    private var converter: AVAudioConverter?
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private let lock = NSLock()
    private var samples: [Float] = []
    var onError: ((String) -> Void)?

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw PieError("No display found for audio capture") }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48_000
        cfg.channelCount = 2
        cfg.width = 2; cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 2)
        cfg.queueDepth = 3
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
    }

    func stop() async -> [Float] {
        if let stream { try? await stream.stopCapture() }
        stream = nil
        return snapshot()
    }

    func snapshot() -> [Float] { lock.lock(); defer { lock.unlock() }; return samples }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.write("system audio stopped: \(error.localizedDescription)")
        onError?(error.localizedDescription)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sb.isValid, let desc = sb.formatDescription,
              let asbd = desc.audioStreamBasicDescription else { return }
        var asbdCopy = asbd
        guard let inFormat = AVAudioFormat(streamDescription: &asbdCopy) else { return }
        if converter == nil || converter?.inputFormat != inFormat {
            converter = AVAudioConverter(from: inFormat, to: outFormat)
        }
        let frames = AVAudioFrameCount(sb.numSamples)
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames) else { return }
        pcm.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
        guard status == noErr, let converter else { return }
        let cap = AVAudioFrameCount(Double(frames) * 16_000 / inFormat.sampleRate + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, st in
            if fed { st.pointee = .noDataNow; return nil }
            fed = true; st.pointee = .haveData; return pcm
        }
        guard err == nil, let ch = out.floatChannelData else { return }
        let chunk = UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength))
        lock.lock(); samples.append(contentsOf: chunk); lock.unlock()
    }
}

final class Notetaker: ObservableObject {
    @Published var activeID: UUID?
    @Published var elapsed: TimeInterval = 0
    @Published var micLevel: Float = 0
    @Published var statusLine = ""

    let store: Store
    let transcriber: Transcriber
    let llm: LLM
    private let mic = MicRecorder()
    private var system: SystemAudioCapture?
    private var timer: Timer?
    private var started = Date()
    private var micOffset = 0
    private var sysOffset = 0
    private var chunkTask: Task<Void, Never>?
    private let chunkSeconds = 45

    init(store: Store, transcriber: Transcriber, llm: LLM) {
        self.store = store; self.transcriber = transcriber; self.llm = llm
        mic.onLevel = { [weak self] l in DispatchQueue.main.async { self?.micLevel = l } }
    }

    var isRecording: Bool { activeID != nil }

    private func update(_ id: UUID, _ f: (inout Meeting) -> Void) {
        guard let i = store.meetings.firstIndex(where: { $0.id == id }) else { return }
        f(&store.meetings[i])
    }

    @MainActor
    func start(title: String? = nil) async {
        guard !isRecording else { return }
        guard Permissions.microphone else { Permissions.requestMicrophone { _ in }; statusLine = "Microphone access needed"; return }
        let fmt = DateFormatter(); fmt.dateFormat = "MMM d, h:mm a"
        let meeting = Meeting(title: title ?? "Meeting \(fmt.string(from: Date()))")
        store.meetings.insert(meeting, at: 0)
        do { try mic.start(deviceUID: store.settings.microphoneUID) } catch {
            update(meeting.id) { $0.status = .failed; $0.errorMessage = error.localizedDescription }
            return
        }
        if store.settings.notetakerSystemAudio {
            let sys = SystemAudioCapture()
            do { try await sys.start(); system = sys } catch {
                Log.write("system audio unavailable: \(error.localizedDescription)")
                statusLine = "Recording your mic only. Allow Screen Recording to capture the other side."
                if !Permissions.screenRecording { Permissions.requestScreenRecording() }
            }
        }
        micOffset = 0; sysOffset = 0
        started = Date()
        activeID = meeting.id
        elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.elapsed = Date().timeIntervalSince(self.started)
            if Int(self.elapsed) % self.chunkSeconds == 0 { self.transcribePending(final: false) }
        }
        Sounds.start()
    }

    /// Transcribes audio captured since the last pass, so the transcript fills in live.
    private func transcribePending(final: Bool) {
        guard let id = activeID ?? (final ? lastID : nil) else { return }
        let micAll = mic.snapshot()
        let sysAll = system?.snapshot() ?? []
        let micNew = Array(micAll.dropFirst(micOffset)), sysNew = Array(sysAll.dropFirst(sysOffset))
        let micStart = Double(micOffset) / 16_000, sysStart = Double(sysOffset) / 16_000
        micOffset = micAll.count; sysOffset = sysAll.count
        let previous = chunkTask
        chunkTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            var segs: [TranscriptSegment] = []
            for (samples, start, who) in [(micNew, micStart, "You"), (sysNew, sysStart, "Others")] {
                guard samples.count > 16_000, WAV.rms(samples) > 0.003 else { continue }
                do {
                    let r = try await self.transcriber.transcribe(samples, timeout: 90)
                    if r.segments.isEmpty, !r.text.isEmpty {
                        segs.append(TranscriptSegment(start: start, end: start + Double(samples.count) / 16_000, speaker: who, text: r.text))
                    } else {
                        segs += r.segments.map { TranscriptSegment(start: $0.start + start, end: $0.end + start, speaker: who, text: Transcriber.clean($0.text)) }
                            .filter { !$0.text.isEmpty }
                    }
                } catch {
                    Log.write("meeting chunk failed: \(error.localizedDescription)")
                    await MainActor.run { self.statusLine = "A chunk failed to transcribe: \(error.localizedDescription.prefix(80))" }
                }
            }
            let found = segs
            await MainActor.run {
                self.update(id) { m in
                    m.segments = (m.segments + found).sorted { $0.start < $1.start }
                }
            }
        }
    }

    private var lastID: UUID?

    @MainActor
    func stop() async {
        guard let id = activeID else { return }
        timer?.invalidate()
        lastID = id
        let duration = Date().timeIntervalSince(started)
        transcribePending(final: true)
        let micAll = mic.stop()
        let sysAll = await system?.stop() ?? []
        system = nil
        activeID = nil
        Sounds.stop()
        update(id) { $0.status = .processing; $0.durationSec = duration }
        // Keep the raw audio next to the meeting so it can be reprocessed.
        let folder = Paths.meetings.appendingPathComponent(id.uuidString)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? WAV.encode(micAll).write(to: folder.appendingPathComponent("mic.wav"))
        if !sysAll.isEmpty { try? WAV.encode(sysAll).write(to: folder.appendingPathComponent("system.wav")) }
        update(id) { $0.audioFolder = id.uuidString }
        await chunkTask?.value
        // Capture any tail that arrived between the last snapshot and stop.
        let tailMic = Array(micAll.dropFirst(micOffset)), tailSys = Array(sysAll.dropFirst(sysOffset))
        if tailMic.count > 16_000 || tailSys.count > 16_000 {
            var segs: [TranscriptSegment] = []
            for (s, off, who) in [(tailMic, micOffset, "You"), (tailSys, sysOffset, "Others")] where s.count > 16_000 && WAV.rms(s) > 0.003 {
                if let r = try? await transcriber.transcribe(s, timeout: 90), !r.text.isEmpty {
                    let base = Double(off) / 16_000
                    segs.append(TranscriptSegment(start: base, end: base + Double(s.count) / 16_000, speaker: who, text: r.text))
                }
            }
            update(id) { m in m.segments = (m.segments + segs).sorted { $0.start < $1.start } }
        }
        await summarize(id)
    }

    @MainActor
    func summarize(_ id: UUID) async {
        guard let m = store.meetings.first(where: { $0.id == id }) else { return }
        guard !m.segments.isEmpty else {
            update(id) { $0.status = .ready; $0.summary = "No speech was detected in this meeting." }
            return
        }
        update(id) { $0.status = .processing }
        statusLine = "Writing summary"
        let system = """
        You write meeting notes from a transcript. "You" is the person who recorded the meeting; "Others" are the remote participants.
        Output Markdown in exactly this shape:
        Title: <a short specific title, max 8 words>

        ## Summary
        <3 to 6 sentences>

        ## Action items
        - [ ] <owner if known>: <task>

        ## Key points
        - <point>

        Use plain, direct English. Do not invent facts that are not in the transcript. Never use em dashes or en dashes.
        """
        do {
            let transcript = String(m.transcriptText.prefix(120_000))
            var out = try await llm.complete(system: system, user: transcript, timeout: 120, allowCLI: true, maxTokens: 3000)
            var title = m.title
            if let first = out.components(separatedBy: "\n").first, first.lowercased().hasPrefix("title:") {
                title = first.dropFirst(6).trimmingCharacters(in: .whitespaces)
                out = out.components(separatedBy: "\n").dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            out = out.replacingOccurrences(of: "\u{2014}", with: ", ").replacingOccurrences(of: "\u{2013}", with: ", ")
            update(id) { $0.summary = out; $0.title = title.isEmpty ? $0.title : title; $0.status = .ready; $0.errorMessage = nil }
            statusLine = ""
        } catch {
            update(id) { $0.status = .ready; $0.errorMessage = "Summary unavailable: \(error.localizedDescription)" }
            statusLine = ""
        }
    }

    /// Re-transcribes a meeting from its saved audio files.
    @MainActor
    func reprocess(_ id: UUID) async {
        guard let m = store.meetings.first(where: { $0.id == id }), let f = m.audioFolder else { return }
        update(id) { $0.status = .processing; $0.segments = []; $0.errorMessage = nil }
        let folder = Paths.meetings.appendingPathComponent(f)
        var segs: [TranscriptSegment] = []
        for (file, who) in [("mic.wav", "You"), ("system.wav", "Others")] {
            guard let samples = try? WAV.readMono16k(folder.appendingPathComponent(file)) else { continue }
            let step = 16_000 * 300
            var i = 0
            while i < samples.count {
                let piece = Array(samples[i..<min(samples.count, i + step)])
                if WAV.rms(piece) > 0.003, let r = try? await transcriber.transcribe(piece, timeout: 180) {
                    let base = Double(i) / 16_000
                    if r.segments.isEmpty { segs.append(TranscriptSegment(start: base, end: base + 300, speaker: who, text: r.text)) }
                    else { segs += r.segments.map { TranscriptSegment(start: $0.start + base, end: $0.end + base, speaker: who, text: $0.text) } }
                }
                i += step
            }
        }
        update(id) { $0.segments = segs.sorted { $0.start < $1.start } }
        await summarize(id)
    }
}

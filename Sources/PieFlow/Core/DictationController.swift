import AppKit
import Combine

final class DictationController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case recording(handsFree: Bool)
        case processing
        case transforming(String)
        case message(String, isError: Bool)
    }

    @Published var phase: Phase = .idle
    @Published var level: Float = 0
    @Published var lastText: String = ""

    let store: Store
    let transcriber: Transcriber
    let engine: TextEngine
    let hotkeys = HotkeyMonitor()
    private let mic = MicRecorder()
    private var startedAt = Date()
    private var targetApp: NSRunningApplication?
    private var levelTimer: Timer?
    private var maxTimer: Timer?
    private var messageWork: DispatchWorkItem?

    init(store: Store, transcriber: Transcriber, engine: TextEngine) {
        self.store = store
        self.transcriber = transcriber
        self.engine = engine
        mic.onLevel = { [weak self] l in DispatchQueue.main.async { self?.level = self.map { $0.level * 0.4 + l * 0.6 } ?? l } }
        hotkeys.onEvent = { [weak self] e in self?.handle(e) }
    }

    func startListening() {
        hotkeys.hotkey = store.settings.hotkey
        hotkeys.transformsEnabled = store.settings.transformsEnabled
        let was = hotkeys.isListening
        hotkeys.start()
        if was != hotkeys.isListening { objectWillChange.send() }
    }

    var isRecording: Bool { if case .recording = phase { return true }; return false }

    private func handle(_ e: HotkeyMonitor.Event) {
        switch e {
        case .pressDown:
            if case .recording(let hf) = phase, hf { stopAndProcess() }
            else if canStart { begin(handsFree: false) }
        case .pressUp:
            if case .recording(let hf) = phase, !hf {
                if Date().timeIntervalSince(startedAt) < 0.25 { cancel(silent: true) } else { stopAndProcess() }
            }
        case .handsFree:
            if case .recording = phase { setPhase(.recording(handsFree: true)) }
            else if canStart { begin(handsFree: true) }
        case .cancel:
            if isRecording { cancel(silent: false) }
        case .transform(let digit):
            if canStart, let tf = store.transforms.first(where: { $0.hotkeyDigit == digit }) { runTransform(tf) }
        }
    }

    private var canStart: Bool {
        switch phase {
        case .idle, .message: return true
        default: return false
        }
    }

    private func setPhase(_ p: Phase) {
        phase = p
        hotkeys.recordingActive = isRecording
        if case .recording(let hf) = p { hotkeys.handsFreeActive = hf } else { hotkeys.handsFreeActive = false }
    }

    func toggleFromUI() {
        if isRecording { stopAndProcess() } else if canStart { begin(handsFree: true) }
    }

    func begin(handsFree: Bool) {
        guard Permissions.microphone else {
            Permissions.requestMicrophone { _ in }
            flash("Microphone access needed", error: true)
            return
        }
        targetApp = NSWorkspace.shared.frontmostApplication
        do {
            try mic.start(deviceUID: store.settings.microphoneUID)
        } catch {
            flash(error.localizedDescription, error: true); return
        }
        startedAt = Date()
        messageWork?.cancel()
        setPhase(.recording(handsFree: handsFree))
        Sounds.start()
        if store.settings.muteWhileDictating { SystemAudio.mute(true) }
        maxTimer?.invalidate()
        maxTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: false) { [weak self] _ in self?.stopAndProcess() }
        Log.write("dictation start (handsFree=\(handsFree)) app=\(targetApp?.localizedName ?? "?")")
    }

    func cancel(silent: Bool) {
        mic.stop()
        maxTimer?.invalidate()
        if store.settings.muteWhileDictating { SystemAudio.mute(false) }
        level = 0
        if silent { setPhase(.idle) } else { flash("Cancelled", error: false) }
    }

    func stopAndProcess() {
        guard isRecording else { return }
        maxTimer?.invalidate()
        let samples = mic.stop()
        let duration = Date().timeIntervalSince(startedAt)
        if store.settings.muteWhileDictating { SystemAudio.mute(false) }
        Sounds.stop()
        level = 0
        guard samples.count > Int(MicRecorder.sampleRate * 0.3), WAV.rms(samples) > 0.002 else {
            flash("Didn't catch that", error: false); return
        }
        setPhase(.processing)
        let app = targetApp
        let category = AppCategory.from(bundleID: app?.bundleIdentifier, appName: app?.localizedName)
        Task { @MainActor in
            do {
                let result = try await transcriber.transcribe(samples)
                guard !result.text.isEmpty else { flash("Didn't catch that", error: false); return }
                var text = await engine.process(result.text, category: category, appName: app?.localizedName)
                if store.settings.autoApplyTransform, let id = store.settings.autoApplyTransformID,
                   let tf = store.transforms.first(where: { $0.id == id }) {
                    text = (try? await engine.transform(text, with: tf)) ?? text
                }
                insert(text, into: app)
                let audioName = "\(UUID().uuidString).wav"
                try? WAV.encode(samples).write(to: Paths.audio.appendingPathComponent(audioName))
                store.history.insert(DictationEntry(rawText: result.text, text: text, appName: app?.localizedName,
                                                    bundleID: app?.bundleIdentifier, category: category,
                                                    durationSec: duration, engine: result.engine, audioFile: audioName), at: 0)
                lastText = text
                setPhase(.idle)
            } catch {
                Sounds.error()
                Log.write("dictation failed: \(error.localizedDescription)")
                // Keep the audio so it can be retried from history.
                let audioName = "\(UUID().uuidString).wav"
                try? WAV.encode(samples).write(to: Paths.audio.appendingPathComponent(audioName))
                store.history.insert(DictationEntry(rawText: "", text: "", appName: app?.localizedName, bundleID: app?.bundleIdentifier,
                                                    category: category, durationSec: duration, engine: "failed", audioFile: audioName), at: 0)
                flash(error.localizedDescription.components(separatedBy: "\n").first ?? "Transcription failed", error: true)
            }
        }
    }

    private func insert(_ text: String, into app: NSRunningApplication?) {
        guard Permissions.accessibility else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            flash("Copied. Allow Accessibility to auto-paste", error: true)
            return
        }
        if let app, app.processIdentifier != NSRunningApplication.current.processIdentifier,
           NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
            app.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { Inserter.paste(text) }
        } else {
            Inserter.paste(text)
        }
    }

    /// Re-run transcription for a history entry (used by "Retry" in history).
    func retry(_ entry: DictationEntry, with provider: STTProvider? = nil) async throws -> DictationEntry {
        guard let f = entry.audioFile else { throw PieError("Audio for this dictation was not kept") }
        let samples = try WAV.readMono16k(Paths.audio.appendingPathComponent(f))
        let result = try await transcriber.transcribe(samples, only: provider)
        var e = entry
        e.rawText = result.text
        e.text = await engine.process(result.text, category: entry.category, appName: entry.appName)
        e.engine = result.engine
        return e
    }

    func runTransform(_ tf: Transform) {
        guard Permissions.accessibility else { flash("Allow Accessibility to use Transforms", error: true); return }
        setPhase(.transforming(tf.name))
        Task { @MainActor in
            let sel = await Inserter.copySelection()
            guard !sel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                flash("Select some text first", error: false); return
            }
            do {
                let out = try await engine.transform(sel, with: tf)
                Inserter.paste(out)
                store.fixesCount += 1
                setPhase(.idle)
            } catch {
                flash(error.localizedDescription.components(separatedBy: "\n").first ?? "Transform failed", error: true)
            }
        }
    }

    func flash(_ msg: String, error: Bool) {
        setPhase(.message(msg, isError: error))
        messageWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            if case .message = self?.phase { self?.setPhase(.idle) }
        }
        messageWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + (error ? 3.5 : 1.6), execute: w)
    }
}

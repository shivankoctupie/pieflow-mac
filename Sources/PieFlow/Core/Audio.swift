import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transport: UInt32
    let sampleRate: Double

    var isBluetooth: Bool { transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE }
    var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }
    var transportName: String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "built in"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeAggregate: return "aggregate"
        case kAudioDeviceTransportTypeVirtual: return "virtual"
        default: return "other"
        }
    }
    var summary: String { "\(name) [\(transportName), \(Int(sampleRate)) Hz]" }
}

/// Which microphone PieFlow will actually open, and why.
struct InputChoice {
    let device: AudioDevice?      // nil = let the system default drive
    let isolate: Bool             // voice processing on or off for this capture
    let reason: String
}

enum AudioDevices {
    static func inputs() -> [AudioDevice] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard inputChannels(id) > 0 else { return nil }
            return make(id)
        }
    }

    private static func make(_ id: AudioDeviceID) -> AudioDevice {
        AudioDevice(id: id, uid: string(id, kAudioDevicePropertyDeviceUID) ?? "\(id)",
                    name: string(id, kAudioObjectPropertyName) ?? "Unknown",
                    transport: u32(id, kAudioDevicePropertyTransportType),
                    sampleRate: f64(id, kAudioDevicePropertyNominalSampleRate))
    }

    static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDevice? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0); var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return make(id)
    }
    static var defaultInput: AudioDevice? { defaultDevice(kAudioHardwarePropertyDefaultInputDevice) }
    static var defaultOutput: AudioDevice? { defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) }

    /// True when the default output is the Mac's own speakers (headphones in the jack count as not speakers).
    static var outputIsBuiltInSpeakers: Bool {
        guard let out = defaultOutput, out.isBuiltIn else { return false }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSource, mScope: kAudioDevicePropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMain)
        var src: UInt32 = 0; var size = UInt32(4)
        if AudioObjectGetPropertyData(out.id, &addr, 0, nil, &size, &src) == noErr, src == 0x6864_706E { return false } // 'hdpn'
        return true
    }

    /// The microphone policy. A pinned device wins. Otherwise, when the system default input is a
    /// Bluetooth headset, prefer the built in microphone: the headset's mic runs over the narrowband
    /// headset profile (16 kHz, lazy to open, drags playback quality down), which is what produced empty
    /// and garbled dictations. Voice isolation is only useful when the Mac's own speakers are playing.
    static func choose(preferredUID: String?, voiceIsolation: Bool) -> InputChoice {
        let isolate = voiceIsolation && (outputIsBuiltInSpeakers || ProcessInfo.processInfo.environment["PIEFLOW_FORCE_ISOLATION"] == "1")
        let why = isolate ? "isolation on (speakers active)" : voiceIsolation ? "isolation off (output is \(defaultOutput?.name ?? "not the speakers"))" : "isolation off (setting)"
        if let uid = preferredUID {
            if let d = device(uid: uid) { return InputChoice(device: d, isolate: isolate, reason: "pinned \(d.summary), \(why)") }
            return InputChoice(device: nil, isolate: isolate, reason: "pinned device not present, using system default, \(why)")
        }
        guard let def = defaultInput else { return InputChoice(device: nil, isolate: isolate, reason: "no default input, \(why)") }
        if def.isBluetooth, let builtIn = inputs().first(where: { $0.isBuiltIn }) {
            return InputChoice(device: builtIn, isolate: isolate, reason: "default input is Bluetooth (\(def.summary)), using \(builtIn.summary), \(why)")
        }
        return InputChoice(device: def, isolate: isolate, reason: "system default \(def.summary), \(why)")
    }

    static func defaultInputName() -> String {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0); var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return string(id, kAudioObjectPropertyName) ?? "System default"
    }

    static func device(uid: String?) -> AudioDevice? {
        guard let uid else { return nil }
        return inputs().first { $0.uid == uid }
    }

    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                              mScope: kAudioDevicePropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func u32(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var v: UInt32 = 0; var size = UInt32(4)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v)
        return v
    }
    private static func f64(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> Double {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var v: Double = 0; var size = UInt32(8)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v)
        return v
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }
}

/// Captures the microphone and delivers 16 kHz mono float samples.
final class MicRecorder {
    static let sampleRate: Double = 16_000
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private let lock = NSLock()
    private var samples: [Float] = []
    private(set) var isRunning = false
    var onLevel: ((Float) -> Void)?
    /// Called with each converted chunk (used by the notetaker).
    var onChunk: (([Float]) -> Void)?

    /// True when the running engine has Apple voice processing (echo cancellation + noise suppression) on.
    private(set) var voiceProcessingActive = false
    private(set) var inputFormatDescription = ""

    /// `voiceIsolation` enables Apple's voice processing on the input: it cancels whatever this Mac is
    /// playing through its speakers (music, a call, a video) and suppresses background noise, so only the
    /// person at the keyboard is transcribed. Falls back to the plain microphone if the device refuses it.
    private(set) var choice: InputChoice?
    private var configObserver: NSObjectProtocol?
    private var restarts = 0
    private var watchdog: Timer?
    private var startedAt = Date()
    /// Timing for the "is it instant" question: when start() was called and when audio first arrived.
    private(set) var startCalledAt = Date()
    private(set) var startReturnedAt = Date()
    private(set) var firstBufferAt: Date?

    func start(deviceUID: String?, voiceIsolation: Bool = true) throws {
        startCalledAt = Date(); firstBufferAt = nil
        defer { startReturnedAt = Date() }
        let c = AudioDevices.choose(preferredUID: deviceUID, voiceIsolation: voiceIsolation)
        choice = c
        restarts = 0
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()
        if let w = warm, w.key == Self.key(c) {
            // Fast path: the pipeline was prepared ahead of time, only the mic has to open.
            warm = nil
            do {
                switch w.backend {
                case .engine(let e, let isolate): try run(engine: e, voiceIsolation: isolate, device: nil)
                case .session(let s, let d, let dev): try run(session: s, delegate: d, device: dev)
                }
                Log.write("mic: prepared \(w.backend.label), \(c.reason); format \(inputFormatDescription)")
                return
            } catch {
                Log.write("mic: prepared pipeline failed (\(error.localizedDescription)), building fresh")
            }
        }
        let isDefault = Self.usesEngine(c)
        if isDefault {
            // AVAudioEngine only ever captures the system default device reliably, and it is the only
            // path that offers voice processing.
            do {
                try startEngine(device: nil, voiceIsolation: c.isolate)
            } catch where c.isolate {
                Log.write("voice processing unavailable (\(error.localizedDescription)), using plain microphone")
                try startEngine(device: nil, voiceIsolation: false)
            }
            Log.write("mic: engine, \(c.reason); format \(inputFormatDescription)")
        } else if let dev = c.device {
            // A specific device (the built in mic while earbuds are the default, or a pinned mic) goes
            // through AVCaptureSession, which switches devices properly. No voice processing there.
            do {
                try startCapture(device: dev)
                Log.write("mic: capture session, \(c.reason)\(c.isolate ? " (isolation unavailable on a non default device)" : ""); format \(inputFormatDescription)")
            } catch {
                Log.write("mic: capture session for \(dev.name) failed (\(error.localizedDescription)), using the system default")
                try startEngine(device: nil, voiceIsolation: c.isolate)
            }
        }
    }

    // MARK: AVCaptureSession backend

    private var session: AVCaptureSession?
    private var captureDelegate: CaptureDelegate?

    final class CaptureDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
        let handle: (CMSampleBuffer) -> Void
        init(_ h: @escaping (CMSampleBuffer) -> Void) { handle = h }
        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) { handle(sampleBuffer) }
    }

    private func buildSession(device: AudioDevice) throws -> (AVCaptureSession, CaptureDelegate) {
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
        guard let cap = devices.first(where: { $0.uniqueID == device.uid }) ?? devices.first(where: { $0.localizedName == device.name }) else {
            throw PieError("\(device.name) is not available to AVCaptureSession")
        }
        let s = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: cap)
        guard s.canAddInput(input) else { throw PieError("cannot add \(device.name) as capture input") }
        s.addInput(input)
        let out = AVCaptureAudioDataOutput()
        let delegate = CaptureDelegate { [weak self] sb in self?.ingest(sampleBuffer: sb) }
        out.setSampleBufferDelegate(delegate, queue: DispatchQueue(label: "pieflow.capture"))
        guard s.canAddOutput(out) else { throw PieError("cannot add audio output") }
        s.addOutput(out)
        return (s, delegate)
    }

    private func run(session s: AVCaptureSession, delegate: CaptureDelegate, device: AudioDevice) throws {
        stopEngine()
        s.startRunning()
        guard s.isRunning else { throw PieError("capture session did not start") }
        session = s
        captureDelegate = delegate
        converter = nil
        voiceProcessingActive = false
        inputFormatDescription = "capture \(device.name)"
        isRunning = true
        startedAt = Date()
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            guard let self, self.isRunning, self.session === s else { return }
            self.lock.lock(); let n = self.samples.count; self.lock.unlock()
            guard n == 0 else { return }
            Log.write("mic: \(device.name) delivered no audio in 1.5 s, falling back")
            self.fallBack(isolation: false)
        }
    }

    private func startCapture(device: AudioDevice) throws {
        let (s, d) = try buildSession(device: device)
        try run(session: s, delegate: d, device: device)
    }

    /// Last resort when a device stays silent: the built in mic through the capture session, else the engine default.
    private func fallBack(isolation: Bool) {
        if let builtIn = AudioDevices.inputs().first(where: { $0.isBuiltIn }), builtIn.id != AudioDevices.defaultInput?.id || session == nil {
            do { try startCapture(device: builtIn); Log.write("mic: fallback to \(builtIn.name) via capture session"); return }
            catch { Log.write("mic: built in fallback failed: \(error.localizedDescription)") }
        }
        do { try startEngine(device: nil, voiceIsolation: isolation); Log.write("mic: fallback to engine default") }
        catch { Log.write("mic: fallback failed: \(error.localizedDescription)") }
    }

    private func ingest(sampleBuffer sb: CMSampleBuffer) {
        guard sb.isValid, let desc = sb.formatDescription, let asbd = desc.audioStreamBasicDescription else { return }
        var copy = asbd
        guard let fmt = AVAudioFormat(streamDescription: &copy) else { return }
        let frames = AVAudioFrameCount(sb.numSamples)
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return }
        pcm.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList) == noErr else { return }
        process(pcm)
    }

    // MARK: standby pipeline

    enum Backend {
        case engine(AVAudioEngine, isolate: Bool)
        case session(AVCaptureSession, CaptureDelegate, AudioDevice)
        var label: String { if case .engine = self { return "engine" } else { return "capture session" } }
    }
    struct Warm { let key: String; let backend: Backend }
    private var warm: Warm?

    static func key(_ c: InputChoice) -> String { "\(c.device?.id ?? 0)/\(c.isolate)/\(AudioDevices.defaultInput?.id ?? 0)" }
    /// Bluetooth mics flap between profiles while the engine starts; the capture session copes, the engine does not.
    static func usesEngine(_ c: InputChoice) -> Bool {
        (c.device == nil || c.device?.id == AudioDevices.defaultInput?.id) && c.device?.isBluetooth != true
    }

    /// Builds the pipeline for the current devices without opening the microphone, so the next
    /// start() is near instant. Cheap to call often: it rebuilds only when the choice changed.
    func prewarm(deviceUID: String?, voiceIsolation: Bool) {
        guard !isRunning else { return }
        let c = AudioDevices.choose(preferredUID: deviceUID, voiceIsolation: voiceIsolation)
        let k = Self.key(c)
        if warm?.key == k { return }
        discardWarm()
        do {
            if Self.usesEngine(c) {
                let e: AVAudioEngine
                do { e = try buildEngine(voiceIsolation: c.isolate) } catch where c.isolate { e = try buildEngine(voiceIsolation: false) }
                warm = Warm(key: k, backend: .engine(e, isolate: c.isolate))
            } else if let dev = c.device {
                let (s, d) = try buildSession(device: dev)
                warm = Warm(key: k, backend: .session(s, d, dev))
            }
            Log.write("mic: standby pipeline ready (\(warm?.backend.label ?? "none"), \(c.reason))")
        } catch {
            Log.write("mic: standby pipeline failed: \(error.localizedDescription)")
        }
    }

    func discardWarm() {
        if case .engine(let e, _)? = warm?.backend { e.inputNode.removeTap(onBus: 0) }
        warm = nil
    }

    private func buildEngine(voiceIsolation: Bool) throws -> AVAudioEngine {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if voiceIsolation {
            try input.setVoiceProcessingEnabled(true)
            input.isVoiceProcessingBypassed = false
            input.isVoiceProcessingAGCEnabled = false
            if #available(macOS 14.0, *) {
                input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
            }
        }
        let inFormat = input.inputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw NSError(domain: "PieFlow", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone input available."])
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buffer, _ in self?.process(buffer) }
        engine.prepare()
        return engine
    }

    private func run(engine: AVAudioEngine, voiceIsolation: Bool, device: AudioDevice?) throws {
        stopEngine()
        let inFormat = engine.inputNode.inputFormat(forBus: 0)
        inputFormatDescription = "\(Int(inFormat.sampleRate))Hz/\(inFormat.channelCount)ch"
        converter = nil
        voiceProcessingActive = voiceIsolation
        try engine.start()
        self.engine = engine
        isRunning = true
        startedAt = Date()
        armWatchdog(engine: engine, device: device, voiceIsolation: voiceIsolation)
        observeConfigChanges(engine)
    }

    private func startEngine(device: AudioDevice?, voiceIsolation: Bool) throws {
        stopEngine()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if voiceIsolation {
            try input.setVoiceProcessingEnabled(true)
            input.isVoiceProcessingBypassed = false
            input.isVoiceProcessingAGCEnabled = false
            // Keep other apps at full volume; we only want the cancellation, not the FaceTime style ducking.
            if #available(macOS 14.0, *) {
                input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
            }
        }
        // Select the device after voice processing (enabling it swaps the underlying audio unit).
        // AUAudioUnit.setDeviceID is the supported way; the raw AudioUnitSetProperty route was accepted
        // silently and then captured nothing when the chosen device was not the system default.
        if let dev = device {
            do { try input.auAudioUnit.setDeviceID(dev.id) } catch {
                Log.write("mic: could not select \(dev.name): \(error.localizedDescription), using the system default")
            }
        }
        voiceProcessingActive = voiceIsolation
        let inFormat = input.inputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw NSError(domain: "PieFlow", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone input available."])
        }
        inputFormatDescription = "\(Int(inFormat.sampleRate))Hz/\(inFormat.channelCount)ch"
        converter = nil
        // Tap in the node's own format (a stale or mismatched format here throws an uncatchable
        // NSException). process() takes channel 0 and resamples, whatever arrives.
        input.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        isRunning = true
        startedAt = Date()
        armWatchdog(engine: engine, device: device, voiceIsolation: voiceIsolation)
        observeConfigChanges(engine)
    }

    /// A device that accepted the selection but delivers nothing in the first second is dead to us.
    private func armWatchdog(engine: AVAudioEngine, device: AudioDevice?, voiceIsolation: Bool) {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            guard let self, self.isRunning, self.engine === engine else { return }
            self.lock.lock(); let n = self.samples.count; self.lock.unlock()
            guard n == 0 else { return }
            Log.write("mic: \(device?.name ?? "default device") delivered no audio in 1.2 s, falling back")
            self.fallBack(isolation: voiceIsolation)
        }
    }

    /// Plugging or unplugging headphones mid dictation tears the engine down. Rebuild it and keep
    /// the audio captured so far instead of silently returning an empty recording.
    private func observeConfigChanges(_ engine: AVAudioEngine) {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self, self.isRunning, self.restarts < 3 else { return }
            self.restarts += 1
            let c = AudioDevices.choose(preferredUID: self.choice?.device?.uid, voiceIsolation: self.choice?.isolate ?? false)
            Log.write("mic: audio configuration changed, restarting capture (\(c.reason))")
            do {
                if Self.usesEngine(c) { try self.startEngine(device: nil, voiceIsolation: c.isolate) }
                else if let dev = c.device { try self.startCapture(device: dev) }
            } catch {
                Log.write("mic: restart after configuration change failed: \(error.localizedDescription)")
            }
        }
    }

    private static let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: MicRecorder.sampleRate, channels: 1, interleaved: false)!

    /// Channel 0 of whatever the tap delivers, resampled to 16 kHz. Multi channel voice processing
    /// output is identical copies, and AVAudioConverter's own channel mixing produced silence for it.
    private func process(_ buffer: AVAudioPCMBuffer) {
        if firstBufferAt == nil { firstBufferAt = Date() }
        let frames = Int(buffer.frameLength)
        guard frames > 0, let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate, channels: 1, interleaved: false),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(frames)) else { return }
        mono.frameLength = AVAudioFrameCount(frames)
        let dst = mono.floatChannelData![0]
        if let f = buffer.floatChannelData {
            let stride = buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1
            for i in 0..<frames { dst[i] = f[0][i * stride] }
        } else if let s16 = buffer.int16ChannelData {
            let stride = buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1
            for i in 0..<frames { dst[i] = Float(s16[0][i * stride]) / 32768 }
        } else { return }
        if converter == nil || converter?.inputFormat != monoFormat {
            converter = AVAudioConverter(from: monoFormat, to: Self.outFormat)
        }
        guard let converter else { return }
        let ratio = Self.outFormat.sampleRate / monoFormat.sampleRate
        let cap = AVAudioFrameCount(Double(frames) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.outFormat, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return mono
        }
        guard err == nil, let ch = out.floatChannelData else { return }
        let chunk = Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
        lock.lock(); samples.append(contentsOf: chunk); lock.unlock()
        var sum: Float = 0
        for s in chunk { sum += s * s }
        let rms = sqrt(sum / Float(max(chunk.count, 1)))
        onLevel?(min(1, rms * 9))
        onChunk?(chunk)
    }

    @discardableResult
    func stop() -> [Float] {
        stopEngine()
        lock.lock(); defer { lock.unlock() }
        let out = samples
        samples.removeAll()
        return out
    }

    func snapshot() -> [Float] { lock.lock(); defer { lock.unlock() }; return samples }

    private func stopEngine() {
        watchdog?.invalidate(); watchdog = nil
        if let session { session.stopRunning() }
        session = nil; captureDelegate = nil
        if let configObserver { NotificationCenter.default.removeObserver(configObserver); self.configObserver = nil }
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        isRunning = false
    }
}

enum WAV {
    /// 16-bit PCM mono WAV.
    static func encode(_ samples: [Float], sampleRate: Int = 16_000) -> Data {
        var d = Data()
        let dataBytes = samples.count * 2
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + dataBytes))
        d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(UInt32(dataBytes))
        var pcm = [Int16](repeating: 0, count: samples.count)
        for i in samples.indices { pcm[i] = Int16(max(-1, min(1, samples[i])) * 32767) }
        pcm.withUnsafeBufferPointer { d.append(UnsafeBufferPointer(start: UnsafeRawPointer($0.baseAddress!).assumingMemoryBound(to: UInt8.self), count: dataBytes)) }
        return d
    }

    /// Reads any audio file AVFoundation understands into 16 kHz mono floats.
    static func readMono16k(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
        try file.read(into: inBuf)
        guard let conv = AVAudioConverter(from: file.processingFormat, to: outFormat) else { return [] }
        let cap = AVAudioFrameCount(Double(inBuf.frameLength) * 16_000 / file.processingFormat.sampleRate + 1024)
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { return [] }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, st in
            if fed { st.pointee = .endOfStream; return nil }
            fed = true; st.pointee = .haveData; return inBuf
        }
        if let err { throw err }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }

    static func rms(_ s: [Float]) -> Float {
        guard !s.isEmpty else { return 0 }
        var sum: Float = 0
        for x in s { sum += x * x }
        return sqrt(sum / Float(s.count))
    }
}

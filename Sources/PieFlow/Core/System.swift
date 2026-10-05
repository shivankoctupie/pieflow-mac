import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import ServiceManagement

enum Permissions {
    static var accessibility: Bool { AXIsProcessTrusted() }
    static var inputMonitoring: Bool { CGPreflightListenEventAccess() }
    static var microphone: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }

    /// Accessibility and Input Monitoring are toggle lists in System Settings. An entry left there by an
    /// older copy of PieFlow shows as "on" but no longer matches this binary, so switching it does nothing.
    /// Clearing PieFlow's own entry first makes the prompt create a fresh one.
    static func requestAccessibility() {
        resetService("Accessibility")
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        open("Privacy_Accessibility")
    }
    static func requestInputMonitoring() {
        resetService("ListenEvent")
        if !CGRequestListenEventAccess() { open("Privacy_ListenEvent") }
    }

    @discardableResult
    static func resetService(_ service: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", service, Bundle.main.bundleIdentifier ?? "app.pieflow.mac"]
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        do { try p.run() } catch { Log.write("tccutil \(service): \(error.localizedDescription)"); return false }
        p.waitUntilExit()
        let msg = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        Log.write("tccutil reset \(service): exit \(p.terminationStatus) \(msg)")
        return p.terminationStatus == 0
    }
    static func requestMicrophone(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined: AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { done(ok) } }
        case .authorized: done(true)
        default: open("Privacy_Microphone"); done(false)
        }
    }
    static func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess() { open("Privacy_ScreenCapture") }
    }
    static func open(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
    static var summary: String {
        "mic=\(microphone) accessibility=\(accessibility) input=\(inputMonitoring) screen=\(screenRecording)"
    }

    /// Clears every privacy grant macOS holds for PieFlow (including stale ones from older builds).
    static func resetAll() {
        for s in ["Accessibility", "ListenEvent", "Microphone", "ScreenCapture", "AppleEvents"] { resetService(s) }
        Log.write("permissions reset")
    }

    /// Input Monitoring and Screen Recording only apply to a fresh process.
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"\(path)\""]
        try? p.run()
        Store.shared.flush()
        NSApp.terminate(nil)
    }

    static func openKeyboardSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
    }

    /// macOS setting "Press fn key to": 0 = Do Nothing, 1 = Change Input Source, 2 = Emoji, 3 = Dictation.
    static var fnUsageType: Int? {
        let v = CFPreferencesCopyValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString,
                                       kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return v as? Int
    }
}

enum LoginItem {
    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { Log.write("login item: \(error.localizedDescription)") }
    }
}

/// Global key watcher. Handles push to talk, hands-free lock, Esc to cancel and transform shortcuts.
final class HotkeyMonitor {
    enum Event { case pressDown, pressUp, handsFree, cancel, transform(Int) }

    var onEvent: ((Event) -> Void)?
    var hotkey: HotkeyChoice = .fn
    var transformsEnabled = true
    /// True while recording, so Esc and space are swallowed only then.
    var recordingActive = false
    var handsFreeActive = false

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var keyDown = false
    private var lastDown = Date.distantPast
    private var lastUp = Date.distantPast
    private(set) var isListening = false
    private var loggedFailure = false

    @discardableResult
    func start() -> Bool {
        stop()
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let ref = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask), callback: { _, type, event, ref in
            guard let ref else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<HotkeyMonitor>.fromOpaque(ref).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }, userInfo: ref) else {
            if !loggedFailure { Log.write("hotkey: event tap creation failed (\(Permissions.summary))"); loggedFailure = true }
            isListening = false
            return false
        }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isListening = true
        Log.write("hotkey: listening for \(hotkey.label)")
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil; isListening = false
    }

    private func isHotkeyFlagSet(_ flags: CGEventFlags) -> Bool {
        switch hotkey {
        case .fn: return flags.contains(.maskSecondaryFn)
        case .rightOption: return flags.contains(.maskAlternate)
        case .rightCommand: return flags.contains(.maskCommand)
        case .rightControl: return flags.contains(.maskControl)
        }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        if type == .flagsChanged, code == hotkey.keyCode {
            let down = isHotkeyFlagSet(flags)
            if down && !keyDown {
                keyDown = true
                let now = Date()
                let doubleTap = now.timeIntervalSince(lastUp) < 0.35 && lastUp.timeIntervalSince(lastDown) < 0.3
                lastDown = now
                DispatchQueue.main.async { self.onEvent?(doubleTap ? .handsFree : .pressDown) }
            } else if !down && keyDown {
                keyDown = false
                lastUp = Date()
                DispatchQueue.main.async { self.onEvent?(.pressUp) }
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown {
            // Space while holding the hotkey locks hands-free mode (Wispr's fn + space).
            if code == 49, keyDown, recordingActive {
                DispatchQueue.main.async { self.onEvent?(.handsFree) }
                return nil
            }
            if code == 53, recordingActive {
                DispatchQueue.main.async { self.onEvent?(.cancel) }
                return nil
            }
            if transformsEnabled, flags.contains(.maskAlternate),
               !flags.contains(.maskCommand), !flags.contains(.maskControl), !flags.contains(.maskShift) {
                let digits: [Int64: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
                if let d = digits[code], Store.shared.transforms.contains(where: { $0.hotkeyDigit == d }) {
                    DispatchQueue.main.async { self.onEvent?(.transform(d)) }
                    return nil
                }
            }
        }
        return Unmanaged.passUnretained(event)
    }
}

/// Puts text into the frontmost app by pasting, then restores the clipboard.
enum Inserter {
    static func paste(_ text: String) {
        let pb = NSPasteboard.general
        let saved: [NSPasteboardItem] = (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for t in item.types { if let d = item.data(forType: t) { copy.setData(d, forType: t) } }
            return copy
        }
        pb.clearContents()
        pb.setString(text, forType: .string)
        // Mark as transient so clipboard managers skip it.
        pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let changeAfterSet = pb.changeCount
        postKey(9, flags: .maskCommand)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard pb.changeCount == changeAfterSet else { return }   // user copied something new meanwhile
            pb.clearContents()
            if !saved.isEmpty { pb.writeObjects(saved) }
        }
    }

    /// Copies the current selection and returns it (empty when nothing is selected).
    static func copySelection() async -> String {
        let pb = NSPasteboard.general
        let before = pb.changeCount
        let saved = pb.string(forType: .string)
        postKey(8, flags: .maskCommand)
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 25_000_000)
            if pb.changeCount != before { break }
        }
        guard pb.changeCount != before else { return "" }
        let sel = pb.string(forType: .string) ?? ""
        if let saved { pb.clearContents(); pb.setString(saved, forType: .string) }
        return sel
    }

    static func postKey(_ key: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)
        down?.flags = flags; up?.flags = flags
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }
}

enum Sounds {
    static func play(_ name: String) {
        guard Store.shared.settings.sounds else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
    static func start() { play("Tink") }
    static func stop() { play("Pop") }
    static func error() { play("Basso") }
}

enum SystemAudio {
    private static var wasMuted = false
    static func mute(_ on: Bool) {
        if on {
            wasMuted = run("output muted of (get volume settings)") == "true"
            if !wasMuted { _ = run("set volume with output muted") }
        } else if !wasMuted {
            _ = run("set volume without output muted")
        }
    }
    private static func run(_ src: String) -> String? {
        var err: NSDictionary?
        return NSAppleScript(source: src)?.executeAndReturnError(&err).stringValue
    }
}

/// Live permission status. Publishes only when something actually changes, so views that show
/// it never rebuild (and never steal focus from a text field) on a timer.
final class PermissionState: ObservableObject {
    static let shared = PermissionState()
    @Published private(set) var microphone = Permissions.microphone
    @Published private(set) var accessibility = Permissions.accessibility
    @Published private(set) var inputMonitoring = Permissions.inputMonitoring
    @Published private(set) var screenRecording = Permissions.screenRecording
    @Published private(set) var fnUsageType = Permissions.fnUsageType
    private var timer: Timer?

    private init() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        func set<T: Equatable>(_ kp: ReferenceWritableKeyPath<PermissionState, T>, _ v: T) { if self[keyPath: kp] != v { self[keyPath: kp] = v } }
        set(\.microphone, Permissions.microphone)
        set(\.accessibility, Permissions.accessibility)
        set(\.inputMonitoring, Permissions.inputMonitoring)
        set(\.screenRecording, Permissions.screenRecording)
        set(\.fnUsageType, Permissions.fnUsageType)
        let now = Permissions.summary
        if now != lastLogged { Log.write("permissions: \(now)"); lastLogged = now }
    }
    private var lastLogged = ""
    /// Set once the user clicks Allow on a permission that needs a relaunch to take effect.
    @Published var needsRelaunch = false
}

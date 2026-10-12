import AppKit
import CoreAudio
import Combine

/// Detects calls by watching which processes have the microphone open (CoreAudio process objects,
/// macOS 14+). Zoom, Teams, FaceTime, Slack huddles, Webex, Discord and Meet in a browser all show
/// up here the second a call starts, and vanish when it ends.
final class MeetingWatcher: ObservableObject {
    struct Candidate: Equatable {
        let bundleID: String
        let name: String
    }

    static let knownApps: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams2": "Microsoft Teams",
        "com.microsoft.teams": "Microsoft Teams",
        "com.apple.FaceTime": "FaceTime",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.cisco.webexmeetingsapp": "Webex",
        "com.webex.meetingmanager": "Webex",
        "com.hnc.Discord": "Discord",
        "com.google.Chrome": "Chrome",
        "com.google.Chrome.canary": "Chrome",
        "com.apple.Safari": "Safari",
        "company.thebrowser.Browser": "Arc",
        "org.mozilla.firefox": "Firefox",
        "com.brave.Browser": "Brave",
        "com.microsoft.edgemac": "Edge",
        "com.vivaldi.Vivaldi": "Vivaldi",
        "com.operasoftware.Opera": "Opera",
        "com.skype.skype": "Skype",
        "com.loom.desktop": "Loom",
        "com.electron.lark": "Lark",
        "com.around.Around": "Around",
        "com.whereby.app": "Whereby",
        "net.whatsapp.WhatsApp": "WhatsApp",
        "org.telegram.desktop": "Telegram",
        "ru.keepcoder.Telegram": "Telegram",
    ]

    @Published private(set) var active: Candidate?
    var onStart: ((Candidate) -> Void)?
    var onEnd: ((Candidate) -> Void)?

    private var timer: Timer?
    private var firstSeen: [String: Date] = [:]
    private var lastSeen: Date?
    private let startAfter: TimeInterval = 4      // ignore a quick mic check
    private let endAfter: TimeInterval = 20       // a call does not blink; a reconnect does
    private let acceptAny = ProcessInfo.processInfo.environment["PIEFLOW_MEETING_ANY"] == "1"
    private let selfPID = UInt32(ProcessInfo.processInfo.processIdentifier)

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
        Log.write("meeting watcher: on")
    }

    func stop() { timer?.invalidate(); timer = nil }

    /// Bundle ids currently capturing the microphone, excluding ourselves and system daemons.
    static func processesUsingMic(excludingPID: UInt32) -> [(bundleID: String, pid: UInt32)] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / 4)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        func u32(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32 {
            var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var v: UInt32 = 0; var s = UInt32(4)
            AudioObjectGetPropertyData(id, &a, 0, nil, &s, &v)
            return v
        }
        func str(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String {
            var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var v: Unmanaged<CFString>?; var s = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            return AudioObjectGetPropertyData(id, &a, 0, nil, &s, &v) == noErr ? (v?.takeRetainedValue() as String? ?? "") : ""
        }
        return ids.compactMap { id in
            guard u32(id, kAudioProcessPropertyIsRunningInput) != 0 else { return nil }
            let pid = u32(id, kAudioProcessPropertyPID)
            let bid = str(id, kAudioProcessPropertyBundleID)
            guard pid != excludingPID, !bid.isEmpty, !bid.hasPrefix("com.apple.") else { return nil }
            return (bid, pid)
        }
    }

    private func tick() {
        let using = Self.processesUsingMic(excludingPID: selfPID)
        let now = Date()
        let candidates = using.filter { acceptAny || Self.knownApps[$0.bundleID] != nil }
        for c in candidates where firstSeen[c.bundleID] == nil { firstSeen[c.bundleID] = now }
        firstSeen = firstSeen.filter { key, _ in candidates.contains { $0.bundleID == key } }

        if let a = active {
            if candidates.contains(where: { $0.bundleID == a.bundleID }) {
                lastSeen = now
            } else if let last = lastSeen, now.timeIntervalSince(last) > endAfter {
                Log.write("meeting watcher: \(a.name) released the mic, call ended")
                active = nil
                onEnd?(a)
            }
            return
        }
        if let (bid, first) = firstSeen.min(by: { $0.value < $1.value }), now.timeIntervalSince(first) >= startAfter {
            let c = Candidate(bundleID: bid, name: Self.knownApps[bid] ?? Self.appName(bid) ?? bid)
            active = c
            lastSeen = now
            Log.write("meeting watcher: \(c.name) (\(bid)) has had the mic for \(Int(startAfter)) s, call started")
            onStart?(c)
        }
    }

    private static func appName(_ bundleID: String) -> String? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName
    }
}

/// Small floating prompt at the top right: "Zoom call detected. Record it?"
final class MeetingPrompt {
    private var panel: NSPanel?
    private var timer: Timer?

    func show(appName: String, onStart: @escaping () -> Void) {
        close()
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 112),
                        styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView], backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.backgroundColor = NSColor(Theme.page)
        p.hasShadow = true
        p.isReleasedWhenClosed = false
        p.contentView = NSHostingView(rootView: MeetingPromptView(appName: appName,
            start: { [weak self] in onStart(); self?.close() },
            dismiss: { [weak self] in self?.close() }))
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.maxX - 420, y: f.maxY - 130))
        }
        p.orderFrontRegardless()
        Sounds.play("Glass")
        panel = p
        timer = Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { [weak self] _ in self?.close() }
    }

    func close() {
        timer?.invalidate(); timer = nil
        panel?.orderOut(nil); panel = nil
    }
}

import SwiftUI

struct MeetingPromptView: View {
    let appName: String
    let start: () -> Void
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "record.circle").font(.system(size: 22, weight: .light)).foregroundStyle(Theme.red).padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                Text("\(appName) is on a call").font(.sans(15, .semibold)).foregroundStyle(Theme.ink)
                Text("Record it with Notetaker? It stops by itself when the call ends.").font(.sans(13)).foregroundStyle(Theme.ink2)
                HStack(spacing: 8) {
                    Button("Record", action: start).buttonStyle(PrimaryButton())
                    Button("Not now", action: dismiss).buttonStyle(GhostButton())
                }.padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(width: 400)
    }
}

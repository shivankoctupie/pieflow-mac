import SwiftUI
import Combine
import AppKit

struct OnboardingView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var models: ModelManager
    @EnvironmentObject var dictation: DictationController
    @ObservedObject private var perms = PermissionState.shared
    let finish: () -> Void
    @State private var step = Int(ProcessInfo.processInfo.environment["PIEFLOW_ONBOARD_STEP"] ?? "") ?? 0
    @State private var practice = ""
    @State private var startCount = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let steps = ["Welcome", "Permissions", "Shortcut", "Engine", "Try it"]

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) { LogoMark(); Text("PieFlow").font(.sans(22, .semibold)) }.padding(.bottom, 26)
                ForEach(steps.indices, id: \.self) { i in
                    HStack(spacing: 10) {
                        ZStack {
                            Circle().fill(i < step ? Theme.ink : (i == step ? Color.white : Theme.cardStrong)).frame(width: 24, height: 24)
                            if i < step { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white) }
                            else { Text("\(i + 1)").font(.sans(12, .semibold)).foregroundStyle(Theme.ink) }
                        }
                        .overlay(Circle().stroke(i == step ? Theme.ink : .clear, lineWidth: 1.5))
                        Text(steps[i]).font(.sans(15, i == step ? .semibold : .regular)).foregroundStyle(i <= step ? Theme.ink : Theme.ink3)
                    }
                }
                Spacer()
                Text("Everything runs on your Mac. Audio goes only to the engines you choose.")
                    .font(.sans(12.5)).foregroundStyle(Theme.ink3)
            }
            .padding(30).frame(width: 260).background(Theme.window)

            VStack(alignment: .leading, spacing: 18) {
                Group {
                    switch step {
                    case 0: welcome
                    case 1: permissions
                    case 2: shortcut
                    case 3: engine
                    default: tryIt
                    }
                }
                Spacer()
                HStack {
                    if step > 0 { Button("Back") { step -= 1 }.buttonStyle(GhostButton()) }
                    Spacer()
                    if step == 1 && !permsOK { Button("Skip for now") { step += 1 }.buttonStyle(.plain).font(.sans(14)).foregroundStyle(Theme.ink2) }
                    if step < steps.count - 1 {
                        Button("Continue") { advance() }.buttonStyle(PrimaryButton()).disabled(step == 3 && !engineOK)
                    } else {
                        Button("Finish") { store.settings.onboarded = true; finish() }.buttonStyle(PrimaryButton())
                    }
                }
            }
            .padding(44)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.page)
        }
        .frame(width: 900, height: 620)
        .onReceive(timer) { _ in
            if perms.accessibility && !dictation.hotkeys.isListening { dictation.startListening() }
        }
    }

    private var permsOK: Bool { perms.microphone && perms.accessibility }
    private var engineOK: Bool { !store.keys.xai.isEmpty || !store.keys.groq.isEmpty || !models.installed.isEmpty }

    private func advance() {
        if step == 3 { startCount = store.history.count }
        step += 1
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            (Text("Write at the speed of ").font(.serif(46)) + Text("thought").font(.serif(46, italic: true)))
            Text("Hold a key, speak naturally, and polished text appears in any app. PieFlow also takes notes in your meetings.")
                .font(.sans(17)).foregroundStyle(Theme.ink2).frame(maxWidth: 520, alignment: .leading)
            Text("What should we call you?").font(.sans(14, .medium)).foregroundStyle(Theme.ink2).padding(.top, 20)
            TextField("Your first name", text: $store.settings.userName).pieField().frame(width: 280)
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Give PieFlow access").font(.serif(40))
            Text("These stay on your Mac. You can change them later in System Settings.").font(.sans(15)).foregroundStyle(Theme.ink2)
            SettingsCard {
                perm("Microphone", "So PieFlow can hear you", perms.microphone) { Permissions.requestMicrophone { _ in perms.refresh() } }
                perm("Accessibility", "To detect the shortcut and paste text where your cursor is", perms.accessibility) { Permissions.requestAccessibility() }
                perm("Input Monitoring", "Only if the shortcut still fails after Accessibility", perms.inputMonitoring || dictation.hotkeys.isListening, divider: false) { Permissions.requestInputMonitoring(); perms.needsRelaunch = true }
            }
            Text("After you switch on Accessibility in System Settings, come back here. PieFlow notices on its own.")
                .font(.sans(13)).foregroundStyle(Theme.ink3)
        }
    }

    private func perm(_ t: String, _ s: String, _ ok: Bool, divider: Bool = true, _ a: @escaping () -> Void) -> some View {
        SettingsRow(title: t, subtitle: s, divider: divider) {
            if ok { HStack(spacing: 6) { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.teal); Text("Allowed").font(.sans(14)) } }
            else { Button("Allow", action: a).buttonStyle(PrimaryButton()) }
        }
    }

    private var shortcut: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your dictation key").font(.serif(40))
            HStack(spacing: 8) {
                Text("Hold").font(.sans(16))
                KeyCap(text: store.settings.hotkey.label)
                Text("and speak, then let go. Double tap for hands-free.").font(.sans(16))
            }
            ChipPicker(selection: Binding(get: { store.settings.hotkey }, set: { store.settings.hotkey = $0; dictation.hotkeys.hotkey = $0 }),
                       options: HotkeyChoice.allCases.map { ($0, $0.label) })
            if store.settings.hotkey == .fn, let fn = perms.fnUsageType, fn != 0 {
                VStack(alignment: .leading, spacing: 10) {
                    Text("One quick change").font(.sans(15, .semibold))
                    Text("Your Mac currently uses fn to \(fn == 2 ? "open the emoji picker" : fn == 3 ? "start Apple Dictation" : "switch input source"). Open Keyboard settings and set \"Press fn key to\" to \"Do Nothing\" so the two do not clash.")
                        .font(.sans(14)).foregroundStyle(Theme.ink2)
                    Button("Open Keyboard settings") { Permissions.openKeyboardSettings() }.buttonStyle(GhostButton())
                }
                .padding(18).background(RoundedRectangle(cornerRadius: 14).fill(Theme.accentSoft))
            } else if store.settings.hotkey == .fn {
                HStack(spacing: 8) { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.teal)
                    Text("fn is free to use.").font(.sans(14)) }
            }
            Text(dictation.hotkeys.isListening ? "Shortcut listener is running." : "Shortcut listener starts once Accessibility is allowed.")
                .font(.sans(13)).foregroundStyle(dictation.hotkeys.isListening ? Theme.teal : Theme.ink3)
        }
    }

    private var engine: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pick your engine").font(.serif(40))
            Text("Cloud keys are fastest. A local model works offline and is the fallback. Set up one or more.")
                .font(.sans(15)).foregroundStyle(Theme.ink2)
            SettingsCard {
                SettingsRow(title: "Grok (xAI) key", subtitle: "console.x.ai") {
                    KeyField(placeholder: "xai-...", key: $store.keys.xai)
                }
                SettingsRow(title: "Groq key", subtitle: "console.groq.com, free tier available") {
                    KeyField(placeholder: "gsk_...", key: $store.keys.groq)
                }
                let base = LocalModel.all[0]
                SettingsRow(title: "Local Whisper", subtitle: "\(base.label), \(base.sizeMB) MB download", divider: false) {
                    if let p = models.progress[base.id] { ProgressView(value: p).frame(width: 160) }
                    else if models.installed.contains(base.id) { HStack(spacing: 6) { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.teal); Text("Installed").font(.sans(14)) } }
                    else { Button("Download") { models.download(base); store.settings.localModel = base.id }.buttonStyle(PrimaryButton()) }
                }
            }
            if let e = models.errors[LocalModel.all[0].id] { Text(e).font(.sans(13)).foregroundStyle(Theme.red) }
        }
    }

    private var tryIt: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Try it now").font(.serif(40))
            HStack(spacing: 8) {
                Text("Click in the box, hold").font(.sans(16))
                KeyCap(text: store.settings.hotkey.label)
                Text("and say: \"Hey, are you free for lunch tomorrow?\"").font(.sans(16))
            }
            TextEditor(text: $practice).font(.sans(16)).scrollContentBackground(.hidden).padding(12)
                .frame(height: 150).background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
            if store.history.count > startCount {
                HStack(spacing: 8) { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.teal)
                    Text("That worked. You're ready.").font(.sans(15, .medium)) }
            } else if case .message(let m, _) = dictation.phase {
                Text(m).font(.sans(14)).foregroundStyle(Theme.ink2)
            }
        }
    }
}

import SwiftUI
import Combine
import AppKit

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, system, transcription, notetaker, privacy, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "General"
        case .system: return "System"
        case .transcription: return "Transcription"
        case .notetaker: return "Notetaker"
        case .privacy: return "Data and Privacy"
        case .about: return "About"
        }
    }
    var icon: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .system: return "laptopcomputer"
        case .transcription: return "waveform"
        case .notetaker: return "record.circle"
        case .privacy: return "checkmark.shield"
        case .about: return "info.circle"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var router: Router
    @Environment(\.dismiss) var dismiss

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                SectionLabel(text: "Settings").padding(.horizontal, 14).padding(.bottom, 16)
                ForEach([SettingsTab.general, .system, .transcription, .notetaker]) { t in
                    SidebarRow(icon: t.icon, title: t.title, selected: router.settingsTab == t) { router.settingsTab = t }
                }
                Rectangle().fill(Theme.line).frame(height: 1).padding(.vertical, 14)
                SectionLabel(text: "Account").padding(.horizontal, 14).padding(.bottom, 10)
                ForEach([SettingsTab.privacy, .about]) { t in
                    SidebarRow(icon: t.icon, title: t.title, selected: router.settingsTab == t) { router.settingsTab = t }
                }
                Spacer()
                HStack {
                    Text("PieFlow v\(AppInfo.version)").font(.sans(13)).foregroundStyle(Theme.ink3)
                    Spacer()
                    Image(systemName: "lock.icloud").foregroundStyle(Theme.ink3).help("Everything stays on this Mac")
                }.padding(.horizontal, 14)
            }
            .padding(.horizontal, 12).padding(.vertical, 26)
            .frame(width: 250)
            .background(Theme.window)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack {
                        Text(router.settingsTab.title).font(.serif(38))
                        Spacer()
                        Button { dismiss() } label: {
                            Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink2)
                                .frame(width: 30, height: 30).background(Circle().fill(Theme.card))
                        }.buttonStyle(.plain).keyboardShortcut(.cancelAction)
                    }
                    switch router.settingsTab {
                    case .general: GeneralSettings()
                    case .system: SystemSettings()
                    case .transcription: TranscriptionSettings()
                    case .notetaker: NotetakerSettings()
                    case .privacy: PrivacySettings()
                    case .about: AboutSettings()
                    }
                }
                .padding(.horizontal, 44).padding(.vertical, 34)
            }
            .background(Color.white)
        }
        .frame(width: 940, height: 680)
    }
}

enum AppInfo {
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }
}

struct GeneralSettings: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var dictation: DictationController
    @State private var devices = AudioDevices.inputs()

    var body: some View {
        SettingsCard {
            SettingsRow(title: "Shortcuts", subtitle: "Hold \(store.settings.hotkey.label) and speak. Double tap or add space for hands-free. Esc cancels.") {
                ThemedPicker(selection: Binding(get: { store.settings.hotkey }, set: {
                    store.settings.hotkey = $0
                    dictation.hotkeys.hotkey = $0
                }), options: HotkeyChoice.allCases.map { ($0, $0.label) })
            }
            SettingsRow(title: "Microphone", subtitle: store.settings.microphoneUID.flatMap { AudioDevices.device(uid: $0)?.name } ?? "System default (\(AudioDevices.defaultInputName()))") {
                ThemedPicker(selection: $store.settings.microphoneUID,
                             options: [(String?.none, "System default")] + devices.map { (Optional($0.uid), $0.name) })
                .onAppear { devices = AudioDevices.inputs() }
            }
            SettingsRow(title: "Isolate my voice", subtitle: "Cancels audio playing through this Mac's speakers and suppresses background noise, so music, videos or the other side of a call are not transcribed. Turn off only if your microphone misbehaves with it.") {
                PillToggle(isOn: $store.settings.voiceIsolation)
            }
            SettingsRow(title: "Dictation Language", subtitle: languageName(store.settings.language)) {
                ThemedPicker(selection: $store.settings.language, options: Self.languages)
            }
            SettingsRow(title: "Your name", subtitle: "Used for the welcome message", divider: false) {
                TextField("Name", text: $store.settings.userName).pieField().frame(width: 220)
            }
        }
        if store.settings.hotkey == .fn, let fn = PermissionState.shared.fnUsageType, fn != 0 {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 8) {
                    Text("macOS also uses the fn key").font(.sans(15, .medium))
                    Text("Your Mac opens \(fn == 2 ? "the emoji picker" : fn == 3 ? "Apple Dictation" : "the input source switcher") when you press fn. In Keyboard settings, set \"Press fn key to\" to \"Do Nothing\".")
                        .font(.sans(14)).foregroundStyle(Theme.ink2)
                    Button("Open Keyboard settings") { Permissions.openKeyboardSettings() }.buttonStyle(GhostButton())
                }
            }
            .padding(18).background(RoundedRectangle(cornerRadius: 14).fill(Theme.accentSoft))
        }
    }

    static let languages: [(String, String)] = [
        ("en", "English"), ("auto", "Detect automatically"), ("hi", "Hindi"), ("es", "Spanish"), ("fr", "French"),
        ("de", "German"), ("pt", "Portuguese"), ("it", "Italian"), ("ja", "Japanese"), ("zh", "Chinese"), ("ko", "Korean"),
        ("ar", "Arabic"), ("ru", "Russian"), ("nl", "Dutch"), ("ta", "Tamil"), ("te", "Telugu"), ("bn", "Bengali"), ("mr", "Marathi"),
    ]
    private func languageName(_ c: String) -> String { Self.languages.first { $0.0 == c }?.1 ?? c }
}

struct SystemSettings: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var dictation: DictationController
    @ObservedObject private var perms = PermissionState.shared
    @State private var listening = false

    var body: some View {
        Text("Permissions").font(.sans(16, .medium))
        SettingsCard {
            permRow("Microphone", "Hear you when you dictate", perms.microphone) { Permissions.requestMicrophone { _ in perms.refresh() } }
            permRow("Accessibility", "Detect the \(store.settings.hotkey.label) key and paste text into apps", perms.accessibility) { Permissions.requestAccessibility() }
            SettingsRow(title: "Input Monitoring", subtitle: listening ? "Not needed: the shortcut already works through Accessibility" : "Only if the shortcut still fails after Accessibility is allowed") {
                if listening || perms.inputMonitoring {
                    HStack(spacing: 6) { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.teal); Text(perms.inputMonitoring ? "Allowed" : "Not needed").font(.sans(14)) }
                } else {
                    Button("Allow") { Permissions.requestInputMonitoring(); perms.needsRelaunch = true }.buttonStyle(PrimaryButton())
                }
            }
            permRow("Screen & System Audio Recording", "Notetaker only: hear the other side of calls", perms.screenRecording, divider: false) { Permissions.requestScreenRecording(); perms.needsRelaunch = true }
        }
        .onAppear { listening = dictation.hotkeys.isListening }
        .onChange(of: perms.accessibility) { _, ok in
            if ok && !dictation.hotkeys.isListening { dictation.startListening() }
            listening = dictation.hotkeys.isListening
        }
        .onReceive(dictation.objectWillChange) { _ in
            DispatchQueue.main.async { if listening != dictation.hotkeys.isListening { listening = dictation.hotkeys.isListening } }
        }
        if perms.needsRelaunch {
            HStack(spacing: 12) {
                Text("Switched it on in System Settings? Restart PieFlow so macOS applies it.").font(.sans(13.5)).foregroundStyle(Theme.ink2)
                Spacer()
                Button("Restart PieFlow") { Permissions.relaunch() }.buttonStyle(PrimaryButton())
            }
            .padding(16).background(RoundedRectangle(cornerRadius: 12).fill(Theme.accentSoft))
        }
        HStack {
            Text(listening ? "Shortcut is active." : "Shortcut is not active yet. Grant Accessibility, then press Restart listener.")
                .font(.sans(13.5)).foregroundStyle(listening ? Theme.teal : Theme.red)
            Spacer()
            Button("Restart listener") { dictation.startListening(); listening = dictation.hotkeys.isListening }.buttonStyle(GhostButton())
        }
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Stuck on Allow?").font(.sans(14, .medium))
                Text("Allow already clears a stale entry before asking again. If it still will not stick, Reset clears every PieFlow entry and restarts the app, then allow each one again.")
                    .font(.sans(13)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Reset permissions") { Permissions.resetAll(); Permissions.relaunch() }.buttonStyle(GhostButton()).fixedSize()
        }
        .padding(.top, 4)
        Text("App settings").font(.sans(16, .medium)).padding(.top, 8)
        SettingsCard {
            SettingsRow(title: "Launch app at login") {
                PillToggle(isOn: Binding(get: { store.settings.launchAtLogin }, set: { store.settings.launchAtLogin = $0; LoginItem.set($0) }))
            }
            SettingsRow(title: "Show Flow Bar at all times") { PillToggle(isOn: $store.settings.showFlowBar) }
            SettingsRow(title: "Show app in dock", divider: false) {
                PillToggle(isOn: Binding(get: { store.settings.showInDock }, set: {
                    store.settings.showInDock = $0
                    NSApp.setActivationPolicy($0 ? .regular : .accessory)
                    NSApp.activate(ignoringOtherApps: true)
                }))
            }
        }
        Text("Sound").font(.sans(16, .medium)).padding(.top, 8)
        SettingsCard {
            SettingsRow(title: "Dictation and notification sounds") { PillToggle(isOn: $store.settings.sounds) }
            SettingsRow(title: "Mute all audio while dictating", divider: false) { PillToggle(isOn: $store.settings.muteWhileDictating) }
        }
    }

    private func permRow(_ t: String, _ s: String, _ ok: Bool, divider: Bool = true, _ action: @escaping () -> Void) -> some View {
        SettingsRow(title: t, subtitle: s, divider: divider) {
            if ok {
                HStack(spacing: 6) { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.teal); Text("Allowed").font(.sans(14)) }
            } else {
                Button("Allow", action: action).buttonStyle(PrimaryButton())
            }
        }
    }
}

struct TranscriptionSettings: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var models: ModelManager
    @EnvironmentObject var llmBox: LLMBox
    @State private var testResult: [String: String] = [:]

    var body: some View {
        Text("Speech to text engines").font(.sans(16, .medium))
        Text("PieFlow tries engines from top to bottom and falls back to the next one if a request fails. Reorder them with the arrows.")
            .font(.sans(13.5)).foregroundStyle(Theme.ink2)
        SettingsCard {
            ForEach(Array(store.settings.providerOrder.enumerated()), id: \.element) { i, p in
                SettingsRow(title: "\(i + 1). \(p.label)", subtitle: detail(p), divider: i < store.settings.providerOrder.count - 1) {
                    HStack(spacing: 4) {
                        IconButton(symbol: "arrow.up", help: "Move up") { move(i, -1) }.disabled(i == 0)
                        IconButton(symbol: "arrow.down", help: "Move down") { move(i, 1) }.disabled(i == store.settings.providerOrder.count - 1)
                    }
                }
            }
        }
        Text("API keys").font(.sans(16, .medium)).padding(.top, 8)
        SettingsCard {
            keyRow("Grok (xAI)", "console.x.ai > API Keys. Uses Grok speech to text.", key: $store.keys.xai, id: "grok")
            keyRow("Groq", "console.groq.com > API Keys. Whisper Large v3 Turbo, very fast. Also powers AI cleanup.", key: $store.keys.groq, id: "groq", divider: false)
        }
        Text("Keys are stored only on this Mac in ~/Library/Application Support/PieFlow/keys.json (readable by you alone).")
            .font(.sans(12.5)).foregroundStyle(Theme.ink3)

        Text("Local Whisper (offline fallback)").font(.sans(16, .medium)).padding(.top, 8)
        SettingsCard {
            ForEach(Array(LocalModel.all.enumerated()), id: \.element.id) { i, m in
                SettingsRow(title: m.label, subtitle: "\(m.sizeMB) MB\(store.settings.localModel == m.id ? ", in use" : "")" + (models.errors[m.id].map { ". \($0)" } ?? ""),
                            divider: i < LocalModel.all.count - 1) {
                    if let p = models.progress[m.id] {
                        ProgressView(value: p).frame(width: 140)
                    } else if models.installed.contains(m.id) {
                        HStack(spacing: 8) {
                            if store.settings.localModel != m.id { Button("Use") { store.settings.localModel = m.id }.buttonStyle(GhostButton()) }
                            Button("Remove") { models.delete(m) }.buttonStyle(GhostButton())
                        }
                    } else {
                        Button("Download") { models.download(m); store.settings.localModel = m.id }.buttonStyle(PrimaryButton())
                    }
                }
            }
        }
        Text("AI cleanup").font(.sans(16, .medium)).padding(.top, 8)
        SettingsCard {
            SettingsRow(title: "Polish dictations with AI", subtitle: "Removes filler, applies self corrections and your Style. Needs a Groq or xAI key; without one PieFlow uses its built in rules.") {
                PillToggle(isOn: $store.settings.aiCleanup)
            }
            SettingsRow(title: "Groq model") { TextField("", text: $store.settings.cleanupModelGroq).pieField().frame(width: 260) }
            SettingsRow(title: "xAI model", divider: false) { TextField("", text: $store.settings.cleanupModelXAI).pieField().frame(width: 260) }
        }
    }

    private func detail(_ p: STTProvider) -> String {
        switch p {
        case .grok: return store.keys.xai.isEmpty ? "No key yet" : "Ready"
        case .groq: return store.keys.groq.isEmpty ? "No key yet" : "Ready"
        case .local: return models.installed.isEmpty ? "No model downloaded" : "Ready, works offline"
        }
    }

    private func move(_ i: Int, _ d: Int) {
        var o = store.settings.providerOrder
        o.swapAt(i, i + d)
        store.settings.providerOrder = o
    }

    private func keyRow(_ title: String, _ sub: String, key: Binding<String>, id: String, divider: Bool = true) -> some View {
        SettingsRow(title: title, subtitle: testResult[id] ?? sub, divider: divider) {
            HStack(spacing: 8) {
                KeyField(placeholder: "Paste key", key: key)
                Button("Test") { test(id) }.buttonStyle(GhostButton()).fixedSize().disabled(key.wrappedValue.isEmpty)
            }
        }
    }

    private func test(_ id: String) {
        testResult[id] = "Testing..."
        Task { @MainActor in
            // One second of quiet tone is enough to prove the key and endpoint work.
            let samples = (0..<16_000).map { i in Float(sin(Double(i) * 2 * .pi * 220 / 16_000) * 0.05) }
            let t = Transcriber(store: store)
            do {
                _ = try await t.transcribe(samples, timeout: 20, only: id == "grok" ? .grok : .groq)
                testResult[id] = "Key works."
            } catch {
                testResult[id] = "Failed: \(error.localizedDescription.prefix(140))"
            }
        }
    }
}

struct NotetakerSettings: View {
    @EnvironmentObject var store: Store
    var body: some View {
        SettingsCard {
            SettingsRow(title: "Capture the other side of calls", subtitle: "Records system audio with ScreenCaptureKit. Needs Screen & System Audio Recording permission. Turn off to record your mic only.") {
                PillToggle(isOn: $store.settings.notetakerSystemAudio)
            }
            SettingsRow(title: "Summaries", subtitle: LLM.claudeCLI != nil ? "Groq or xAI if a key is set, otherwise your local Claude Code CLI." : "Uses your Groq or xAI key.", divider: false) {
                EmptyView()
            }
        }
        Text("Tip: use headphones on calls so your mic does not pick up the other side twice.").font(.sans(13.5)).foregroundStyle(Theme.ink2)
    }
}

struct PrivacySettings: View {
    @EnvironmentObject var store: Store
    @State private var confirm = false
    var body: some View {
        SettingsCard {
            SettingsRow(title: "Where your data lives", subtitle: Paths.support.path) {
                Button("Show in Finder") { NSWorkspace.shared.open(Paths.support) }.buttonStyle(GhostButton())
            }
            SettingsRow(title: "Keep dictation audio for", subtitle: "Older recordings are deleted automatically. Text history is kept.") {
                ThemedPicker(selection: $store.settings.keepAudioDays,
                             options: [(1, "1 day"), (7, "7 days"), (30, "30 days"), (36500, "Forever")], width: 140)
            }
            SettingsRow(title: "What leaves your Mac", subtitle: "Only audio and text sent to the engines you configured (xAI, Groq). Local Whisper runs fully offline. No analytics, no accounts.") { EmptyView() }
            SettingsRow(title: "Export history", subtitle: "All dictations as a CSV file") {
                Button("Export") { exportCSV() }.buttonStyle(GhostButton())
            }
            SettingsRow(title: "Erase everything", subtitle: "Deletes history, notes, meetings and audio. Keeps settings and keys.", divider: false) {
                Button("Erase") { confirm = true }.buttonStyle(GhostButton())
            }
        }
        .alert("Erase all PieFlow data?", isPresented: $confirm) {
            Button("Erase", role: .destructive) { store.eraseAll() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This cannot be undone.") }
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "pieflow-history.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let iso = ISO8601DateFormatter()
        var csv = "date,app,words,engine,text\n"
        for e in store.history {
            csv += "\(iso.string(from: e.date)),\"\(e.appName ?? "")\",\(e.wordCount),\(e.engine),\"\(e.text.replacingOccurrences(of: "\"", with: "\"\""))\"\n"
        }
        try? csv.write(to: url, atomically: true, encoding: .utf8)
    }
}

struct AboutSettings: View {
    @EnvironmentObject var router: Router
    @EnvironmentObject var updater: Updater
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) { LogoMark(size: 28); Text("PieFlow for Mac").font(.sans(22, .semibold)) }
            Text("Version \(AppInfo.version). Personal voice dictation and meeting notes. Free and local first.")
                .font(.sans(15)).foregroundStyle(Theme.ink2)
            SettingsCard {
                SettingsRow(title: "Updates", subtitle: updateLine, divider: false) {
                    switch updater.state {
                    case .checking: ProgressView().controlSize(.small)
                    case .available: Button("Update now") { updater.installAvailable() }.buttonStyle(PrimaryButton())
                    case .downloading, .installing: ProgressView().controlSize(.small)
                    default: Button("Check now") { updater.check(userInitiated: true) }.buttonStyle(GhostButton())
                    }
                }
            }
            Text("PieFlow checks github.com/\(Updater.repo) for new releases after launch and every few hours. Nothing about you is sent; it is one request for the release list.")
                .font(.sans(12.5)).foregroundStyle(Theme.ink3)
            HStack {
                Button("Run setup again") {
                    Store.shared.settings.onboarded = false
                    router.showSettings = false
                    NotificationCenter.default.post(name: .showOnboarding, object: nil)
                }.buttonStyle(GhostButton())
                Button("Open log") { NSWorkspace.shared.open(Paths.logFile) }.buttonStyle(GhostButton())
            }.padding(.top, 8)
        }
    }

    private var updateLine: String {
        let when = updater.lastChecked.map { "Last checked " + RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date()) } ?? "Not checked yet"
        switch updater.state {
        case .checking: return "Checking GitHub releases"
        case .upToDate: return "You are on the latest version. \(when)."
        case .available(let r): return "Version \(r.version) is available. \(when)."
        case .downloading(let p): return "Downloading, \(Int(p * 100))%"
        case .installing: return "Installing and relaunching"
        case .failed(let m): return "Check failed: \(m)"
        case .idle: return when + "."
        }
    }
}

extension Notification.Name {
    static let showOnboarding = Notification.Name("pieflow.showOnboarding")
}

struct HelpView: View {
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("How PieFlow works").font(.serif(32)); Spacer()
                Button("Done") { dismiss() }.buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction) }
            Group {
                help("Push to talk", "Hold fn (or your chosen key), speak, let go. Text appears where your cursor is.")
                help("Hands-free", "Double tap fn, or hold fn and press space. Speak as long as you like, then press fn again. Esc cancels.")
                help("Transforms", "Select text anywhere and press ⌥1 for Polish or ⌥2 for Prompt Engineer. Add your own on the Transforms page.")
                help("Snippets", "Say a trigger phrase like \"my email address\" and PieFlow inserts the saved text.")
                help("Dictionary", "Add names and jargon. Fix a word in history and PieFlow learns it.")
                help("Notetaker", "Start Notetaker before a call. It records your mic and the call audio, transcribes live, then writes a summary and action items.")
                help("If fn opens the emoji picker", "System Settings > Keyboard > \"Press fn key to\" > Do Nothing.")
                help("If nothing pastes", "System Settings > Privacy & Security > Accessibility > enable PieFlow. After updating PieFlow, toggle it off and on again.")
            }
        }
        .padding(32).frame(width: 640).background(Theme.page)
    }
    private func help(_ t: String, _ d: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(t).font(.sans(15, .semibold))
            Text(d).font(.sans(14)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
        }
    }
}

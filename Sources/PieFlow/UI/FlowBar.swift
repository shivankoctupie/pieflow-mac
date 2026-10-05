import SwiftUI
import Combine
import AppKit

final class FlowBarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class FlowBarController {
    private var panel: FlowBarPanel?
    let dictation: DictationController
    let store: Store

    init(dictation: DictationController, store: Store) {
        self.dictation = dictation
        self.store = store
    }

    func show() {
        if panel == nil {
            let p = FlowBarPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 90),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.level = .statusBar
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            p.isMovableByWindowBackground = false
            p.hidesOnDeactivate = false
            let host = NSHostingView(rootView: FlowBarView(dictation: dictation, store: store))
            host.frame = p.contentRect(forFrameRect: p.frame)
            p.contentView = host
            panel = p
        }
        position()
        panel?.orderFrontRegardless()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.position()
        }
    }

    func position() {
        guard let panel, let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: vf.midX - panel.frame.width / 2, y: vf.minY + 6))
    }
}

struct FlowBarView: View {
    @ObservedObject var dictation: DictationController
    @ObservedObject var store: Store
    @State private var hover = false
    @State private var levels: [CGFloat] = Array(repeating: 0.05, count: 18)

    private let timer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack {
            Spacer()
            content
                .animation(.spring(response: 0.28, dampingFraction: 0.85), value: dictation.phase)
                .animation(.easeOut(duration: 0.15), value: hover)
        }
        .frame(width: 420, height: 90)
        .onReceive(timer) { _ in
            guard dictation.isRecording else { return }
            levels.removeFirst()
            levels.append(max(0.06, CGFloat(dictation.level)))
        }
    }

    @ViewBuilder
    private var content: some View {
        switch dictation.phase {
        case .idle:
            if store.settings.showFlowBar {
                idlePill
            }
        case .recording(let handsFree):
            HStack(spacing: 10) {
                if handsFree {
                    circleButton("xmark", bg: Color.white.opacity(0.14)) { dictation.cancel(silent: false) }
                }
                waveform
                if handsFree {
                    circleButton("stop.fill", bg: Color(hex: 0xE5484D)) { dictation.stopAndProcess() }
                }
            }
            .padding(.horizontal, handsFree ? 6 : 16)
            .frame(height: 38)
            .background(Capsule().fill(Color(hex: 0x111111)))
            .overlay(Capsule().stroke(Color.white.opacity(0.12)))
            .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        case .processing:
            pill { ProcessingDots() }
        case .transforming(let name):
            pill {
                HStack(spacing: 8) {
                    ProcessingDots()
                    Text(name).font(.sans(12.5, .medium)).foregroundStyle(.white.opacity(0.9))
                }
            }
        case .message(let msg, let isError):
            pill {
                HStack(spacing: 7) {
                    Image(systemName: isError ? "exclamationmark.circle" : "info.circle")
                        .font(.system(size: 12)).foregroundStyle(isError ? Color(hex: 0xFF8A65) : .white.opacity(0.75))
                    Text(msg).font(.sans(12.5, .medium)).foregroundStyle(.white.opacity(0.92)).lineLimit(1)
                }
            }
        }
    }

    private var idlePill: some View {
        Group {
            if hover {
                HStack(spacing: 8) {
                    Text("Click or hold").font(.sans(12, .medium)).foregroundStyle(.white.opacity(0.65))
                    KeyCapDark(text: store.settings.hotkey.label)
                    Text("to dictate").font(.sans(12, .medium)).foregroundStyle(.white.opacity(0.65))
                }
                .padding(.horizontal, 14).frame(height: 30)
                .background(Capsule().fill(Color(hex: 0x111111)))
                .overlay(Capsule().stroke(Color.white.opacity(0.12)))
            } else {
                Capsule().fill(Color(hex: 0x1A1A1A).opacity(0.85))
                    .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 0.5))
                    .frame(width: 44, height: 9)
                    .padding(.vertical, 10)
            }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { dictation.toggleFromUI() }
    }

    private var waveform: some View {
        HStack(spacing: 3) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule().fill(Color.white)
                    .frame(width: 3, height: 4 + levels[i] * 22)
            }
        }
        .frame(height: 28)
        .animation(.linear(duration: 0.05), value: levels)
    }

    private func pill<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        c().padding(.horizontal, 16).frame(height: 34)
            .background(Capsule().fill(Color(hex: 0x111111)))
            .overlay(Capsule().stroke(Color.white.opacity(0.12)))
            .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
    }

    private func circleButton(_ symbol: String, bg: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                .frame(width: 26, height: 26).background(Circle().fill(bg))
        }.buttonStyle(.plain)
    }
}

struct KeyCapDark: View {
    let text: String
    var body: some View {
        Text(text).font(.sans(11.5, .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.16)))
    }
}

struct ProcessingDots: View {
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3) { i in
                    Circle().fill(Color.white)
                        .frame(width: 5, height: 5)
                        .opacity(0.35 + 0.65 * max(0, sin(t * 5 - Double(i) * 0.8)))
                }
            }
        }
    }
}

import SwiftUI
import Combine
import AppKit

final class FlowBarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Where the Flow Bar sits. The pill hangs from the bottom centre of its panel, and that point (the
/// anchor) is what gets placed: bottom centre of the screen by default, or wherever the user dragged it.
/// A dragged spot is kept as a fraction of the usable screen, so it is the same spot on any display.
enum FlowBarLayout {
    static let size = NSSize(width: 420, height: 90)
    /// Default gap between the pill's panel and the bottom of the usable screen.
    static let restGap: CGFloat = 6
    /// Kept clear on either side of the anchor so the pill is not cut by the screen edge when it widens.
    static let sideMargin: CGFloat = 135
    /// Kept clear above the anchor: the tallest pill plus its shadow.
    static let topMargin: CGFloat = 52
    /// Dropped this close to the default spot, the pill goes back to it.
    static let snap: CGFloat = 28

    static func defaultAnchor(in vf: NSRect) -> NSPoint { NSPoint(x: vf.midX, y: vf.minY + restGap) }

    static func clamp(_ a: NSPoint, in vf: NSRect) -> NSPoint {
        let side = min(sideMargin, vf.width / 2)
        return NSPoint(x: min(max(a.x, vf.minX + side), vf.maxX - side),
                       y: min(max(a.y, vf.minY), max(vf.minY, vf.maxY - topMargin)))
    }

    static func anchor(in vf: NSRect, x: Double?, y: Double?) -> NSPoint {
        guard let x, let y else { return defaultAnchor(in: vf) }
        return clamp(NSPoint(x: vf.minX + CGFloat(x) * vf.width, y: vf.minY + CGFloat(y) * vf.height), in: vf)
    }

    /// nil when the anchor is at (or was dropped next to) the default spot.
    static func fractions(of a: NSPoint, in vf: NSRect) -> (x: Double, y: Double)? {
        let d = defaultAnchor(in: vf)
        if abs(a.x - d.x) <= snap, abs(a.y - d.y) <= snap { return nil }
        guard vf.width > 0, vf.height > 0 else { return nil }
        return (Double((a.x - vf.minX) / vf.width), Double((a.y - vf.minY) / vf.height))
    }

    static func origin(for anchor: NSPoint) -> NSPoint { NSPoint(x: anchor.x - size.width / 2, y: anchor.y) }
    static func anchor(of frame: NSRect) -> NSPoint { NSPoint(x: frame.midX, y: frame.minY) }
}

final class FlowBarController {
    private var panel: FlowBarPanel?
    private var watching: Set<AnyCancellable> = []
    let dictation: DictationController
    let store: Store

    /// Tests replace these two: where the mouse is, and what a click on the pill does.
    var mouseLocation: () -> NSPoint = { NSEvent.mouseLocation }
    lazy var onTap: () -> Void = { [weak self] in self?.dictation.toggleFromUI() }
    /// Set while the pill is being dragged: where the mouse and the panel were when the drag began.
    private var drag: (mouse: NSPoint, origin: NSPoint)?

    init(dictation: DictationController, store: Store) {
        self.dictation = dictation
        self.store = store
    }

    func show() {
        if panel == nil {
            let p = FlowBarPanel(contentRect: NSRect(origin: .zero, size: FlowBarLayout.size),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.level = .statusBar
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            p.isMovableByWindowBackground = false
            p.hidesOnDeactivate = false
            // Hiding the app (Cmd+H, or macOS hiding it by itself) takes every window that can hide with
            // it. The Flow Bar went too, so dictation kept working with nothing on screen.
            p.canHide = false
            let view = FlowBarView(dictation: dictation, store: store,
                                   onTap: { [weak self] in self?.onTap() },
                                   onDrag: { [weak self] travelled in self?.dragMoved(travelled: travelled) },
                                   onDragEnd: { [weak self] in self?.dragEnded() })
            let host = NSHostingView(rootView: view)
            host.frame = p.contentRect(forFrameRect: p.frame)
            p.contentView = host
            panel = p
            NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                self?.position()
            }
            // Come back to the front, on the screen being worked on, every time a dictation starts.
            dictation.$phase.sink { [weak self] phase in
                guard case .recording = phase else { return }
                self?.position()
                self?.panel?.orderFrontRegardless()
            }.store(in: &watching)
            // "Reset" in Settings clears the saved spot; move as soon as it does.
            store.$settings.map { [$0.flowBarX, $0.flowBarY] }.removeDuplicates().dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.position() }
                .store(in: &watching)
        }
        position()
        panel?.orderFrontRegardless()
    }

    var frame: NSRect? { panel?.frame }

    private func screen(at point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    }

    /// Puts the pill at its spot (default or dragged) on the screen the mouse is on.
    func position() {
        guard let panel, drag == nil else { return }
        guard let screen = screen(at: mouseLocation()) ?? NSScreen.main else { return }
        let anchor = FlowBarLayout.anchor(in: screen.visibleFrame, x: store.settings.flowBarX, y: store.settings.flowBarY)
        panel.setFrameOrigin(FlowBarLayout.origin(for: anchor))
    }

    // MARK: dragging

    /// Called for every mouse move of a drag on the pill. The panel follows the real mouse position:
    /// the gesture's own coordinates are relative to the panel, which is the thing being moved. Only the
    /// first call uses `travelled` (how far the press had moved before it counted as a drag, in SwiftUI's
    /// downward y), to find where the press began, so the pill stays exactly under the pointer.
    func dragMoved(travelled: CGSize = .zero) {
        guard let panel else { return }
        let mouse = mouseLocation()
        if drag == nil { drag = (NSPoint(x: mouse.x - travelled.width, y: mouse.y + travelled.height), panel.frame.origin) }
        guard let drag else { return }
        var anchor = NSPoint(x: drag.origin.x + panel.frame.width / 2 + mouse.x - drag.mouse.x,
                             y: drag.origin.y + mouse.y - drag.mouse.y)
        if let screen = screen(at: mouse) ?? panel.screen { anchor = FlowBarLayout.clamp(anchor, in: screen.visibleFrame) }
        panel.setFrameOrigin(FlowBarLayout.origin(for: anchor))
    }

    /// The drop: remember the spot, or forget it when the pill was put back at the bottom centre.
    func dragEnded() {
        guard let panel, drag != nil else { return }
        drag = nil
        let anchor = FlowBarLayout.anchor(of: panel.frame)
        guard let screen = screen(at: anchor) ?? panel.screen ?? NSScreen.main else { return }
        let spot = FlowBarLayout.fractions(of: anchor, in: screen.visibleFrame)
        var settings = store.settings
        settings.flowBarX = spot?.x
        settings.flowBarY = spot?.y
        store.settings = settings
        Log.write(spot.map { String(format: "flow bar moved to %.3f, %.3f of the screen", $0.x, $0.y) } ?? "flow bar back at bottom centre")
        position()
    }
}

struct FlowBarView: View {
    @ObservedObject var dictation: DictationController
    @ObservedObject var store: Store
    var onTap: () -> Void = {}
    var onDrag: (CGSize) -> Void = { _ in }
    var onDragEnd: () -> Void = {}
    @State private var hover = false

    /// What the pill is showing. One capsule changes size between these, so states flow into each other.
    private enum Shape: Equatable {
        case hidden, nub, hint
        case recording(handsFree: Bool)
        case processing
        case text(String, isError: Bool, busy: Bool)
    }

    private var shape: Shape {
        switch dictation.phase {
        case .idle: return store.settings.showFlowBar ? (hover ? .hint : .nub) : .hidden
        case .recording(let handsFree): return .recording(handsFree: handsFree)
        case .processing: return .processing
        case .transforming(let name): return .text(name, isError: false, busy: true)
        case .message(let msg, let isError): return .text(msg, isError: isError, busy: false)
        }
    }

    private var isSmall: Bool { shape == .nub || shape == .hidden }
    private var isIdle: Bool { shape == .nub || shape == .hint }

    /// Fixed sizes where the content is known; text states take the width of their text.
    private var width: CGFloat? {
        switch shape {
        case .hidden, .nub: return 44
        case .recording(let handsFree): return handsFree ? 172 : 112
        case .processing: return 64
        case .hint, .text: return nil
        }
    }

    private var height: CGFloat {
        switch shape {
        case .hidden, .nub: return 9
        case .hint: return 30
        case .recording: return 38
        case .processing, .text: return 34
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            pill
                .padding(.top, isSmall ? 10 : 0)
                .padding(.bottom, isSmall ? 10 : 8)   // room for the shadow, which the panel edge would cut
                .contentShape(Rectangle())
                .onHover { hover = $0 }
                .onTapGesture { if isIdle { onTap() } }
                // Drag the pill to move it. A press that does not travel stays a click.
                .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .onChanged { onDrag($0.translation) }
                    .onEnded { _ in onDragEnd() })
        }
        .frame(width: FlowBarLayout.size.width, height: FlowBarLayout.size.height)
        .animation(.spring(response: 0.28, dampingFraction: 0.76), value: shape)
    }

    private var pill: some View {
        ZStack { content }
            .padding(.horizontal, isSmall ? 0 : 14)
            .frame(width: width, height: height)
            .background(Capsule().fill(Color(hex: 0x111111).opacity(isSmall ? 0.85 : 1)))
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(isSmall ? 0.25 : 0.12), lineWidth: isSmall ? 0.5 : 1))
            .shadow(color: .black.opacity(isSmall ? 0 : 0.25), radius: 8, y: 3)
            .opacity(shape == .hidden ? 0 : 1)
    }

    @ViewBuilder
    private var content: some View {
        switch shape {
        case .hidden, .nub:
            EmptyView()
        case .hint:
            HStack(spacing: 8) {
                Text("Click or hold").font(.sans(12, .medium)).foregroundStyle(.white.opacity(0.65))
                KeyCapDark(text: store.settings.hotkey.label)
                Text("to dictate").font(.sans(12, .medium)).foregroundStyle(.white.opacity(0.65))
            }
            .fixedSize()
            .transition(.opacity)
        case .recording(let handsFree):
            HStack(spacing: 10) {
                if handsFree {
                    circleButton("xmark", bg: Color.white.opacity(0.14)) { dictation.cancel(silent: false) }
                        .transition(.scale.combined(with: .opacity))
                }
                Waveform(level: dictation.level)
                if handsFree {
                    circleButton("stop.fill", bg: Color(hex: 0xE5484D)) { dictation.stopAndProcess() }
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .transition(.opacity)
        case .processing:
            ProcessingDots().transition(.opacity)
        case .text(let text, let isError, let busy):
            HStack(spacing: 7) {
                if busy {
                    ProcessingDots()
                } else {
                    Image(systemName: isError ? "exclamationmark.circle" : "info.circle")
                        .font(.system(size: 12)).foregroundStyle(isError ? Color(hex: 0xFF8A65) : .white.opacity(0.75))
                }
                Text(text).font(.sans(12.5, .medium)).foregroundStyle(.white.opacity(0.92)).lineLimit(1)
            }
            .fixedSize()
            .transition(.opacity)
        }
    }

    private func circleButton(_ symbol: String, bg: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                .frame(width: 26, height: 26).background(Circle().fill(bg))
        }.buttonStyle(.plain)
    }
}

/// The bars inside the recording pill. Drawn once per display frame straight from the microphone
/// level, with no SwiftUI state in between, so it costs nothing while idle and never re-renders the pill.
struct Waveform: View {
    let level: MicLevel
    @State private var motion = WaveMotion()

    private static let bars = 13
    private static let barWidth: CGFloat = 3
    private static let gap: CGFloat = 3

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let heights = motion.step(at: timeline.date.timeIntervalSinceReferenceDate, level: CGFloat(level.value), count: Self.bars)
                for (i, h) in heights.enumerated() {
                    let barHeight = 3 + h * (size.height - 3)
                    let rect = CGRect(x: CGFloat(i) * (Self.barWidth + Self.gap), y: (size.height - barHeight) / 2,
                                      width: Self.barWidth, height: barHeight)
                    context.fill(Path(roundedRect: rect, cornerRadius: Self.barWidth / 2), with: .color(.white))
                }
            }
        }
        .frame(width: CGFloat(Self.bars) * Self.barWidth + CGFloat(Self.bars - 1) * Self.gap, height: 24)
    }
}

/// Turns the raw level into bar heights that move like a liquid: quick to rise with the voice, slower
/// to settle, tallest in the middle, with a ripple travelling outward so the bars never move as one block.
final class WaveMotion {
    private var smoothed: CGFloat = 0
    private var heights: [CGFloat] = []
    private var last: Double = 0

    func step(at time: Double, level: CGFloat, count: Int) -> [CGFloat] {
        if heights.count != count { heights = Array(repeating: 0, count: count) }
        let dt = last == 0 ? 1.0 / 60 : min(0.1, max(0, time - last))
        last = time
        let target = pow(min(1, max(0, level)), 0.7)
        let rate = target > smoothed ? 0.035 : 0.18
        smoothed += (target - smoothed) * CGFloat(1 - exp(-dt / rate))
        let middle = Double(count - 1) / 2
        for i in 0..<count {
            let distance = abs(Double(i) - middle) / max(middle, 1)
            let envelope = 0.4 + 0.6 * cos(distance * .pi / 2)
            let ripple = 0.68 + 0.32 * sin(time * 8.5 - distance * 4.2 + Double(i % 2) * 0.9)
            let goal = min(1, smoothed * CGFloat(envelope * ripple) * 1.25)
            heights[i] += (goal - heights[i]) * CGFloat(1 - exp(-dt / 0.045))
        }
        return heights
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

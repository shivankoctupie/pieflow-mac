import SwiftUI
import AppKit
import CoreText

enum Theme {
    // Warm paper palette taken from the reference app.
    static let window = Color(hex: 0xF4F2EE)        // sidebar and window chrome
    static let page = Color(hex: 0xFAF9F7)          // main content card
    static let card = Color(hex: 0xF1EFEA)          // grouped settings card
    static let cardStrong = Color(hex: 0xE9E6DF)    // selected sidebar row, chips
    static let line = Color(hex: 0xE4E1DA)
    static let ink = Color(hex: 0x1A1A1A)
    static let ink2 = Color(hex: 0x55524C)
    static let ink3 = Color(hex: 0x8C8880)
    static let accent = Color(hex: 0xF5A54A)        // orange "Create report" button
    static let accentSoft = Color(hex: 0xFDF1E4)
    static let accentLine = Color(hex: 0xF0B87A)
    static let teal = Color(hex: 0x1F5F5B)
    static let teal2 = Color(hex: 0x3E9A92)
    static let teal3 = Color(hex: 0x86CFC4)
    static let teal4 = Color(hex: 0xCDEBE6)
    static let red = Color(hex: 0xC2410C)

    static func registerFonts() {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files where f.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil)
        }
    }

    static var fontsAvailable: Bool { NSFont(name: "Figtree-Regular", size: 12) != nil && NSFont(name: "EBGaramond-Regular", size: 12) != nil }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

extension Font {
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .bold, .heavy, .black: name = "Figtree-Bold"
        case .semibold: name = "Figtree-SemiBold"
        case .medium: name = "Figtree-Medium"
        default: name = "Figtree-Regular"
        }
        return NSFont(name: name, size: size) != nil ? .custom(name, size: size) : .system(size: size, weight: weight)
    }
    static func serif(_ size: CGFloat, italic: Bool = false) -> Font {
        let name = italic ? "EBGaramond-Italic" : "EBGaramond-Regular"
        return NSFont(name: name, size: size) != nil ? .custom(name, size: size) : .system(size: size, design: .serif)
    }
}

// MARK: reusable pieces

struct PrimaryButton: ButtonStyle {
    var dark = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.sans(14, .medium))
            .padding(.horizontal, 18).padding(.vertical, 9)
            .foregroundStyle(dark ? Color.white : Theme.ink)
            .background(RoundedRectangle(cornerRadius: 9).fill(dark ? Theme.ink : Theme.cardStrong))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Rectangle())
    }
}

struct AccentButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.sans(14, .medium))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .foregroundStyle(Theme.ink)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.accent))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.black.opacity(0.75), lineWidth: 1.2))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

struct GhostButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.sans(14, .medium))
            .padding(.horizontal, 16).padding(.vertical, 8)
            .foregroundStyle(Theme.ink)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct IconButton: View {
    let symbol: String
    var help: String = ""
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Theme.ink2)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(hover ? Theme.cardStrong : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// Flat pill toggle matching the reference (black on, warm grey off).
struct PillToggle: View {
    @Binding var isOn: Bool
    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule().fill(isOn ? Theme.ink : Color(hex: 0xD5D1C9)).frame(width: 44, height: 26)
            Circle().fill(Color.white).frame(width: 20, height: 20).padding(3)
                .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
        }
        .animation(.easeOut(duration: 0.15), value: isOn)
        .onTapGesture { isOn.toggle() }
        .accessibilityAddTraits(.isButton)
    }
}

struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .padding(.horizontal, 20)
            .background(RoundedRectangle(cornerRadius: 16).fill(Theme.card))
    }
}

struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var divider = true
    @ViewBuilder var trailing: Trailing
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.sans(15, .medium)).foregroundStyle(Theme.ink)
                    if let subtitle { Text(subtitle).font(.sans(13.5)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 12)
                trailing
            }
            .padding(.vertical, 16)
            if divider { Rectangle().fill(Theme.line).frame(height: 1) }
        }
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.sans(12, .semibold)).kerning(1.4).foregroundStyle(Theme.ink3)
    }
}

struct PageTitle: View {
    let text: String
    var beta = false
    var body: some View {
        HStack(spacing: 10) {
            Text(text).font(.sans(28, .semibold)).foregroundStyle(Theme.ink)
            if beta {
                Text("Beta").font(.sans(11, .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.ink))
            }
        }
    }
}

struct KeyCap: View {
    let text: String
    var body: some View {
        Text(text).font(.sans(12.5, .medium)).foregroundStyle(Theme.ink)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.line))
    }
}

struct FieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.textFieldStyle(.plain).font(.sans(14))
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line))
    }
}
extension View { func pieField() -> some View { modifier(FieldStyle()) } }

/// A dark photographic-feeling hero banner built from layered blurred shapes (no stock imagery).
struct HeroBanner<Content: View>: View {
    var tint: [Color] = [Color(hex: 0x2B2118), Color(hex: 0x6B4A2E), Color(hex: 0xB07A48)]
    var onClose: (() -> Void)?
    @ViewBuilder var content: Content
    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 18).fill(Color(hex: 0x14110E))
            Canvas { ctx, size in
                let blocks: [(CGFloat, CGFloat, CGFloat, CGFloat, Int)] = [
                    (0.55, 0.10, 0.22, 0.95, 0), (0.70, -0.1, 0.18, 0.8, 1), (0.83, 0.2, 0.25, 0.9, 2),
                    (0.62, 0.55, 0.30, 0.6, 1), (0.92, -0.05, 0.12, 0.7, 0),
                ]
                ctx.addFilter(.blur(radius: 28))
                for (x, y, w, h, c) in blocks {
                    let r = CGRect(x: x * size.width, y: y * size.height, width: w * size.width, height: h * size.height)
                    ctx.fill(Path(roundedRect: r, cornerRadius: 30), with: .color(tint[c].opacity(0.85)))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18))
            LinearGradient(colors: [Color.black.opacity(0.75), Color.black.opacity(0.05)], startPoint: .leading, endPoint: .trailing)
                .clipShape(RoundedRectangle(cornerRadius: 18))
            content.padding(.horizontal, 40).padding(.vertical, 34)
            if let onClose {
                HStack { Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ink)
                            .frame(width: 28, height: 28).background(Circle().fill(Color.white.opacity(0.9)))
                    }.buttonStyle(.plain).padding(16)
                }
            }
        }
    }
}

struct HeroButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.sans(15, .medium)).foregroundStyle(Theme.ink)
            .padding(.horizontal, 22).padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color(hex: 0xF3EFE8)))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// Dropdown styled like the reference app's language picker (white box, thin border, chevron),
/// instead of the system blue stepper control.
struct ThemedPicker<T: Hashable>: View {
    @Binding var selection: T
    let options: [(T, String)]
    var width: CGFloat = 220
    var body: some View {
        Menu {
            ForEach(options.indices, id: \.self) { i in
                Button { selection = options[i].0 } label: {
                    if options[i].0 == selection { Label(options[i].1, systemImage: "checkmark") } else { Text(options[i].1) }
                }
            }
        } label: {
            HStack {
                Text(options.first { $0.0 == selection }?.1 ?? "Choose").font(.sans(14.5)).foregroundStyle(Theme.ink).lineLimit(1)
                Spacer(minLength: 6)
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.ink2)
            }
            .padding(.horizontal, 14).frame(width: width, height: 38)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// Segmented chooser drawn in the app's own style.
struct ChipPicker<T: Hashable>: View {
    @Binding var selection: T
    let options: [(T, String)]
    var body: some View {
        HStack(spacing: 4) {
            ForEach(options.indices, id: \.self) { i in
                let on = options[i].0 == selection
                Text(options[i].1).font(.sans(14, .medium)).foregroundStyle(on ? Color.white : Theme.ink)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(on ? Theme.ink : Color.clear))
                    .contentShape(Rectangle())
                    .onTapGesture { selection = options[i].0 }
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 11).fill(Theme.cardStrong))
    }
}

/// API key field with a Paste button, so a key can be dropped in even if the field has no focus.
struct KeyField: View {
    let placeholder: String
    @Binding var key: String
    var width: CGFloat = 230
    var body: some View {
        HStack(spacing: 8) {
            SecureField(placeholder, text: Binding(get: { key }, set: { key = $0.trimmingCharacters(in: .whitespacesAndNewlines) }))
                .pieField().frame(width: width)
            Button(key.isEmpty ? "Paste" : "Clear") {
                if key.isEmpty { key = (NSPasteboard.general.string(forType: .string) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
                else { key = "" }
            }
            .buttonStyle(GhostButton()).fixedSize()
        }
    }
}

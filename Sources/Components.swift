import SwiftUI

// MARK: - Bausteine

struct SectionHeader: View {
    let title: String
    var detail: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Spacer()
            if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 14).padding(.top, 2).padding(.bottom, 3)
    }
}

struct MenuSeparator: View {
    var body: some View { Divider().padding(.horizontal, 14).padding(.vertical, 5) }
}

/// Belegung: Akzentfarbe, ab 75 % orange, ab 90 % rot.
struct UsageBar: View {
    let fraction: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule()
                    .fill(fraction > 0.9 ? Color(nsColor: .systemRed) : fraction > 0.75 ? Color(nsColor: .systemOrange) : Color.accentColor)
                    .frame(width: max(4, g.size.width * fraction))
            }
        }
        .frame(height: 4)
        .help(L("\(Int(fraction * 100)) % belegt", "\(Int(fraction * 100))% used"))
    }
}

/// Schalter-Zeile wie in den Kontrollzentrum-Modulen (Text links, kleiner Schalter rechts).
struct ToggleRow: View {
    let title: String
    var icon: String = "power"
    @Binding var isOn: Bool
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 12)).frame(width: 17)
            Text(title).font(.system(size: 13))
            Spacer()
            Toggle(title, isOn: $isOn).toggleStyle(.switch).controlSize(.mini).labelsHidden()
        }
        .padding(.horizontal, 9).frame(height: 26)
    }
}

extension View {
    /// macOS 26/27: runder Liquid-Glass-Button, auf älteren Systemen randlos.
    @ViewBuilder func glassCircleButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.small)
        } else {
            self.buttonStyle(.borderless)
        }
    }
}

/// Befehlszeile wie ein nativer Menüeintrag (macOS 26: Symbol links, Akzent-Hervorhebung, Häkchen, Kürzel).
struct MenuItem: View {
    let title: String
    let icon: String
    var checked: Bool? = nil
    var detail: String? = nil
    var shortcut: String? = nil
    let action: () -> Void
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 12)).frame(width: 17)
                Text(title).font(.system(size: 13))
                Spacer(minLength: 6)
                if let detail { Text(detail).font(.system(size: 12)).opacity(0.55) }
                if let shortcut { Text(shortcut).font(.system(size: 12)).opacity(0.55) }
                if checked == true { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)) }
            }
            .foregroundStyle(hl ? Color.white : enabled ? Color.primary : Color.secondary)
            .padding(.horizontal, 9).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hl ? Color.accentColor : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }

    private var hl: Bool { hover && enabled }
}

/// Hinweis-Kasten im Menü (Problem/Tipp) mit optionaler Aktion.
struct NoticeRow: View {
    let icon: String
    let text: String
    var tint: Color = Color(nsColor: .systemOrange)
    var action: (title: String, run: () -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint).frame(width: 17)
            VStack(alignment: .leading, spacing: 4) {
                Text(text).font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
                if let action {
                    Button(action.title, action: action.run).controlSize(.small)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.12)))
        .padding(.horizontal, 9).padding(.vertical, 3)
    }
}

/// „3 Min.“ / „2 Std.“ (englisch „3 min“ / „2 h“)
enum RelTime {
    static func short(_ d: Date, now: Date = Date()) -> String {
        let s = max(0, now.timeIntervalSince(d))
        if s < 60 { return L("gerade eben", "just now") }
        if s < 3600 { return L("\(Int(s / 60)) Min.", "\(Int(s / 60)) min") }
        if s < 86400 { return L("\(Int(s / 3600)) Std.", "\(Int(s / 3600)) h") }
        return L("\(Int(s / 86400)) Tg.", "\(Int(s / 86400)) d")
    }

    /// „seit 3 Std.“ / „connected for 3 h“ (Untertitel einer verbundenen Freigabe).
    static func connected(since d: Date, now: Date = Date()) -> String {
        let r = short(d, now: now)
        if Lang.isGerman { return "seit \(r)" }
        return now.timeIntervalSince(d) < 60 ? "connected just now" : "connected for \(r)"
    }

    /// „zuletzt vor 3 Min.“ / „last checked 3 min ago“.
    static func lastChecked(_ d: Date, now: Date = Date()) -> String {
        let r = short(d, now: now)
        if Lang.isGerman { return "zuletzt vor \(r)" }
        return now.timeIntervalSince(d) < 60 ? "last checked just now" : "last checked \(r) ago"
    }
}

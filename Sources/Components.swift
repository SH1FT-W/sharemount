import SwiftUI

// MARK: - Bausteine

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
                    Button(action.title, action: action.run).controlSize(.small).glassButton()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(cardShape(8).fill(tint.opacity(0.12)))
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

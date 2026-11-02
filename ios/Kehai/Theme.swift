import SwiftUI
import UIKit

/// Same palette as the web version: a quiet night-blue notebook with one warm accent.
enum Theme {
    static let bg = Color(light: 0xEDF0F2, dark: 0x0F1218)
    static let surface = Color(light: 0xF8F9FA, dark: 0x171B23)
    static let ink = Color(light: 0x1B2130, dark: 0xE8E5DC)
    static let muted = Color(light: 0x5A6373, dark: 0x9AA1AE)
    static let line = Color(light: 0xD2D8DF, dark: 0x2B313C)
    static let accent = Color(light: 0xC2701F, dark: 0xE6A157)

    static func tag(_ t: MomentTag) -> Color {
        switch t {
        case .laugh: return Color(light: 0xB67B10, dark: 0xE0AE4C)
        case .sing: return Color(light: 0x3A8560, dark: 0x6CBB8E)
        case .chat: return Color(light: 0x4867B8, dark: 0x88A5EA)
        case .shout: return Color(light: 0xB9505B, dark: 0xE48A93)
        }
    }

    /// Hiragino Maru Gothic ships with iOS; falls back to the system font if it ever doesn't.
    static func display(_ size: CGFloat) -> Font { .custom("HiraMaruProN-W4", size: size) }
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

enum Format {
    /// 0:42, 12:05, 1:02:03
    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        let h = s / 3600, m = s % 3600 / 60, ss = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, ss) : String(format: "%d:%02d", m, ss)
    }

    /// 12分, 1時間5分
    static func minutes(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        return m >= 60 ? "\(m / 60)時間\(m % 60)分" : "\(m)分"
    }

    static func time(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// "2026-11-02" -> 11月2日（月）
    static func day(_ key: String) -> String {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3, let d = Calendar.current.date(from: DateComponents(year: p[0], month: p[1], day: p[2])) else { return key }
        let w = Calendar.current.component(.weekday, from: d) - 1
        let names = ["日", "月", "火", "水", "木", "金", "土"]
        return "\(p[1])月\(p[2])日（\(names[w])）"
    }

    static func megabytes(_ bytes: Int64) -> String { String(format: "%.1fMB", Double(bytes) / 1_048_576) }
}

/// The main pill button, filled when it is the next thing to press.
struct PillButtonStyle: ButtonStyle {
    var filled = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .tracking(1.5)
            .padding(.vertical, 14)
            .frame(minWidth: 200)
            .foregroundStyle(filled ? Theme.bg : Theme.ink)
            .background(Capsule().fill(filled ? Theme.accent : Color.clear))
            .overlay(Capsule().stroke(filled ? Color.clear : Theme.line, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

/// A rounded card on the page background.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line, lineWidth: 1))
    }
}

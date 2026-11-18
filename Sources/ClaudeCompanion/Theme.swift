import AppKit
import SwiftUI

extension Color {
    /// A color with separate light and dark appearance values.
    init(light: Int, dark: Int) {
        func ns(_ hex: Int) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                    blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        }
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? ns(dark) : ns(light)
        })
    }

    init(hex: Int) { self.init(light: hex, dark: hex) }
}

/// Style A: warm, light, a coral accent on calm cards.
enum Ember {
    static let accent = Color(light: 0xC4552E, dark: 0xE27A4F)      // buttons, links
    static let ring = Color(light: 0xD9653B, dark: 0xE8794A)
    static let ringTrack = Color(light: 0xEEDCCF, dark: 0x45372F)
    static let card = Color(light: 0xF7F0EA, dark: 0x2D2724)
    static let cardRaised = Color(light: 0xFFFFFF, dark: 0x3A322D)
    static let alert = Color(light: 0xFCE7DC, dark: 0x4A2C1E)
    static let window = Color(light: 0xFBF7F3, dark: 0x1E1B19)
    static let ink = Color(hex: 0x3B1A10)
}

extension Font {
    /// SF Pro Rounded for key numbers.
    static func number(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

extension Account {
    /// The account's fixed identity color (blue, orange, green… by position).
    func color(in accounts: [Account]) -> Color {
        SeriesPalette.color(accounts.firstIndex(of: self) ?? 0)
    }
}

extension CompanionConfig {
    func color(for accountID: String) -> Color {
        SeriesPalette.color(accounts.firstIndex { $0.id == accountID } ?? 0)
    }
}

/// A rounded card in the Ember style.
struct EmberCard<Content: View>: View {
    var padding: CGFloat = 12
    var fill: Color = Ember.card
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(fill))
    }
}

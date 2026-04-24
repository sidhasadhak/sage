import SwiftUI

enum Theme {
    // MARK: - Winter Chill Palette
    // #B8E3E9  lightest cyan
    static let frost = Color(red: 0.722, green: 0.890, blue: 0.914)
    // #93B1B5  muted sage-teal
    static let mist  = Color(red: 0.576, green: 0.694, blue: 0.710)
    // #4F7C82  mid teal — primary accent
    static let teal  = Color(red: 0.310, green: 0.486, blue: 0.510)
    // #0B2E33  near-black deep teal
    static let deep  = Color(red: 0.043, green: 0.180, blue: 0.200)

    // MARK: - Semantic Colors
    static let accent         = Color("AccentColor")         // #4F7C82 — set in Assets
    static let userBubble     = teal                         // solid teal for user messages
    static let aiBubble       = Color(.secondarySystemFill)  // adaptive for light/dark
    static let cardBackground = Color(.secondarySystemBackground)
    static let destructive    = Color.red

    // MARK: - Typography
    static let titleFont    = Font.system(.title2, design: .rounded, weight: .semibold)
    static let headlineFont = Font.system(.headline, design: .rounded)
    static let bodyFont     = Font.system(.body, design: .default)
    static let captionFont  = Font.system(.caption, design: .rounded)

    // MARK: - Layout
    static let cornerRadius:      CGFloat = 16
    static let smallCornerRadius: CGFloat = 10
    static let cardPadding:       CGFloat = 16
    static let bubbleMaxWidth:    CGFloat = 0.78 // fraction of screen width

    // MARK: - Animation
    static let springAnimation = Animation.spring(response: 0.4, dampingFraction: 0.75)
    static let easeAnimation   = Animation.easeInOut(duration: 0.2)
}

// MARK: - View Modifiers

struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(Theme.cardPadding)
            .background(Theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
    }
}

struct SageButtonStyle: ButtonStyle {
    var filled: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.headlineFont)
            .foregroundStyle(filled ? .white : .primary)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(filled ? Color.accentColor : Color(.tertiarySystemFill))
            .clipShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Theme.easeAnimation, value: configuration.isPressed)
    }
}

extension View {
    func cardStyle() -> some View {
        modifier(CardStyle())
    }
}

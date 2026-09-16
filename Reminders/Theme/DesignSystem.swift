import SwiftUI

enum RemindersTheme {
    static let paper = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let ink = Color(uiColor: .label)
    // Accent must not follow `label`: List selection uses tint as its fill,
    // so a white tint in dark appearance makes white row text disappear.
    static let accent = Color(uiColor: .systemBlue)
    static let actionForeground = Color(uiColor: .systemBackground)
    static let muted = Color(uiColor: .secondaryLabel)
    static let pale = Color(uiColor: .tertiarySystemGroupedBackground)
    // Dynamic system colors retain contrast in both light and dark appearances.
    static let danger = Color(uiColor: .systemRed)
    static let success = Color(uiColor: .systemGreen)
}

struct PaperCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(RemindersTheme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color(uiColor: .separator).opacity(0.55), lineWidth: 1)
            }
    }
}

extension View {
    func paperCard() -> some View { modifier(PaperCard()) }

    /// Prevent UIKit's default list/form canvas from falling back to a light
    /// opaque surface while the app is in dark appearance.
    func reminderCanvas() -> some View {
        scrollContentBackground(.hidden)
            .background(RemindersTheme.paper)
            .foregroundStyle(RemindersTheme.ink)
    }
}

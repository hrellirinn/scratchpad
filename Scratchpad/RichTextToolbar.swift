import SwiftUI

/// The formatting toolbar from the v2 Figma: four text styles, a gap, two list
/// styles. 20 pt buttons, 2 pt apart; the active one gets a soft filled square.
struct RichTextToolbar: View {
    var controller: EditorController
    var theme: EditorTheme

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                button("bold",          active: controller.isBold,       help: "Bold (⌘B)")          { controller.toggleBold() }
                button("italic",        active: controller.isItalic,     help: "Italic (⌘I)")        { controller.toggleItalic() }
                button("underline",     active: controller.isUnderlined, help: "Underline (⌘U)")     { controller.toggleUnderline() }
                button("strikethrough", active: controller.isStruck,     help: "Strikethrough")      { controller.toggleStrikethrough() }
            }
            HStack(spacing: 2) {
                button("list.bullet", active: controller.listKind == .bullet,    help: "Bulleted list") { controller.toggleBullets() }
                button("checklist",   active: controller.listKind == .checklist, help: "Checklist")     { controller.toggleChecklist() }
            }
        }
    }

    private func button(_ symbol: String, active: Bool, help: String, action: @escaping () -> Void) -> some View {
        let ink = Color(nsColor: theme.textColor)
        return Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 20, height: 20)
                .foregroundStyle(ink.opacity(active ? 1 : 0.65))
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(ink.opacity(active ? 0.22 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

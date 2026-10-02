import AppKit
import Observation

/// The bridge between the SwiftUI toolbar and the AppKit text view.
///
/// Buttons call the actions; the view reads the `is…` flags to show which
/// formats are active at the cursor. `refresh()` is called by the editor
/// whenever the selection or text changes.
@Observable
final class EditorController {

    weak var textView: IndentingTextView?

    private(set) var isBold = false
    private(set) var isItalic = false
    private(set) var isUnderlined = false
    private(set) var isStruck = false
    private(set) var listKind: ListKind?

    func refresh() {
        guard let textView, textView.isRichText else {
            isBold = false; isItalic = false; isUnderlined = false; isStruck = false; listKind = nil
            return
        }
        let state = textView.formattingState()
        isBold = state.bold
        isItalic = state.italic
        isUnderlined = state.underline
        isStruck = state.strikethrough
        listKind = state.list
    }

    func toggleBold()          { perform { $0.toggleTrait(.bold) } }
    func toggleItalic()        { perform { $0.toggleTrait(.italic) } }
    func toggleUnderline()     { perform { $0.toggleStyle(.underlineStyle) } }
    func toggleStrikethrough() { perform { $0.toggleStyle(.strikethroughStyle) } }
    func toggleBullets()       { perform { $0.toggleList(.bullet) } }
    func toggleChecklist()     { perform { $0.toggleList(.checklist) } }

    private func perform(_ action: (IndentingTextView) -> Void) {
        guard let textView else { return }
        action(textView)
        // Clicking a toolbar button shouldn't steal the keyboard from the editor.
        textView.window?.makeFirstResponder(textView)
        refresh()
    }
}

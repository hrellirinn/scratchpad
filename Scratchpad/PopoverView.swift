import SwiftUI

/// Everything you see inside the panel — including the glass itself.
///
/// Layout, top to bottom, matching the Figma frame:
///   1. Sheet selector  — native segmented control, full width
///   2. Editor          — CodeEditor on a dark panel; plain (gutter) or rich (toolbar) per sheet
///   3. Footer          — gear menu, right-aligned
///
/// This view paints NO background: the Liquid Glass is the `NSGlassEffectView`
/// this view lives inside (see FloatingPanel).
struct PopoverView: View {

    /// The model, owned by AppDelegate. Because it's `@Observable`, reading
    /// `store.texts` / `store.selectedIndex` here subscribes this view to changes.
    var store: SheetStore
    var settings: AppSettings

    /// Light or dark, as the *panel* currently is (the window's appearance, which
    /// Settings ▸ Appearance controls). Drives the editor palette.
    @Environment(\.colorScheme) private var colorScheme

    /// SwiftUI's built-in action for showing the `Settings` scene (⌘,).
    @Environment(\.openSettings) private var openSettings

    /// Lets the toolbar talk to the text view and mirrors its formatting state.
    @State private var editorController = EditorController()

    // Design tokens for this view. Pulled out so they're easy to tune and,
    // later, easy to drive from Settings.
    private enum Metrics {
        static let outerPadding: CGFloat = 8
        static let spacing: CGFloat = 8
        static let editorChromeInset: CGFloat = 8     // header controls' distance from the editor edge
        static let headerBand: CGFloat = 32           // the mode bar above the text (both modes)
    }

    var body: some View {
        VStack(spacing: Metrics.spacing) {
            if settings.sheetCount > 1 {
                sheetSelector
            }
            editor
            footer
        }
        .padding(Metrics.outerPadding)
        .frame(width: AppDelegate.panelSize.width,
               height: AppDelegate.panelSize.height)
        // If the user reduces the sheet count below the selected tab, fall back
        // to the last visible one. `initial: true` also runs this at launch.
        .onChange(of: settings.sheetCount, initial: true) { _, count in
            if store.selectedIndex >= count { store.selectedIndex = count - 1 }
        }
    }

    // MARK: Sheet selector

    private var sheetSelector: some View {
        SheetSelector(
            titles: (0..<settings.sheetCount).map(store.title(for:)),
            selectedIndex: Binding(
                get: { store.selectedIndex },
                set: { store.selectedIndex = $0 }
            ),
            onRename: { index, name in
                if let name { store.rename(index, to: name) }
                editorController.focusEditor()
            }
        )
        .frame(maxWidth: .infinity)
    }

    // MARK: Editor

    private var isRich: Bool { store.format(for: store.selectedIndex) == .rich }

    /// A two-way connection between the editor and the *current* sheet's text.
    /// `get` reads from the store; `set` hands keystrokes back to it (which
    /// also schedules the autosave).
    private var currentText: Binding<String> {
        Binding(
            get: { store.texts[store.selectedIndex] },
            set: { store.setText($0, for: store.selectedIndex) }
        )
    }

    private var currentRichText: Binding<NSAttributedString> {
        Binding(
            get: { store.richTexts[store.selectedIndex] },
            set: { store.setRichText($0, for: store.selectedIndex) }
        )
    }

    /// The switch: flips the current sheet between plain and rich.
    private var richTextSwitch: Binding<Bool> {
        Binding(
            get: { isRich },
            set: { store.setFormat($0 ? .rich : .plain, for: store.selectedIndex) }
        )
    }

    private var editor: some View {
        let theme = EditorTheme.make(settings: settings, colorScheme: colorScheme)
        let shape = RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)

        return ZStack(alignment: .top) {
            CodeEditor(text: currentText,
                       richText: currentRichText,
                       format: store.format(for: store.selectedIndex),
                       language: store.language(for: store.selectedIndex),
                       documentID: store.selectedIndex,
                       theme: theme,
                       topInset: Metrics.headerBand,     // text starts below the header, scrolls under it
                       controller: editorController)

            // Header wash: the blur itself is drawn by the scroll view (FrostedScrollView);
            // this adds a veil of the editor colour so the controls stay legible.
            Color(nsColor: theme.backgroundColor).opacity(0.3)
                .frame(height: Metrics.headerBand)
                .allowsHitTesting(false)

            editorHeader(theme: theme)
                .padding(Metrics.editorChromeInset)
        }
        .background(shape.fill(Color(nsColor: theme.backgroundColor).opacity(theme.backgroundOpacity)))
        .clipShape(shape)
        .overlay {
            // The two hairlines from the Figma: a dark one along the top
            // edge and a light one along the bottom, giving the panel a
            // slight "inset" feel.
            VStack(spacing: 0) {
                Rectangle().fill(Color(nsColor: theme.hairlineTop)).frame(height: 1)
                Spacer(minLength: 0)
                Rectangle().fill(Color(nsColor: theme.hairlineBottom)).frame(height: 1)
            }
            .clipShape(shape)
            .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.15), value: isRich)
    }

    /// The mode bar across the top of the editor (v2 Figma):
    ///   plain → [Plain Text ⌄] ……………………… (switch)
    ///   rich  → B I U S  ≡ ☑ ……………… Rich Text (switch)
    private func editorHeader(theme: EditorTheme) -> some View {
        let ink = Color(nsColor: theme.textColor)
        return HStack(spacing: 8) {
            if isRich {
                RichTextToolbar(controller: editorController, theme: theme)
                    .transition(.opacity)
            } else {
                languageMenu(theme: theme)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
            if isRich {
                Text("Rich Text")
                    .font(.system(size: 12))
                    .foregroundStyle(ink.opacity(0.6))
            }
            Toggle("Rich text", isOn: richTextSwitch)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help(isRich ? "Switch to plain text" : "Switch to rich text")
        }
        .frame(height: 20)
    }

    /// Syntax-colouring picker for plain sheets. Decoration only — the file
    /// stays plain text whatever is chosen.
    private func languageMenu(theme: EditorTheme) -> some View {
        let ink = Color(nsColor: theme.textColor)
        let current = store.language(for: store.selectedIndex)
        return Menu {
            ForEach(SyntaxLanguage.allCases) { language in
                Button {
                    store.setLanguage(language, for: store.selectedIndex)
                } label: {
                    if language == current {
                        Label(language.title, systemImage: "checkmark")
                    } else {
                        Text(language.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(current.title)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 11))
            .foregroundStyle(ink.opacity(0.6))
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(ink.opacity(0.22))
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Syntax colouring")
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Spacer()
            Menu {
                Button("Settings…") {
                    (NSApp.delegate as? AppDelegate)?.prepareForSettings()
                    openSettings()
                }
                Divider()
                Button("Quit Scratchpad") {
                    NSApp.terminate(nil)
                }
            } label: {
                Image(systemName: "gear")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .frame(height: 20)
    }
}

#Preview {
    PopoverView(store: SheetStore(), settings: AppSettings.shared)
}

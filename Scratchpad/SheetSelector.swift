import SwiftUI

/// The sheet tabs: a capsule segmented control.
///
/// Built in SwiftUI because neither the SwiftUI `Picker` nor AppKit's
/// `NSSegmentedControl` will give us fully rounded ends on macOS 26. It follows
/// the native control's proportions and states, so it should still read as
/// "system", just with the geometry you asked for.
///
/// States (from the Figma):
///   - track            : 12% capsule (white on dark, black on light)
///   - selected segment : raised pill, label at 100%
///   - other segments   : label at 60%, hairline separators between them
///
/// Double-click a tab (or right-click ▸ Rename…) to rename it in place.
/// Return keeps the new name, Esc cancels.
struct SheetSelector: View {

    var titles: [String]
    @Binding var selectedIndex: Int
    /// Called when a rename ends, with the new name or `nil` if it was
    /// cancelled. Leave it out and the tabs can't be renamed.
    var onRename: ((_ index: Int, _ name: String?) -> Void)? = nil

    /// Lets the selection pill animate from one segment to the next instead of
    /// jumping — `matchedGeometryEffect` moves a view between positions.
    @Namespace private var selection
    @Environment(\.colorScheme) private var colorScheme

    /// The tab being renamed, and the name typed so far.
    @State private var editingIndex: Int?
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    private enum Metrics {
        static let height: CGFloat = 28
        static let inset: CGFloat = 2          // gap between track edge and pill
        static let fontSize: CGFloat = 14
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(titles.indices, id: \.self) { index in
                segment(at: index)
            }
        }
        .padding(Metrics.inset)
        .background(Capsule().fill(.primary.opacity(0.12)))
        .frame(height: Metrics.height)
        // Animate every selection change with the system's default spring.
        .animation(.snappy(duration: 0.25), value: selectedIndex)
    }

    private func segment(at index: Int) -> some View {
        let isSelected = index == selectedIndex

        return Button {
            selectedIndex = index
        } label: {
            Text(titles[index])
                .font(.system(size: Metrics.fontSize))
                .foregroundStyle(.primary.opacity(isSelected ? 1 : 0.6))
                .lineLimit(1)
                .opacity(editingIndex == index ? 0 : 1)      // the rename field sits on top
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    if isSelected {
                        Capsule()
                            // Dark: a lighter translucent pill. Light: a near-white
                            // raised pill, like the native control.
                            .fill(colorScheme == .dark ? .white.opacity(0.22) : .white.opacity(0.9))
                            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                            .matchedGeometryEffect(id: "pill", in: selection)
                    }
                }
                .overlay(alignment: .leading) {
                    // Hairline separator, like the native control: only between
                    // two *unselected* segments.
                    if index > 0, !isSelected, index - 1 != selectedIndex {
                        Rectangle()
                            .fill(.primary.opacity(0.2))
                            .frame(width: 1)
                            .padding(.vertical, 6)
                    }
                }
                .contentShape(Capsule())   // whole segment is clickable, not just the text
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded { beginRename(index) })
        .contextMenu {
            if onRename != nil {
                Button("Rename…") { beginRename(index) }
            }
        }
        .help(titles[index])          // full name, if the tab cuts it short
        .overlay {
            // Outside the Button, so clicks reach the field instead of the tab.
            if editingIndex == index {
                renameField
            }
        }
    }

    // MARK: Renaming

    private var renameField: some View {
        TextField("", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: Metrics.fontSize))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 8)
            .focused($fieldFocused)
            .onAppear { fieldFocused = true }
            .onSubmit { endRename(keep: true) }
            .onExitCommand { endRename(keep: false) }
            // Clicking elsewhere keeps what was typed, like Finder.
            .onChange(of: fieldFocused) { _, focused in
                if !focused { endRename(keep: true) }
            }
    }

    private func beginRename(_ index: Int) {
        guard onRename != nil else { return }
        selectedIndex = index
        draft = titles[index]
        editingIndex = index
    }

    private func endRename(keep: Bool) {
        guard let index = editingIndex else { return }
        editingIndex = nil
        onRename?(index, keep ? draft : nil)
    }
}

#Preview {
    @Previewable @State var index = 0
    SheetSelector(titles: ["Sheet 1", "Sheet 2", "Sheet 3", "Sheet 4", "Sheet 5"],
                  selectedIndex: $index)
        .padding()
        .frame(width: 440)
        .background(.black)
}

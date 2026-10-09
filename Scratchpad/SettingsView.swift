import ServiceManagement
import SwiftUI

/// The Settings window (⌘,). Laid out after CotEditor's preferences:
/// General (sheets), Appearance (font, line height, appearance, opacity), About.
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettingsTab() }
            Tab("Appearance", systemImage: "eyeglasses") { AppearanceSettingsTab() }
            Tab("About", systemImage: "info.circle") { AboutTab() }
        }
        .frame(width: 520)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @Bindable private var settings = AppSettings.shared

    /// Asked of the system rather than stored, because it can also be
    /// switched off in System Settings ▸ General ▸ Login Items.
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            LabeledContent("Startup:") {
                Toggle("Open Scratchpad at login", isOn: $opensAtLogin)
            }
            .padding(.bottom, 12)

            // The 220pt width must apply to the segments only. On the Picker
            // itself it squeezed the label into the same box, wrapping it.
            LabeledContent("Number of sheets:") {
                Picker("", selection: $settings.sheetCount) {
                    ForEach(1...AppSettings.maxSheets, id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 220)
            }

            Text("With one sheet the tab strip is hidden. Hidden sheets keep their text.")
                .font(.callout)
                .foregroundStyle(.secondary)

            LabeledContent("Open Scratchpad:") {
                ShortcutRecorder(shortcut: $settings.panelShortcut)
            }
            .padding(.top, 12)

            Text("Works from any app. Press it again to close the panel.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .onChange(of: opensAtLogin) { _, on in setOpensAtLogin(on) }
        .onAppear { opensAtLogin = SMAppService.mainApp.status == .enabled }
    }

    private func setOpensAtLogin(_ on: Bool) {
        let service = SMAppService.mainApp
        guard on != (service.status == .enabled) else { return }
        do {
            try on ? service.register() : service.unregister()
            // Switched off by hand in System Settings earlier: only the user
            // can turn it back on there, so take them to it.
            if service.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch {
            print("[Scratchpad] couldn't change login item: \(error)")
            opensAtLogin = service.status == .enabled
        }
    }
}

// MARK: - Appearance

private struct AppearanceSettingsTab: View {
    @Bindable private var settings = AppSettings.shared

    /// Owns the connection to the macOS Font panel. Kept in `@State` so it
    /// lives as long as this tab is on screen.
    @State private var fontPanel = FontPanelBridge()

    private var fontLabel: String {
        let name = settings.font.displayName ?? settings.fontName
        return "\(name)  \(Int(settings.fontSize))"
    }

    var body: some View {
        Form {
            // Font: [Monaco 12] ⇕ [Select…]
            LabeledContent("Font:") {
                HStack(spacing: 6) {
                    Text(fontLabel)
                        .font(Font(settings.font).leading(.tight))
                        .lineLimit(1)
                        .frame(width: 260, height: 22)
                        .background(.background, in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary))
                    Stepper("", value: $settings.fontSize, in: AppSettings.fontSizeRange, step: 1)
                        .labelsHidden()
                    Button("Select…") {
                        fontPanel.open(current: settings.font) { font in
                            settings.fontName = font.fontName
                            settings.fontSize = font.pointSize
                        }
                    }
                }
            }

            // Line height: [1.4] ⇕ times
            LabeledContent("Line height:") {
                HStack(spacing: 6) {
                    TextField("", value: $settings.lineHeightMultiple,
                              format: .number.precision(.fractionLength(1)))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 56)
                    Stepper("", value: $settings.lineHeightMultiple,
                            in: AppSettings.lineHeightRange, step: 0.1)
                        .labelsHidden()
                    Text("times")
                }
            }

            // Appearance: ◯ Match System ◯ Light ● Dark
            Picker("Appearance:", selection: $settings.appearanceMode) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode == .system ? "Match System" : mode.label).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
            .horizontalRadioGroupLayout()

            LabeledContent("") {
                Toggle("Keep editor dark in Light appearance", isOn: $settings.keepEditorDark)
                    .disabled(settings.appearanceMode == .dark)
            }

            // Editor opacity: [slider] [88%]
            LabeledContent("Editor opacity:") {
                HStack(spacing: 8) {
                    Slider(value: $settings.editorOpacity, in: 0.5...1.0)
                        .frame(width: 220)
                    Text(settings.editorOpacity, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                }
            }
        }
        .padding(24)
        .onChange(of: settings.fontSize) { _, size in
            let r = AppSettings.fontSizeRange
            let clamped = min(max(size, r.lowerBound), r.upperBound)
            if clamped != size { settings.fontSize = clamped }
        }
        .onChange(of: settings.lineHeightMultiple) { _, value in
            let r = AppSettings.lineHeightRange
            let clamped = min(max(value, r.lowerBound), r.upperBound)
            if clamped != value { settings.lineHeightMultiple = clamped }
        }
    }
}

/// Talks to the system Font panel. AppKit sends `changeFont(_:)` to the font
/// manager's target whenever the user picks a face or size; we turn that into
/// a callback with the resulting `NSFont`.
@Observable
private final class FontPanelBridge: NSObject {
    private var current: NSFont = .systemFont(ofSize: 12)
    private var onChange: ((NSFont) -> Void)?

    func open(current: NSFont, onChange: @escaping (NSFont) -> Void) {
        self.current = current
        self.onChange = onChange
        let manager = NSFontManager.shared
        manager.target = self
        manager.setSelectedFont(current, isMultiple: false)
        manager.orderFrontFontPanel(nil)
    }

    /// Called by AppKit. `convert` applies the panel's choice to our current font.
    @objc func changeFont(_ sender: Any?) {
        let manager = (sender as? NSFontManager) ?? NSFontManager.shared
        current = manager.convert(current)
        onChange?(current)
    }

    /// Which sections of the panel to show: face + size, no colour/effects.
    @objc func validModesForFontPanel(_ fontPanel: NSFontPanel) -> NSFontPanel.ModeMask {
        [.face, .size, .collection]
    }
}

// MARK: - About

private struct AboutTab: View {
    private var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }
    private var name: String { info["CFBundleName"] as? String ?? "Scratchpad" }
    private var version: String { info["CFBundleShortVersionString"] as? String ?? "" }
    private var build: String { info["CFBundleVersion"] as? String ?? "" }
    private var copyright: String { info["NSHumanReadableCopyright"] as? String ?? "" }

    private let blurb = """
    Scratchpad is a one-person project by Elías R. Ragnarsson — a designer in \
    Reykjavík who spends his days on design systems, tokens and the tooling that \
    holds them together, and his evenings somewhere between a guitar, a 3D printer \
    and a stack of science fiction. It started as a way to keep a few notes within \
    reach of the menubar, and as an exercise in treating a small personal tool like \
    a real product.
    """

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text(name)
                .font(.title2.weight(.semibold))
            Text("Version \(version) (\(build))")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(blurb)
                .font(.callout)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
                // Inside a TabView, SwiftUI offers the text one line of height and
                // truncates with "…". This says "take whatever height you need".
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            Text(copyright)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 12)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 24)
    }
}

#Preview {
    SettingsView()
}

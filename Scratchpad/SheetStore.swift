import AppKit
import Observation

/// Whether a sheet is plain text (Monaco, line numbers, `.txt`) or rich text
/// (system font, formatting toolbar, `.rtf`). Chosen per sheet with the switch.
enum SheetFormat: String {
    case plain, rich
}

/// The app's model: five sheets, each backed by a file.
///
/// `@Observable` means SwiftUI views that read these properties redraw when they
/// change. Only this object touches the disk; views just read and write content.
@Observable
final class SheetStore {

    static let sheetCount = 5

    /// Plain-text content per sheet (used when `formats[i] == .plain`).
    private(set) var texts: [String]
    /// Rich-text content per sheet (used when `formats[i] == .rich`).
    private(set) var richTexts: [NSAttributedString]
    /// Which kind each sheet is.
    private(set) var formats: [SheetFormat] {
        didSet { UserDefaults.standard.set(formats.map(\.rawValue), forKey: Keys.formats) }
    }
    /// Syntax colouring per plain-text sheet (decoration only; files stay plain).
    private(set) var languages: [SyntaxLanguage] {
        didSet { UserDefaults.standard.set(languages.map(\.rawValue), forKey: Keys.languages) }
    }

    /// Which tab is showing. Persisted so the app reopens where you left it.
    var selectedIndex: Int {
        didSet { UserDefaults.standard.set(selectedIndex, forKey: Keys.selectedIndex) }
    }

    /// Where the files live. Inside the sandbox this resolves to
    /// ~/Library/Containers/<bundle id>/Data/Library/Application Support/Scratchpad/
    let directory: URL

    /// One pending save per sheet, so rapid typing collapses into a single write.
    private var pendingSaves: [Int: DispatchWorkItem] = [:]
    private let saveDelay: TimeInterval = 0.6

    private enum Keys {
        static let selectedIndex = "selectedSheetIndex"
        static let formats = "sheetFormats"
        static let languages = "sheetLanguages"
    }

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Scratchpad", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Which format each sheet was last saved in (default: all plain).
        let savedFormats = (UserDefaults.standard.array(forKey: Keys.formats) as? [String]) ?? []
        var loadedFormats = (0..<Self.sheetCount).map { index -> SheetFormat in
            index < savedFormats.count ? (SheetFormat(rawValue: savedFormats[index]) ?? .plain) : .plain
        }

        // Load whatever is on disk; a missing file is simply an empty sheet.
        var loadedTexts: [String] = []
        var loadedRich: [NSAttributedString] = []
        for index in 0..<Self.sheetCount {
            if loadedFormats[index] == .rich,
               let data = try? Data(contentsOf: Self.fileURL(in: dir, index: index, format: .rich)),
               let rich = NSAttributedString(rtf: data, documentAttributes: nil) {
                loadedRich.append(rich)
                loadedTexts.append("")
            } else {
                // Either a plain sheet, or a rich sheet whose file went missing — fall back to plain.
                loadedFormats[index] = .plain
                let text = (try? String(contentsOf: Self.fileURL(in: dir, index: index, format: .plain),
                                        encoding: .utf8)) ?? ""
                loadedTexts.append(text)
                loadedRich.append(NSAttributedString())
            }
        }

        let savedLanguages = (UserDefaults.standard.array(forKey: Keys.languages) as? [String]) ?? []
        let loadedLanguages = (0..<Self.sheetCount).map { index -> SyntaxLanguage in
            index < savedLanguages.count ? (SyntaxLanguage(rawValue: savedLanguages[index]) ?? .plain) : .plain
        }

        directory = dir
        texts = loadedTexts
        richTexts = loadedRich
        formats = loadedFormats
        languages = loadedLanguages

        let saved = UserDefaults.standard.integer(forKey: Keys.selectedIndex)
        selectedIndex = (0..<Self.sheetCount).contains(saved) ? saved : 0
    }

    // MARK: - Naming

    func title(for index: Int) -> String {
        "Sheet \(index + 1)"
    }

    static func fileURL(in directory: URL, index: Int, format: SheetFormat) -> URL {
        directory.appendingPathComponent("Sheet \(index + 1).\(format == .rich ? "rtf" : "txt")")
    }

    func format(for index: Int) -> SheetFormat { formats[index] }
    func language(for index: Int) -> SyntaxLanguage { languages[index] }
    func setLanguage(_ language: SyntaxLanguage, for index: Int) { languages[index] = language }

    // MARK: - Editing

    /// Plain-text edits. Called on every keystroke via the view's binding.
    func setText(_ text: String, for index: Int) {
        guard texts[index] != text else { return }
        texts[index] = text
        scheduleSave(index)
    }

    /// Rich-text edits (typing *and* formatting changes).
    func setRichText(_ text: NSAttributedString, for index: Int) {
        guard !richTexts[index].isEqual(to: text) else { return }
        richTexts[index] = text
        scheduleSave(index)
    }

    /// Flip a sheet between plain and rich, converting its content.
    func setFormat(_ format: SheetFormat, for index: Int) {
        guard formats[index] != format else { return }
        pendingSaves[index]?.cancel()
        pendingSaves[index] = nil

        switch format {
        case .rich:
            // Plain → rich: same words, no formatting yet. The editor applies the theme.
            richTexts[index] = NSAttributedString(string: texts[index])
            texts[index] = ""
        case .plain:
            // Rich → plain: keep the words, drop the formatting. List markers
            // ("\t•\t", "\t☐\t", "\t☑\t") become readable prefixes.
            texts[index] = Self.plainText(from: richTexts[index])
            richTexts[index] = NSAttributedString()
        }

        let old = formats[index]
        formats[index] = format
        save(index)
        try? FileManager.default.removeItem(at: Self.fileURL(in: directory, index: index, format: old))
    }

    private static func plainText(from rich: NSAttributedString) -> String {
        // Walk paragraphs: "\t•\t" style markers become "• ", and each nesting
        // level becomes two leading spaces.
        let text = rich.string as NSString
        var output = ""
        var index = 0
        while index < text.length {
            let paragraph = text.paragraphRange(for: NSRange(location: index, length: 0))
            var line = text.substring(with: paragraph)
            if line.count >= 3, line.hasPrefix("\t"), Array(line)[2] == "\t",
               "•◦▪☐☑".contains(Array(line)[1]) {
                let style = rich.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle
                let level = max(0, Int((style?.headIndent ?? 24) / 24 + 0.5) - 1)
                let marker = Array(line)[1]
                line = String(repeating: "  ", count: level) + String(marker) + " " + line.dropFirst(3)
            }
            output += line
            guard NSMaxRange(paragraph) > index else { break }
            index = NSMaxRange(paragraph)
        }
        return output
    }

    private func scheduleSave(_ index: Int) {
        pendingSaves[index]?.cancel()                     // typing continued: start the clock over
        let work = DispatchWorkItem { [weak self] in
            self?.save(index)
        }
        pendingSaves[index] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDelay, execute: work)
    }

    // MARK: - Saving

    private func save(_ index: Int) {
        pendingSaves[index] = nil
        let format = formats[index]
        let url = Self.fileURL(in: directory, index: index, format: format)
        do {
            switch format {
            case .plain:
                // `atomically: true` writes to a temp file then swaps it in, so a crash
                // mid-write can never leave you with a half-written sheet.
                try texts[index].write(to: url, atomically: true, encoding: .utf8)
            case .rich:
                let rich = richTexts[index]
                let data = rich.rtf(from: NSRange(location: 0, length: rich.length),
                                    documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) ?? Data()
                try data.write(to: url, options: .atomic)
            }
        } catch {
            print("[Scratchpad] failed to save \(url.lastPathComponent): \(error)")
        }
    }

    /// Flush every pending save now — used when the panel closes and at quit.
    func saveAll() {
        for index in pendingSaves.keys.sorted() {
            pendingSaves[index]?.cancel()
            save(index)
        }
    }
}

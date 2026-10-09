# Scratchpad

Scratch notes in the menubar. Click the clipboard icon, type, click away. Everything saves as you go.

- Up to five sheets, each plain or rich text
- Plain: line numbers, auto-indent, syntax colouring for HTML, CSS, JavaScript, JSON, Swift and Markdown
- Rich: bold, italic, underline, strikethrough, bullets, checklists (Tab / ⇧Tab to nest)
- Liquid Glass panel, light or dark, adjustable editor font, line height and opacity
- Esc closes the panel

Needs macOS 26.

## Install

Download the zip from [Releases](https://github.com/hrellirinn/scratchpad/releases), unzip, drag Scratchpad into Applications.

The app isn't notarized, so the first launch says macOS can't verify it. Open **System Settings ▸ Privacy & Security** and click **Open Anyway**.

## Build

Open `Scratchpad.xcodeproj` in Xcode 26 and run. No dependencies.

## Where your notes live

Plain files, one per sheet:

```
~/Library/Containers/is.elli.Scratchpad/Data/Library/Application Support/Scratchpad/
  Sheet 1.txt
  Sheet 2.rtf
  …
```

`.txt` for plain sheets, `.rtf` for rich ones. Back them up like any other file.

import Foundation
import os

/// Messages that land in Console.app (search "Scratchpad"), release builds
/// included. `print` only shows up when running from Xcode.
enum Log {
    static let storage = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Scratchpad", category: "storage")
}

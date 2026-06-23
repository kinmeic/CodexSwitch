import AppKit

/// Thin wrapper around NSPasteboard for copying text to the system clipboard.
/// Centralizes the two-step clearContents + setString pattern so call sites
/// stay consistent and concise.
enum Clipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

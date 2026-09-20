// Clipboard.swift
// Mixtape — Core/Utilities
//
// One copy-to-clipboard, because AppKit and UIKit spell it differently and there
// were three identical private copies of this shading into each other. AppKit
// also needs the `clearContents()` that UIKit doesn't — the kind of detail that
// gets dropped in the fourth copy.

import Foundation

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Puts `text` on the system clipboard, replacing whatever was there.
public func copyToClipboard(_ text: String) {
    #if os(iOS)
    UIPasteboard.general.string = text
    #elseif os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #endif
}

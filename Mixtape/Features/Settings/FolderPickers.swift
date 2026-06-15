// FolderPickers.swift
// Mixtape — Components

import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit

public struct FolderPickerHelper {
    public static func show(onCompletion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Select"
        panel.message = "Choose or create a folder where Mixtape will save your exported songs."
        
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            if response == .OK {
                onCompletion(panel.url)
            } else {
                onCompletion(nil)
            }
        }
    }
}

#else
import UIKit

struct IOSFolderPicker: UIViewControllerRepresentable {
    var onCompletion: (URL?) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCompletion: onCompletion)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        var onCompletion: (URL?) -> Void

        init(onCompletion: @escaping (URL?) -> Void) {
            self.onCompletion = onCompletion
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onCompletion(urls.first)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCompletion(nil)
        }
    }
}
#endif

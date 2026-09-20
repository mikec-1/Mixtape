// LocalFilesSettingsGroup.swift
// Mixtape — Features/Settings
//
// The folders Mixtape looks in, and nothing more.
//
// Worth being clear about what this is not: it is not the export folder. Mixtape
// writes to the export folder, and scanning a folder Mixtape writes to is how a
// song deleted on the phone used to come back on the Mac. A watched folder is
// one Mixtape only ever reads, so everything found in it is the user's own file,
// put there by them.

import SwiftUI

struct LocalFilesSettingsGroup: View {

    @EnvironmentObject private var deps: AppDependencies

    @State private var showFolderPicker = false

    private var folders: WatchedFoldersStore { deps.watchedFolders }

    var body: some View {
        SettingsGroup(
            title: "Local Files",
            footer: "Mixtape reads these folders and never writes to them. The songs it finds play from where they are — they aren't copied, uploaded, or synced to your other devices. Save one to Mixtape when you want it on your phone or on the web."
        ) {
            ForEach(folders.folders) { folder in
                SettingsRow(title: folder.displayName,
                            subtitle: folder.lastKnownPath,
                            icon: "folder") {
                    Button {
                        folders.remove(id: folder.id)
                        deps.localFiles.rescan()
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(Color.mixTextTertiary)
                    }
                    .buttonStyle(.plain).mixHandCursor()
                    .help("Stop watching this folder")
                }
            }

            SettingsButtonRow(id: "localFiles.addFolder",
                              title: "Add Folder",
                              icon: "plus.circle") {
                #if os(macOS)
                FolderPickerHelper.show(
                    message: "Choose a folder of music for Mixtape to watch. Mixtape only reads it."
                ) { url in
                    guard let url else { return }
                    folders.add(url)
                    deps.localFiles.rescan()
                }
                #else
                showFolderPicker = true
                #endif
            }

            if !folders.isEmpty {
                SettingsRow(id: "localFiles.count",
                            title: "Songs Found",
                            icon: "music.note.list") {
                    SettingsValue(text: deps.localFiles.isScanning
                                        ? "Scanning\u{2026}"
                                        : "\(deps.localFiles.tracks.count)")
                }

                SettingsButtonRow(id: "localFiles.rescan",
                                  title: "Rescan Now",
                                  icon: "arrow.clockwise",
                                  isEnabled: !deps.localFiles.isScanning) {
                    deps.localFiles.rescan()
                }
            }
        }
        #if os(iOS)
        .sheet(isPresented: $showFolderPicker) {
            IOSFolderPicker { url in
                guard let url else { return }
                folders.add(url)
                deps.localFiles.rescan()
            }
        }
        #endif
    }
}

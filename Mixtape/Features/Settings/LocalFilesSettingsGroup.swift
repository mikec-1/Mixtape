// The folders Mixtape reads from. Not the export folder: Mixtape only ever reads
// these, so everything in them is the user's own file.

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

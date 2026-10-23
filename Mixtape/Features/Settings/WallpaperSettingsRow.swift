// Choose a picture for the app's background, or remove it. See `MixWallpaper`.

import SwiftUI
#if os(iOS)
import PhotosUI
#else
import AppKit
import UniformTypeIdentifiers
#endif

struct WallpaperSettingsRow: View {

    @ObservedObject var theme: ThemeManager
    @EnvironmentObject private var deps: AppDependencies

    #if os(iOS)
    @State private var item: PhotosPickerItem?
    #endif

    var body: some View {
        SettingsRow(id: "general.wallpaper",
                    title: "Wallpaper",
                    subtitle: "A picture behind the whole app, with glass panels over it. Kept on this device.",
                    icon: "photo") {
            HStack(spacing: 14) {
                if theme.wallpaper != nil {
                    Button("Remove", role: .destructive) { theme.removeWallpaper() }
                        .buttonStyle(.plain).mixHandCursor()
                        .foregroundStyle(Color.mixTextSecondary)
                }
                chooser
                    .font(.mixButton)
                    .foregroundStyle(Color.mixPrimary)
            }
        }
    }

    private var title: String { theme.wallpaper == nil ? "Choose…" : "Change…" }

    #if os(iOS)
    private var chooser: some View {
        PhotosPicker(title, selection: $item, matching: .images, photoLibrary: .shared())
            .buttonStyle(.borderless)
            .onChange(of: item) { _, picked in
                guard let picked else { return }
                Task {
                    defer { item = nil }
                    await apply(try? await picked.loadTransferable(type: Data.self))
                }
            }
    }
    #else
    private var chooser: some View {
        Button(title) {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.image]
            panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let url = panel.url else { return }
            Task { await apply(try? Data(contentsOf: url)) }
        }
        .buttonStyle(.plain).mixHandCursor()
    }
    #endif

    private func apply(_ data: Data?) async {
        do {
            guard let data else { throw MixWallpaper.Failure.unreadable }
            try await theme.setWallpaper(data)
        } catch {
            deps.showToast(.failed("Couldn\u{2019}t use that picture"))
        }
    }
}

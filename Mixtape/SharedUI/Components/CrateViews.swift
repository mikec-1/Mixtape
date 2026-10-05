// Crate UI shared by both apps: the cover, the page, "Add to Crate", the
// name prompt and sharing. See `CrateService`.

import SwiftUI

// MARK: - Artwork

/// One item's cover, the same art its own row uses.
struct CrateEntryArtwork: View {
    let entry: CrateEntry
    let size: CGFloat?
    var cornerRadius: CGFloat = 0

    var body: some View {
        switch entry {
        case .playlist(let p):
            PlaylistArtwork(playlist: p, size: size, cornerRadius: cornerRadius)
        case .album(let a):
            ArtworkThumbnail(data: a.artworkData, artworkRef: a.trackIDs.first.map { .track($0) } ?? .album(a.id),
                             size: size, cornerRadius: cornerRadius, placeholder: MixtapeIcons.album)
        case .artist(let a):
            ArtworkThumbnail(data: a.artworkData, artworkRef: .artist(a.id),
                             size: size, cornerRadius: cornerRadius, placeholder: MixtapeIcons.artist)
        case .online(let i):
            ArtworkThumbnail(data: nil, size: size, cornerRadius: cornerRadius,
                             placeholder: i.kind == .album ? MixtapeIcons.album : MixtapeIcons.artist)
        }
    }
}

/// The first four items as a 2x2, or the first one alone.
// ponytail: derived only, a chosen cover needs an upload path like playlists
struct CrateCover: View {
    let entries: [CrateEntry]
    let size: CGFloat

    var body: some View {
        let shown = Array(entries.prefix(4))
        Group {
            if shown.count == 4 {
                VStack(spacing: 0) {
                    HStack(spacing: 0) { cell(shown[0]); cell(shown[1]) }
                    HStack(spacing: 0) { cell(shown[2]); cell(shown[3]) }
                }
            } else if let first = shown.first {
                CrateEntryArtwork(entry: first, size: size)
            } else {
                ZStack {
                    Color.mixSurface2
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: size * 0.36, weight: .medium))
                        .foregroundStyle(Color.mixTextTertiary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: max(4, size * 0.06), style: .continuous))
    }

    private func cell(_ entry: CrateEntry) -> some View {
        CrateEntryArtwork(entry: entry, size: size / 2)
    }
}

// MARK: - Page

struct CrateDetailView: View {
    let crateID: UUID
    @ObservedObject var library: LibraryService

    @ObservedObject private var service = CrateService.shared
    #if os(macOS)
    @EnvironmentObject private var appState: MacAppState
    #else
    @EnvironmentObject private var iosAppState: IOSAppState
    @Environment(\.dismiss) private var dismiss
    #endif

    @State private var isRenaming = false
    @State private var confirmDelete = false

    var body: some View {
        if let crate = service.crate(id: crateID) {
            let entries = service.entries(of: crate, in: library)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header(crate, entries: entries)
                    if entries.isEmpty {
                        ContentUnavailableView("Nothing in this crate yet",
                                               systemImage: "square.stack.3d.up",
                                               description: Text("Add playlists, albums and artists from their menus."))
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 16)],
                                  alignment: .leading, spacing: 20) {
                            ForEach(entries) { entry in
                                tile(entry)
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            service.remove(entry.item, from: crateID)
                                        } label: {
                                            Label("Remove from Crate", systemImage: "minus.circle")
                                        }
                                    }
                            }
                        }
                    }
                }
                .padding(20)
            }
            .background(Color.mixBackground)
            #if os(iOS)
            .navigationTitle(crate.name)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .sheet(isPresented: $isRenaming) { CrateEditorSheet(library: library, crate: crate) }
            .mixConfirmationDialog("Delete \u{201C}\(crate.name)\u{201D}?", isPresented: $confirmDelete) {
                Button("Delete Crate", role: .destructive) {
                    #if os(macOS)
                    appState.selectedCrateID = nil
                    #else
                    dismiss()
                    #endif
                    service.delete(crateID)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Its playlists, albums and artists stay in your library.")
            }
        } else {
            // Deleted here or on another device.
            ContentUnavailableView("Crate not found", systemImage: "square.stack.3d.up.slash")
        }
    }

    private func header(_ crate: Crate, entries: [CrateEntry]) -> some View {
        HStack(alignment: .bottom, spacing: 20) {
            CrateCover(entries: entries, size: 160)

            VStack(alignment: .leading, spacing: 6) {
                Text("Crate")
                    .font(.mixLabel)
                    .foregroundStyle(Color.mixTextSecondary)
                Text(crate.name)
                    .font(.mixHeadline)
                    .foregroundStyle(Color.mixTextPrimary)
                    .lineLimit(2)
                Text(entries.count == 1 ? "1 item" : "\(entries.count) items")
                    .font(.mixCaption)
                    .foregroundStyle(Color.mixTextSecondary)

                Menu {
                    Button {
                        isRenaming = true
                    } label: {
                        Label("Rename\u{2026}", systemImage: "pencil")
                    }
                    CrateShareMenuItems(crate: crate)
                    Divider()
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label("Delete Crate", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.mixTextSecondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(.top, 4)
                .accessibilityLabel("Crate options")
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func tile(_ entry: CrateEntry) -> some View {
        #if os(iOS)
        switch entry {
        case .playlist(let p): NavigationLink(value: p) { tileLabel(entry) }.buttonStyle(.plain)
        case .album(let a):    NavigationLink(value: a) { tileLabel(entry) }.buttonStyle(.plain)
        case .artist(let a):   NavigationLink(value: a) { tileLabel(entry) }.buttonStyle(.plain)
        case .online:          Button { open(entry) } label: { tileLabel(entry) }.buttonStyle(.plain)
        }
        #else
        Button { open(entry) } label: { tileLabel(entry) }
            .buttonStyle(.plain).mixHandCursor()
        #endif
    }

    private func tileLabel(_ entry: CrateEntry) -> some View {
        let subtitle: String = {
            switch entry {
            case .playlist:        return "Playlist"
            case .album(let a):    return a.artistName
            case .artist:          return "Artist"
            case .online(let i):   return i.kind == .album ? (i.artist ?? "Album") : "Artist"
            }
        }()
        let isArtist: Bool = {
            if case .artist = entry { return true }
            if case .online(let i) = entry { return i.kind == .artist }
            return false
        }()
        return VStack(alignment: .leading, spacing: 6) {
            CrateEntryArtwork(entry: entry, size: nil)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(isArtist ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 8, style: .continuous)))
            Text(entry.title)
                .font(.mixBodyBold)
                .foregroundStyle(Color.mixTextPrimary)
                .lineLimit(1)
            Text(subtitle)
                .font(.mixCaption)
                .foregroundStyle(Color.mixTextSecondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
    }

    /// Library rows open their library page; anything not held opens on Discover.
    private func open(_ entry: CrateEntry) {
        #if os(macOS)
        switch entry {
        // Set directly so closing the playlist lands back here.
        case .playlist(let p): appState.selectedPlaylist = p
        case .album(let a):    appState.showAlbum(a)
        case .artist(let a):   appState.showArtist(a)
        case .online(let i):
            if i.kind == .album {
                appState.showOnlineAlbum(title: i.key, artistName: i.artist ?? "", trackID: nil)
            } else {
                appState.openDiscoverArtist(named: i.key)
            }
        }
        #else
        guard case .online(let i) = entry else { return }
        // ponytail: an album not held opens its artist, iOS has no album-by-name route yet
        iosAppState.openOnlineArtist(name: i.kind == .album ? (i.artist ?? i.key) : i.key)
        #endif
    }
}

// MARK: - Library shelf (iOS)

/// Crates above the playlists in Your Library. Nothing when there are none.
struct CratesShelf: View {
    @ObservedObject var library: LibraryService
    @ObservedObject private var service = CrateService.shared

    var body: some View {
        if !service.crates.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(service.crates) { crate in
                        NavigationLink(value: crate) {
                            VStack(alignment: .leading, spacing: 6) {
                                CrateCover(entries: service.entries(of: crate, in: library, limit: 4), size: 96)
                                Text(crate.name)
                                    .font(.mixBodyBold)
                                    .foregroundStyle(Color.mixTextPrimary)
                                    .lineLimit(1)
                                Text("Crate")
                                    .font(.mixCaption)
                                    .foregroundStyle(Color.mixTextSecondary)
                            }
                            .frame(width: 96, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { CrateShareMenuItems(crate: crate) }
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 10)
        }
    }
}

// MARK: - Add to Crate

/// A submenu in an item's actions menu. Picking a crate toggles the item in it.
struct AddToCrateMenu: View {
    let item: CrateItem
    @ObservedObject private var service = CrateService.shared

    var body: some View {
        Menu {
            ForEach(service.crates) { crate in
                Button {
                    service.toggle(item, in: crate.id)
                } label: {
                    if service.contains(item, in: crate.id) {
                        Label(crate.name, systemImage: "checkmark")
                    } else {
                        Text(crate.name)
                    }
                }
            }
            if !service.crates.isEmpty { Divider() }
            Button("New Crate\u{2026}") { service.requestNewCrate(with: item) }
        } label: {
            Label("Add to Crate", systemImage: "square.stack.3d.up")
        }
    }
}

/// The sheet for `CrateService.requestNewCrate`, hosted once at the root.
struct NewCratePrompt: ViewModifier {
    let library: LibraryService
    @ObservedObject private var service = CrateService.shared

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(
            get: { service.newCrateRequest != nil },
            set: { if !$0 { service.newCrateRequest = nil } }
        )) {
            CrateEditorSheet(library: library, item: service.newCrateRequest?.item)
        }
    }
}

/// New crate or rename, laid out like the playlist editor. The cover is derived, so it only previews.
struct CrateEditorSheet: View {
    @ObservedObject var library: LibraryService
    var crate: Crate? = nil
    /// The first item of a new crate.
    var item: CrateItem? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        let entries = CrateService.shared.entries(
            of: crate ?? Crate(id: UUID(), name: name, items: item.map { [$0] } ?? [], dateCreated: .now),
            in: library)
        MixSheet(title: crate == nil ? "New Crate" : "Rename Crate",
                 subtitle: "Keep playlists, albums and artists together, and share them as one link.",
                 size: .medium,
                 primary: MixSheetAction(crate == nil ? "Create" : "Save",
                                         isEnabled: !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                         action: save)) {
            HStack(alignment: .top, spacing: 16) {
                CrateCover(entries: entries, size: 120)
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Crate name", text: $name)
                        .mixSheetField()
                        .onSubmit(save)
                    Text(summary(entries))
                        .font(.system(size: MixFontScale.size(12)))
                        .foregroundStyle(Color.mixTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task { name = crate?.name ?? "My Crate #\(CrateService.shared.crates.count + 1)" }
    }

    private func summary(_ entries: [CrateEntry]) -> String {
        if crate == nil, let first = entries.first { return "Starts with \(first.title)." }
        switch entries.count {
        case 0:  return "Empty for now. Add playlists, albums and artists from their menus."
        case 1:  return "1 item"
        default: return "\(entries.count) items"
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let crate { CrateService.shared.rename(crate.id, to: trimmed) }
        else { CrateService.shared.create(named: trimmed, with: item) }
        dismiss()
    }
}

// MARK: - Sharing

/// One link for the whole crate. Playlists get their own share links first.
struct CrateShareMenuItems: View {
    let crate: Crate

    @EnvironmentObject private var deps: AppDependencies

    var body: some View {
        Group {
            Button { share(copy: true) } label: {
                Label("Copy Crate Link", systemImage: "link")
            }
            // Copy only on macOS, like every other share menu there.
            #if os(iOS)
            Button { share(copy: false) } label: {
                Label(ShareSheet.title, systemImage: MixtapeIcons.share)
            }
            #endif
        }
        // Playlist links are rows in someone's account.
        .disabled(deps.authService.currentUser == nil || crate.items.isEmpty)
    }

    private func share(copy: Bool) {
        let library = deps.libraryService
        let entries = CrateService.shared.entries(of: crate, in: library).prefix(MixtapeLink.crateLimit)
        Task {
            var items: [[String]] = []
            // ponytail: one playlist at a time, a task group if big crates feel slow
            for entry in entries {
                switch entry {
                case .playlist(let p):
                    guard !p.isSystem else { continue }
                    let tracks = p.trackIDs.compactMap { library.track(id: $0) }
                    // Someone else's playlist can't be linked by us, so it's left out.
                    if let id = try? await PlaylistSharingService.shared.linkShareID(
                        playlist: p, tracks: tracks, deviceID: AppDependencies.deviceID) {
                        items.append(["p", id.uuidString.lowercased()])
                    }
                case .album(let a):  items.append(["a", a.title, a.artistName])
                case .artist(let a): items.append(["r", a.name])
                case .online(let i): items.append(i.kind == .album ? ["a", i.key, i.artist ?? ""] : ["r", i.key])
                }
            }
            let item = ShareItem(url: MixtapeLink.crate(name: crate.name, items: items),
                                 noun: "Crate", title: crate.name, subtitle: "Crate")
            if copy {
                copyToClipboard(item.url.absoluteString)
                deps.showToast(ShareSheet.copiedMessage)
            } else {
                ShareSheet.present(item, deps: deps)
            }
        }
    }
}

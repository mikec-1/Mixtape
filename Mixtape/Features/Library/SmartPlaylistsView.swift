// SmartPlaylistsView.swift
// Mixtape — Features/Library
//
// The Smart section of Your Library: the user's rule-based playlists. Tapping
// one resolves it live and shows its tracks, which are playable through the
// shared PlaybackEngine.
//
// This is a section rather than a page behind a row now. It used to be reached
// through a permanent "Smart Playlists" entry pinned above the playlist list,
// which spent a row of the first screen on a signpost; smart playlists are a
// kind of playlist, so they get a chip alongside Playlists / Albums / Artists
// and creating one lives in the library's + menu with everything else.

import SwiftUI
import SwiftData

public struct SmartPlaylistsSection: View {

    @EnvironmentObject private var deps: AppDependencies
    #if os(macOS)
    @EnvironmentObject private var appState: MacAppState
    #endif
    @ObservedObject var service: SmartPlaylistService

    /// Raised to the library so the "New Smart Playlist" sheet is presented by
    /// the same code that presents every other create route.
    let onCreate: () -> Void

    public init(service: SmartPlaylistService, onCreate: @escaping () -> Void) {
        self.service  = service
        self.onCreate = onCreate
    }

    public var body: some View {
        Group {
            if deps.visibleSmartPlaylists.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Each platform's own playlist row, fed the smart playlist dressed as one,
    // so the Smart tab reads as more playlists rather than a different kind of
    // list. ponytail: resolves every rule per redraw; memoise if a library
    // with many smart playlists shows it.
    #if os(macOS)
    // Opens flat through the router like every other playlist on the Mac,
    // rather than pushing inside a stack of its own.
    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(deps.visibleSmartPlaylists) { smart in
                    PlaylistRowItem(playlist: smart.asPlaylist(trackIDs: deps.smartTrackIDs(smart)),
                                    kind: "Smart Playlist",
                                    onOpen: { appState.showSmartPlaylist(smart) })
                        .environmentObject(deps.downloadManager)
                        .contextMenu {
                            Button("Delete Smart Playlist", role: .destructive) {
                                service.delete(id: smart.id)
                            }
                        }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .scrollContentBackground(.hidden)
        .background(Color.mixBackground)
    }
    #else
    private var list: some View {
        List {
            ForEach(deps.visibleSmartPlaylists) { smart in
                NavigationLink {
                    SmartPlaylistDetailView(playlist: smart, service: service)
                        .environmentObject(deps)
                } label: {
                    PlaylistRowView(playlist: smart.asPlaylist(trackIDs: deps.smartTrackIDs(smart)),
                                    kind: "Smart Playlist")
                        .environmentObject(deps.downloadManager)
                }
                .listRowBackground(Color.mixBackground)
                .listRowSeparatorTint(Color.mixSeparator)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        service.delete(id: smart.id)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
    #endif

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "wand.and.stars")
                .font(.system(size: 48))
                .foregroundStyle(Color.mixTextTertiary)
            Text("No Smart Playlists")
                .font(.mixTitle2)
                .foregroundStyle(Color.mixTextPrimary)
            Text("Smart playlists update themselves from rules — everything you added this month, songs you never play, an artist's whole catalogue.")
                .font(.mixBody)
                .foregroundStyle(Color.mixTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button(action: onCreate) {
                Label("New Smart Playlist", systemImage: "plus")
                    .font(.mixButton)
                    .foregroundStyle(Color.mixOnAccent)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Color.mixAccentFill)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain).mixHandCursor()
            Spacer()
        }
    }
}

// MARK: - Detail

/// A smart playlist's page is the playlist page. Resolved on every draw so the
/// songs follow the library, and handed over as a read-only `Playlist` — see
/// `SmartPlaylist.asPlaylist(trackIDs:)`.
public struct SmartPlaylistDetailView: View {

    let playlist: SmartPlaylist
    @ObservedObject var service: SmartPlaylistService

    public init(playlist: SmartPlaylist, service: SmartPlaylistService) {
        self.playlist = playlist
        self.service  = service
    }

    @EnvironmentObject private var deps: AppDependencies

    public var body: some View {
        // The stored copy, so a rename in the editor reaches an open page.
        let live = service.playlists.first { $0.id == playlist.id } ?? playlist
        PlaylistDetailView(playlist: live.asPlaylist(trackIDs: deps.smartTrackIDs(live)),
                           isSmart: true)
    }
}

// MARK: - Cover

/// The cover a smart playlist wears on Home: the same borrowed single cover or
/// 2×2 as any playlist. `AppDependencies` answers the loader with the songs the
/// rule resolves to, since there is no library row to read them from.
public struct SmartPlaylistCover: View {
    let playlist: SmartPlaylist
    var size: CGFloat = 140

    public init(playlist: SmartPlaylist, size: CGFloat = 140) {
        self.playlist = playlist
        self.size     = size
    }

    public var body: some View {
        // Its icon on its own colour, not a 2×2 of the first four songs: a
        // smart playlist is a *rule*, and four covers off the top of it say
        // nothing about the rule and make every one of these look like every
        // other one. The colour is derived from the id the way a mix's is
        // (`MixCoverStyle`), so a list keeps its colour everywhere it appears.
        let accent = MixCoverStyle.color(for: playlist.id.uuidString)
        RoundedRectangle(cornerRadius: size * 0.06, style: .continuous)
            .fill(
                LinearGradient(colors: [accent.opacity(0.95), accent.opacity(0.55)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: playlist.iconName)
                    .font(.system(size: size * 0.34, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: size * 0.03, y: size * 0.01)
            }
    }
}

extension SmartPlaylist {
    /// This smart playlist as a read-only `Playlist`, so it goes through the
    /// same rows, covers and page as every other playlist. Never stored: the id
    /// isn't a library row, so library lookups fall back to this value. `.mix`
    /// because that is the non-owned kind with no remote source to refresh,
    /// and it earns the "Mixtape" byline.
    func asPlaylist(trackIDs: [UUID] = []) -> Playlist {
        Playlist(id: id, name: name, description: rule.blurb, trackIDs: trackIDs,
                 dateCreated: dateCreated, dateModified: dateCreated, origin: .mix,
                 sync: SyncMetadata(serverID: nil, status: .localOnly,
                                    localModifiedAt: dateCreated, serverModifiedAt: nil,
                                    lastSyncedAt: nil, deviceID: ""))
    }
}

// SpotifyImportView.swift
// Mixtape
//
// Connect Spotify, paste a playlist link, and rebuild it locally. Songs come in as
// online tracks that stream on play, so even big playlists import in seconds.
// Shown from the iOS import sheet and the macOS toolbar.

import SwiftUI

public struct SpotifyImportView: View {

    private let spotifyClient: SpotifyClient
    private let importService: SpotifyImportService
    @ObservedObject private var auth: SpotifyAuth
    private let followService: SpotifyFollowService?
    private let ledger: SpotifyImportLedger?

    public init(spotifyClient: SpotifyClient,
                importService: SpotifyImportService,
                auth: SpotifyAuth,
                followService: SpotifyFollowService? = nil,
                ledger: SpotifyImportLedger? = nil) {
        self.spotifyClient = spotifyClient
        self.importService = importService
        self.auth = auth
        self.followService = followService
        self.ledger = ledger
    }

    // MARK: - State

    private enum Phase: Equatable {
        case input
        case working(done: Int, total: Int)
        case finished(name: String, count: Int)
        case failed(String)
    }

    @State private var link  = ""
    @State private var phase: Phase = .input
    @State private var isConnecting = false
    @State private var connectError: String?
    /// Opt-in mirror. Off by default — see `SpotifyLibraryPickerModel.keepInSync`.
    @State private var keepInSync = false

    @Environment(\.dismiss) private var dismiss

    // MARK: - Body

    public var body: some View {
        MixSheet(title: "Import Spotify Playlist",
                 subtitle: auth.isAuthorized
                     ? "Share \u{2192} Copy link on a playlist in Spotify, then paste it here. We'll recreate it with the same cover and songs."
                     : "Spotify requires you to sign in before Mixtape can read a playlist's songs. We only ask for read access.",
                 size: .compact,
                 primary: primaryAction) {
            content
        }
    }

    // MARK: - Sub-views

    /// Either the sign-in explanation or the field — and in both cases the
    /// outcome shows up underneath rather than replacing the page.
    ///
    /// This was four full-screen states stacked behind a `switch`, each one
    /// centred between two `Spacer`s under a 120pt circle. On a Mac that's a
    /// 520×500 window that is mostly empty in every state it can reach.
    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            if auth.isAuthorized {
                TextField("https://open.spotify.com/playlist/\u{2026}", text: $link)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    #endif
                    .onSubmit(startImport)
                    .mixSheetField()

                if followService != nil, case .input = phase {
                    Toggle(isOn: $keepInSync) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Keep in sync with Spotify")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(Color.mixTextPrimary)
                            Text("Synced playlists follow the Spotify original and are read-only here. You can unlink at any time.")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.mixTextTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.switch)
                    .tint(Color.mixPrimary)
                }
            }
            statusLine
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if let connectError, !auth.isAuthorized {
            MixSheetStatus(kind: .failure, title: "Couldn't connect", detail: connectError)
        } else if auth.isAuthorized {
            switch phase {
            case .input:
                EmptyView()

            case .failed(let message):
                MixSheetStatus(kind: .failure, title: "Couldn't import that playlist", detail: message)

            case .working(let done, let total):
                // Real progress, unlike the single-song importer: the playlist
                // told us how many songs it has before we started.
                MixSheetStatus(kind: .busy,
                               title: total > 0 ? "Adding songs\u{2026}" : "Fetching playlist\u{2026}",
                               detail: total > 0 ? "\(done) of \(total)" : nil,
                               progress: total > 0 ? Double(done) / Double(total) : nil)

            case .finished(let name, let count):
                MixSheetStatus(kind: .success,
                               title: "Added \u{201C}\(name)\u{201D}",
                               detail: "\(count) song\(count == 1 ? "" : "s") imported.")
            }
        }
    }

    /// The footer button carries the whole flow: connect, then import, then
    /// close. One control that changes what it says beats four pages that each
    /// grow their own.
    private var primaryAction: MixSheetAction {
        guard auth.isAuthorized else {
            return MixSheetAction("Connect Spotify", isBusy: isConnecting, action: connect)
        }
        if case .finished = phase {
            return MixSheetAction("Done") { dismiss() }
        }
        if case .working = phase {
            return MixSheetAction("Import Playlist", isBusy: true) { }
        }
        return MixSheetAction("Import Playlist", isEnabled: canImport, action: startImport)
    }

    // MARK: - Logic

    private var canImport: Bool {
        SpotifyClient.playlistID(from: link) != nil
    }

    private func connect() {
        connectError = nil
        isConnecting = true
        Task {
            do {
                try await auth.connect()
            } catch let error as SpotifyAuthError {
                connectError = error.errorDescription
            } catch {
                connectError = "Couldn't connect to Spotify. Please try again."
            }
            isConnecting = false
        }
    }

    private func startImport() {
        guard canImport else { return }
        let input = link
        phase = .working(done: 0, total: 0)
        Task {
            do {
                let token = try await auth.validAccessToken()
                let playlist = try await spotifyClient.fetchUserPlaylist(input, accessToken: token)
                guard !playlist.tracks.isEmpty else {
                    phase = .failed("That playlist has no songs we can import.")
                    return
                }
                let created = await importService.importPlaylist(playlist) { progress in
                    phase = .working(done: progress.completed, total: progress.total)
                }
                if keepInSync, let followService,
                   let sourceID = SpotifyClient.playlistID(from: input) {
                    followService.link(
                        .init(sourceID: sourceID, kind: .playlist, name: playlist.name,
                              snapshotID: playlist.snapshotID, lastSyncedAt: .now),
                        toPlaylist: created.id
                    )
                }
                // Recorded here as well as in the library picker: the two are
                // routes to the same import, and a playlist pasted in as a link
                // should still read as "already imported" when the account's
                // full listing is opened later.
                if let ledger, let sourceID = SpotifyClient.playlistID(from: input) {
                    ledger.record(
                        SpotifyLibraryItem(sourceID: sourceID,
                                           kind: .playlist,
                                           name: playlist.name,
                                           subtitle: "",
                                           trackCount: playlist.tracks.count,
                                           coverURL: nil),
                        playlistID: created.id
                    )
                }
                phase = .finished(name: created.name, count: playlist.tracks.count)
            } catch let error as SpotifyAuthError {
                phase = .failed(error.errorDescription ?? "Import failed.")
            } catch let error as SpotifyPlaylistError {
                phase = .failed(error.errorDescription ?? "Import failed.")
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}

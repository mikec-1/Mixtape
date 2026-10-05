// Connect Spotify, paste a playlist link, and rebuild it locally as online
// tracks. Used by the iOS import sheet and the macOS toolbar.

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
    /// Opt-in mirror, off by default. See `SpotifyLibraryPickerModel.keepInSync`.
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

    /// The sign-in explanation or the field, with the outcome underneath.
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
                                .font(.system(size: MixFontScale.size(12.5), weight: .medium))
                                .foregroundStyle(Color.mixTextPrimary)
                            Text("Synced playlists follow the Spotify original and are read-only here. You can unlink at any time.")
                                .font(.system(size: MixFontScale.size(11)))
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
                // Real progress: the playlist's song count is known up front.
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

    /// One footer button for the whole flow: connect, import, close.
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
                // Also recorded here so a playlist imported by link shows as imported in the library picker.
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

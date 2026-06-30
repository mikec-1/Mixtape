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

    public init(spotifyClient: SpotifyClient, importService: SpotifyImportService, auth: SpotifyAuth) {
        self.spotifyClient = spotifyClient
        self.importService = importService
        self.auth = auth
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

    @Environment(\.dismiss) private var dismiss

    // MARK: - Body

    public var body: some View {
        NavigationStack {
            ZStack {
                Color.mixBackground.ignoresSafeArea()

                VStack(spacing: 28) {
                    Spacer()
                    illustration
                    content
                    Spacer()
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: 460)
            }
            .navigationTitle("Import from Spotify")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Color.mixPrimary)
                }
            }
        }
    }

    // MARK: - Sub-views

    private var illustration: some View {
        ZStack {
            Circle()
                .fill(Color.mixSurface)
                .frame(width: 120, height: 120)
            Image(systemName: "music.note.list")
                .font(.system(size: 50))
                .foregroundStyle(Color.mixPrimary)
        }
    }

    @ViewBuilder
    private var content: some View {
        if !auth.isAuthorized {
            connectContent
        } else {
            switch phase {
            case .input, .failed:
                inputContent
            case .working(let done, let total):
                workingContent(done: done, total: total)
            case .finished(let name, let count):
                finishedContent(name: name, count: count)
            }
        }
    }

    private var connectContent: some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                Text("Connect Spotify")
                    .font(.mixTitle)
                    .foregroundStyle(Color.mixTextPrimary)
                Text("Spotify now requires you to sign in before Mixtape can read a playlist's songs. We only request read access to your playlists.")
                    .font(.mixBody)
                    .foregroundStyle(Color.mixTextSecondary)
                    .multilineTextAlignment(.center)
            }

            if let connectError {
                Label(connectError, systemImage: "exclamationmark.circle.fill")
                    .font(.mixLabel)
                    .foregroundStyle(Color.mixAccent)
                    .multilineTextAlignment(.center)
            }

            Button(action: connect) {
                HStack(spacing: 8) {
                    if isConnecting { ProgressView().tint(.white) }
                    Text(isConnecting ? "Connecting…" : "Connect Spotify")
                        .font(.mixButton)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.mixPrimary)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .disabled(isConnecting)
        }
    }

    private var inputContent: some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                Text("Paste a playlist link")
                    .font(.mixTitle)
                    .foregroundStyle(Color.mixTextPrimary)
                Text("Open a public playlist in Spotify, tap Share → Copy link, then paste it here. We'll recreate it with the same cover and songs.")
                    .font(.mixBody)
                    .foregroundStyle(Color.mixTextSecondary)
                    .multilineTextAlignment(.center)
            }

            TextField("https://open.spotify.com/playlist/…", text: $link)
                .textFieldStyle(.plain)
                .font(.mixBody)
                .foregroundStyle(Color.mixTextPrimary)
                .padding(.vertical, 12)
                .padding(.horizontal, 14)
                .background(Color.mixSurface)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                #endif
                .onSubmit(startImport)

            if case .failed(let message) = phase {
                Label(message, systemImage: "exclamationmark.circle.fill")
                    .font(.mixLabel)
                    .foregroundStyle(Color.mixAccent)
                    .multilineTextAlignment(.center)
            }

            Button(action: startImport) {
                Text("Import Playlist")
                    .font(.mixButton)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(canImport ? Color.mixPrimary : Color.mixSurface)
                    .foregroundStyle(canImport ? .white : Color.mixTextSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .disabled(!canImport)
        }
    }

    private func workingContent(done: Int, total: Int) -> some View {
        VStack(spacing: 14) {
            ProgressView()
                .tint(Color.mixPrimary)
            Text(total > 0 ? "Adding songs… \(done) / \(total)" : "Fetching playlist…")
                .font(.mixBody)
                .foregroundStyle(Color.mixTextSecondary)
        }
    }

    private func finishedContent(name: String, count: Int) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(Color.mixSuccess)
            Text("Added “\(name)”")
                .font(.mixTitle2)
                .foregroundStyle(Color.mixTextPrimary)
                .multilineTextAlignment(.center)
            Text("\(count) song\(count == 1 ? "" : "s") imported. Tap a song to start streaming.")
                .font(.mixBody)
                .foregroundStyle(Color.mixTextSecondary)
                .multilineTextAlignment(.center)
            Button("Done") { dismiss() }
                .font(.mixButton)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.mixPrimary)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .buttonStyle(.plain)
        }
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

// Recreates a Mixtape playlist on Spotify. Matches are shown as confident,
// uncertain and missing before anything is written, with uncertain ones unticked.
// Only creates and fills one new playlist; never changes anything else on Spotify.

import SwiftUI

public struct SpotifyExportView: View {

    private let tracks: [Track]
    private let sourceName: String
    /// The library playlist this came from, if any. Without one there's nothing to
    /// sync-link, so those options are hidden.
    private let sourcePlaylistID: UUID?

    @Environment(AppDependencies.self) private var deps
    @Environment(\.dismiss) private var dismiss

    public init(playlistName: String, tracks: [Track], playlistID: UUID? = nil) {
        self.sourceName       = playlistName
        self.tracks           = tracks
        self.sourcePlaylistID = playlistID
    }

    // MARK: - State

    private enum Phase: Equatable {
        /// Connected but read-only. See `SpotifyAuth.canWrite`.
        case needsPermission
        case planning
        case reviewing
        case pushing
        case finished(URL?)
        case failed(String)
    }

    @State private var phase: Phase = .planning
    @State private var plan: SpotifyExportService.Plan?
    /// Track ids to send. Starts as the confident matches.
    @State private var chosen: Set<UUID> = []
    /// Per-song override when someone picks a different candidate.
    @State private var overrides: [UUID: SpotifyTrackMatch] = [:]
    @State private var name: String = ""
    @State private var isPublic = false
    /// On by default; people sending a playlist usually want it kept in sync.
    @State private var pushesToSpotify = true
    @State private var pullsFromSpotify = false
    @State private var work: Task<Void, Never>?

    private var auth: SpotifyAuth { deps.spotifyAuth }
    private var service: SpotifyExportService { deps.spotifyExportService }

    // MARK: - Body

    public var body: some View {
        MixSheet(title: "Send to Spotify",
                 subtitle: subtitle,
                 size: .large,
                 scroll: phase != .reviewing,
                 primary: primaryAction,
                 showsCancel: phase != .pushing) {
            content
        }
        .task {
            name = sourceName
            await start()
        }
        .onDisappear { work?.cancel() }
    }

    private var subtitle: String? {
        switch phase {
        case .needsPermission:
            return "Spotify has to grant permission to add things before this can run."
        case .planning:
            return "Looking every song up on Spotify."
        case .reviewing:
            return "Untick anything you don't want sent."
        case .pushing, .finished, .failed:
            return nil
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .needsPermission:
            permissionPane

        case .planning:
            SpotifyExportProgress(service: service, title: "Matching songs on Spotify", stage: .planning)

        case .reviewing:
            reviewPane

        case .pushing:
            SpotifyExportProgress(service: service, title: "Creating the playlist on Spotify", stage: .pushing)

        case .finished(let url):
            finishedPane(url: url)

        case .failed(let message):
            MixSheetStatus(kind: .failure, title: "Couldn't send it", detail: message)
        }
    }

    private var permissionPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            MixSheetStatus(
                kind: .noop,
                title: "One more permission",
                detail: "Mixtape will ask Spotify to allow creating playlists and saving songs. It still can't change or delete anything you already have."
            )
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var reviewPane: some View {
        if let plan {
            VStack(alignment: .leading, spacing: 14) {
                summary(for: plan)

                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("Playlist name")
                    TextField("", text: $name)
                        .textFieldStyle(.plain)
                        .font(.system(size: MixFontScale.size(13)))
                        .foregroundStyle(Color.mixTextPrimary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .background(squareFill)
                        .overlay(squareStroke)
                }

                Toggle(isOn: $isPublic) {
                    Text("Make it public on Spotify")
                        .font(.system(size: MixFontScale.size(12.5)))
                        .foregroundStyle(Color.mixTextPrimary)
                }
                .toggleStyle(.switch)
                .tint(Color.mixPrimary)

                if sourcePlaylistID != nil {
                    syncOptions
                }

                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("Songs")
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(plan.candidates.enumerated()), id: \.element.id) { index, candidate in
                                if index > 0 {
                                    Rectangle()
                                        .fill(Color.primary.opacity(0.06))
                                        .frame(height: 1)
                                }
                                row(for: candidate)
                            }
                        }
                    }
                    .background(squareFill)
                    .overlay(squareStroke)
                }
            }
            // `scroll: false` skips MixSheet's insets, so add the margin here.
            .padding(.horizontal, MixSheetMetrics.margin)
            .padding(.vertical, MixSheetMetrics.contentVertical)
        }
    }

    /// The same two sync switches an imported playlist gets. Both on means a merge.
    private var syncOptions: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel("Keep in sync")

            VStack(alignment: .leading, spacing: 0) {
                syncToggle("Send changes to Spotify",
                           detail: "Songs you add here are added there too.",
                           isOn: $pushesToSpotify)
                Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1)
                syncToggle("Bring changes back from Spotify",
                           detail: "Songs added on Spotify show up here.",
                           isOn: $pullsFromSpotify)
            }
            .background(squareFill)
            .overlay(squareStroke)
        }
    }

    private func syncToggle(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: MixFontScale.size(12.5)))
                    .foregroundStyle(Color.mixTextPrimary)
                Text(detail)
                    .font(.system(size: MixFontScale.size(11)))
                    .foregroundStyle(Color.mixTextTertiary)
            }
        }
        .toggleStyle(.switch)
        .tint(Color.mixPrimary)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
    }

    /// 4pt corners, so these read as fields rather than cards.
    private var squareFill: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.mixSurface2)
    }

    private var squareStroke: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: MixFontScale.size(11), weight: .medium))
            .foregroundStyle(Color.mixTextSecondary)
    }

    /// One plain summary sentence.
    private func summary(for plan: SpotifyExportService.Plan) -> some View {
        let found = plan.confident.count + plan.uncertain.count
        let total = plan.candidates.count

        var parts: [String] = ["\(found) of \(total) song\(total == 1 ? "" : "s") found on Spotify"]
        if !plan.uncertain.isEmpty { parts.append("\(plan.uncertain.count) worth checking") }
        if !plan.missing.isEmpty   { parts.append("\(plan.missing.count) not on Spotify") }
        if !plan.unchecked.isEmpty {
            parts.append("\(plan.unchecked.count) couldn't be checked")
        }

        // The reason on its own line, since it's the actionable part.
        return VStack(alignment: .leading, spacing: 3) {
            Text(parts.joined(separator: " \u{00B7} "))
            if let reason = plan.uncheckedReason {
                Text(reason.sentence)
                    .foregroundStyle(Color.mixTextTertiary)
            }
        }
        .font(.system(size: MixFontScale.size(12)))
        .foregroundStyle(Color.mixTextSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(for candidate: SpotifyExportService.Candidate) -> some View {
        let match = overrides[candidate.track.id] ?? candidate.match
        let isOn  = chosen.contains(candidate.track.id)
        let canPick = match != nil

        return HStack(spacing: 10) {
            Button {
                guard canPick else { return }
                if isOn { chosen.remove(candidate.track.id) }
                else    { chosen.insert(candidate.track.id) }
            } label: {
                // Plain checkbox so the Send button stays the only accent.
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle(isOn ? Color.mixTextPrimary : Color.mixTextTertiary)
            }
            .buttonStyle(.plain).mixHandCursor()
            .disabled(!canPick)

            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.track.title)
                    .font(.system(size: MixFontScale.size(12.5), weight: .medium))
                    .foregroundStyle(Color.mixTextPrimary)
                    .lineLimit(1)

                if let match {
                    // Only shown when the match differs from the song.
                    Text(differs(candidate.track, match)
                         ? "\u{2192} \(match.title) \u{00B7} \(match.artist)"
                         : candidate.track.artistName)
                        .font(.system(size: MixFontScale.size(11)))
                        .foregroundStyle(differs(candidate.track, match)
                                         ? Color.mixTextSecondary
                                         : Color.mixTextTertiary)
                        .lineLimit(1)
                } else {
                    // Only claim "Not on Spotify" when a search actually came back empty.
                    Text(candidate.uncheckedReason?.phrase ?? "Not on Spotify")
                        .font(.system(size: MixFontScale.size(11)))
                        .foregroundStyle(Color.mixTextTertiary)
                }
            }

            Spacer(minLength: 8)

            if candidate.verdict == .uncertain, match != nil {
                Text("check this one")
                    .font(.system(size: MixFontScale.size(10.5)))
                    .foregroundStyle(Color.mixTextTertiary)
            }

            if !candidate.alternatives.isEmpty {
                alternativesMenu(for: candidate)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isOn ? Color.primary.opacity(0.05) : Color.clear)
        .opacity(canPick ? 1 : 0.55)
    }

    /// Pick another result when the guess is wrong.
    private func alternativesMenu(for candidate: SpotifyExportService.Candidate) -> some View {
        Menu {
            if let original = candidate.match {
                Button {
                    overrides[candidate.track.id] = original
                } label: {
                    Text("\(original.title) \u{00B7} \(original.artist)")
                }
            }
            ForEach(candidate.alternatives) { alternative in
                Button {
                    overrides[candidate.track.id] = alternative
                    chosen.insert(candidate.track.id)
                } label: {
                    Text("\(alternative.title) \u{00B7} \(alternative.artist)")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.mixTextTertiary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        // Fixed width, never `fixedSize()`: a Menu's ideal width is its widest item,
        // which pushed rows past the sheet.
        .frame(width: 20)
    }

    private func finishedPane(url: URL?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            MixSheetStatus(
                kind: .success,
                title: "\u{201C}\(name)\u{201D} is on Spotify",
                detail: finishedDetail
            )
            if let url {
                // Not a `Link`, so it opens the Spotify app if installed. See `SpotifyAppLink`.
                Button("Open it in Spotify") { SpotifyAppLink.open(url) }
                    .buttonStyle(.plain).mixHandCursor()
                    .font(.system(size: MixFontScale.size(12.5), weight: .medium))
                    .foregroundStyle(Color.mixPrimary)
            }
            Spacer(minLength: 0)
        }
    }

    /// Up to three sentences: sent, unticked by the user, and unmatched, counted separately.
    private var finishedDetail: String {
        let sent = chosen.count
        guard let plan else { return songs(sent) + " added." }

        // Unticked = ready but removed by the user. Everything else had no usable match.
        let confidentIDs = Set(plan.confident.map(\.track.id))
        let unticked = confidentIDs.subtracting(chosen).count
        let unmatched = plan.candidates.count - sent - unticked

        var lines = unticked > 0 || unmatched > 0
            ? [songs(sent) + " added."]
            : ["All " + songs(sent) + " went across."]
        if unticked > 0 {
            lines.append("You unticked " + songs(unticked) + ".")
        }
        if unmatched > 0 {
            lines.append(songs(unmatched)
                         + (unmatched == 1 ? " wasn't added because Spotify doesn't have it,"
                                           : " weren't added because Spotify doesn't have them,")
                         + " or the match wasn't close enough.")
        }
        if let sentence = syncSentence { lines.append(sentence) }
        return lines.joined(separator: " ")
    }

    private var syncSentence: String? {
        guard sourcePlaylistID != nil else { return nil }
        switch chosenDirection {
        case .both:  return "The two copies will keep each other up to date."
        case .push:  return "Changes you make here will be sent across."
        case .pull:  return "Changes made on Spotify will show up here."
        case .none:  return nil
        }
    }

    private func songs(_ count: Int) -> String {
        "\(count) song\(count == 1 ? "" : "s")"
    }

    // MARK: - Footer

    private var primaryAction: MixSheetAction? {
        switch phase {
        case .needsPermission:
            return MixSheetAction("Allow and Continue") { requestPermission() }

        case .planning:
            return MixSheetAction("Matching\u{2026}", isEnabled: false, isBusy: true) { }

        case .reviewing:
            let count = chosen.count
            return MixSheetAction(count == 0 ? "Send" : "Send \(count) Song\(count == 1 ? "" : "s")",
                                  isEnabled: count > 0 && !name.trimmingCharacters(in: .whitespaces).isEmpty) {
                push()
            }

        case .pushing:
            return MixSheetAction("Sending\u{2026}", isEnabled: false, isBusy: true) { }

        case .finished:
            return MixSheetAction("Done") { dismiss() }

        case .failed:
            return MixSheetAction("Try Again") { Task { await start() } }
        }
    }

    // MARK: - Actions

    private func start() async {
        guard auth.isAuthorized else {
            phase = .failed("Connect Spotify in Settings first.")
            return
        }
        guard auth.canWrite else {
            phase = .needsPermission
            return
        }
        phase = .planning
        do {
            let built = try await service.plan(name: sourceName, tracks: tracks)
            plan   = built
            // Confident only; an unsure match shouldn't be pre-ticked.
            chosen = Set(built.confident.map(\.track.id))
            phase  = .reviewing
        } catch is CancellationError {
            // The sheet is closing; there is nobody left to tell.
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func requestPermission() {
        work = Task {
            do {
                try await auth.connect(includingWrite: true)
                await start()
            } catch is SpotifyAuthError {
                phase = .failed("Spotify didn't grant permission to add things to your account.")
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func push() {
        guard let plan else { return }
        let uris = plan.candidates.compactMap { candidate -> String? in
            guard chosen.contains(candidate.track.id) else { return nil }
            return (overrides[candidate.track.id] ?? candidate.match)?.uri
        }
        let skipped = plan.candidates.count - uris.count

        phase = .pushing
        work = Task {
            do {
                let outcome = try await service.commit(
                    name:        name.trimmingCharacters(in: .whitespaces),
                    description: "Sent from Mixtape.",
                    isPublic:    isPublic,
                    uris:        uris,
                    skipped:     skipped
                )
                linkForSync(outcome)
                phase = .finished(outcome.playlistURL)
            } catch is CancellationError {
                phase = .reviewing
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Saves the sync link if either switch is on. `syncedIDs` is seeded with exactly
    /// what went across, so songs Spotify lacks read as local additions later rather
    /// than as Spotify deletions.
    private func linkForSync(_ outcome: SpotifyExportService.Outcome) {
        guard let playlistID = sourcePlaylistID,
              let direction  = chosenDirection
        else { return }

        var link = SpotifyFollowService.Link(
            sourceID: outcome.playlistID,
            kind:     .playlist,
            name:     name.trimmingCharacters(in: .whitespaces)
        )
        link.direction  = direction
        link.syncedIDs  = plan?.candidates
            .filter { chosen.contains($0.track.id) }
            .map(\.track.id) ?? []
        // URIs are already known from the plan.
        link.uriByTrack = plan?.candidates.reduce(into: [String: String]()) { out, candidate in
            guard chosen.contains(candidate.track.id) else { return }
            if let uri = (overrides[candidate.track.id] ?? candidate.match)?.uri {
                out[candidate.track.id.uuidString] = uri
            }
        }
        deps.spotifyFollowService.link(link, toPlaylist: playlistID)
    }

    private var chosenDirection: SpotifyFollowService.Link.Direction? {
        switch (pushesToSpotify, pullsFromSpotify) {
        case (true, true):  return .both
        case (true, false): return .push
        case (false, true): return .pull
        case (false, false): return nil
        }
    }

    private func differs(_ track: Track, _ match: SpotifyTrackMatch) -> Bool {
        LibraryTrackIndex.key(title: track.title, artistName: track.artistName)
            != LibraryTrackIndex.key(title: match.title, artistName: match.artist)
    }
}


/// Progress panes observing the service directly; a nested `ObservableObject`
/// doesn't republish through `AppDependencies`.
private struct SpotifyExportProgress: View {

    enum Stage { case planning, pushing }

    var service: SpotifyExportService
    let title: String
    let stage: Stage

    var body: some View {
        let counts = stage == .planning ? service.planned : service.pushed
        VStack(alignment: .leading, spacing: 10) {
            MixSheetStatus(
                kind: .busy,
                title: title,
                // Songs, not a percentage.
                detail: (counts?.total ?? 0) > 0
                    ? "\(counts!.done) of \(counts!.total) songs"
                    : "Starting\u{2026}",
                progress: (counts?.total ?? 0) > 0
                    ? Double(counts!.done) / Double(counts!.total)
                    : nil
            )
            Spacer(minLength: 0)
        }
    }
}

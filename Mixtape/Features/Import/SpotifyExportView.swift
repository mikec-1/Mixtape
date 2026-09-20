// SpotifyExportView.swift
// Mixtape — Features/Import
//
// The other direction: a Mixtape playlist recreated on Spotify.
//
// This sheet exists because the matching is guesswork and guesswork has to be
// shown. `SpotifyExportService` looks every song up, sorts the results into
// confident / uncertain / missing, and this displays that split before anything
// is written — with the uncertain ones unticked, so the default outcome is a
// playlist containing only songs Mixtape is willing to stand behind.
//
// Nothing here can remove or change anything on Spotify. It creates one new
// playlist and fills it.

import SwiftUI

public struct SpotifyExportView: View {

    private let tracks: [Track]
    private let sourceName: String
    /// The library playlist this came from, when it is one. `nil` for a
    /// selection of songs that isn't a stored playlist — there is nothing for a
    /// sync link to point back at, so the keep-in-sync options stay hidden.
    private let sourcePlaylistID: UUID?

    @EnvironmentObject private var deps: AppDependencies
    @Environment(\.dismiss) private var dismiss

    public init(playlistName: String, tracks: [Track], playlistID: UUID? = nil) {
        self.sourceName       = playlistName
        self.tracks           = tracks
        self.sourcePlaylistID = playlistID
    }

    // MARK: - State

    private enum Phase: Equatable {
        /// Connected, but the grant is read-only — see `SpotifyAuth.canWrite`.
        case needsPermission
        case planning
        case reviewing
        case pushing
        case finished(URL?)
        case failed(String)
    }

    @State private var phase: Phase = .planning
    @State private var plan: SpotifyExportService.Plan?
    /// Track ids that will be sent. Seeded from the confident matches, then
    /// entirely the user's.
    @State private var chosen: Set<UUID> = []
    /// Per-song override when someone picks a different candidate.
    @State private var overrides: [UUID: SpotifyTrackMatch] = [:]
    @State private var name: String = ""
    @State private var isPublic = false
    /// Ticked by default: someone sending a playlist across almost always wants
    /// the copy to go on matching this one, and the alternative — a snapshot
    /// that silently rots — is the thing people come back and ask for.
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
                        .font(.system(size: 13))
                        .foregroundStyle(Color.mixTextPrimary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .background(squareFill)
                        .overlay(squareStroke)
                }

                Toggle(isOn: $isPublic) {
                    Text("Make it public on Spotify")
                        .font(.system(size: 12.5))
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
            // `scroll: false` skips MixSheet's content insets — the scrolling
            // branch is what applies them — so this pane has to carry the
            // window margin itself, or it draws edge to edge while the header
            // above it sits 20pt in.
            .padding(.horizontal, MixSheetMetrics.margin)
            .padding(.vertical, MixSheetMetrics.contentVertical)
        }
    }

    /// The same two switches an imported playlist gets, offered here so a sent
    /// playlist isn't a one-off copy that starts drifting the moment it lands.
    ///
    /// Two switches rather than one three-way picker because that is the shape
    /// of the decision: each end either follows the other or it doesn't, and
    /// both on is a real arrangement (a merge, not a fight) rather than a
    /// compromise between two settings.
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
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.mixTextPrimary)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.mixTextTertiary)
            }
        }
        .toggleStyle(.switch)
        .tint(Color.mixPrimary)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
    }

    /// A 4pt corner, not a 12pt one: the sheet's plates are meant to read as
    /// fields in a window, not as cards in a feed.
    private var squareFill: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.mixSurface2)
    }

    private var squareStroke: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.mixTextSecondary)
    }

    /// One plain sentence instead of three tinted pills. "1 matched" said
    /// nothing on its own — matched to *what*? — and colour here was decoration:
    /// the counts aren't categories the eye has to sort, they're a total the
    /// reader checks once before pressing Send.
    private func summary(for plan: SpotifyExportService.Plan) -> some View {
        let found = plan.confident.count + plan.uncertain.count
        let total = plan.candidates.count

        var parts: [String] = ["\(found) of \(total) song\(total == 1 ? "" : "s") found on Spotify"]
        if !plan.uncertain.isEmpty { parts.append("\(plan.uncertain.count) worth checking") }
        if !plan.missing.isEmpty   { parts.append("\(plan.missing.count) not on Spotify") }
        if !plan.unchecked.isEmpty {
            parts.append("\(plan.unchecked.count) couldn't be checked")
        }

        // The reason goes on its own line rather than into the dot-separated
        // run: it is the one part of this the reader may need to act on, and
        // it says what to do about it.
        return VStack(alignment: .leading, spacing: 3) {
            Text(parts.joined(separator: " \u{00B7} "))
            if let reason = plan.uncheckedReason {
                Text(reason.sentence)
                    .foregroundStyle(Color.mixTextTertiary)
            }
        }
        .font(.system(size: 12))
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
                // Square, and the same ink as the text. A ring of accent on
                // every row made the list the loudest thing in the sheet; the
                // one coloured control here should be the Send button.
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle(isOn ? Color.mixTextPrimary : Color.mixTextTertiary)
            }
            .buttonStyle(.plain).mixHandCursor()
            .disabled(!canPick)

            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.track.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.mixTextPrimary)
                    .lineLimit(1)

                if let match {
                    // Only worth printing when it *differs* — repeating the
                    // same title back is noise, and hiding it when it agrees
                    // makes every visible line a thing worth looking at.
                    Text(differs(candidate.track, match)
                         ? "\u{2192} \(match.title) \u{00B7} \(match.artist)"
                         : candidate.track.artistName)
                        .font(.system(size: 11))
                        .foregroundStyle(differs(candidate.track, match)
                                         ? Color.mixTextSecondary
                                         : Color.mixTextTertiary)
                        .lineLimit(1)
                } else {
                    // "Not on Spotify" is a claim about the catalogue. Only
                    // make it when a search actually came back empty.
                    Text(candidate.uncheckedReason?.phrase ?? "Not on Spotify")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.mixTextTertiary)
                }
            }

            Spacer(minLength: 8)

            if candidate.verdict == .uncertain, match != nil {
                Text("check this one")
                    .font(.system(size: 10.5))
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

    /// The correction hatch. A wrong guess with the right song two rows down in
    /// the results is the commonest failure there is, and without this the only
    /// remedy would be to untick it and add it by hand on Spotify.
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
        // A hard 20pt, never `fixedSize()`. A Menu's ideal width is the width of
        // its widest item — "Stuff (feat. Travis Scott) · Lil Baby, Travis
        // Scott" and the rest — so `fixedSize()` made every row demand hundreds
        // of points it didn't have. The row can't shrink a fixed-size child, so
        // the content simply drew past the sheet's frame and off both sides of
        // the window. The trigger is one glyph; only the popup needs the width.
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
                // Not a `Link`: that hands the https URL to the browser even
                // when the Spotify app is sitting right there, already signed
                // in. See `SpotifyAppLink`.
                Button("Open it in Spotify") { SpotifyAppLink.open(url) }
                    .buttonStyle(.plain).mixHandCursor()
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.mixPrimary)
            }
            Spacer(minLength: 0)
        }
    }

    /// Three plain sentences, and only the ones that apply.
    ///
    /// The old single line lumped every song that didn't go into one number and
    /// blamed Spotify for all of them, including the ones the user unticked
    /// themselves. Those are two different facts and only one of them is a
    /// problem, so they're now counted apart and said apart.
    private var finishedDetail: String {
        let sent = chosen.count
        guard let plan else { return songs(sent) + " added." }

        // Unticked means a song that was ready to go and the user took it out.
        // Everything else that stayed behind had no usable match to begin with:
        // Spotify didn't have it, or the guess wasn't good enough to pre-tick.
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
            // Confident only. An unsure match that arrived pre-ticked would be
            // a guess the user endorsed by not noticing.
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

    /// Records the sync link, if either switch is on.
    ///
    /// `syncedIDs` is seeded with exactly the songs that went across, which
    /// makes it a true record of what both ends agreed on: songs left behind
    /// because Spotify doesn't have them are outside the agreement, so a later
    /// merge reads them as local additions rather than as things Spotify
    /// deleted. Without that seeding the very first sync would delete every
    /// unmatched song from the user's own playlist.
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
        // Every URI is already in hand from the plan, so the first push has
        // nothing left to look up.
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


/// The progress panes, split out so they can observe the service directly.
///
/// The parent reaches the service through `AppDependencies`, and a nested
/// `ObservableObject` doesn't republish through its owner — a pane reading
/// `service.planned` from up there would render once and then sit still. This
/// is the same shape as the queue mirror's observation problem.
private struct SpotifyExportProgress: View {

    enum Stage { case planning, pushing }

    @ObservedObject var service: SpotifyExportService
    let title: String
    let stage: Stage

    var body: some View {
        let counts = stage == .planning ? service.planned : service.pushed
        VStack(alignment: .leading, spacing: 10) {
            MixSheetStatus(
                kind: .busy,
                title: title,
                // Songs, not a percentage — the same reasoning as the import
                // side: "412 of 900" is a number someone can feel.
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

// SpotifyLikesPushPage.swift
// Mixtape — Features/Settings
//
// Choosing which favourites to add to Spotify's Liked Songs.
//
// This was a button and a confirmation dialog: press it, and some number of
// songs were matched and saved with no chance to look at the matching first.
// The failure that made the case against it is small and completely ordinary —
// one favourite, already saved on Spotify, and a row cheerfully offering to
// "like 1 song" that would have done precisely nothing.
//
// So the check comes first. What fills this page is not "your liked songs", it's
// the difference between the two libraries: songs favourited here that Spotify
// doesn't already have saved. When that difference is empty the page says so
// and offers nothing, which is the honest answer and also the common one for
// anybody who runs this twice.
//
// Matching by name is guesswork — live takes, remasters, karaoke covers — so
// the confident matches arrive ticked and the doubtful ones arrive unticked but
// visible. Nothing is saved that the user didn't leave ticked.

import SwiftUI

struct SpotifyLikesPushPage: View {

    @EnvironmentObject private var deps: AppDependencies
    @ObservedObject var service: SpotifyExportService
    let onBack: () -> Void

    /// The favourites playlist, in order, minus anything tombstoned.
    private var favourites: [Track] {
        guard let playlist = deps.libraryService.playlist(id: Playlist.favouritesID) else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: deps.libraryService.tracks.map { ($0.id, $0) })
        return playlist.trackIDs.compactMap { byID[$0] }.filter { !$0.isDeleted }
    }

    enum Phase: Equatable {
        case checking
        case choosing
        case pushing
        case finished(added: Int)
        case failed(String)
    }

    @State private var phase: Phase = .checking
    @State private var review: SpotifyExportService.LikesReview?
    /// Ticked rows, by track id. Seeded from the confident matches.
    @State private var chosen: Set<UUID> = []
    /// A corrected match, where the user picked a different search result.
    @State private var overrides: [UUID: SpotifyTrackMatch] = [:]
    @State private var work: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Rectangle()
                .fill(Color.mixSeparator)
                .frame(height: 0.5)

            content
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.mixBackground)
        .task { await check() }
        // Leaving stops the run, for the same reason the import page does it:
        // nothing should go on writing to an account with no way on screen to
        // stop it. Saving is additive and idempotent, so a half-finished push
        // needs no undoing — the next run simply picks up what's left.
        .onDisappear { work?.cancel() }
    }

    // MARK: Chrome

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onBack) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Connections")
                        .font(.mixLabel)
                }
                .foregroundStyle(Color.mixTextSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).mixHandCursor()

            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Add Your Likes to Spotify")
                        .font(.mixTitle)
                        .foregroundStyle(Color.mixTextPrimary)
                    Text(subtitle)
                        .font(.mixSubtext)
                        .foregroundStyle(Color.mixTextSecondary)
                        // Bounded, like the import page's: an unbounded
                        // `fixedSize` measured against the narrow settings
                        // column locks in a minimum height taller than the
                        // window.
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                primaryButton
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var subtitle: String {
        switch phase {
        case .checking:
            return "Checking which of your liked songs Spotify already has saved."
        case .pushing:
            return "Adding them to your Liked Songs."
        case .finished(let added):
            return added == 0
                ? "Nothing was added."
                : "Added to your Liked Songs. Nothing else in your Spotify account was touched."
        case .failed:
            return "Nothing was added."
        case .choosing:
            guard let review, !review.hasNothingToPush else {
                return "Your Liked Songs are already up to date."
            }
            return "Tick what to add. It only adds, and never unlikes anything on Spotify."
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch phase {
        case .checking:
            actionButton("Add", isEnabled: false, isBusy: true) { }
        case .choosing:
            if let review, !review.hasNothingToPush {
                actionButton(chosen.isEmpty ? "Add" : "Add \(songs(chosen.count))",
                             isEnabled: !chosen.isEmpty) { push() }
            } else {
                actionButton("Done", action: onBack)
            }
        case .pushing:
            actionButton("Adding\u{2026}", isEnabled: false, isBusy: true) { }
        case .finished, .failed:
            actionButton("Done", action: onBack)
        }
    }

    // MARK: Body

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .checking:
            checkingPane

        case .choosing:
            if let review {
                if review.hasNothingToPush {
                    nothingToPushPane(review)
                } else {
                    chooserPane(review)
                }
            }

        case .pushing:
            VStack(alignment: .leading, spacing: 12) {
                progressLine(service.pushed, verb: "Added")
                Spacer(minLength: 0)
            }

        case .finished(let added):
            VStack(alignment: .leading, spacing: 12) {
                MixSheetStatus(
                    kind: added == 0 ? .noop : .success,
                    title: added == 0 ? "Nothing to add" : "\(songs(added)) added",
                    detail: finishedDetail(added: added)
                )
                Spacer(minLength: 0)
            }

        case .failed(let message):
            VStack(alignment: .leading, spacing: 12) {
                MixSheetStatus(kind: .failure, title: "Couldn't add them", detail: message)
                Spacer(minLength: 0)
            }
        }
    }

    private var checkingPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            progressLine(service.planned, verb: "Checked")
            Text("Each song is looked up on Spotify and compared with what you've already saved, so this only offers you what's actually missing.")
                .font(.mixCaption)
                .foregroundStyle(Color.mixTextTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    /// The common case on a second run, and the one the old button got wrong.
    private func nothingToPushPane(_ review: SpotifyExportService.LikesReview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            MixSheetStatus(
                kind: .noop,
                title: "Nothing to add",
                detail: nothingToPushDetail(review)
            )

            if !review.missing.isEmpty {
                missingList(review.missing)
            }

            Spacer(minLength: 0)
        }
    }

    private func nothingToPushDetail(_ review: SpotifyExportService.LikesReview) -> String {
        var parts: [String] = []
        if review.alreadyLiked > 0 {
            parts.append(review.alreadyLiked == 1
                         ? "Your one liked song is already in Spotify's Liked Songs"
                         : "All \(review.alreadyLiked) of your matched songs are already in Spotify's Liked Songs")
        }
        if !review.missing.isEmpty {
            parts.append("\(songs(review.missing.count)) couldn't be found on Spotify")
        }
        if review.unchecked > 0 {
            // Without this, a run that was throttled before it matched anything
            // reads as "nothing to do" — the emptiest possible way of hiding a
            // failure, and the one most likely to be believed.
            parts.append("\(songs(review.unchecked)) couldn't be checked at all \u{2014} \(review.uncheckedReason?.sentence ?? "Couldn't reach Spotify")")
        }
        guard !parts.isEmpty else {
            return "There's nothing liked here that Spotify doesn't already have."
        }
        return parts.joined(separator: ", and ") + "."
    }

    private func chooserPane(_ review: SpotifyExportService.LikesReview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(summaryLine(review))
                .font(.mixCaption)
                .foregroundStyle(Color.mixTextSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 14) {
                Button("Select All") { chosen = Set(review.pushable.map { $0.track.id }) }
                Button("Select None") { chosen = [] }
            }
            .buttonStyle(.plain).mixHandCursor()
            .font(.mixLabel)
            .foregroundStyle(Color.mixTextSecondary)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(review.pushable) { candidate in
                        row(for: candidate)
                    }

                    if !review.missing.isEmpty {
                        missingList(review.missing)
                            .padding(.top, 10)
                    }
                }
            }
        }
    }

    private func summaryLine(_ review: SpotifyExportService.LikesReview) -> String {
        guard review.checkSucceeded else {
            // The list is every match, not the missing ones: say so, rather
            // than letting an unchecked list pass for a checked one.
            return "\(songs(review.pushable.count)) matched. Spotify didn't say which of these you've already liked, so some may already be there. Adding them again changes nothing."
        }
        var parts = ["\(songs(review.pushable.count)) not in your Liked Songs yet"]
        if review.unchecked > 0 {
            // Spotify stopped answering partway through. Say it plainly, and say
            // why: the alternative is a list that silently omits songs and looks
            // whole. Never fold these into "not on Spotify" — nobody
            // established that they aren't.
            let why = review.uncheckedReason?.sentence ?? "Couldn't reach Spotify"
            parts.append("\(review.unchecked) couldn't be checked \u{2014} \(why)")
        }
        if review.alreadyLiked > 0 { parts.append("\(review.alreadyLiked) already there") }
        if !review.missing.isEmpty { parts.append("\(review.missing.count) not on Spotify") }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// Songs Spotify has nothing for. Shown, not hidden: it's the only place
    /// anyone would find out, and it isn't a failure of the push.
    private func missingList(_ missing: [SpotifyExportService.Candidate]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Not on Spotify")
                .font(.mixCaptionBold)
                .foregroundStyle(Color.mixTextTertiary)
                .padding(.horizontal, 9)

            ForEach(missing) { candidate in
                Text("\(candidate.track.title) \u{00B7} \(candidate.track.artistName)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.mixTextTertiary)
                    .lineLimit(1)
                    .padding(.horizontal, 9)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(for candidate: SpotifyExportService.Candidate) -> some View {
        let match = overrides[candidate.track.id] ?? candidate.match
        let isOn  = chosen.contains(candidate.track.id)

        return HStack(spacing: 10) {
            Button {
                if isOn { chosen.remove(candidate.track.id) }
                else    { chosen.insert(candidate.track.id) }
            } label: {
                // Square and in the text's own ink, matching the export sheet.
                // The one coloured control on the page should be Add.
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle(isOn ? Color.mixTextPrimary : Color.mixTextTertiary)
            }
            .buttonStyle(.plain).mixHandCursor()

            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.track.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.mixTextPrimary)
                    .lineLimit(1)

                if let match {
                    // Printed only when it differs. Repeating the same title
                    // back is noise; hiding it when it agrees makes every
                    // visible second line worth reading.
                    Text(differs(candidate.track, match)
                         ? "\u{2192} \(match.title) \u{00B7} \(match.artist)"
                         : candidate.track.artistName)
                        .font(.system(size: 11))
                        .foregroundStyle(differs(candidate.track, match)
                                         ? Color.mixTextSecondary
                                         : Color.mixTextTertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if candidate.verdict == .uncertain {
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
        .contentShape(Rectangle())
    }

    /// The correction hatch, same as the export sheet's: a wrong guess with the
    /// right song two results down is the commonest failure there is.
    private func alternativesMenu(for candidate: SpotifyExportService.Candidate) -> some View {
        Menu {
            if let original = candidate.match {
                Button("\(original.title) \u{00B7} \(original.artist)") {
                    overrides[candidate.track.id] = original
                }
            }
            ForEach(candidate.alternatives) { alternative in
                Button("\(alternative.title) \u{00B7} \(alternative.artist)") {
                    overrides[candidate.track.id] = alternative
                    chosen.insert(candidate.track.id)
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.mixTextTertiary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        // A hard 20pt, never `fixedSize()` — a Menu's ideal width is its widest
        // item, which here is a full title and artist list.
        .frame(width: 20)
    }

    private func progressLine(_ counts: (done: Int, total: Int)?, verb: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let counts, counts.total > 0 {
                Text("\(verb) \(counts.done) of \(counts.total)\u{2026}")
                    .font(.mixBody)
                    .foregroundStyle(Color.mixTextPrimary)
                ProgressView(value: Double(counts.done), total: Double(counts.total))
                    .progressViewStyle(.linear)
            } else {
                Text("Starting\u{2026}")
                    .font(.mixBody)
                    .foregroundStyle(Color.mixTextPrimary)
                ProgressView().progressViewStyle(.linear)
            }
        }
    }

    private func finishedDetail(added: Int) -> String {
        guard added > 0 else { return "Your Liked Songs are unchanged." }
        return "\(songs(added)) now in your Liked Songs. You can run this again any time. It only ever adds."
    }

    private func actionButton(_ title: String,
                              isEnabled: Bool = true,
                              isBusy: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if isBusy {
                    ProgressView().controlSize(.small).tint(.white)
                }
                Text(title)
                    .font(.mixBodyBold)
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Capsule().fill(Color.mixPrimary))
            .opacity(isEnabled && !isBusy ? 1 : 0.55)
        }
        .buttonStyle(.plain).mixHandCursor()
        .disabled(!isEnabled || isBusy)
    }

    private func songs(_ count: Int) -> String {
        "\(count) song\(count == 1 ? "" : "s")"
    }

    /// Whether the match is worth printing next to the local row.
    private func differs(_ track: Track, _ match: SpotifyTrackMatch) -> Bool {
        LibraryTrackIndex.key(title: track.title, artistName: track.artistName)
            != LibraryTrackIndex.key(title: match.title, artistName: match.artist)
    }

    // MARK: Work

    private func check() async {
        guard phase == .checking else { return }
        do {
            // Consent, if this connection has never been allowed to write.
            // Asked here rather than at the button on the previous page: it's a
            // whole trip through a browser, and the moment to ask is when
            // someone has said what they want.
            if !deps.spotifyAuth.canWrite {
                try await deps.spotifyAuth.connect(includingWrite: true)
                // A new grant drops the cached account; nothing else asks for it
                // again until this pane is left and reopened.
                deps.spotifyAuth.loadProfile(using: deps.spotifyClient, force: true)
            }
            let found = try await service.reviewLikes(favourites)
            review = found
            // Confident matches arrive ticked, doubtful ones visible and not.
            chosen = Set(found.pushable.filter { $0.verdict == .confident }.map { $0.track.id })
            phase = .choosing
        } catch is CancellationError {
            // Left the page. Say nothing.
        } catch SpotifyAuthError.cancelled {
            // Closing the consent window is an answer, not a failure.
            onBack()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func push() {
        guard let review else { return }
        let uris = review.pushable
            .filter { chosen.contains($0.track.id) }
            .compactMap { overrides[$0.track.id]?.uri ?? $0.match?.uri }
            // Two local rows can land on the same Spotify recording, and the
            // count reported at the end is this array's length.
            .reduce(into: [String]()) { out, uri in if !out.contains(uri) { out.append(uri) } }
        guard !uris.isEmpty else { return }

        phase = .pushing
        work = Task {
            do {
                let added = try await service.pushLikes(uris: uris)
                phase = .finished(added: added)
            } catch is CancellationError {
                phase = .choosing
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}

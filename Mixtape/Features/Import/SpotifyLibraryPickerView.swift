// Import a Spotify library in whole or in part: playlists, Liked Songs and saved
// albums, ticked from a list. Uses the single-playlist importer underneath, run
// as one job that survives individual failures. Logic lives in
// `SpotifyLibraryPickerModel`; this is the sheet host (also used on iOS).

import SwiftUI

public struct SpotifyLibraryPickerView: View {

    @StateObject private var model: SpotifyLibraryPickerModel
    @ObservedObject private var auth: SpotifyAuth

    public init(spotifyClient: SpotifyClient,
                importService: SpotifyImportService,
                auth: SpotifyAuth,
                followService: SpotifyFollowService? = nil,
                ledger: SpotifyImportLedger? = nil) {
        _model = StateObject(wrappedValue: SpotifyLibraryPickerModel(
            spotifyClient: spotifyClient,
            importService: importService,
            auth: auth,
            followService: followService,
            ledger: ledger
        ))
        self.auth = auth
    }

    @Environment(\.dismiss) private var dismiss

    /// Stopping rolls back, so confirm first.
    @State private var confirmStopImport = false

    // MARK: - Body

    public var body: some View {
        MixSheet(title: "Import from Spotify",
                 subtitle: subtitle,
                 size: .large,
                 // The list scrolls itself.
                 scroll: false,
                 primary: primaryAction,
                 showsCancel: model.phase != .migrating) {
            content
        }
        .onDisappear {
            // Closing the sheet stops the run, so nothing writes to the library unseen.
            model.cancelMigration()
        }
        .task(id: auth.isAuthorized) {
            await model.loadIfNeeded()
        }
        .mixConfirmationDialog("Stop importing?",
                            isPresented: $confirmStopImport,
                            titleVisibility: .visible) {
            Button("Stop and Remove", role: .destructive) { model.cancelMigration() }
            Button("Keep Importing", role: .cancel) { }
        } message: {
            Text(stopImportMessage)
        }
    }

    private var stopImportMessage: String {
        guard let progress = model.progress, progress.overallCompleted > 0 else {
            return "Nothing has been imported yet. You can start again any time."
        }
        let songs = progress.overallCompleted == 1 ? "1 song" : "\(progress.overallCompleted) songs"
        return "The \(songs) imported so far will be removed from your library. Songs you already had are kept."
    }

    private var subtitle: String? {
        switch model.phase {
        case .idle where !auth.isAuthorized:
            return "Spotify requires you to sign in before Mixtape can read your library. We only ask for read access."
        case .choosing:
            return "Pick what to bring over. Songs already in your library are reused, not duplicated."
        default:
            return nil
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Above the list, since it explains what's missing from it.
            if auth.needsReauthorization, auth.isAuthorized {
                MixSheetStatus(
                    kind: .failure,
                    title: "Reconnect to see everything",
                    detail: "Your Spotify connection predates Mixtape asking for Liked Songs and saved albums, so only playlists are listed. Reconnecting takes one tap and only adds read access."
                )
                .padding(.bottom, 12)
            }

            switch model.phase {
            case .choosing:
                SpotifyLibraryChooser(model: model)
            default:
                VStack(alignment: .leading, spacing: 12) {
                    SpotifyLibraryStatus(model: model, isAuthorized: auth.isAuthorized)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, MixSheetMetrics.margin)
        .padding(.vertical, MixSheetMetrics.contentVertical)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Footer

    /// One button for the whole flow: connect, import, close.
    private var primaryAction: MixSheetAction {
        if !auth.isAuthorized {
            return MixSheetAction("Connect Spotify", isBusy: model.isConnecting) { model.connect() }
        }
        if auth.needsReauthorization {
            return MixSheetAction("Reconnect Spotify", isBusy: model.isConnecting) { model.connect() }
        }
        switch model.phase {
        case .idle, .loading:
            return MixSheetAction("Import", isEnabled: false, isBusy: model.phase == .loading) { }

        case .failed:
            return MixSheetAction("Try Again") { Task { await model.load() } }

        case .choosing:
            // New songs only, to match the "9 new" badges.
            let songs = model.selectedNewSongCount
            let title = model.selection.isEmpty || songs == 0
                ? "Import"
                : "Import \(songs) Song\(songs == 1 ? "" : "s")"
            return MixSheetAction(title, isEnabled: !model.selection.isEmpty) { model.startMigration() }

        case .migrating:
            return MixSheetAction("Stop", isDestructive: true) { confirmStopImport = true }

        case .finished:
            return MixSheetAction("Done") { dismiss() }
        }
    }
}

// MARK: - Chooser
// The listing: filter, select-all and one row per item. Shared with Settings,
// so it has no chrome of its own.

struct SpotifyLibraryChooser: View {

    @ObservedObject var model: SpotifyLibraryPickerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                MixSearchField(text: $model.filter, placeholder: "Filter your library")
                selectAllButton
            }

            // Above the list since it changes what the import is.
            if model.canFollow { keepInSyncToggle }

            // Sections that failed to load, usually a rate limit that clears with time.
            ForEach(model.warnings, id: \.self) { warning in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10.5))
                    Text(warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: MixFontScale.size(11.5)))
                .foregroundStyle(Color.mixTextSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if model.visibleSections.isEmpty {
                Text(model.filter.isEmpty
                     ? "There's nothing in this Spotify account to import."
                     : "Nothing matches \u{201C}\(model.filter)\u{201D}.")
                    .font(.mixSubtext)
                    .foregroundStyle(Color.mixTextSecondary)
                    .padding(.top, 8)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14, pinnedViews: [.sectionHeaders]) {
                        ForEach(model.visibleSections, id: \.title) { section in
                            SwiftUI.Section {
                                VStack(spacing: 4) {
                                    ForEach(section.items) { item in
                                        row(for: item)
                                    }
                                }
                            } header: {
                                sectionHeader(section.title, count: section.items.count)
                            }
                        }
                    }
                    .padding(.bottom, 4)
                }

                if let note = alreadyImportedNote {
                    Text(note)
                        .font(.system(size: MixFontScale.size(11.5)))
                        .foregroundStyle(Color.mixTextTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The mirror opt-in, as its own card. The second line says a mirror is Spotify's to change.
    private var keepInSyncToggle: some View {
        Toggle(isOn: $model.keepInSync) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(model.keepInSync ? Color.mixPrimary : Color.mixTextSecondary)
                    Text("Keep in sync with Spotify")
                        .font(.system(size: MixFontScale.size(12.5), weight: .semibold))
                        .foregroundStyle(Color.mixTextPrimary)
                }
                Text("Checks for changes every so often. Synced playlists are read-only here, and can be unlinked at any time.")
                    .font(.system(size: MixFontScale.size(11)))
                    .foregroundStyle(Color.mixTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .tint(Color.mixPrimary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(model.keepInSync ? Color.mixPrimary.opacity(0.10) : Color.mixSurface2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(model.keepInSync ? Color.mixPrimary.opacity(0.35) : Color.clear,
                        lineWidth: 1)
        )
    }

    /// One note under the list rather than a warning per row.
    private var alreadyImportedNote: String? {
        let repeats = model.selectedAlreadyImported
        guard !repeats.isEmpty else { return nil }
        let what = repeats.count == 1
            ? "\u{201C}\(repeats[0].name)\u{201D} has"
            : "\(repeats.count) of the things you've ticked have"
        return "\(what) been imported before. Importing again only adds what's new \u{2014} nothing is duplicated."
    }

    private var selectAllButton: some View {
        Button(model.allVisibleSelected ? "None" : "All") {
            model.toggleAllVisible()
        }
        .buttonStyle(.plain).mixHandCursor()
        .font(.system(size: MixFontScale.size(12.5), weight: .medium))
        .foregroundStyle(Color.mixPrimary)
        .disabled(model.visibleSections.isEmpty)
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: MixFontScale.size(11.5), weight: .semibold))
                .foregroundStyle(Color.mixTextSecondary)
            Text("\(count)")
                .font(.system(size: MixFontScale.size(11.5)))
                .foregroundStyle(Color.mixTextTertiary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .background(Color.mixBackground)
    }

    /// What the ledger knows about this row: imported, or imported with new songs
    /// since. Neither blocks ticking; re-imports only add what's missing.
    @ViewBuilder
    private func importedBadge(for item: SpotifyLibraryItem) -> some View {
        switch model.importState(for: item) {
        case .never:
            EmptyView()

        case .imported(let date):
            badge(icon: "checkmark.circle.fill",
                  text: "Imported",
                  tint: Color.mixTextSecondary)
                .help("Imported \(Self.relative.localizedString(for: date, relativeTo: .now)).")

        case .outdated(let date, let newSongs, let removedSongs):
            let parts = [newSongs > 0 ? "+\(newSongs)" : nil,
                         removedSongs > 0 ? "−\(removedSongs)" : nil].compactMap { $0 }
            badge(icon: newSongs > 0 ? "arrow.down.circle.fill" : "minus.circle.fill",
                  text: newSongs > 0 && removedSongs == 0 ? "\(newSongs) new" : parts.joined(separator: " "),
                  tint: newSongs > 0 ? Color.mixPrimary : Color.mixTextSecondary)
                .help("Imported \(Self.relative.localizedString(for: date, relativeTo: .now)). Spotify's copy has changed since.")
        }
    }

    private func badge(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            Text(text)
                .font(.system(size: MixFontScale.size(10), weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(
            Capsule(style: .continuous).fill(tint.opacity(0.14))
        )
        .fixedSize()
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    private func row(for item: SpotifyLibraryItem) -> some View {
        let isOn = model.selection.contains(item.id)
        return Button {
            model.toggle(item)
        } label: {
            HStack(spacing: 11) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(isOn ? Color.mixPrimary : Color.mixTextTertiary)

                cover(for: item)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.system(size: MixFontScale.size(13), weight: .medium))
                        .foregroundStyle(Color.mixTextPrimary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(item.subtitle)
                            .font(.system(size: MixFontScale.size(11.5)))
                            .foregroundStyle(Color.mixTextTertiary)
                            .lineLimit(1)
                        importedBadge(for: item)
                    }
                }

                Spacer(minLength: 8)

                Text("\(item.trackCount)")
                    .font(.system(size: MixFontScale.size(11.5)))
                    .foregroundStyle(Color.mixTextTertiary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isOn ? Color.mixSurface2 : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).mixHandCursor()
    }

    /// The cover or a stand-in. Liked Songs has no image on Spotify, so draw the gradient.
    @ViewBuilder
    private func cover(for item: SpotifyLibraryItem) -> some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        Group {
            if item.kind == .likedSongs {
                LinearGradient(colors: [Color.mixPrimary, Color.mixAccent],
                               startPoint: .topLeading,
                               endPoint: .bottomTrailing)
                    .overlay(
                        Image(systemName: MixtapeIcons.heart)
                            .font(.system(size: 14))
                            .foregroundStyle(.white)
                    )
            } else {
                CachedRemoteImage(url: item.coverURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color.mixSurface2.overlay(
                        Image(systemName: item.kind == .album ? MixtapeIcons.album : MixtapeIcons.playlist)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.mixTextTertiary)
                    )
                }
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(shape)
    }
}

// MARK: - Status
// Every state other than the chooser, as a status row.

struct SpotifyLibraryStatus: View {

    @ObservedObject var model: SpotifyLibraryPickerModel
    let isAuthorized: Bool

    var body: some View {
        switch model.phase {
        case .idle:
            if !isAuthorized {
                MixSheetStatus(
                    kind: .noop,
                    title: "Not connected",
                    detail: "Connect your Spotify account to see your playlists here."
                )
            }

        case .loading:
            MixSheetStatus(kind: .busy, title: "Reading your Spotify library\u{2026}")

        case .migrating:
            migrationStatus

        case .finished:
            finishedStatus

        case .failed(let message):
            MixSheetStatus(kind: .failure, title: "Couldn't read your library", detail: message)

        case .choosing:
            EmptyView()
        }
    }

    /// Two bars: the current item, and the whole job.
    @ViewBuilder
    private var migrationStatus: some View {
        let done  = model.progress?.songsCompleted ?? 0
        let total = model.progress?.songsTotal ?? 0
        let index = model.progress?.itemIndex ?? 0
        let count = model.progress?.itemCount ?? model.selection.count
        // Say whether it's reading or importing, so slow doesn't look stuck.
        let verb: String = {
            switch model.progress?.phase {
            case .fetching: return "read"
            default:        return "imported"
            }
        }()
        let isFinishing = model.progress?.phase == .finishing

        // Overall = songs across every selected item.
        let overallDone  = model.progress?.overallCompleted ?? 0
        let overallTotal = model.progress?.overallTotal ?? 0
        let overall = overallTotal > 0
            ? min(1, Double(overallDone) / Double(overallTotal))
            : 0

        MixSheetStatus(
            kind: .busy,
            title: model.progress.map { "\($0.itemName)" } ?? "Starting\u{2026}",
            detail: total > 0
                ? (isFinishing
                   ? "Item \(index) of \(count) \u{00B7} adding \(total) songs to your library\u{2026}"
                   : "Item \(index) of \(count) \u{00B7} \(verb) \(done) of \(total) songs")
                : "Item \(index) of \(count)",
            progress: total > 0 ? Double(done) / Double(total) : nil
        )

        // Overall bar only for multiple items; for one it would duplicate the first.
        if count > 1 {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text("Overall")
                        .font(.system(size: MixFontScale.size(11.5), weight: .medium))
                        .foregroundStyle(Color.mixTextTertiary)
                    Spacer(minLength: 4)
                    if overallTotal > 0 {
                        Text("\(overallDone) of \(overallTotal) songs")
                            .font(.system(size: MixFontScale.size(11.5), weight: .medium))
                            .foregroundStyle(Color.mixTextTertiary)
                            .monospacedDigit()
                    }
                }
                ProgressView(value: overall)
                    .progressViewStyle(.linear)
                    .tint(Color.mixTextSecondary)
            }
        }
    }

    @ViewBuilder
    private var finishedStatus: some View {
        if let result = model.result {
            let songs = result.songCount
            MixSheetStatus(
                kind: result.wasCancelled || result.importedCount == 0 ? .noop : .success,
                title: result.wasCancelled
                    ? "Import stopped"
                    : "Imported \(result.importedCount) item\(result.importedCount == 1 ? "" : "s")",
                // A stopped run is rolled back, so there's no count to report.
                detail: result.wasCancelled
                    ? "Nothing was added. Any songs brought over before you stopped have been removed again."
                    : changeSummary(songs: songs)
            )

            if !result.failures.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Couldn't import \(result.failures.count) of them")
                        .font(.system(size: MixFontScale.size(12), weight: .medium))
                        .foregroundStyle(Color.mixTextSecondary)

                    ForEach(result.failures) { failure in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(failure.name)
                                .font(.system(size: MixFontScale.size(12), weight: .medium))
                                .foregroundStyle(Color.mixTextPrimary)
                            Text(failure.reason)
                                .font(.system(size: MixFontScale.size(11.5)))
                                .foregroundStyle(Color.mixTextTertiary)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.mixSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }
}

private extension SpotifyLibraryStatus {
    /// "+9 −2 since last time" when known, plain counts otherwise.
    func changeSummary(songs: Int) -> String {
        let change = model.lastChange
        guard change.removed > 0 else {
            return "\(songs) song\(songs == 1 ? "" : "s") added. Anything you already had was reused."
        }
        return "+\(change.new) new, −\(change.removed) removed on Spotify since your last import. "
            + "Songs taken off Spotify stay in your library."
    }
}

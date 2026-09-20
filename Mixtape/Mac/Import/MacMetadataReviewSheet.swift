// MacMetadataReviewSheet.swift
// Mixtape — Mac/Import
//
// Sheet shown after importing a track. The user can review/edit the proposed
// values, then Apply (downloads artwork + writes tags) or Skip.
//
// It opens on the *filename* reading, immediately, and runs the iTunes lookup
// itself — import no longer waits for it. That lookup used to be the reason
// the sheet took the best part of ten seconds to appear, by which point the
// user had moved on and the sheet arriving felt like an interruption. The
// answer now lands in a sheet that's already on screen, and folds into any
// field the user hasn't started typing in.

#if os(macOS)
import SwiftUI

struct MacMetadataReviewSheet: View {

    let item: MetadataReviewItem

    @EnvironmentObject private var deps:     AppDependencies
    @EnvironmentObject private var appState: MacAppState

    @State private var draft: MetadataDraft

    /// The candidate currently on screen. Starts as the item's local reading
    /// and is replaced if the lookup finds something better — the artwork and
    /// the confidence badge both come from here, not from `item`.
    @State private var candidate: EnrichmentCandidate

    @State private var isLookingUp = false

    /// A cover the user chose here. Nil while they leave the candidate alone.
    @State private var draftArtwork:  Data? = nil
    /// Set by the bin. Distinct from `draftArtwork == nil`, which is also the
    /// untouched state — without this the bin would have nothing to record.
    @State private var artworkCleared = false

    @State private var isApplying = false

    init(item: MetadataReviewItem) {
        self.item = item
        _draft     = State(initialValue: MetadataDraft(candidate: item.candidate, track: item.track))
        _candidate = State(initialValue: item.candidate)
    }

    var body: some View {
        MixSheet(title: "Review Metadata",
                 subtitle: batchLabel,
                 size: .large) {
            VStack(alignment: .leading, spacing: 18) {
                artworkAndSummary
                confidenceBadge
                editableFields
            }
        } footer: {
            actionBar
        }
        // Reset draft fields each time the review queue advances to a new song.
        .onChange(of: item.id) { _, _ in
            draft.reset(to: item.candidate, track: item.track)
            candidate = item.candidate
            // The cover edit belongs to the song that was on screen, not to
            // the next one in the queue.
            draftArtwork   = nil
            artworkCleared = false
        }
        // Keyed on the item, so advancing the queue cancels the outgoing song's
        // lookup instead of letting it come back and overwrite the next one.
        .task(id: item.id) { await runLookup() }
    }

    // MARK: - Lookup

    private func runLookup() async {
        guard let lookup = item.lookup else { return }
        isLookingUp = true
        defer { isLookingUp = false }

        guard let found = await deps.enrichmentService.enrich(url: lookup.sourceURL,
                                                              existing: lookup.existing)
        else { return }
        // The queue may have moved on while this was in flight; `.task(id:)`
        // cancels then, and applying a stale answer to a new song is exactly
        // the bug that check prevents.
        guard !Task.isCancelled else { return }

        // A filename-only answer is what's already on screen. Replacing the
        // candidate anyway would just re-badge the sheet for no gain.
        guard found.source == .itunes else { return }
        candidate = found
        draft.merge(found, track: item.track)
    }

    // MARK: - Header

    /// Where you are in the queue. It was an 11pt grey counter tucked into the
    /// bottom-left of the button bar, which is where you look last.
    private var batchLabel: String? {
        appState.batchTotal > 1
            ? "Song \(appState.currentItemNumber) of \(appState.batchTotal)"
            : "Check what we found before it's written to the file."
    }

    /// Says where the values on screen came from — including "still asking",
    /// which is the honest answer for the first few seconds now that the sheet
    /// doesn't wait for iTunes before showing itself.
    private var confidenceBadge: some View {
        let (label, color): (String, Color) = {
            switch candidate.confidence {
            case 0.7...: return ("High confidence", Color.mixSuccess)
            case 0.4...: return ("Medium confidence", Color.mixWarning)
            default:     return ("Low confidence", Color.mixDestructive)
            }
        }()
        let sourceLabel: String = {
            if isLookingUp { return "Looking up\u{2026}" }
            switch candidate.source {
            case .itunes:           return "iTunes · \(label)"
            case .filenameOnly:     return "Filename only"
            case .existingMetadata: return "Your existing tags"
            }
        }()
        return HStack(spacing: 5) {
            if isLookingUp {
                ProgressView().scaleEffect(0.45).frame(width: 9, height: 9)
            } else if candidate.source == .itunes {
                Image(systemName: "music.note")
                    .font(.system(size: 9))
            }
            Text(sourceLabel)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(isLookingUp ? Color.mixTextSecondary : color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background((isLookingUp ? Color.mixTextSecondary : color).opacity(0.12), in: Capsule())
        .mixAnimation(.easeOut(duration: 0.15), value: isLookingUp)
    }

    // MARK: - Artwork + Summary

    private var artworkAndSummary: some View {
        HStack(alignment: .top, spacing: 14) {
            ArtworkPickerView(
                data: $draftArtwork,
                size: 100,
                showsRemoveBadge: showsRemoveBadge,
                onRemove: { artworkCleared = true },
                placeholder: { artworkPreview }
            )
            .shadow(color: .black.opacity(0.3), radius: 6, y: 3)

            VStack(alignment: .leading, spacing: 4) {
                Text(draft.fields.title.isEmpty ? "Unknown Title" : draft.fields.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.mixTextPrimary)
                    .lineLimit(2)
                Text(draft.fields.artist.isEmpty ? "Unknown Artist" : draft.fields.artist)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mixPrimary)
                    .lineLimit(1)
                Text(draft.fields.album.isEmpty ? "Unknown Album" : draft.fields.album)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mixTextSecondary)
                    .lineLimit(1)
                if !draft.fields.year.isEmpty {
                    Text(draft.fields.year)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.mixTextTertiary)
                }
                Spacer()
                Text(item.track.file.localPath.split(separator: "/").last.map(String.init) ?? "")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.mixTextTertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Whether there is a cover to throw away: one the user just chose, or the
    /// candidate's, as long as they haven't already cleared it.
    private var showsRemoveBadge: Bool {
        if draftArtwork != nil { return true }
        if artworkCleared      { return false }
        return candidate.artworkURL != nil || item.track.artworkData != nil
    }

    private var artworkChoice: ImportService.ArtworkChoice {
        if let draftArtwork { return .replace(draftArtwork) }
        return artworkCleared ? .remove : .keep
    }

    /// What sits behind the picker when the user hasn't supplied their own —
    /// the candidate's remote cover, the file's embedded art, or nothing.
    @ViewBuilder
    private var artworkPreview: some View {
        if artworkCleared {
            artworkPlaceholder
        } else if let url = candidate.artworkURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    artworkPlaceholder
                default:
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.mixSurface)
                }
            }
        } else if let data = item.track.displayArtwork, let img = NSImage(data: data) {
            Image(nsImage: img).resizable().scaledToFill()
        } else {
            artworkPlaceholder
        }
    }

    private var artworkPlaceholder: some View {
        Rectangle()
            .fill(Color.mixSurface)
            .overlay {
                Image(systemName: "music.note")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.mixTextTertiary)
            }
    }

    // MARK: - Editable Fields

    private var editableFields: some View {
        VStack(spacing: 0) {
            reviewField("Title",  value: $draft.fields.title)
            Divider().padding(.horizontal, 2)
            // Artist = primary artist / folder; Featured = collaborator after the separator
            reviewField("Artist", value: $draft.fields.artist)
            Divider().padding(.horizontal, 2)
            featuredRow
            Divider().padding(.horizontal, 2)
            reviewField("Album",  value: $draft.fields.album)
            Divider().padding(.horizontal, 2)
            reviewField("Year",   value: $draft.fields.year)
            Divider().padding(.horizontal, 2)
            reviewField("Genre",  value: $draft.fields.genre)
        }
        .background(Color.mixSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// Featured artist row — pre-split from the raw artist string.
    /// Leave empty if no feature. The track is always filed under "Artist" above.
    private var featuredRow: some View {
        HStack(spacing: 12) {
            Text("Featured")
                .font(.system(size: 12))
                .foregroundStyle(Color.mixTextSecondary)
                .frame(width: 48, alignment: .leading)
            TextField("Collaborating artist(s)", text: $draft.fields.featured)
                .font(.system(size: 12))
                .textFieldStyle(.plain)
                .foregroundStyle(Color.mixTextPrimary)
            if !draft.fields.featured.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 9))
                    Text("ft.")
                        .font(.system(size: 9, weight: .medium))
                }
                .foregroundStyle(Color.mixPrimary.opacity(0.7))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.mixPrimary.opacity(0.1), in: Capsule())
                .help("Track is filed under Artist above. Featured artist is shown in the full artist name.")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func reviewField(_ label: String, value: Binding<String>) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Color.mixTextSecondary)
                .frame(width: 48, alignment: .leading)
            TextField(label, text: value)
                .font(.system(size: 12))
                .textFieldStyle(.plain)
                .foregroundStyle(Color.mixTextPrimary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: - Action Bar

    /// Apply commits, Skip moves the queue on — so Skip can't be the chrome's
    /// Cancel: closing the sheet and passing on this song aren't the same act.
    private var actionBar: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)
            Button("Skip") { appState.dequeueReview() }
                .buttonStyle(.plain).mixHandCursor()
                .foregroundStyle(Color.mixTextSecondary)
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(isApplying)

            MixSheetPrimaryButton(
                action: MixSheetAction("Apply Changes",
                                       isBusy: isApplying,
                                       action: applyChanges),
                fullWidth: false
            )
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Apply

    private func applyChanges() {
        isApplying = true
        let trackID    = item.track.id
        let artworkURL = candidate.artworkURL
        let title      = draft.fields.title
        // The track is always filed under the primary artist, passed separately
        // as primaryArtistOverride; the stored name keeps the feature.
        let primary    = draft.primaryArtist
        let fullArtist = draft.fullArtist
        let album      = draft.fields.album
        let year       = Int(draft.fields.year)
        let genre      = draft.fields.genre.isEmpty ? nil : draft.fields.genre
        let choice     = artworkChoice

        Task {
            await deps.importService.applyEnrichment(
                trackID:               trackID,
                title:                 title,
                artistName:            fullArtist,
                albumTitle:            album,
                year:                  year,
                genre:                 genre,
                artworkURL:            artworkURL,
                artistImageURL:        candidate.artistImageURL,
                primaryArtistOverride: primary.isEmpty ? nil : primary,
                artwork:               choice
            )
            await MainActor.run {
                isApplying = false
                appState.dequeueReview()
            }
        }
    }
}

#endif

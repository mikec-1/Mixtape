// Sheet shown after importing a track: review/edit the proposed tags, then Apply or Skip. Touch version
// of MacMetadataReviewSheet. Opens on the filename reading and runs the iTunes lookup itself.

#if os(iOS)
import SwiftUI

struct IOSMetadataReviewSheet: View {

    let item: MetadataReviewItem

    @Environment(AppDependencies.self) private var deps
    @Environment(IOSAppState.self) private var appState

    @State private var draft: MetadataDraft

    /// Candidate on screen: the item's local reading, replaced if the lookup finds better. Artwork and badge
    /// read from here.
    @State private var candidate: EnrichmentCandidate

    @State private var isLookingUp = false

    /// A cover the user chose here. Nil while they leave the candidate alone.
    @State private var draftArtwork:  Data? = nil
    /// Set by the bin. `draftArtwork == nil` is also the untouched state, so this records the clear.
    @State private var artworkCleared = false

    @State private var isApplying = false

    @Environment(\.dismiss) private var dismiss

    init(item: MetadataReviewItem) {
        self.item = item
        _draft     = State(initialValue: MetadataDraft(candidate: item.candidate, track: item.track))
        _candidate = State(initialValue: item.candidate)
    }

    var body: some View {
        MixSheet(title: item.isEdit ? "Edit Metadata" : "Review Metadata",
                 subtitle: batchLabel,
                 size: .large,
                 dismissDisabled: isApplying) {
            VStack(spacing: 18) {
                artworkHero
                summarySection
                fieldsSection
            }
        } footer: {
            actionBar
        }
        // Reset draft fields each time the review queue advances to a new song.
        .onChange(of: item.id) { _, _ in
            draft.reset(to: item.candidate, track: item.track)
            candidate = item.candidate
            // The cover edit belongs to the song that was on screen, not the next one.
            draftArtwork   = nil
            artworkCleared = false
        }
        // Keyed on the item so advancing the queue cancels the old lookup.
        .task(id: item.id) { await runLookup() }
    }

    /// Where you are in the queue, shown with the title.
    private var batchLabel: String? {
        appState.batchTotal > 1
            ? "Song \(appState.currentItemNumber) of \(appState.batchTotal)"
            : item.isEdit ? "Changes are written to the song's file."
                          : "Check what we found before it's written to the file."
    }

    // MARK: - Lookup

    private func runLookup() async {
        guard let lookup = item.lookup else { return }
        isLookingUp = true
        defer { isLookingUp = false }

        guard let found = await deps.enrichmentService.enrich(url: lookup.sourceURL,
                                                              existing: lookup.existing)
        else { return }
        // `.task(id:)` cancels when the queue moves on; don't apply a stale answer.
        guard !Task.isCancelled else { return }

        // A filename-only answer is already on screen.
        guard found.source == .itunes else { return }
        candidate = found
        draft.merge(found, track: item.track)
    }

    // MARK: - Artwork Hero

    /// The cover, and the tap target for changing it.
    private var artworkHero: some View {
        ArtworkPickerView(
            data: $draftArtwork,
            size: 140,
            cornerRadius: 10,
            showsRemoveBadge: showsRemoveBadge,
            onRemove: { artworkCleared = true },
            placeholder: { candidateArtworkImage.scaledToFill() }
        )
        .shadow(color: .black.opacity(0.28), radius: 12, y: 5)
        .frame(maxWidth: .infinity)
    }

    /// Whether there's a cover to remove: a user-chosen one, or the candidate's unless already cleared.
    private var showsRemoveBadge: Bool {
        if draftArtwork != nil { return true }
        if artworkCleared      { return false }
        return candidate.artworkURL != nil || item.track.artworkData != nil
    }

    private var artworkChoice: ImportService.ArtworkChoice {
        if let draftArtwork { return .replace(draftArtwork) }
        return artworkCleared ? .remove : .keep
    }

    /// Behind the picker when the user hasn't chosen one: remote cover, embedded art, or nothing.
    @ViewBuilder
    private var candidateArtworkImage: some View {
        if artworkCleared {
            artworkPlaceholder
        } else if let url = candidate.artworkURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img): img.resizable()
                case .failure:          artworkPlaceholder
                default:
                    Color.mixSurface
                        .overlay(ProgressView().tint(Color.mixTextTertiary))
                }
            }
        } else if let data = item.track.displayArtwork, let img = mixImage(from: data) {
            img.resizable()
        } else {
            artworkPlaceholder
        }
    }

    private var artworkPlaceholder: some View {
        Color.mixSurface
            .overlay(
                Image(systemName: "music.note")
                    .font(.system(size: 36))
                    .foregroundStyle(Color.mixTextTertiary)
            )
    }

    // MARK: - Summary (live-updated from draft)

    private var summarySection: some View {
        VStack(spacing: 6) {
            Text(draft.fields.title.isEmpty ? "Unknown Title" : draft.fields.title)
                .font(.system(size: MixFontScale.size(18), weight: .semibold))
                .foregroundStyle(Color.mixTextPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text(draft.fields.artist.isEmpty ? "Unknown Artist" : draft.fields.artist)
                .font(.system(size: MixFontScale.size(14)))
                .foregroundStyle(Color.mixPrimary)
                .lineLimit(1)
            Text(draft.fields.album.isEmpty ? "" : draft.fields.album)
                .font(.system(size: MixFontScale.size(13)))
                .foregroundStyle(Color.mixTextSecondary)
                .lineLimit(1)
            // Confidence badge, inline under album so it always has room.
            confidenceBadge
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Editable Fields

    private var fieldsSection: some View {
        VStack(spacing: 0) {
            reviewField("Title",    text: $draft.fields.title,    keyboard: .default)
            divider
            // Artist = primary / folder; Featured = collaborator after the separator
            reviewField("Artist",   text: $draft.fields.artist,   keyboard: .default)
            divider
            featuredRow
            divider
            reviewField("Album",    text: $draft.fields.album,    keyboard: .default)
            divider
            reviewField("Year",     text: $draft.fields.year,     keyboard: .numberPad)
            divider
            reviewField("Genre",    text: $draft.fields.genre,    keyboard: .default)
        }
        .background(Color.mixSurface,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// Featured artist. Empty if none; the track is filed under Artist.
    private var featuredRow: some View {
        HStack(spacing: 12) {
            Text("Featured")
                .font(.system(size: MixFontScale.size(13)))
                .foregroundStyle(Color.mixTextSecondary)
                .frame(width: 70, alignment: .leading)
            TextField("Collaborating artist(s)", text: $draft.fields.featured)
                .font(.system(size: MixFontScale.size(14)))
                .foregroundStyle(Color.mixTextPrimary)
                .autocorrectionDisabled()
            if !draft.fields.featured.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 9))
                    Text("ft.")
                        .font(.system(size: MixFontScale.size(9), weight: .medium))
                }
                .foregroundStyle(Color.mixPrimary.opacity(0.8))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.mixPrimary.opacity(0.12), in: Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var divider: some View {
        Divider().padding(.leading, 70)
    }

    private func reviewField(_ label: String,
                             text: Binding<String>,
                             keyboard: UIKeyboardType) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: MixFontScale.size(13)))
                .foregroundStyle(Color.mixTextSecondary)
                .frame(width: 50, alignment: .leading)
            TextField(label, text: text)
                .font(.system(size: MixFontScale.size(14)))
                .foregroundStyle(Color.mixTextPrimary)
                .keyboardType(keyboard)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Confidence Badge

    /// Where the values came from, including "still looking" while iTunes is pending.
    private var confidenceBadge: some View {
        let (label, color): (String, Color) = {
            switch candidate.confidence {
            case 0.7...: return ("High confidence",   .green)
            case 0.4...: return ("Medium confidence", .yellow)
            default:     return ("Low confidence",    .orange)
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
        let tint = isLookingUp ? Color.mixTextSecondary : color
        return HStack(spacing: 4) {
            if isLookingUp {
                ProgressView().scaleEffect(0.5).frame(width: 10, height: 10)
            } else if candidate.source == .itunes {
                Image(systemName: "music.note").font(.system(size: MixFontScale.size(9)))
            }
            Text(sourceLabel)
                .font(.system(size: MixFontScale.size(10), weight: .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.15), in: Capsule())
        .mixAnimation(.easeOut(duration: 0.15), value: isLookingUp)
    }

    // MARK: - Action Bar

    /// Apply commits; Skip moves the queue on. Skip isn't Cancel: closing and passing aren't the same.
    private var actionBar: some View {
        VStack(spacing: 10) {
            MixSheetPrimaryButton(
                action: MixSheetAction("Apply Changes",
                                       isBusy: isApplying,
                                       action: applyChanges),
                fullWidth: true
            )
            Button(item.isEdit ? "Cancel" : "Skip This Song") { appState.dequeueReview() }
                .buttonStyle(.plain).mixHandCursor()
                .font(.system(size: MixFontScale.size(14), weight: .medium))
                .foregroundStyle(Color.mixTextSecondary)
                .disabled(isApplying)
        }
    }

    // MARK: - Apply

    private func applyChanges() {
        isApplying = true
        let trackID    = item.track.id
        let artworkURL = candidate.artworkURL
        let title      = draft.fields.title
        // Filed under the primary artist (passed as primaryArtistOverride); the stored name keeps the feature.
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

// IOSMetadataReviewSheet.swift
// Mixtape — iOS/Import
//
// Full-screen sheet shown after importing a track when the enrichment service
// finds a metadata candidate. The user can review/edit proposed values, then
// tap Apply (downloads artwork + writes tags) or Skip.
//
// Mirrors MacMetadataReviewSheet but designed for touch:
//   • Large artwork hero at the top
//   • Form-style editable fields
//   • Sticky action bar at the bottom

#if os(iOS)
import SwiftUI

struct IOSMetadataReviewSheet: View {

    let item: MetadataReviewItem

    @EnvironmentObject private var deps:     AppDependencies
    @EnvironmentObject private var appState: IOSAppState

    @State private var draftTitle:    String
    /// Primary artist only — the track is filed under this artist folder.
    @State private var draftArtist:   String
    /// Featured/collaborating artist (everything after the & / ft. / feat. separator).
    @State private var draftFeatured: String
    @State private var draftAlbum:    String
    @State private var draftYear:     String
    @State private var draftGenre:    String

    @State private var isApplying = false

    @Environment(\.dismiss) private var dismiss

    init(item: MetadataReviewItem) {
        self.item = item
        let c       = item.candidate
        let t       = item.track
        let raw     = c.artistName ?? t.artistName
        let (primary, featured) = ImportService.splitArtist(from: raw)
        _draftTitle    = State(initialValue: c.title ?? t.title)
        _draftArtist   = State(initialValue: primary)
        _draftFeatured = State(initialValue: featured ?? "")
        _draftAlbum    = State(initialValue: c.albumTitle ?? t.albumTitle)
        _draftYear     = State(initialValue: (c.year ?? t.year).map(String.init) ?? "")
        _draftGenre    = State(initialValue: c.genre ?? t.genre ?? "")
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                // Scrollable content
                ScrollView {
                    VStack(spacing: 0) {
                        artworkHero
                        summarySection
                        Divider().padding(.horizontal, 16)
                        fieldsSection
                        // Extra bottom padding so content clears the sticky action bar
                        Color.clear.frame(height: 100)
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Color.mixBackground)

                // Sticky action bar pinned to bottom
                actionBar
                    .background(.ultraThinMaterial)
            }
            .navigationTitle("Review Metadata")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if appState.batchTotal > 1 {
                        Text("\(appState.currentItemNumber) of \(appState.batchTotal)")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.mixTextTertiary)
                    }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isApplying)
        // Reset draft fields each time the review queue advances to a new song.
        .onChange(of: item.track.id) { _, _ in
            let c = item.candidate
            let t = item.track
            let raw = c.artistName ?? t.artistName
            let (primary, featured) = ImportService.splitArtist(from: raw)
            draftTitle    = c.title ?? t.title
            draftArtist   = primary
            draftFeatured = featured ?? ""
            draftAlbum    = c.albumTitle ?? t.albumTitle
            draftYear     = (c.year ?? t.year).map(String.init) ?? ""
            draftGenre    = c.genre ?? t.genre ?? ""
        }
    }

    // MARK: - Artwork Hero

    private var artworkHero: some View {
        ZStack(alignment: .bottom) {
            // Blurred background
            artworkImage
                .scaledToFill()
                .frame(height: 220)
                .clipped()
                .overlay(Color.black.opacity(0.45))
                .blur(radius: 20)
                .clipped()

            // Crisp artwork thumbnail centred
            artworkImage
                .scaledToFit()
                .frame(width: 140, height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
                .padding(.bottom, 20)
        }
        .frame(height: 220)
    }

    @ViewBuilder
    private var artworkImage: some View {
        if let url = item.candidate.artworkURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img): img.resizable()
                case .failure:          artworkPlaceholder
                default:
                    Color.mixSurface
                        .overlay(ProgressView().tint(Color.mixTextTertiary))
                }
            }
        } else if let data = item.track.artworkData,
                  let ui   = UIImage(data: data) {
            Image(uiImage: ui).resizable()
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
            Text(draftTitle.isEmpty ? "Unknown Title" : draftTitle)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.mixTextPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text(draftArtist.isEmpty ? "Unknown Artist" : draftArtist)
                .font(.system(size: 14))
                .foregroundStyle(Color.mixPrimary)
                .lineLimit(1)
            Text(draftAlbum.isEmpty ? "" : draftAlbum)
                .font(.system(size: 13))
                .foregroundStyle(Color.mixTextSecondary)
                .lineLimit(1)
            // Confidence badge — shown inline under album so it always has room
            confidenceBadge
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    // MARK: - Editable Fields

    private var fieldsSection: some View {
        VStack(spacing: 0) {
            reviewField("Title",    text: $draftTitle,    keyboard: .default)
            divider
            // Artist = primary / folder; Featured = collaborator after the separator
            reviewField("Artist",   text: $draftArtist,   keyboard: .default)
            divider
            featuredRow
            divider
            reviewField("Album",    text: $draftAlbum,    keyboard: .default)
            divider
            reviewField("Year",     text: $draftYear,     keyboard: .numberPad)
            divider
            reviewField("Genre",    text: $draftGenre,    keyboard: .default)
        }
        .background(Color.mixSurface, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }

    /// Featured artist row. Leave empty if the track has no feature.
    /// The track is always filed under the Artist field above.
    private var featuredRow: some View {
        HStack(spacing: 12) {
            Text("Featured")
                .font(.system(size: 13))
                .foregroundStyle(Color.mixTextSecondary)
                .frame(width: 70, alignment: .leading)
            TextField("Collaborating artist(s)", text: $draftFeatured)
                .font(.system(size: 14))
                .foregroundStyle(Color.mixTextPrimary)
                .autocorrectionDisabled()
            if !draftFeatured.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 9))
                    Text("ft.")
                        .font(.system(size: 9, weight: .medium))
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
                .font(.system(size: 13))
                .foregroundStyle(Color.mixTextSecondary)
                .frame(width: 50, alignment: .leading)
            TextField(label, text: text)
                .font(.system(size: 14))
                .foregroundStyle(Color.mixTextPrimary)
                .keyboardType(keyboard)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Confidence Badge

    private var confidenceBadge: some View {
        let (label, color): (String, Color) = {
            switch item.candidate.confidence {
            case 0.7...: return ("High confidence",   .green)
            case 0.4...: return ("Medium confidence", .yellow)
            default:     return ("Low confidence",    .orange)
            }
        }()
        let sourceLabel: String = {
            switch item.candidate.source {
            case .itunes:           return "iTunes · \(label)"
            case .filenameOnly:     return "Filename only"
            case .existingMetadata: return "Your existing tags"
            }
        }()
        return HStack(spacing: 4) {
            if item.candidate.source == .itunes {
                Image(systemName: "music.note").font(.system(size: 9))
            }
            Text(sourceLabel)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.15), in: Capsule())
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button("Skip") {
                appState.dequeueReview()
            }
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(Color.mixTextSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.mixSurface, in: RoundedRectangle(cornerRadius: 12))

            Button {
                applyChanges()
            } label: {
                Group {
                    if isApplying {
                        ProgressView().tint(.white)
                    } else {
                        Text("Apply Changes")
                            .font(.system(size: 16, weight: .semibold))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .background(Color.mixPrimary, in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(.white)
            .disabled(isApplying)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Apply

    private func applyChanges() {
        isApplying = true
        let trackID    = item.track.id
        let artworkURL = item.candidate.artworkURL
        let title      = draftTitle
        // Recombine primary + featured into the stored artist string.
        // The track is always filed under `primary` (passed as primaryArtistOverride).
        let primary    = draftArtist.trimmingCharacters(in: .whitespaces)
        let featured   = draftFeatured.trimmingCharacters(in: .whitespaces)
        let fullArtist = featured.isEmpty ? primary : "\(primary) ft. \(featured)"
        let album      = draftAlbum
        let year       = Int(draftYear)
        let genre      = draftGenre.isEmpty ? nil : draftGenre

        Task {
            await deps.importService.applyEnrichment(
                trackID:               trackID,
                title:                 title,
                artistName:            fullArtist,
                albumTitle:            album,
                year:                  year,
                genre:                 genre,
                artworkURL:            artworkURL,
                artistImageURL:        item.candidate.artistImageURL,
                primaryArtistOverride: primary.isEmpty ? nil : primary
            )
            await MainActor.run {
                isApplying = false
                appState.dequeueReview()
            }
        }
    }
}
#endif

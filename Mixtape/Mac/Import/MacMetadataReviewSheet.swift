// MacMetadataReviewSheet.swift
// Mixtape — Mac/Import
//
// Sheet shown after importing a track when the enrichment service finds
// a metadata candidate. The user can review/edit the proposed values,
// then Apply (downloads artwork + writes tags) or Skip.

#if os(macOS)
import SwiftUI

struct MacMetadataReviewSheet: View {

    let item: MetadataReviewItem

    @EnvironmentObject private var deps:     AppDependencies
    @EnvironmentObject private var appState: MacAppState

    // Editable draft — pre-filled from the candidate (fallback to existing track values)
    @State private var draftTitle:    String
    /// Primary artist only — the track is filed under this artist folder.
    @State private var draftArtist:   String
    /// Featured/collaborating artist (everything after the & / ft. / feat. separator).
    /// Empty when the track has no feature. Combined back with draftArtist on Apply.
    @State private var draftFeatured: String
    @State private var draftAlbum:    String
    @State private var draftYear:     String
    @State private var draftGenre:    String

    @State private var isApplying = false

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
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 20) {
                    artworkAndSummary
                    Divider()
                    editableFields
                }
                .padding(20)
            }
            Divider()
            actionBar
        }
        .frame(width: 480)
        .background(Color.mixBackground)
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

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Review Metadata")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.mixTextPrimary)
            Spacer()
            confidenceBadge
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var confidenceBadge: some View {
        let (label, color): (String, Color) = {
            switch item.candidate.confidence {
            case 0.7...: return ("High confidence", Color.mixSuccess)
            case 0.4...: return ("Medium confidence", Color.mixWarning)
            default:     return ("Low confidence", Color.mixDestructive)
            }
        }()
        let sourceLabel: String = {
            switch item.candidate.source {
            case .itunes:           return "iTunes · \(label)"
            case .filenameOnly:     return "Filename only"
            case .existingMetadata: return "Your existing tags"
            }
        }()
        return HStack(spacing: 5) {
            if item.candidate.source == .itunes {
                Image(systemName: "music.note")
                    .font(.system(size: 9))
            }
            Text(sourceLabel)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.12), in: Capsule())
    }

    // MARK: - Artwork + Summary

    private var artworkAndSummary: some View {
        HStack(alignment: .top, spacing: 14) {
            artworkPreview
                .frame(width: 100, height: 100)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.3), radius: 6, y: 3)

            VStack(alignment: .leading, spacing: 4) {
                Text(draftTitle.isEmpty ? "Unknown Title" : draftTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.mixTextPrimary)
                    .lineLimit(2)
                Text(draftArtist.isEmpty ? "Unknown Artist" : draftArtist)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mixPrimary)
                    .lineLimit(1)
                Text(draftAlbum.isEmpty ? "Unknown Album" : draftAlbum)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mixTextSecondary)
                    .lineLimit(1)
                if !draftYear.isEmpty {
                    Text(draftYear)
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

    @ViewBuilder
    private var artworkPreview: some View {
        if let url = item.candidate.artworkURL {
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
        } else if let data = item.track.artworkData, let img = NSImage(data: data) {
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
            reviewField("Title",  value: $draftTitle)
            Divider().padding(.horizontal, 2)
            // Artist = primary artist / folder; Featured = collaborator after the separator
            reviewField("Artist", value: $draftArtist)
            Divider().padding(.horizontal, 2)
            featuredRow
            Divider().padding(.horizontal, 2)
            reviewField("Album",  value: $draftAlbum)
            Divider().padding(.horizontal, 2)
            reviewField("Year",   value: $draftYear)
            Divider().padding(.horizontal, 2)
            reviewField("Genre",  value: $draftGenre)
        }
        .background(Color.mixSurface, in: RoundedRectangle(cornerRadius: 8))
    }

    /// Featured artist row — pre-split from the raw artist string.
    /// Leave empty if no feature. The track is always filed under "Artist" above.
    private var featuredRow: some View {
        HStack(spacing: 12) {
            Text("Featured")
                .font(.system(size: 12))
                .foregroundStyle(Color.mixTextSecondary)
                .frame(width: 48, alignment: .leading)
            TextField("Collaborating artist(s)", text: $draftFeatured)
                .font(.system(size: 12))
                .textFieldStyle(.plain)
                .foregroundStyle(Color.mixTextPrimary)
            if !draftFeatured.isEmpty {
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

    private var actionBar: some View {
        HStack {
            // Progress counter shown when reviewing a batch
            if appState.batchTotal > 1 {
                Text("\(appState.currentItemNumber) of \(appState.batchTotal)")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.mixTextTertiary)
            }
            Spacer()
            Button("Skip") {
                appState.dequeueReview()
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(.escape, modifiers: [])

            Button {
                applyChanges()
            } label: {
                if isApplying {
                    ProgressView().scaleEffect(0.7).frame(width: 16, height: 16)
                } else {
                    Text("Apply Changes")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.mixPrimary)
            .disabled(isApplying)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Apply

    private func applyChanges() {
        isApplying = true
        let trackID    = item.track.id
        let artworkURL = item.candidate.artworkURL
        let title      = draftTitle
        // Recombine primary + featured into the stored artist string.
        // The track is always filed under `draftArtist` (passed as primaryArtistOverride).
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

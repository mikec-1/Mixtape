// MacEmptyLibraryView.swift
// Mixtape — Mac/Shared
//
// Empty-state view shown when a library section has no content.

#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers

enum MacEmptyContext {
    case songs
    case albums
    case artists
    case playlists

    var systemImage: String {
        switch self {
        case .songs:     return "music.note"
        case .albums:    return "square.stack"
        case .artists:   return "music.mic"
        case .playlists: return "music.note.list"
        }
    }

    var heading: String {
        switch self {
        case .songs:     return "No Songs Yet"
        case .albums:    return "No Albums Yet"
        case .artists:   return "No Artists Yet"
        case .playlists: return "No Playlists Yet"
        }
    }

    var subheading: String {
        switch self {
        case .songs:     return "Import music using the + button above to get started."
        case .albums:    return "Import some tracks and albums will appear here automatically."
        case .artists:   return "Import some tracks and artists will appear here automatically."
        case .playlists: return "Click + in the toolbar to create your first playlist."
        }
    }
}

struct MacEmptyLibraryView: View {
    let context: MacEmptyContext

    @EnvironmentObject private var deps:     AppDependencies
    @EnvironmentObject private var appState: MacAppState
    @State private var isImporting = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: context.systemImage)
                .font(.system(size: 52))
                .foregroundStyle(Color.mixPrimary.opacity(0.5))

            VStack(spacing: 8) {
                Text(context.heading)
                    .font(.title2).fontWeight(.semibold)
                    .foregroundStyle(Color.mixTextPrimary)
                Text(context.subheading)
                    .font(.callout)
                    .foregroundStyle(Color.mixTextSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }

            if context == .songs {
                Button("Import Music…") {
                    isImporting = true
                }
                .buttonStyle(.borderedProminent).mixHandCursor()
                .tint(Color.mixPrimary)
                .controlSize(.large)
                .fileImporter(
                    isPresented: $isImporting,
                    allowedContentTypes: [.audio, .mp3, .mpeg4Audio, .aiff, .wav],
                    allowsMultipleSelection: true
                ) { result in
                    guard case .success(let urls) = result else { return }
                    Task { @MainActor in
                        for url in urls {
                            let r = await deps.importService.importTrack(from: url)
                            if case .imported(_, let review) = r {
                                appState.enqueueReview(review)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.mixBackground)
    }
}

// MARK: - Shared Artwork View

/// Reusable artwork thumbnail — shows a music-note placeholder when artworkData is nil.
struct MacArtworkView: View {
    let data:         Data?
    /// The row this cover belongs to, for rows whose blob the bulk fetch
    /// skipped. Consulted only when `data` is nil — see `ArtworkProvider`.
    var artworkRef:   ArtworkRef? = nil

    let size:         CGFloat?   // nil = fills available space
    let cornerRadius: CGFloat

    var body: some View {
        Group {
            // Bytes in hand draw now; a row identity is resolved and decoded
            // off the render path — see `AsyncArtworkImage`.
            if let data, !data.isEmpty, let img = mixImage(from: data, displaySize: size) {
                img
                    .resizable()
                    .scaledToFill()
            } else if let artworkRef {
                AsyncArtworkImage(source: .row(artworkRef), size: size) {
                    artworkPlaceholder
                }
            } else {
                artworkPlaceholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .background(Color.mixSurface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var artworkPlaceholder: some View {
        ZStack {
            Color.mixSurface
            Image(systemName: "music.note")
                .font(.system(size: max(10, (size ?? 40) * 0.35)))
                .foregroundStyle(Color.mixTextTertiary)
        }
    }
}

#endif

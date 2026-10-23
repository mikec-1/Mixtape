// Posts an edit to the community: a title, a caption and a cover, which starts as the song's own.

import SwiftUI

struct PostSheet: View {
    let track: Track
    /// Opens the post once it's up, by its share code.
    let onOpen: (String) -> Void

    @Environment(AppDependencies.self) private var deps
    @Environment(\.dismiss) private var dismiss

    @State private var artwork: Data?
    @State private var title = ""
    @State private var caption = ""
    @State private var posting = false
    @State private var problem: String?
    @State private var code: String?
    @State private var loaded = false
    /// Started on open so it's usually done by the time Post is pressed.
    @State private var shape: Task<String?, Never>?

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        MixSheet(title: "Post Song",
                 subtitle: track.edit?.isStudio == true
                    ? "Anyone with the link can play it. Studio edits share their audio file."
                    : "Anyone with the link can play it. Only the edit is shared, never the audio file.",
                 size: .medium,
                 dismissDisabled: posting) {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let code {
                    MixSheetStatus(kind: .success, title: "Posted",
                                   detail: "Anyone with the link can listen, like and comment.")
                    ShareLink(item: MixtapeLink.post(code)) {
                        Label("Share Link", systemImage: "square.and.arrow.up").font(.mixLabel)
                    }
                    .buttonStyle(.plain).mixHandCursor()
                    .foregroundStyle(Color.mixPrimary)
                } else {
                    fields
                }
                if let problem {
                    MixSheetStatus(kind: .failure, title: problem)
                }
            }
        } footer: {
            if let code {
                MixSheetActions(primary: MixSheetAction("Open Post") { dismiss(); onOpen(code) },
                                cancelTitle: "Done")
            } else {
                MixSheetActions(primary: MixSheetAction("Post", isEnabled: !trimmedTitle.isEmpty,
                                                        isBusy: posting, action: post))
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            title = track.title
            artwork = track.displayArtwork
            shape = Task { [deps, track] in await deps.postWaveform(of: track) }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ArtworkPickerView(data: $artwork, size: 88, cornerRadius: 8,
                              showsRemoveBadge: artwork != nil && code == nil,
                              onRemove: { artwork = nil }) {
                Image(systemName: MixtapeIcons.track)
                    .font(.system(size: 28))
                    .foregroundStyle(Color.mixTextSecondary)
            }
            .disabled(code != nil || posting)
            .accessibilityLabel("Cover")
            VStack(alignment: .leading, spacing: 2) {
                Text(track.displayTitle)
                    .font(.mixBody.weight(.semibold))
                    .foregroundStyle(Color.mixTextPrimary)
                Text(track.edit?.label ?? track.artistName)
                    .font(.mixCaption)
                    .foregroundStyle(Color.mixTextSecondary)
            }
            .lineLimit(1)
        }
    }

    @ViewBuilder
    private var fields: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Title").font(.mixLabel).foregroundStyle(Color.mixTextSecondary)
            TextField("Title", text: Binding(get: { title }, set: { title = String($0.prefix(200)) }))
                .mixSheetField()
        }
        VStack(alignment: .leading, spacing: 6) {
            Text("Caption").font(.mixLabel).foregroundStyle(Color.mixTextSecondary)
            TextField("Optional", text: Binding(get: { caption }, set: { caption = String($0.prefix(2000)) }),
                      axis: .vertical)
                .lineLimit(3...6)
                .mixSheetField()
        }
        .disabled(posting)
    }

    private func post() {
        guard !posting, !trimmedTitle.isEmpty, let recipe = track.edit else { return }
        posting = true
        problem = nil
        Task {
            defer { posting = false }
            do {
                let original = deps.editOriginal(of: recipe, editDuration: track.duration)
                let audio = recipe.isStudio ? try await deps.downloadManager.localAudio(for: track) : nil
                defer { if let scratch = audio?.scratch { try? FileManager.default.removeItem(at: scratch) } }
                let result = try await deps.community.create(
                    edit: track, original: original, title: trimmedTitle,
                    caption: caption.trimmingCharacters(in: .whitespacesAndNewlines), artwork: artwork,
                    waveform: await shape?.value, audio: audio?.url)
                code = result.code
                if result.artworkFailed { problem = "Posted, but the cover didn\u{2019}t upload." }
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

extension AppDependencies {
    /// A post's waveform from the edit's audio, got the way the editor gets it. Nil if there's none.
    func postWaveform(of track: Track) async -> String? {
        guard let audio = try? await downloadManager.localAudio(for: track) else { return nil }
        defer { if let scratch = audio.scratch { try? FileManager.default.removeItem(at: scratch) } }
        return await Waveform.peaks(of: audio.url, count: Waveform.postSlices * 4).map(Waveform.encode)
    }
}

// ArtworkPickerView.swift
// Mixtape — SharedUI/Components
//
// The cover-art well: pencil badge in the bottom-right to choose an image, bin
// in the bottom-left to throw the current one away. The cover itself is just a
// picture — pressing it does nothing, so nobody opens a file dialog by trying
// to look at their artwork.
//
// Extracted from PlaylistEditorSheet so the import review sheets get the same
// control rather than a lookalike — three hand-rolled copies is how two of them
// end up drifting apart.
//
// `data` is the *user's* pick and nothing else. A caller that already has an
// image to show — an import candidate's remote cover, the track's embedded art —
// draws it in `placeholder` and passes `showsRemoveBadge: true`, which is what
// keeps "the user hasn't touched this" distinct from "there is no image".

#if os(iOS)
import PhotosUI
#endif
import SwiftUI
import UniformTypeIdentifiers

struct ArtworkPickerView<Placeholder: View>: View {

    @Binding var data: Data?

    let size: CGFloat
    var cornerRadius: CGFloat = 8

    /// Whether the bin is offered. Not derived from `data`: the caller knows
    /// whether its placeholder is a real cover or an empty square, and a bin
    /// next to an empty square is a button that can't do anything.
    let showsRemoveBadge: Bool

    let onRemove: () -> Void

    @ViewBuilder let placeholder: () -> Placeholder

    #if os(iOS)
    @State private var photoItem: PhotosPickerItem?
    #elseif os(macOS)
    @State private var showFilePicker = false
    #endif

    var body: some View {
        ZStack {
            artworkSquare

            // Both badges are siblings of the cover, never children of it. The
            // square isn't a control any more, so neither badge is nested in
            // another target that could swallow its taps.
            if showsRemoveBadge { removeBadge }
            editBadge
        }
        .frame(width: size, height: size)
        #if os(iOS)
        .onChange(of: photoItem) { _, item in
            Task {
                if let picked = try? await item?.loadTransferable(type: Data.self) {
                    data = Self.normalised(picked)
                }
            }
        }
        #elseif os(macOS)
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            // Not a guard: `startAccessingSecurityScopedResource` returns false
            // for a URL that needs no scope — which is most of what the file
            // importer hands back — and bailing on that made the picker do
            // nothing at all for perfectly readable files. Balance the call
            // only when it actually granted something.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                data = Self.normalised(try Data(contentsOf: url))
            } catch {
                print("[Artwork] Could not read \(url.lastPathComponent): \(error)")
            }
        }
        #endif
    }

    // MARK: - Sizing

    /// The longest edge a stored cover is allowed to have.
    ///
    /// A cover is never drawn larger than a page header, and a photo out of a
    /// phone library is several thousand pixels on a side. Keeping the original
    /// would put megabytes into the row, into every sync push, and into the
    /// artwork cache on every device that pulls it — for pixels nothing ever
    /// displays.
    /// 1024 was too small: a cover fills most of the width of a phone screen,
    /// and at 3x that alone is over a thousand pixels before the hero blur
    /// behind it is scaled up. 2048 still turns a 12MB photo into a couple of
    /// hundred kilobytes.
    private static var maxCoverEdge: CGFloat { 2048 }

    /// Shrinks and re-encodes a picked image, keeping the original only if it
    /// can't be decoded at all — better a large cover than no cover.
    static func normalised(_ picked: Data) -> Data {
        ImageDownsampler.downsampledJPEG(from: picked,
                                         maxDimension: maxCoverEdge,
                                         compressionQuality: 0.8) ?? picked
    }

    // MARK: - Cover

    /// Inert. No `contentShape`, no button around it — the badges are the
    /// controls, and a cover you can't press is the point of the layout.
    private var artworkSquare: some View {
        Group {
            if let data, let img = mixImage(from: data, displaySize: size) {
                img.resizable().scaledToFill()
            } else {
                placeholder()
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .allowsHitTesting(false)
    }

    // MARK: - Edit badge

    /// Bottom-right, mirroring the bin. The pencil is `MixtapeIcons.edit`
    /// everywhere else in the app, so it's what "change this" looks like here.
    private var editBadge: some View {
        corner(.trailing) {
            #if os(iOS)
            PhotosPicker(selection: $photoItem, matching: .images) {
                badgeLabel(MixtapeIcons.edit, tint: .black.opacity(0.55))
            }
            .buttonStyle(.plain).mixHandCursor()
            #elseif os(macOS)
            Button { showFilePicker = true } label: {
                badgeLabel(MixtapeIcons.edit, tint: .black.opacity(0.55))
            }
            .buttonStyle(.plain).mixHandCursor()
            #endif
        }
        .help("Change cover")
        .accessibilityLabel("Change cover")
    }

    // MARK: - Remove badge

    /// Mirrors the edit badge across the cover, bottom-left. Red because this
    /// is the one control here that throws something away.
    private var removeBadge: some View {
        corner(.leading) {
            Button {
                data = nil
                #if os(iOS)
                // Otherwise re-picking the same photo is a no-op: the
                // selection hasn't changed, so `onChange` never fires and
                // the cover the user just cleared never comes back.
                photoItem = nil
                #endif
                onRemove()
            } label: {
                badgeLabel(MixtapeIcons.delete, tint: Color.mixDestructive)
            }
            .buttonStyle(.plain).mixHandCursor()
        }
        .help("Remove cover")
        .accessibilityLabel("Remove cover")
    }

    // MARK: - Badge geometry

    /// One definition for both badges — they sit at opposite corners of the
    /// same square, so any difference between them reads as a mistake.
    private func badgeLabel(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 13, height: 13)
            .padding(6)
            .background(tint, in: Circle())
            .padding(6)
            // After the outer padding, so the tap target is bigger than the
            // circle it draws. The badges are now the only way into the
            // picker, and a 25pt target for that on a phone is too mean.
            .contentShape(Circle())
    }

    /// Pins `content` to a bottom corner without making the rest of the square
    /// hit-testable — spacers aren't targets, so the gap stays inert.
    private func corner<Content: View>(_ edge: HorizontalAlignment,
                                       @ViewBuilder content: () -> Content) -> some View {
        VStack {
            Spacer()
            HStack {
                if edge == .trailing { Spacer() }
                content()
                if edge == .leading { Spacer() }
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Convenience

extension ArtworkPickerView where Placeholder == AnyView {

    /// The plain empty-square case: no image behind the picker, so the bin
    /// appears exactly when the user has chosen something.
    static func standard(data: Binding<Data?>,
                         size: CGFloat,
                         cornerRadius: CGFloat = 8) -> ArtworkPickerView<AnyView> {
        ArtworkPickerView<AnyView>(
            data: data,
            size: size,
            cornerRadius: cornerRadius,
            showsRemoveBadge: data.wrappedValue != nil,
            onRemove: {},
            placeholder: {
                AnyView(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.mixSurface2)
                        .overlay(
                            Image(systemName: "music.note")
                                .font(.system(size: size * 0.28))
                                .foregroundStyle(Color.mixTextTertiary)
                        )
                )
            }
        )
    }
}

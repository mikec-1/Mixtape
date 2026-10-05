// Cover-art well: pencil (bottom-right) picks, bin (bottom-left) clears.
// The cover itself isn't tappable. Shared by PlaylistEditorSheet and the import sheets.
// `data` is only the user's pick; callers draw existing art in `placeholder`
// and pass `showsRemoveBadge: true`.

#if os(iOS)
import PhotosUI
#endif
import SwiftUI
import UniformTypeIdentifiers
import OSLog

struct ArtworkPickerView<Placeholder: View>: View {

    @Binding var data: Data?

    let size: CGFloat
    var cornerRadius: CGFloat = 8

    /// Caller decides, since only it knows if the placeholder is a real cover.
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

            // Siblings of the cover so nothing swallows their taps.
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
            // Not a guard: this returns false for URLs that need no scope, which is most of them.
            // Only balance it when it granted access.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                data = Self.normalised(try Data(contentsOf: url))
            } catch {
                MixLog.library.error("[Artwork] Could not read \(url.lastPathComponent): \(error)")
            }
        }
        #endif
    }

    // MARK: - Sizing

    /// Longest edge of a stored cover. Phone photos are huge; 2048 covers a 3x hero
    /// and keeps covers in the hundreds of KB.
    private static var maxCoverEdge: CGFloat { 2048 }

    /// Keeps the original only if it can't be decoded.
    static func normalised(_ picked: Data) -> Data {
        ImageDownsampler.downsampledJPEG(from: picked,
                                         maxDimension: maxCoverEdge,
                                         compressionQuality: 0.8) ?? picked
    }

    // MARK: - Cover

    /// Not a control; the badges are.
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

    /// Pencil is `MixtapeIcons.edit` everywhere.
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

    /// Red: the one destructive control here.
    private var removeBadge: some View {
        corner(.leading) {
            Button {
                data = nil
                #if os(iOS)
                // Reset so re-picking the same photo still fires `onChange`.
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

    /// One style for both badges.
    private func badgeLabel(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 13, height: 13)
            .padding(6)
            .background(tint, in: Circle())
            .padding(6)
            // Hit area bigger than the circle.
            .contentShape(Circle())
    }

    /// Pins `content` to a corner; spacers stay inert.
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

    /// Empty-square case: bin shows once the user picks something.
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

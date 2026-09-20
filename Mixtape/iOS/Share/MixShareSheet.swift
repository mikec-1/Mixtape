// MixShareSheet.swift
// Mixtape — iOS/Share
//
// Mixtape's own share sheet: a preview card of what's being shared on a colour
// taken from its artwork, a row of backgrounds to pick from, and the places to
// send it. Replaces the system activity sheet as the first thing "Share…"
// shows; "More" still opens that for everything not listed here.
//
// Destinations appear only when they can work: Messages when the device can
// text, WhatsApp and Telegram when installed (LSApplicationQueriesSchemes).
// Instagram Stories and Snapchat are absent on purpose — both refuse shares
// without a registered developer app id (Meta app id / Snap Creative Kit).

#if os(iOS)
import SwiftUI
import UIKit
import MessageUI

struct MixShareSheet: View {
    let item: ShareItem
    let deps: AppDependencies
    let close: () -> Void

    @State private var artwork: UIImage?
    @State private var palette: [Color] = []
    @State private var backdrop = 0
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Text("Share \(item.noun)")
                    .font(.headline)
                    .foregroundStyle(Color.mixTextPrimary)
                    .padding(.top, 22)

                ShareCard(item: item, artwork: artwork, colors: colors)
                    .frame(maxWidth: 320)
                    .padding(.horizontal, 36)
                    .mixAnimation(.easeInOut(duration: 0.25), value: backdrop)

                backdropPicker
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 12)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom, spacing: 0) { destinations }
        .background {
            LinearGradient(colors: [colors[0].opacity(0.45), Color.mixBackground],
                           startPoint: .top, endPoint: .center)
                .background(Color.mixBackground)
                .ignoresSafeArea()
        }
        .sensoryFeedback(.success, trigger: copied)
        .task { await loadArtwork() }
    }

    // MARK: - Backdrops

    /// Artwork gradient, each artwork colour alone, then graphite.
    private var backdrops: [[Color]] {
        let art = palette.count == 2 ? palette : Self.fallback
        return [art, [art[0], art[0]], [art[1], art[1]], Self.graphite]
    }

    private var colors: [Color] { backdrops[min(backdrop, backdrops.count - 1)] }

    private static let fallback = [Color(hue: 0.72, saturation: 0.42, brightness: 0.42),
                                   Color(hue: 0.62, saturation: 0.48, brightness: 0.2)]
    private static let graphite = [Color(white: 0.24), Color(white: 0.1)]
    private static let backdropNames = ["Artwork gradient", "Artwork colour", "Second artwork colour", "Graphite"]

    private var backdropPicker: some View {
        HStack(spacing: 16) {
            ForEach(backdrops.indices, id: \.self) { index in
                Button { backdrop = index } label: {
                    Circle()
                        .fill(LinearGradient(colors: backdrops[index], startPoint: .top, endPoint: .bottom))
                        .frame(width: 30, height: 30)
                        .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                        .padding(4)
                        .overlay(Circle().strokeBorder(Color.mixTextPrimary,
                                                       lineWidth: backdrop == index ? 2 : 0))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Self.backdropNames[index])
                .accessibilityAddTraits(backdrop == index ? .isSelected : [])
            }
        }
    }

    // MARK: - Destinations

    private var destinations: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 6) {
                DestinationButton(title: copied ? "Copied" : "Copy Link",
                                  systemImage: copied ? "checkmark" : "link",
                                  fill: Color.mixSurface2, foreground: Color.mixTextPrimary) { copyLink() }

                if MFMessageComposeViewController.canSendText() {
                    DestinationButton(title: "Messages", systemImage: "message.fill",
                                      fill: Color(red: 0.2, green: 0.78, blue: 0.35)) { sendMessage() }
                }
                if let whatsapp = appURL("whatsapp://send?text=") {
                    DestinationButton(title: "WhatsApp", systemImage: "phone.bubble.left.fill",
                                      fill: Color(red: 0.15, green: 0.83, blue: 0.4)) { open(whatsapp) }
                }
                if let telegram = appURL("tg://msg_url?url=") {
                    DestinationButton(title: "Telegram", systemImage: "paperplane.fill",
                                      fill: Color(red: 0.16, green: 0.67, blue: 0.93)) { open(telegram) }
                }
                DestinationButton(title: "Share Card", systemImage: "photo.on.rectangle.angled",
                                  fill: Color.mixSurface2, foreground: Color.mixTextPrimary) { shareCard() }
                DestinationButton(title: "More", systemImage: "ellipsis",
                                  fill: Color.mixSurface2, foreground: Color.mixTextPrimary) {
                    presentActivity([item.url])
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)
        }
    }

    // MARK: - Actions

    private func copyLink() {
        copyToClipboard(item.url.absoluteString)
        copied = true
        Task {
            try? await Task.sleep(for: .milliseconds(650))
            close()
            deps.showToast(ShareSheet.copiedMessage)
        }
    }

    /// The app's link with the share URL appended, or nil when the app isn't installed.
    private func appURL(_ prefix: String) -> URL? {
        guard let scheme = URL(string: prefix), UIApplication.shared.canOpenURL(scheme),
              let encoded = item.url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        else { return nil }
        return URL(string: prefix + encoded)
    }

    private func open(_ url: URL) {
        UIApplication.shared.open(url)
        close()
    }

    private func sendMessage() {
        guard let top = ShareSheet.topViewController() else { return }
        let compose = MFMessageComposeViewController()
        compose.body = item.url.absoluteString
        compose.messageComposeDelegate = MessageComposeDismisser.shared
        MessageComposeDismisser.shared.onSent = close
        top.present(compose, animated: true)
    }

    private func shareCard() {
        let renderer = ImageRenderer(content: ShareCard(item: item, artwork: artwork, colors: colors)
            .frame(width: 360)
            .environment(\.colorScheme, .dark))
        renderer.scale = 3
        var items: [Any] = [item.url]
        if let image = renderer.uiImage { items.insert(image, at: 0) }
        presentActivity(items)
    }

    private func presentActivity(_ items: [Any]) {
        guard let top = ShareSheet.topViewController() else { return }
        let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = top.view
        activity.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX,
                                                                    y: top.view.bounds.maxY, width: 0, height: 0)
        top.present(activity, animated: true)
    }

    private func loadArtwork() async {
        let image: UIImage?
        switch item.artwork {
        case .none:
            image = nil
        case .stored(let data, let ref):
            image = ArtworkProvider.resolve(data, ref).flatMap(UIImage.init(data:))
        case .remote(let url):
            image = if let url { await RemoteImageCache.shared.image(for: url) } else { nil }
        case .playlist(let id):
            image = await ArtworkImageLoader.shared.image(for: .playlist(id), bucket: ArtworkDecodeCache.fullSize)
        }
        artwork = image
        palette = ArtworkColors.gradientColors(from: image?.jpegData(compressionQuality: 0.7))
    }
}

// MARK: - Card

/// The preview, and the picture "Share Card" sends — one view so they can't drift.
private struct ShareCard: View {
    let item: ShareItem
    let artwork: UIImage?
    let colors: [Color]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cover
                .padding(.horizontal, item.isRound ? 28 : 0)
                .shadow(color: .black.opacity(0.35), radius: 18, y: 8)

            Text(item.title)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .padding(.top, 20)
            Text(item.subtitle)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)
                .padding(.top, 3)

            Label("Mixtape", systemImage: MixtapeIcons.nowPlaying)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.top, 20)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .background(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var cover: some View {
        Color.white.opacity(0.1)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let artwork {
                    Image(uiImage: artwork).resizable().scaledToFill()
                } else {
                    Image(systemName: item.isRound ? MixtapeIcons.artist : MixtapeIcons.track)
                        .font(.system(size: 56, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .clipShape(item.isRound ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 10, style: .continuous)))
    }
}

// MARK: - Pieces

private struct DestinationButton: View {
    let title: String
    let systemImage: String
    let fill: Color
    var foreground: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(foreground)
                    .frame(width: 58, height: 58)
                    .background(fill, in: Circle())
                    .contentTransition(.symbolEffect(.replace))
                Text(title)
                    .font(.caption)
                    .foregroundStyle(Color.mixTextSecondary)
                    .lineLimit(1)
            }
            .frame(width: 76)
        }
        .buttonStyle(.plain)
    }
}

/// MessageUI wants an NSObject delegate; this one just puts the composer away.
private final class MessageComposeDismisser: NSObject, MFMessageComposeViewControllerDelegate {
    static let shared = MessageComposeDismisser()
    var onSent: (() -> Void)?

    func messageComposeViewController(_ controller: MFMessageComposeViewController,
                                      didFinishWith result: MessageComposeResult) {
        let sent = result == .sent ? onSent : nil
        controller.dismiss(animated: true) { sent?() }
        onSent = nil
    }
}
#endif

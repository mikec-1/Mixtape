// Mixtape's own share sheet: a preview card on a colour from the artwork, background choices, people
// to send it to and destinations. "More" opens the system sheet. Destinations only appear when they can work (Messages,
// installed WhatsApp/Telegram, AirDrop on the Mac). No Instagram Stories or Snapchat: both need a registered developer app id.
// When there's more than one thing to share (a recap's slide, card or link) a picker sits above the preview.

import SwiftUI
import Combine
#if os(iOS)
import UIKit
import MessageUI
#else
import AppKit
#endif

/// One thing the sheet can hand out, named for the picker.
struct ShareChoice {
    let label: String
    let item: ShareItem
    /// A line under the preview, like what sending the link does.
    var note: String? = nil
}

struct MixShareSheet: View {
    let choices: [ShareChoice]
    let deps: AppDependencies
    var dismissed: (() -> Void)? = nil
    let close: () -> Void

    @State private var picked = 0
    @State private var artwork: PlatformImage?
    @State private var palette: [Color] = []
    @State private var backdrop = 0
    @State private var copied = false
    @State private var copiedImage = false
    #if os(iOS)
    /// Held while WhatsApp's "Open in" menu is up; it's dropped the moment nothing owns it.
    @State private var document: UIDocumentInteractionController?
    #endif

    private var item: ShareItem { choices[picked].item }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header

                if choices.count > 1 {
                    Picker("Share", selection: $picked) {
                        ForEach(choices.indices, id: \.self) { Text(choices[$0].label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 300)
                    .padding(.horizontal, 36)
                }

                Group {
                    if item.image != nil {
                        // A picture is its own card.
                        if let artwork {
                            Image(platformImage: artwork)
                                .resizable()
                                .scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
                                .frame(maxHeight: Self.previewHeight)
                                .padding(.horizontal, 36)
                        }
                    } else {
                        ShareCard(item: item, artwork: artwork, colors: colors)
                            .frame(maxWidth: Self.cardWidth)
                            .padding(.horizontal, 36)
                            .mixAnimation(.easeInOut(duration: 0.25), value: backdrop)

                        backdropPicker
                    }
                }
                .id(picked)
                .transition(.opacity)

                if let note = choices[picked].note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(Color.mixTextSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 36)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 12)
            .animation(.easeInOut(duration: 0.2), value: picked)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if deps.authService.currentUser != nil {
                    separator
                    SharePeopleRow(item: item, deps: deps)
                }
                separator
                destinations
            }
            .background(Color.mixBackground)
        }
        .background {
            LinearGradient(colors: [colors[0].opacity(0.45), Color.mixBackground],
                           startPoint: .top, endPoint: .center)
                .background(Color.mixBackground)
                .ignoresSafeArea()
        }
        .sensoryFeedback(.success, trigger: copied)
        .sensoryFeedback(.success, trigger: copiedImage)
        .task(id: picked) { await loadArtwork() }
        .onDisappear { dismissed?() }
        #if os(macOS)
        .frame(width: 460, height: 640)
        .background { MixSheetOutsideClick(dismiss: close) }
        #endif
    }

    #if os(macOS)
    private static let previewHeight: CGFloat = 330
    private static let cardWidth: CGFloat = 250
    #else
    private static let previewHeight: CGFloat = 440
    private static let cardWidth: CGFloat = 320
    #endif

    private var header: some View {
        Text("Share \(item.noun)")
            .font(.headline)
            .foregroundStyle(Color.mixTextPrimary)
            .frame(maxWidth: .infinity)
            #if os(macOS)
            .overlay(alignment: .trailing) {
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: MixSheetMetrics.closeSize))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color.mixTextSecondary)
                        .frame(width: MixSheetMetrics.closeFrame, height: MixSheetMetrics.closeFrame)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).mixHandCursor()
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close")
                .padding(.trailing, 14)
            }
            #endif
            .padding(.top, 22)
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
                .buttonStyle(.plain).mixHandCursor()
                .accessibilityLabel(Self.backdropNames[index])
                .accessibilityAddTraits(backdrop == index ? .isSelected : [])
            }
        }
    }

    private var separator: some View {
        Rectangle().fill(Color.mixSeparator).frame(height: 1).padding(.horizontal, 16)
    }

    // MARK: - Destinations

    private var destinations: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 6) {
                DestinationButton(title: copied ? "Copied" : "Copy Link",
                                  systemImage: copied ? "checkmark" : "link",
                                  fill: Color.mixSurface2, foreground: Color.mixTextPrimary) { copyLink() }
                if item.image != nil {
                    DestinationButton(title: copiedImage ? "Copied" : "Copy Image",
                                      systemImage: copiedImage ? "checkmark" : "photo",
                                      fill: Color.mixSurface2, foreground: Color.mixTextPrimary) { copyImage() }
                }
                platformDestinations
                if item.image == nil {
                    DestinationButton(title: "Share Card", systemImage: "photo.on.rectangle.angled",
                                      fill: Color.mixSurface2, foreground: Color.mixTextPrimary) { shareCard() }
                }
                DestinationButton(title: "More", systemImage: "ellipsis",
                                  fill: Color.mixSurface2, foreground: Color.mixTextPrimary) {
                    linkGoesOut()
                    #if os(iOS)
                    presentActivity(item.image == nil ? [item.url] : [artwork].compactMap { $0 })
                    #else
                    showPicker(systemItems)
                    #endif
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)
        }
    }

    // MARK: - Actions

    /// A private thing's link only opens for others once it's public.
    private func linkGoesOut() {
        if item.image == nil { item.beforeLink?() }
    }

    private func copyLink() {
        item.beforeLink?()
        copyToClipboard(item.url.absoluteString)
        copied = true
        Task {
            try? await Task.sleep(for: .milliseconds(650))
            close()
            deps.showToast(ShareSheet.copiedMessage)
        }
    }

    private func copyImage() {
        guard let data = item.image else { return }
        #if os(iOS)
        UIPasteboard.general.setData(data, forPasteboardType: "public.png")
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: .png)
        #endif
        copiedImage = true
        Task {
            try? await Task.sleep(for: .milliseconds(650))
            close()
            deps.showToast(.done("Image copied to clipboard"))
        }
    }

    private func cardImage() -> PlatformImage? {
        let renderer = ImageRenderer(content: ShareCard(item: item, artwork: artwork, colors: colors)
            .frame(width: 360)
            .environment(\.colorScheme, .dark))
        renderer.scale = 3
        #if os(iOS)
        return renderer.uiImage
        #else
        return renderer.nsImage
        #endif
    }

    private func shareCard() {
        linkGoesOut()
        let items: [Any] = [cardImage() as Any?, item.url].compactMap { $0 }
        #if os(iOS)
        presentActivity(items)
        #else
        showPicker(items)
        #endif
    }

    private func loadArtwork() async {
        if let data = item.image {
            artwork = PlatformImage(data: data)
            return
        }
        let image: PlatformImage?
        switch item.artwork {
        case .none:
            image = nil
        case .stored(let data, let ref):
            image = ArtworkProvider.resolve(data, ref).flatMap(PlatformImage.init(data:))
        case .remote(let url):
            image = if let url { await RemoteImageCache.shared.image(for: url) } else { nil }
        case .playlist(let id):
            image = await ArtworkImageLoader.shared.image(for: .playlist(id), bucket: ArtworkDecodeCache.fullSize)
        }
        artwork = image
        #if os(iOS)
        palette = ArtworkColors.gradientColors(from: image?.jpegData(compressionQuality: 0.7))
        #else
        palette = ArtworkColors.gradientColors(from: image?.tiffRepresentation)
        #endif
    }

    // MARK: - iOS

    #if os(iOS)
    @ViewBuilder private var platformDestinations: some View {
        if MFMessageComposeViewController.canSendText() {
            DestinationButton(title: "Messages", systemImage: "message.fill",
                              fill: Color(red: 0.2, green: 0.78, blue: 0.35)) { sendMessage() }
        }
        if let whatsapp = appURL("whatsapp://send?text=") {
            DestinationButton(title: "WhatsApp", systemImage: "phone.bubble.left.fill",
                              fill: Color(red: 0.15, green: 0.83, blue: 0.4)) {
                item.image == nil ? open(whatsapp) : openInWhatsApp()
            }
        }
        // Telegram's link only carries text; a picture reaches it through More.
        if item.image == nil, let telegram = appURL("tg://msg_url?url=") {
            DestinationButton(title: "Telegram", systemImage: "paperplane.fill",
                              fill: Color(red: 0.16, green: 0.67, blue: 0.93)) { open(telegram) }
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
        linkGoesOut()
        UIApplication.shared.open(url)
        close()
    }

    /// WhatsApp's documented way in for a picture: a .wai file, which only WhatsApp opens.
    private func openInWhatsApp() {
        guard let data = item.image, let top = ShareSheet.topViewController() else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(item.title).wai")
        guard (try? data.write(to: url)) != nil else { return }
        let controller = UIDocumentInteractionController(url: url)
        controller.uti = "net.whatsapp.image"
        document = controller
        let anchor = CGRect(x: top.view.bounds.midX, y: top.view.bounds.maxY, width: 0, height: 0)
        if !controller.presentOpenInMenu(from: anchor, in: top.view, animated: true) {
            presentActivity([artwork].compactMap { $0 })
        }
    }

    private func sendMessage() {
        guard let top = ShareSheet.topViewController() else { return }
        linkGoesOut()
        let compose = MFMessageComposeViewController()
        if let image = item.image {
            compose.addAttachmentData(image, typeIdentifier: "public.png", filename: "\(item.title).png")
        } else {
            compose.body = item.url.absoluteString
        }
        compose.messageComposeDelegate = MessageComposeDismisser.shared
        MessageComposeDismisser.shared.onSent = close
        top.present(compose, animated: true)
    }

    private func presentActivity(_ items: [Any]) {
        guard let top = ShareSheet.topViewController() else { return }
        let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = top.view
        activity.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX,
                                                                    y: top.view.bounds.maxY, width: 0, height: 0)
        top.present(activity, animated: true)
    }
    #endif

    // MARK: - macOS

    #if os(macOS)
    @ViewBuilder private var platformDestinations: some View {
        if let messages = service(.composeMessage) {
            DestinationButton(title: "Messages", systemImage: "message.fill",
                              fill: Color(red: 0.2, green: 0.78, blue: 0.35)) { perform(messages) }
        }
        if let airDrop = service(.sendViaAirDrop) {
            DestinationButton(title: "AirDrop", systemImage: "dot.radiowaves.left.and.right",
                              fill: Color(red: 0.16, green: 0.55, blue: 0.98)) { perform(airDrop) }
        }
        if let mail = service(.composeEmail) {
            DestinationButton(title: "Mail", systemImage: "envelope.fill",
                              fill: Color(red: 0.16, green: 0.6, blue: 0.98)) { perform(mail) }
        }
    }

    /// A picture goes as a file, so it arrives as a photo.
    private var systemItems: [Any] {
        guard let data = item.image else { return [item.url] }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(item.title).png")
        return (try? data.write(to: file)) != nil ? [file] : [item.url]
    }

    private func service(_ name: NSSharingService.Name) -> NSSharingService? {
        guard let service = NSSharingService(named: name), service.canPerform(withItems: [item.url]) else { return nil }
        return service
    }

    /// The sheet stays up: AirDrop and Mail hang their own window off it.
    private func perform(_ service: NSSharingService) {
        linkGoesOut()
        service.perform(withItems: systemItems)
    }

    /// The system picker at the pointer, over this sheet.
    private func showPicker(_ items: [Any]) {
        guard let window = NSApp.keyWindow, let view = window.contentView else { return }
        let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        NSSharingServicePicker(items: items)
            .show(relativeTo: NSRect(origin: point, size: .zero), of: view, preferredEdge: .minY)
    }
    #endif
}

// MARK: - Card

/// The preview and the image "Share Card" sends, one view so they can't drift.
private struct ShareCard: View {
    let item: ShareItem
    let artwork: PlatformImage?
    let colors: [Color]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cover
                .padding(.horizontal, item.isRound ? 28 : 0)
                .shadow(color: .black.opacity(0.35), radius: 18, y: 8)

            Text(item.title)
                .font(.system(size: MixFontScale.size(22), weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .padding(.top, 20)
            Text(item.subtitle)
                .font(.system(size: MixFontScale.size(15), weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)
                .padding(.top, 3)

            Label("Mixtape", systemImage: MixtapeIcons.nowPlaying)
                .font(.system(size: MixFontScale.size(13), weight: .semibold))
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
                    Image(platformImage: artwork).resizable().scaledToFill()
                } else {
                    Image(systemName: item.isRound ? MixtapeIcons.artist : MixtapeIcons.track)
                        .font(.system(size: 56, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .clipShape(item.isRound ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 10, style: .continuous)))
    }
}

// MARK: - People

/// Recent conversations, one tap each. Search reaches anyone else, and is the whole row until
/// there's someone to show.
private struct SharePeopleRow: View {
    let item: ShareItem
    let deps: AppDependencies

    @ObservedObject private var messages = MessagesService.shared
    @State private var sending: Set<UUID> = []
    @State private var sent: Set<UUID> = []

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 6) {
                DestinationButton(title: "Search", systemImage: "magnifyingglass",
                                  fill: Color.mixSurface2, foreground: Color.mixTextPrimary) {
                    if item.image == nil { item.beforeLink?() }
                    ShareSheet.sendTo(item, deps: deps)
                }
                if messages.threads.isEmpty {
                    Text(messages.loaded ? "No one to send to yet. Search for anyone on Mixtape by their username."
                                         : "Loading your conversations\u{2026}")
                        .font(.caption)
                        .foregroundStyle(Color.mixTextSecondary)
                        .frame(width: 220, height: 58, alignment: .leading)
                        .padding(.leading, 6)
                }
                ForEach(messages.threads.prefix(15)) { person($0.profile) }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .task { if !messages.loaded { await messages.refresh() } }
    }

    private func person(_ p: UserProfile) -> some View {
        let done = sent.contains(p.id)
        let busy = sending.contains(p.id)
        return Button { send(to: p) } label: {
            VStack(spacing: 8) {
                AvatarView(url: p.avatarURL, seed: p.username, size: 58)
                    .overlay {
                        if busy || done {
                            Circle().fill(.black.opacity(0.55))
                            if done {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundStyle(.white)
                            } else {
                                ProgressView().tint(.white)
                            }
                        }
                    }
                Text(done ? "Sent" : p.name)
                    .font(.caption)
                    .foregroundStyle(Color.mixTextSecondary)
                    .lineLimit(1)
            }
            .frame(width: 76)
        }
        .buttonStyle(.plain).mixHandCursor()
        .disabled(busy || done)
        .sensoryFeedback(.success, trigger: done)
        .accessibilityLabel(done ? "Sent to \(p.name)" : "Send to \(p.name)")
    }

    private func send(to p: UserProfile) {
        sending.insert(p.id)
        if item.image == nil { item.beforeLink?() }
        Task {
            do {
                try await item.send(to: p)
                sent.insert(p.id)
            } catch {
                deps.showToast(.failed("Couldn't send that. Try again.", error))
            }
            sending.remove(p.id)
        }
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
        .buttonStyle(.plain).mixHandCursor()
    }
}

#if os(iOS)
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

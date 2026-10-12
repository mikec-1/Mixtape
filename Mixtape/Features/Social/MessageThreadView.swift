// One conversation, plus the people pickers behind "New message" and "Send to". On Mac it sits beside
// the conversation list; on iOS it's pushed inside the full-screen Messages cover.

import Supabase
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
#endif

struct MessageThreadView: View {

    let person: UserProfile
    /// Nil leaves View Profile out.
    var openProfile: (() -> Void)? = nil

    @EnvironmentObject private var deps: AppDependencies
    #if os(macOS)
    @EnvironmentObject private var appState: MacAppState
    #else
    @EnvironmentObject private var iosAppState: IOSAppState
    @State private var picked: [PhotosPickerItem] = []
    @State private var publicPlaylist: PublicPlaylistTarget?
    #endif
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @ObservedObject private var sharing = PlaylistSharingService.shared

    /// Oldest first.
    @State private var messages: [MessagesService.Message] = []
    @State private var pending: Set<UUID> = []
    /// Photos on their way up, drawn from the picked bytes.
    @State private var local: [UUID: Data] = [:]
    @State private var loaded = false
    @State private var hasMore = false
    @State private var loadingOlder = false
    @State private var blocked = false
    @State private var confirmBlock = false
    @State private var draft = ""
    @State private var tray: Tray?
    @State private var songQuery = ""
    @State private var songs: [OnlineTrack] = []
    @State private var pickingPhotos = false
    @State private var lightbox: MessagesService.Message?
    @State private var answering: Set<UUID> = []
    @State private var replying: MessagesService.Message?
    @State private var editing: MessagesService.Message?
    /// A reply's quote was tapped: scroll to the original.
    @State private var jump: UUID?
    @State private var typingChannel: RealtimeChannelV2?
    @State private var theyTyping = false
    @State private var typingClear: Task<Void, Never>?
    @State private var typingSentAt = Date.distantPast
    #if os(macOS)
    @State private var hovered: UUID?
    @State private var reacting: UUID?
    #else
    @State private var focused: MessagesService.Message?
    #endif

    private enum Tray { case stickers, songs }

    private var service: MessagesService { .shared }

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            header
            Rectangle().fill(Color.mixSeparator).frame(height: 0.5)
            #endif
            list
            composer
        }
        .background(MixPageBackground())
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { who(size: 32) }
            ToolbarItem(placement: .topBarTrailing) { more }
        }
        .photosPicker(isPresented: $pickingPhotos, selection: $picked,
                      maxSelectionCount: MessagesService.photoLimit, matching: .images)
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            picked = []
            Task {
                var datas: [Data] = []
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self) { datas.append(data) }
                }
                await sendPhotos(datas)
            }
        }
        .navigationDestination(item: $publicPlaylist) { target in
            PublicPlaylistPage(summary: target.summary, ownerName: target.ownerName)
                .environmentObject(deps)
        }
        .fullScreenCover(item: $lightbox) { photoViewer($0) }
        .fullScreenCover(item: $focused) { focusCard($0) }
        #else
        .fileImporter(isPresented: $pickingPhotos, allowedContentTypes: [.image],
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            if urls.count > MessagesService.photoLimit {
                deps.showToast(.failed("Up to \(MessagesService.photoLimit) photos at a time."))
            }
            let datas = urls.prefix(MessagesService.photoLimit).compactMap { url -> Data? in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return try? Data(contentsOf: url)
            }
            Task { await sendPhotos(datas) }
        }
        .overlay { if let lightbox { photoViewer(lightbox) } }
        #endif
        .task(id: person.id) { await load() }
        .task(id: songQuery) { await searchSongs() }
        .task(id: person.id) { await listenForTyping() }
        .onReceive(service.incoming) { received($0) }
        .onReceive(service.updated) { changed in
            if let i = messages.firstIndex(where: { $0.id == changed.id }) { messages[i] = changed }
        }
        .onAppear { service.viewing = person.id }
        .onDisappear { if service.viewing == person.id { service.viewing = nil } }
        // Realtime drops in the background, so catch up on return.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await load() } }
        }
        .onChange(of: draft) { _, text in
            if text.count > 2000 { draft = String(text.prefix(2000)) }
            sayTyping(text)
        }
        .mixConfirmationDialog("Block \(person.name)?", isPresented: $confirmBlock, titleVisibility: .visible) {
            Button("Block", role: .destructive) { Task { await setBlocked(true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Neither of you will be able to message the other, and this conversation leaves your messages. You can unblock them from here.")
        }
    }

    // MARK: Header

    #if os(macOS)
    private var header: some View {
        HStack(spacing: 12) {
            Button { openProfile?() } label: { who(size: 40) }
                .buttonStyle(.plain)
                .mixHandCursor()
                .disabled(openProfile == nil)
                .help("View profile")
            Spacer(minLength: 0)
            more
        }
        .padding(.horizontal, 20)
        .frame(height: 68)
    }
    #endif

    private func who(size: CGFloat) -> some View {
        HStack(spacing: 10) {
            AvatarView(url: person.avatarURL, seed: person.username, size: size)
            VStack(alignment: .leading, spacing: 1) {
                Text(person.name)
                    .font(.mixBodyBold)
                    .foregroundStyle(Color.mixTextPrimary)
                Text("@\(person.username)")
                    .font(.mixCaption)
                    .foregroundStyle(Color.mixTextTertiary)
            }
            .lineLimit(1)
        }
    }

    private var more: some View {
        Menu {
            if let openProfile { Button("View Profile", action: openProfile) }
            if blocked {
                Button("Unblock \(person.name)") { Task { await setBlocked(false) } }
            } else {
                Button("Block \(person.name)", role: .destructive) { confirmBlock = true }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.mixTextSecondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More")
    }

    // MARK: List

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if hasMore {
                        ProgressView()
                            .controlSize(.small)
                            .padding(8)
                            .onAppear { Task { await loadOlder(proxy) } }
                    } else if loaded {
                        intro
                    }
                    ForEach(Array(messages.enumerated()), id: \.element.id) { i, message in
                        row(message, at: i).id(message.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: messages.last?.id) { _, id in
                if let id { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) } }
            }
            .onChange(of: jump) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
                jump = nil
            }
        }
    }

    /// The top of the conversation: who this is, and a way to their profile.
    private var intro: some View {
        VStack(spacing: 4) {
            AvatarView(url: person.avatarURL, seed: person.username, size: 88)
                .padding(.bottom, 6)
            Text(person.name)
                .font(.mixTitle2)
                .foregroundStyle(Color.mixTextPrimary)
            Text("@\(person.username)")
                .font(.mixSubtext)
                .foregroundStyle(Color.mixTextSecondary)
            if let openProfile {
                pill("View Profile", primary: false, action: openProfile)
                    .padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 28)
        .padding(.bottom, 16)
    }

    private func row(_ message: MessagesService.Message, at i: Int) -> some View {
        let mine = message.senderID != person.id
        let previous = i > 0 ? messages[i - 1] : nil
        let next = i + 1 < messages.count ? messages[i + 1] : nil
        let newDay = previous.map { message.createdAt.timeIntervalSince($0.createdAt) > 3600 } ?? true
        let endsRun = next.map { $0.senderID != message.senderID || $0.createdAt.timeIntervalSince(message.createdAt) > 3600 } ?? true
        return VStack(spacing: 2) {
            if newDay {
                Text(Self.dayLabel(message.createdAt))
                    .font(.mixCaption)
                    .foregroundStyle(Color.mixTextTertiary)
                    .padding(.vertical, 10)
            }
            HStack(alignment: .bottom, spacing: 8) {
                if mine {
                    Spacer(minLength: 56)
                } else if endsRun {
                    // Their face sits under the last message of a run.
                    AvatarView(url: person.avatarURL, seed: person.username, size: 28)
                } else {
                    Color.clear.frame(width: 28, height: 1)
                }
                VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
                    if let original = message.replyTo, message.unsentAt == nil { quote(original, mine: mine) }
                    // Sized to the bubble before the width cap, so the reactions hang off the bubble.
                    content(message, mine: mine)
                        .overlay(alignment: mine ? .bottomTrailing : .bottomLeading) { reactions(message) }
                        .padding(.bottom, hasReaction(message) ? 14 : 0)
                        .opacity(pending.contains(message.id) ? 0.55 : 1)
                        #if os(iOS)
                        .onLongPressGesture(minimumDuration: 0.3) { focus(message) }
                        #else
                        .help(message.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .overlay(alignment: mine ? .leading : .trailing) { reactButton(message, mine: mine) }
                        .contextMenu { actions(message, mine: mine) }
                        #endif
                        .frame(maxWidth: 520, alignment: mine ? .trailing : .leading)
                    if message.editedAt != nil, message.unsentAt == nil { note("Edited") }
                    if mine, next == nil, !pending.contains(message.id) {
                        note(message.readAt == nil ? "Sent" : "Read")
                    }
                }
                if !mine { Spacer(minLength: 56) }
            }
            .padding(.bottom, endsRun ? 8 : 0)
            #if os(macOS)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { hovered = message.id } else if hovered == message.id { hovered = nil }
            }
            #endif
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.mixCaption)
            .foregroundStyle(Color.mixTextTertiary)
            .padding(.horizontal, 6)
    }

    // MARK: Replies, reactions, actions

    private func snippet(_ m: MessagesService.Message) -> String {
        if m.unsentAt != nil { return "Unsent message" }
        switch m.kind {
        case .text: return m.body
        case .image: return "Photo"
        case .sticker: return "Sticker"
        case .share: return m.payload?.title ?? "Link"
        case .invite, .dub: return m.payload?.name ?? "Playlist"
        }
    }

    /// The message this one answers, faded above it. Older than the loaded page reads as "an earlier message".
    private func quote(_ id: UUID, mine: Bool) -> some View {
        let original = messages.first { $0.id == id }
        let whose = original.map { $0.senderID == person.id ? person.name : "you" }
        return Button { if original != nil { jump = id } } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(whose.map { "Replying to \($0)" } ?? "Reply")
                    .font(.mixCaption)
                    .foregroundStyle(Color.mixTextTertiary)
                Text(original.map(snippet) ?? "An earlier message")
                    .font(.mixSubtext)
                    .foregroundStyle(Color.mixTextSecondary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.mixSeparator))
            .frame(maxWidth: 360, alignment: mine ? .trailing : .leading)
        }
        .buttonStyle(.plain)
        .mixHandCursor()
    }

    private func hasReaction(_ m: MessagesService.Message) -> Bool {
        m.senderReaction != nil || m.recipientReaction != nil
    }

    private func myReaction(_ m: MessagesService.Message) -> String? {
        m.senderID == person.id ? m.recipientReaction : m.senderReaction
    }

    @ViewBuilder
    private func reactions(_ m: MessagesService.Message) -> some View {
        let both = [m.senderReaction, m.recipientReaction].compactMap { $0 }
        if !both.isEmpty {
            Text(both[0] == both.last && both.count == 2 ? "\(both[0]) 2" : both.joined())
                .font(.system(size: 13))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.mixSurface2, in: Capsule())
                .overlay(Capsule().stroke(Color.mixBackground, lineWidth: 2))
                .padding(.horizontal, 10)
                .offset(y: 16)
                .accessibilityLabel("Reactions: \(both.joined(separator: " "))")
        }
    }

    private func canAct(_ m: MessagesService.Message) -> Bool {
        m.unsentAt == nil && !pending.contains(m.id) && !blocked
    }

    /// Everything but reacting, shared by the Mac menu and the iOS focus card.
    private func messageActions(_ m: MessagesService.Message, mine: Bool) -> [MessageAction] {
        guard canAct(m) else { return [] }
        var list = [MessageAction(title: "Reply", icon: "arrowshape.turn.up.left") { editing = nil; replying = m }]
        if m.kind == .text {
            list.append(MessageAction(title: "Copy", icon: "doc.on.doc") { copyToClipboard(m.body) })
        }
        if mine, m.kind == .text, m.createdAt > .now.addingTimeInterval(-15 * 60) {
            list.append(MessageAction(title: "Edit", icon: "pencil") {
                replying = nil
                editing = m
                draft = m.body
            })
        }
        if mine, [.text, .image, .sticker, .share].contains(m.kind) {
            list.append(MessageAction(title: "Unsend", icon: "arrow.uturn.backward", destructive: true) { unsend(m) })
        }
        return list
    }

    #if os(macOS)
    @ViewBuilder
    private func actions(_ m: MessagesService.Message, mine: Bool) -> some View {
        if canAct(m) {
            let current = myReaction(m)
            Menu {
                ForEach(MessagesService.reactions, id: \.self) { emoji in
                    Button(emoji == current ? "\(emoji) (remove)" : emoji) {
                        react(m, emoji == current ? nil : emoji)
                    }
                }
            } label: { Label("React", systemImage: "face.smiling") }
            ForEach(messageActions(m, mine: mine)) { action in
                Button(role: action.destructive ? .destructive : nil, action: action.run) {
                    Label(action.title, systemImage: action.icon)
                }
            }
        }
    }

    /// Beside the hovered message, like WhatsApp on the desktop.
    @ViewBuilder
    private func reactButton(_ m: MessagesService.Message, mine: Bool) -> some View {
        if canAct(m), hovered == m.id || reacting == m.id {
            Button { reacting = m.id } label: {
                Image(systemName: "face.smiling")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.mixTextSecondary)
                    .frame(width: 28, height: 28)
                    .background(Color.mixSurface2, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .mixHandCursor()
            .help("React")
            .offset(x: mine ? -36 : 36)
            .popover(isPresented: Binding(get: { reacting == m.id }, set: { if !$0 { reacting = nil } }),
                     arrowEdge: .top) {
                ReactionBar(current: myReaction(m)) { emoji in
                    reacting = nil
                    react(m, emoji)
                }
                .padding(4)
            }
        }
    }
    #else
    /// Long press: the message lifts over a blurred thread with reactions above and actions below.
    private func focus(_ m: MessagesService.Message) {
        guard canAct(m) else { return }
        Haptics.play(.medium)
        // The card draws its own fade, so the cover itself appears without a slide.
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { focused = m }
    }

    private func unfocus() {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { focused = nil }
    }

    private func focusCard(_ m: MessagesService.Message) -> some View {
        let mine = m.senderID != person.id
        return MessageFocus(mine: mine, current: myReaction(m), actions: messageActions(m, mine: mine),
                            react: { react(m, $0) }, close: unfocus) {
            content(m, mine: mine)
                .lineLimit(12)
                .frame(maxWidth: 520, alignment: mine ? .trailing : .leading)
        }
    }
    #endif

    private static func dayLabel(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(date) { return "Today \(time)" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday \(time)" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    @ViewBuilder
    private func content(_ m: MessagesService.Message, mine: Bool) -> some View {
        let p = m.payload ?? MessagesService.Payload()
        if m.unsentAt != nil {
            Text(mine ? "You unsent a message" : "\(person.name) unsent a message")
                .font(.mixSubtext.italic())
                .foregroundStyle(Color.mixTextTertiary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.mixSeparator))
        } else {
        switch m.kind {
        case .image:
            photo(m, p)
        case .sticker:
            if let id = p.id, MessagesService.stickers.contains(id) {
                Image("sticker-\(id)")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 112, height: 112)
                    .accessibilityLabel("Sticker")
            } else {
                bubble("Sticker", mine: mine)
            }
        case .share:
            shareCard(p)
        case .invite, .dub:
            VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
                playlistCard(m, p, mine: mine)
                if m.kind == .dub, !m.body.isEmpty { bubble(m.body, mine: mine) }
            }
        case .text:
            bubble(m.body, mine: mine)
        }
        }
    }

    private func bubble(_ text: String, mine: Bool) -> some View {
        Text(MessagesService.linkified(text))
            .font(.mixBody)
            .foregroundStyle(mine ? Color.mixOnAccent : Color.mixTextPrimary)
            .tint(mine ? Color.mixOnAccent : Color.mixAccentFill)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(mine ? Color.mixAccentFill : Color.mixSurface2,
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .accessibilityLabel("\(mine ? "You" : person.name): \(text)")
    }

    private func photo(_ m: MessagesService.Message, _ p: MessagesService.Payload) -> some View {
        let ratio = min(max((p.w ?? 1) / max(p.h ?? 1, 1), 0.5), 2)
        let edge: CGFloat = 260
        return Button { lightbox = m } label: {
            AttachmentImage(path: p.path, data: local[m.id])
                .frame(width: ratio >= 1 ? edge : edge * ratio, height: ratio >= 1 ? edge / ratio : edge)
                .background(Color.mixSurface2)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .mixHandCursor()
        .accessibilityLabel("Photo")
    }

    private func photoViewer(_ m: MessagesService.Message) -> some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(0.9).ignoresSafeArea()
            AttachmentImage(path: m.payload?.path, data: local[m.id], fit: true)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Button { lightbox = nil } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.15), in: Circle())
            }
            .buttonStyle(.plain)
            .mixHandCursor()
            .keyboardShortcut(.cancelAction)
            .padding(16)
            .accessibilityLabel("Close")
        }
        .contentShape(Rectangle())
        .onTapGesture { lightbox = nil }
    }

    // MARK: Cards

    private static let cardLabel = ["song": "Song", "album": "Album", "artist": "Artist", "playlist": "Playlist",
                                    "jam": "Jam invite"]
    private static let cardGlyph = ["song": "music.note", "album": "square.stack", "artist": "music.mic",
                                    "playlist": "music.note.list", "jam": "person.2.wave.2.fill"]

    private func shareCard(_ p: MessagesService.Payload) -> some View {
        let type = p.type ?? "playlist"
        let playable = type == "song" && p.track != nil
        return Button { openShare(p) } label: {
            cardRow(art: art(URL(string: p.artwork ?? ""), path: p.path,
                             glyph: Self.cardGlyph[type] ?? "link", round: p.round == true),
                    label: Self.cardLabel[type] ?? "Link", title: p.title ?? "", subtitle: p.subtitle,
                    playable: playable)
                .dmCard()
        }
        .buttonStyle(.plain)
        .mixHandCursor()
        .accessibilityLabel(playable ? "Play \(p.title ?? "song")" : "Open \(p.title ?? "")")
    }

    private func playlistCard(_ m: MessagesService.Message, _ p: MessagesService.Payload, mine: Bool) -> some View {
        let id = p.sharedPlaylistID
        // Accept and Decline only while the invite is still open.
        let open = !mine && m.kind == .invite && sharing.pendingInvites.contains { $0.id == id }
        return VStack(alignment: .leading, spacing: 10) {
            Button { if let id { Task { await openPlaylist(id, mine: mine) } } } label: {
                cardRow(art: art(p.artworkPath.flatMap(PlaylistSharingService.coverURL(path:)), path: nil,
                                 glyph: "music.note.list", round: false),
                        label: m.kind == .invite ? (mine ? "You invited them" : "Invited you to collaborate") : "Dub",
                        title: p.name ?? "Playlist", subtitle: nil, playable: false)
            }
            .buttonStyle(.plain)
            .mixHandCursor()
            if open, let id {
                HStack(spacing: 8) {
                    pill("Accept", primary: true) { Task { await answer(id, accept: true) } }
                    pill("Decline", primary: false) { Task { await answer(id, accept: false) } }
                }
                .disabled(answering.contains(id))
            }
        }
        .dmCard()
    }

    private func cardRow<Art: View>(art: Art, label: String, title: String, subtitle: String?,
                                    playable: Bool) -> some View {
        HStack(spacing: 12) {
            art.frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.mixCaption)
                    .foregroundStyle(Color.mixTextTertiary)
                Text(title)
                    .font(.mixBodyBold)
                    .foregroundStyle(Color.mixTextPrimary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.mixSubtext)
                        .foregroundStyle(Color.mixTextSecondary)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            if playable {
                Image(systemName: "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.mixOnAccent)
                    .frame(width: 32, height: 32)
                    .background(Color.mixAccentFill, in: Circle())
            }
        }
        .contentShape(Rectangle())
    }

    private func art(_ remote: URL?, path: String?, glyph: String, round: Bool) -> some View {
        ZStack {
            Color.mixSeparator
            Image(systemName: glyph)
                .font(.system(size: 18))
                .foregroundStyle(Color.mixTextTertiary)
            if let remote {
                CachedRemoteImage(url: remote) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
            } else if let path {
                AttachmentImage(path: path)
            }
        }
        .clipShape(round ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 8, style: .continuous)))
    }

    private func pill(_ title: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.mixLabel)
                .foregroundStyle(primary ? Color.mixOnAccent : Color.mixTextPrimary)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(primary ? Color.mixAccentFill : Color.mixSeparator, in: Capsule())
        }
        .buttonStyle(.plain)
        .mixHandCursor()
    }

    // MARK: Composer

    private var composer: some View {
        let empty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 8) {
            if blocked {
                Text("You blocked \(person.name). Unblock them to send a message.")
                    .font(.mixSubtext)
                    .foregroundStyle(Color.mixTextSecondary)
            } else if let tray {
                trayView(tray)
            }
            if theyTyping, !blocked {
                HStack(spacing: 6) {
                    Image(systemName: "ellipsis")
                        .symbolEffect(.variableColor.iterative)
                    Text("\(person.name) is typing")
                }
                .font(.mixCaption)
                .foregroundStyle(Color.mixTextTertiary)
                .padding(.leading, 8)
            }
            if !blocked, let context = editing ?? replying {
                HStack(spacing: 8) {
                    Image(systemName: editing != nil ? "pencil" : "arrowshape.turn.up.left")
                        .foregroundStyle(Color.mixTextSecondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(editing != nil ? "Editing" : "Replying to \(context.senderID == person.id ? person.name : "yourself")")
                            .font(.mixCaption)
                            .foregroundStyle(Color.mixTextTertiary)
                        Text(snippet(context))
                            .font(.mixSubtext)
                            .foregroundStyle(Color.mixTextSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button {
                        if editing != nil { draft = "" }
                        editing = nil
                        replying = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.mixTextSecondary)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .mixHandCursor()
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel(editing != nil ? "Cancel edit" : "Cancel reply")
                }
                .padding(.horizontal, 8)
            }
            HStack(alignment: .bottom, spacing: 2) {
                tool("face.smiling", "Stickers", on: tray == .stickers) { toggle(.stickers) }
                tool("photo", "Photos", on: false) { tray = nil; pickingPhotos = true }
                tool("music.note", "Songs", on: tray == .songs) { toggle(.songs) }
                // Return sends on Mac; on iOS it's a new line and the button sends.
                TextField("Message \(person.name)", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .font(.mixBody)
                    .foregroundStyle(Color.mixTextPrimary)
                    .onSubmit(send)
                    .padding(.leading, 6)
                    .padding(.vertical, 8)
                Button(action: send) {
                    Image(systemName: editing != nil ? "checkmark" : "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.mixOnAccent)
                        .frame(width: 32, height: 32)
                        .background(Color.mixAccentFill.opacity(empty ? 0.35 : 1), in: Circle())
                }
                .buttonStyle(.plain)
                .mixHandCursor()
                .disabled(empty)
                .accessibilityLabel(editing != nil ? "Save edit" : "Send")
            }
            .padding(4)
            .background(Color.mixSurface2, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .disabled(blocked)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
    }

    private func tool(_ symbol: String, _ label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(on ? Color.mixTextPrimary : Color.mixTextSecondary)
                .frame(width: 32, height: 32)
                .background(on ? Color.mixSeparator : .clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .mixHandCursor()
        .help(label)
        .accessibilityLabel(label)
    }

    private func toggle(_ next: Tray) {
        tray = tray == next ? nil : next
    }

    @ViewBuilder
    private func trayView(_ tray: Tray) -> some View {
        Group {
            switch tray {
            case .stickers:
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8)], spacing: 8) {
                    ForEach(MessagesService.stickers, id: \.self) { id in
                        Button { sendSticker(id) } label: {
                            Image("sticker-\(id)")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 56, height: 56)
                                .frame(maxWidth: .infinity)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .mixHandCursor()
                        .accessibilityLabel("\(id) sticker")
                    }
                }
            case .songs:
                VStack(spacing: 6) {
                    MixSearchField(text: $songQuery, placeholder: "Search songs", isBusy: false, autoFocus: true)
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(songs) { track in
                                Button { sendSong(track) } label: { songRow(track) }
                                    .buttonStyle(.plain)
                                    .mixHandCursor()
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }
            }
        }
        .padding(10)
        .background(Color.mixSurface2, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func songRow(_ track: OnlineTrack) -> some View {
        HStack(spacing: 10) {
            CachedRemoteImage(url: track.artworkURL) { $0.resizable().scaledToFill() } placeholder: { Color.mixSeparator }
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(track.displayTitle)
                    .font(.mixBody)
                    .foregroundStyle(Color.mixTextPrimary)
                Text(track.displayArtistName)
                    .font(.mixSubtext)
                    .foregroundStyle(Color.mixTextSecondary)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "paperplane")
                .foregroundStyle(Color.mixTextTertiary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    // MARK: Loading

    /// Page 1, merged in, so it doubles as the catch-up after a return to the foreground.
    private func load() async {
        async let page = try? service.messages(with: person.id, before: nil)
        async let isOff = service.isBlocked(person.id)
        let (fetched, off) = await (page, isOff)
        blocked = off
        if let fetched {
            if !loaded { hasMore = fetched.count == MessagesService.pageSize }
            merge(fetched)
            // A send whose reply never came back is still on the server if the page has it.
            pending.subtract(fetched.map(\.id))
            if fetched.contains(where: { $0.kind == .invite && $0.senderID == person.id }) {
                await sharing.refreshPendingInvites()
            }
        }
        loaded = true
        await service.markRead(person.id)
    }

    private func loadOlder(_ proxy: ScrollViewProxy) async {
        guard hasMore, !loadingOlder, let first = messages.first else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        guard let page = try? await service.messages(with: person.id, before: first.createdAt) else { return }
        hasMore = page.count == MessagesService.pageSize
        merge(page)
        // Keep the message that was on top where it was.
        proxy.scrollTo(first.id, anchor: .top)
    }

    private func merge(_ page: [MessagesService.Message]) {
        let have = Set(messages.map(\.id))
        messages = (messages + page.filter { !have.contains($0.id) }).sorted { $0.createdAt < $1.createdAt }
    }

    /// Realtime rows for every thread. Nobody messages themselves, so either end being them is enough.
    private func received(_ message: MessagesService.Message) {
        guard message.senderID == person.id || message.recipientID == person.id else { return }
        if let i = messages.firstIndex(where: { $0.id == message.id }) {
            // Our own send echoing back: take the server's copy.
            messages[i] = message
            pending.remove(message.id)
            return
        }
        messages.append(message)
        guard message.senderID == person.id else { return }
        theyTyping = false
        Task { await service.markRead(person.id) }
        if message.kind == .invite { Task { await sharing.refreshPendingInvites() } }
    }

    private func searchSongs() async {
        let query = songQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { songs = []; return }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        let results = await deps.itunesClient.searchPopular(query: query, limit: 8)
        guard !Task.isCancelled else { return }
        songs = results.map {
            OnlineTrack(title: $0.trackName, artistName: $0.artistName, albumTitle: $0.collectionName ?? "",
                        duration: $0.trackTimeMillis.map { TimeInterval($0) / 1000 } ?? 0,
                        artworkURL: $0.artworkUrl100.flatMap { URL(string: $0) },
                        sourceID: $0.sourceID, isExplicit: $0.isExplicit)
        }
    }

    // MARK: Sending

    /// The bubble shows at once, dims until the server has it, and goes if it fails.
    private func post(_ kind: MessagesService.Kind, body: String = "", payload: MessagesService.Payload? = nil,
                      id: UUID = UUID(), replyTo: UUID? = nil,
                      _ work: @escaping (UUID) async throws -> MessagesService.Payload?) {
        guard !blocked, let me = deps.authService.currentUser?.id else { return }
        var message = MessagesService.Message(id: id, senderID: me, recipientID: person.id,
                                              body: body, createdAt: .now)
        message.kind = kind
        message.payload = payload
        message.replyTo = replyTo
        messages.append(message)
        pending.insert(id)
        Task {
            do {
                if let sent = try await work(id), let i = messages.firstIndex(where: { $0.id == id }) {
                    messages[i].payload = sent
                }
            } catch {
                messages.removeAll { $0.id == id }
                local[id] = nil
                if kind == .text, draft.isEmpty { draft = body }
                deps.showToast(.failed(kind == .image ? "Couldn't send that photo." : "Couldn't send that message.", error))
            }
            pending.remove(id)
        }
    }

    private func send() {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        draft = ""
        if let editing {
            self.editing = nil
            if body != editing.body { saveEdit(editing, body) }
            return
        }
        let replyTo = replying?.id
        replying = nil
        typingSentAt = .distantPast
        post(.text, body: body, replyTo: replyTo) { id in
            try await service.send(id: id, to: person.id, body: body, replyTo: replyTo)
            return nil
        }
    }

    /// The row changes at once and goes back if the server says no.
    private func change(_ m: MessagesService.Message, failure: String,
                        _ apply: (inout MessagesService.Message) -> Void, _ work: @escaping () async throws -> Void) {
        guard let i = messages.firstIndex(where: { $0.id == m.id }) else { return }
        let before = messages[i]
        apply(&messages[i])
        Task {
            do { try await work() } catch {
                if let i = messages.firstIndex(where: { $0.id == m.id }) { messages[i] = before }
                deps.showToast(.failed(failure, error))
            }
        }
    }

    private func saveEdit(_ m: MessagesService.Message, _ body: String) {
        change(m, failure: "That message can no longer be edited.", {
            $0.body = body
            $0.editedAt = .now
        }) { try await service.edit(m.id, body: body) }
    }

    private func unsend(_ m: MessagesService.Message) {
        if replying?.id == m.id { replying = nil }
        if editing?.id == m.id { editing = nil; draft = "" }
        change(m, failure: "Couldn't unsend that message.", {
            $0.unsentAt = .now
            $0.body = ""
            $0.payload = nil
            $0.senderReaction = nil
            $0.recipientReaction = nil
        }) { try await service.unsend(m.id) }
    }

    private func react(_ m: MessagesService.Message, _ emoji: String?) {
        let theirs = m.senderID == person.id
        change(m, failure: "Couldn't react to that.", {
            if theirs { $0.recipientReaction = emoji } else { $0.senderReaction = emoji }
        }) { try await service.react(m.id, emoji) }
    }

    // MARK: Typing

    /// Their "typing" pings keep the line up for 5 seconds, ours go out at most every 3.
    private func listenForTyping() async {
        guard let channel = await service.pairChannel(with: person.id) else { return }
        let pings = channel.broadcastStream(event: "typing")
        do { try await SupabaseConfig.client.joinWithDeadline(channel) } catch {
            await SupabaseConfig.client.removeChannel(channel)
            return
        }
        typingChannel = channel
        let me = deps.authService.currentUser?.id.uuidString.lowercased()
        for await ping in pings {
            // Your own other devices share the channel.
            guard ping["payload"]?.objectValue?["from"]?.stringValue != me else { continue }
            theyTyping = true
            typingClear?.cancel()
            typingClear = Task {
                try? await Task.sleep(for: .seconds(5))
                if !Task.isCancelled { theyTyping = false }
            }
        }
        typingChannel = nil
        theyTyping = false
        await SupabaseConfig.client.removeChannel(channel)
    }

    private func sayTyping(_ text: String) {
        guard editing == nil, !text.isEmpty, let channel = typingChannel,
              Date.now.timeIntervalSince(typingSentAt) > 3,
              let me = deps.authService.currentUser?.id.uuidString.lowercased() else { return }
        typingSentAt = .now
        Task { try? await channel.broadcast(event: "typing", message: ["from": me]) }
    }

    private func sendSticker(_ sticker: String) {
        tray = nil
        var payload = MessagesService.Payload()
        payload.id = sticker
        post(.sticker, payload: payload) { id in
            try await service.send(id: id, to: person.id, kind: .sticker, payload: payload)
            return nil
        }
    }

    private func sendSong(_ track: OnlineTrack) {
        tray = nil
        songQuery = ""
        Task {
            let (card, cover) = await ShareItem.track(track).messageCard()
            post(.share, payload: card) { id in
                try await service.sendShare(id: id, to: person.id, card: card, cover: cover)
            }
        }
    }

    private func sendPhotos(_ datas: [Data]) async {
        for data in datas.prefix(MessagesService.photoLimit) {
            guard let photo = await MessagesService.preparePhoto(data) else {
                deps.showToast(.failed("Couldn't send that photo. GIFs can be up to 10 MB."))
                continue
            }
            var payload = MessagesService.Payload()
            payload.w = photo.width
            payload.h = photo.height
            let id = UUID()
            local[id] = photo.data
            post(.image, payload: payload, id: id) { id in
                try await service.sendPhoto(id: id, to: person.id, photo: photo)
            }
        }
    }

    private func setBlocked(_ next: Bool) async {
        do {
            try await service.setBlocked(person.id, next)
            blocked = next
            deps.showToast(.done(next ? "Blocked \(person.name)." : "Unblocked \(person.name)."))
        } catch {
            deps.showToast(.failed("Couldn't change that.", error))
        }
    }

    // MARK: Opening cards

    private func openShare(_ p: MessagesService.Payload) {
        let title = p.title ?? ""
        switch p.type {
        case "song":
            if let track = p.track { Task { await deps.onlineCoordinator.play(track) } }
        case "artist":
            #if os(macOS)
            appState.showOnlineArtist(name: title, trackID: nil)
            #else
            iosAppState.openOnlineArtist(name: title)
            #endif
        case "album":
            #if os(macOS)
            appState.showOnlineAlbum(title: title, artistName: p.subtitle ?? "", trackID: nil)
            #else
            iosAppState.openOnlineAlbum(title: title, artistName: p.subtitle ?? "")
            #endif
        case "jam":
            guard let url = p.url.flatMap(URL.init(string:)),
                  let code = RootView.inviteCode(from: url, kind: "jam") else { return }
            Task { await deps.jam.join(code: code) }
        default:
            guard let url = p.url.flatMap(URL.init(string:)) else { return }
            Task {
                guard let target = await InAppLink.open(url, deps: deps) else { return openURL(url) }
                go(target, owner: person.username)
            }
        }
    }

    /// Yours or joined: the library copy. Otherwise the playlist's page.
    private func openPlaylist(_ sharedID: UUID, mine: Bool) async {
        go(await InAppLink.playlist(sharedID, deps: deps), owner: mine ? "you" : person.username)
    }

    private func go(_ target: InAppLink.Target, owner: String) {
        switch target {
        case .playlist(let playlist):
            #if os(macOS)
            appState.showPlaylist(playlist)
            #else
            iosAppState.openLibraryPlaylist(playlist)
            #endif
        case .page(let summary):
            #if os(macOS)
            appState.showPublicPlaylist(summary, ownerName: owner)
            #else
            publicPlaylist = PublicPlaylistTarget(summary: summary, ownerName: owner)
            #endif
        case .crate(let id):
            #if os(macOS)
            appState.showCrate(id)
            #else
            iosAppState.openLibraryCrate(id)
            #endif
        case .post(let code):
            #if os(macOS)
            appState.showPost(code: code)
            #else
            iosAppState.openPost(code: code)
            #endif
        case .done:
            break
        case .unavailable:
            deps.showToast(.failed("That isn\u{2019}t available any more"))
        }
    }

    /// Same as the inbox's Accept and Decline.
    private func answer(_ sharedID: UUID, accept: Bool) async {
        guard let invite = sharing.pendingInvites.first(where: { $0.id == sharedID }) else { return }
        answering.insert(sharedID)
        defer { answering.remove(sharedID) }
        do {
            try await sharing.respondToInvite(invite, accept: accept, libraryService: deps.libraryService)
            let joined = accept ? sharing.localPlaylistID(forSharedPlaylist: invite.sharedPlaylistID) : nil
            let toast = Toast.done(accept ? "Joined \u{201C}\(invite.record.name)\u{201D}"
                                          : "Declined \u{201C}\(invite.record.name)\u{201D}")
            deps.showToast(joined.map { id in toast.action("View") { Toast.openPlaylist(id) } } ?? toast)
            // `materialise` wrote the playlist locally; sync pushes it to other devices.
            if accept { try? await deps.syncService.sync() }
        } catch {
            deps.showToast(.failed(accept ? "Couldn't join that playlist" : "Couldn't decline that invite", error))
        }
    }
}

private extension View {
    func dmCard() -> some View {
        padding(10)
            .frame(maxWidth: 320, alignment: .leading)
            .background(Color.mixSurface2, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct MessageAction: Identifiable {
    let title: String
    let icon: String
    var destructive = false
    let run: () -> Void
    var id: String { title }
}

/// The quick reactions, and a plus for the rest. Tapping your current one takes it off.
struct ReactionBar: View {
    let current: String?
    let pick: (String?) -> Void

    @State private var more = false

    private static let extra = ["😍", "🥹", "😭", "🙏", "👏", "🎉", "💯", "😎", "🤔", "🙌", "😅", "🤣",
                                "😡", "💀", "👀", "✨", "🥳", "😴", "🤯", "🫶", "💜", "🎶", "🤘", "😤"]

    var body: some View {
        // Your reaction stays in the row even when it came from the extras.
        let quick = MessagesService.reactions + (current.map { MessagesService.reactions.contains($0) ? [] : [$0] } ?? [])
        VStack(spacing: 4) {
            HStack(spacing: 2) {
                ForEach(quick, id: \.self, content: chip)
                Button { withMixAnimation(.easeOut(duration: 0.2)) { more.toggle() } } label: {
                    Image(systemName: more ? "chevron.up" : "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.mixTextSecondary)
                        .frame(width: 34, height: 34)
                        .background(Color.mixSurface2, in: Circle())
                        .frame(width: 40, height: 40)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .mixHandCursor()
                .accessibilityLabel(more ? "Fewer reactions" : "More reactions")
            }
            if more {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(40), spacing: 2), count: 6), spacing: 2) {
                    ForEach(Self.extra, id: \.self, content: chip)
                }
                .transition(.opacity)
            }
        }
        .padding(4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.mixSeparator, lineWidth: 0.5))
    }

    private func chip(_ emoji: String) -> some View {
        let on = emoji == current
        return Button { pick(on ? nil : emoji) } label: {
            Text(emoji)
                .font(.system(size: 26))
                .frame(width: 40, height: 40)
                .background(on ? Color.mixSurface2 : .clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .mixHandCursor()
        .accessibilityLabel(on ? "Remove \(emoji)" : "React \(emoji)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

#if os(iOS)
/// A held message over the blurred thread: reactions above, actions below, on the message's side.
private struct MessageFocus<Preview: View>: View {
    let mine: Bool
    let current: String?
    let actions: [MessageAction]
    let react: (String?) -> Void
    let close: () -> Void
    @ViewBuilder let preview: Preview

    @State private var shown = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Color.black.opacity(0.2))
                .ignoresSafeArea()
                .opacity(shown ? 1 : 0)
                .onTapGesture { dismiss() }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Close")

            VStack(alignment: mine ? .trailing : .leading, spacing: 10) {
                ReactionBar(current: current) { emoji in dismiss { react(emoji) } }
                preview
                    .allowsHitTesting(false)
                if !actions.isEmpty { menu }
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
            .scaleEffect(shown ? 1 : 0.9, anchor: mine ? .trailing : .leading)
            .opacity(shown ? 1 : 0)
        }
        .presentationBackground(.clear)
        .onAppear { withMixAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { shown = true } }
    }

    private var menu: some View {
        VStack(spacing: 0) {
            ForEach(Array(actions.enumerated()), id: \.element.id) { i, action in
                if i > 0 { Divider().overlay(Color.mixSeparator) }
                Button { dismiss(then: action.run) } label: {
                    HStack {
                        Text(action.title)
                        Spacer(minLength: 12)
                        Image(systemName: action.icon)
                    }
                    .font(.mixBody)
                    .foregroundStyle(action.destructive ? Color.mixDestructive : Color.mixTextPrimary)
                    .padding(.horizontal, 16)
                    .frame(height: 46)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 240)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func dismiss(then action: (() -> Void)? = nil) {
        action?()
        withAnimation(MixMotion.current.resolve(.easeOut(duration: 0.15))) {
            shown = false
        } completion: {
            close()
        }
    }
}
#endif

/// A photo from dm-attachments, or the picked bytes while it uploads.
private struct AttachmentImage: View {
    let path: String?
    var data: Data? = nil
    var fit = false

    @State private var url: URL?

    var body: some View {
        Group {
            if let data, let image = mixImage(from: data) {
                sized(image.resizable())
            } else {
                CachedRemoteImage(url: url) { sized($0.resizable()) } placeholder: { Color.clear }
            }
        }
        .task(id: path) {
            if data == nil, let path { url = await MessagesService.shared.attachmentURL(path) }
        }
    }

    @ViewBuilder
    private func sized(_ image: Image) -> some View {
        if fit { image.scaledToFit() } else { image.scaledToFill() }
    }
}

// MARK: - Sharing into a conversation

extension ShareItem {
    /// Into a conversation: a picture as a photo, anything else as a card.
    func send(to person: UserProfile) async throws {
        if let image {
            guard let photo = await MessagesService.preparePhoto(image) else { throw CocoaError(.fileReadCorruptFile) }
            _ = try await MessagesService.shared.sendPhoto(id: UUID(), to: person.id, photo: photo)
        } else {
            let (card, cover) = await messageCard()
            _ = try await MessagesService.shared.sendShare(id: UUID(), to: person.id, card: card, cover: cover)
        }
    }

    /// The card a conversation draws, and the cover's bytes when there's no public link to it.
    func messageCard() async -> (MessagesService.Payload, Data?) {
        var card = MessagesService.Payload()
        card.type = noun == "Dub" ? "playlist" : noun.lowercased()
        card.title = title
        card.subtitle = subtitle
        card.round = isRound ? true : nil
        card.track = track
        card.url = url.absoluteString
        if case .remote(let remote) = artwork, let link = MessagesService.linkableArtwork(remote) {
            card.artwork = link
            return (card, nil)
        }
        let image: PlatformImage?
        switch artwork {
        case .none: image = nil
        case .stored(let data, let ref): image = ArtworkProvider.resolve(data, ref).flatMap(PlatformImage.init(data:))
        case .remote(let url): image = if let url { await RemoteImageCache.shared.image(for: url) } else { nil }
        case .playlist(let id): image = await ArtworkImageLoader.shared.image(for: .playlist(id), bucket: ArtworkDecodeCache.fullSize)
        }
        #if os(macOS)
        return (card, image?.tiffRepresentation)
        #else
        return (card, image?.jpegData(compressionQuality: 0.9))
        #endif
    }
}

/// "Send to" from a share menu or sheet: pick someone and the card lands in your conversation with them.
struct SendToSheet: View {
    let item: ShareItem
    let close: () -> Void

    @EnvironmentObject private var deps: AppDependencies
    @State private var sending = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Send to")
                        .font(.mixTitle2)
                        .foregroundStyle(Color.mixTextPrimary)
                    Text("\(item.noun): \(item.title)")
                        .font(.mixSubtext)
                        .foregroundStyle(Color.mixTextSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if sending { ProgressView().controlSize(.small) }
                Button("Cancel", action: close)
                    .buttonStyle(.plain)
                    .font(.mixLabel)
                    .foregroundStyle(Color.mixTextSecondary)
                    .mixHandCursor()
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 10)

            NewMessagePicker(pick: send)
                .disabled(sending)
        }
        .background(Color.mixBackground)
        #if os(macOS)
        .frame(width: 420, height: 520)
        #endif
    }

    private func send(_ person: UserProfile) {
        sending = true
        Task {
            do {
                try await item.send(to: person)
                deps.showToast(.done("Sent to \(person.name)."))
                close()
            } catch {
                sending = false
                deps.showToast(.failed("Couldn't send that. Try again.", error))
            }
        }
    }
}

// MARK: - People picker

/// Recent conversations, or search by username. Behind "New message" and "Send to".
struct NewMessagePicker: View {

    /// Shows a header with Back. iOS uses the navigation bar instead.
    var back: (() -> Void)? = nil
    let pick: (UserProfile) -> Void

    @EnvironmentObject private var deps: AppDependencies
    @ObservedObject private var messages = MessagesService.shared
    @StateObject private var people = PeopleSearch()
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            if let back {
                HStack(spacing: 8) {
                    Button(action: back) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.mixTextPrimary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .mixHandCursor()
                    .accessibilityLabel("Back")
                    Text("New message")
                        .font(.mixTitle2)
                        .foregroundStyle(Color.mixTextPrimary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .frame(height: 68)
            }

            MixSearchField(text: $query,
                           placeholder: "Search by username",
                           isBusy: people.isSearching,
                           autoFocus: true)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        if !messages.threads.isEmpty {
                            Text("Recent")
                                .font(.mixLabel)
                                .foregroundStyle(Color.mixTextSecondary)
                                .padding(.horizontal, 10)
                                .padding(.top, 8)
                                .padding(.bottom, 4)
                        }
                        ForEach(messages.threads.prefix(12)) { row($0.profile) }
                    } else {
                        if people.failed {
                            Text("Couldn't search. Check your connection.")
                                .font(.mixSubtext)
                                .foregroundStyle(Color.mixTextSecondary)
                                .padding(24)
                        }
                        ForEach(people.results.filter { $0.id != deps.authService.currentUser?.id }) { row($0) }
                    }
                }
                .padding(.horizontal, 6)
            }
        }
        .background(Color.mixBackground)
        #if os(iOS)
        .navigationTitle("New message")
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: query) { await people.search(query, using: deps.authService) }
        .task { if !messages.loaded { await messages.refresh() } }
    }

    private func row(_ profile: UserProfile) -> some View {
        Button { pick(profile) } label: {
            PersonResultRow(profile: profile, showsChevron: false)
        }
        .buttonStyle(.plain)
        .mixHandCursor()
    }
}

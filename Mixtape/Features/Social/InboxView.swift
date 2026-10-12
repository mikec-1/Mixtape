// The inbox behind the tray in the top bar: a popover on Mac, a sheet on iOS.
// Opening it marks everything read; pending invites are answered in place.
// Messages have their own button and page, see MessagesView.

import SwiftUI
import Supabase

/// Font, colour and button style come from the call site, so it matches its neighbours.
struct InboxButton: View {

    /// The tap target. Nil keeps the glyph's own size.
    var hitSize: CGFloat? = nil

    @ObservedObject private var inbox = InboxService.shared
    @State private var open = false

    var body: some View {
        let count = inbox.unreadCount
        Button { open.toggle() } label: {
            Image(systemName: count > 0 ? "tray.fill" : "tray")
                .unreadBadge(count)
                .frame(width: hitSize, height: hitSize)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(count > 0 ? "Inbox, \(count) new" : "Inbox")
        #if os(macOS)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            InboxView { open = false }
                .frame(width: 380, height: 520)
        }
        #else
        .sheet(isPresented: $open) {
            // A stack so a dub can open inside the sheet.
            NavigationStack { InboxView { open = false } }
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.mixBackground)
        }
        #endif
    }
}

extension View {
    /// The count on the inbox tray and the messages plane.
    func unreadBadge(_ count: Int) -> some View {
        overlay(alignment: .topTrailing) {
            if count > 0 {
                Text(count > 9 ? "9+" : "\(count)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.mixOnAccent)
                    .padding(.horizontal, 4)
                    .frame(minWidth: 15, minHeight: 15)
                    .background(Color.mixAccentFill, in: Capsule())
                    .offset(x: 8, y: -7)
            }
        }
    }
}

struct InboxView: View {

    let close: () -> Void

    @EnvironmentObject private var deps: AppDependencies
    #if os(macOS)
    @EnvironmentObject private var appState: MacAppState
    #else
    @EnvironmentObject private var iosAppState: IOSAppState
    #endif
    @Environment(\.openURL) private var openURL
    @ObservedObject private var inbox = InboxService.shared

    @State private var busy: Set<UUID> = []
    #if os(iOS)
    @State private var dub: PublicPlaylistTarget?
    #endif

    var body: some View {
        list
        .onAppear {
            inbox.isOpen = true
            Task { await inbox.markAllRead() }
        }
        .onDisappear { inbox.isOpen = false }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(item: $dub) { target in
            PublicPlaylistPage(summary: target.summary, ownerName: target.ownerName)
                .environmentObject(deps)
        }
        #endif
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Inbox")
                    .font(.mixTitle2)
                    .foregroundStyle(Color.mixTextPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                #if os(iOS)
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 28))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color.mixTextSecondary)
                        .frame(width: 44, height: 44, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                #endif
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(spacing: 0) {
                    if !inbox.loaded {
                        ProgressView().padding(24)
                    } else if inbox.rows.isEmpty {
                        Text("Nothing yet. Invites, dubs, saves, likes, comments and follows show up here.")
                            .font(.mixSubtext)
                            .foregroundStyle(Color.mixTextSecondary)
                            .multilineTextAlignment(.center)
                            .padding(32)
                    } else {
                        ForEach(inbox.rows) { notice in
                            row(notice)
                        }
                        if inbox.hasMore {
                            ProgressView()
                                .padding(16)
                                .onAppear { Task { await inbox.loadMore() } }
                        }
                    }
                }
            }
        }
    }

    // MARK: Row

    @ViewBuilder
    private func row(_ notice: InboxService.Notice) -> some View {
        if canOpen(notice) {
            Button { Task { await open(notice) } } label: { rowContent(notice) }
                .buttonStyle(.plain)
                .mixHandCursor()
        } else {
            rowContent(notice)
        }
    }

    private func rowContent(_ notice: InboxService.Notice) -> some View {
        let p = notice.phrase
        let line = Text(p.who).bold() + Text(p.verb) + Text(p.what).bold()

        return HStack(alignment: .center, spacing: 12) {
            art(notice)

            VStack(alignment: .leading, spacing: 3) {
                line
                    .font(.mixBody)
                    .foregroundStyle(Color.mixTextPrimary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if let body = notice.body, !body.isEmpty {
                    Text(body)
                        .font(.mixSubtext)
                        .foregroundStyle(Color.mixTextSecondary)
                        .lineLimit(2)
                }
                if notice.invitePending { inviteActions(notice) }
            }

            Spacer(minLength: 0)

            // Its own column, so it never wraps under the sentence.
            VStack(alignment: .trailing, spacing: 6) {
                Text(InboxService.age(notice.createdAt))
                    .font(.mixCaption)
                    .foregroundStyle(Color.mixTextTertiary)
                    .monospacedDigit()
                if inbox.dots.contains(notice.id) {
                    Circle()
                        .fill(Color.mixAccentFill)
                        .frame(width: 8, height: 8)
                        .accessibilityLabel("New")
                }
            }
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(inbox.dots.contains(notice.id) ? Color.mixAccentFill.opacity(0.06) : .clear)
        .contentShape(Rectangle())
    }

    /// Who did it, with what it was done to in the corner. The same on every platform.
    @ViewBuilder
    private func art(_ notice: InboxService.Notice) -> some View {
        let side: CGFloat = 48
        if notice.kind == .system {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(Color.mixOnAccent)
                .frame(width: side, height: side)
                .background(Color.mixAccentFill.gradient, in: Circle())
                .accessibilityHidden(true)
        } else {
            AvatarView(url: notice.actorAvatarURL.flatMap(URL.init(string:)),
                       seed: notice.actorUsername ?? notice.phrase.who,
                       size: side)
                .overlay(alignment: .bottomTrailing) {
                    if notice.subjectID != nil { subject(notice).offset(x: 4, y: 4) }
                }
                .accessibilityHidden(true)
        }
    }

    /// The playlist's or post's cover, or a glyph while there isn't one.
    private func subject(_ notice: InboxService.Notice) -> some View {
        let side: CGFloat = 24
        return ZStack {
            Color.mixSurface2
            Image(systemName: notice.isPost ? MixtapeIcons.track : MixtapeIcons.playlist)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.mixTextSecondary)
            if let url = notice.artworkURL {
                CachedRemoteImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Color.mixBackground, lineWidth: 2))
    }

    private func inviteActions(_ notice: InboxService.Notice) -> some View {
        let isBusy = busy.contains(notice.id)
        return HStack(spacing: 8) {
            Button {
                Task { await answer(notice, accept: true) }
            } label: {
                Text("Accept")
                    .font(.mixLabel)
                    .foregroundStyle(Color.mixOnAccent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(Color.mixAccentFill, in: Capsule())
            }
            .buttonStyle(.plain).mixHandCursor()

            Button {
                Task { await answer(notice, accept: false) }
            } label: {
                Text("Decline")
                    .font(.mixLabel)
                    .foregroundStyle(Color.mixTextSecondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color.mixSurface2, in: Capsule())
            }
            .buttonStyle(.plain).mixHandCursor()

            if isBusy { ProgressView().controlSize(.small) }
        }
        .disabled(isBusy)
        .padding(.top, 4)
    }

    // MARK: Actions

    private func answer(_ notice: InboxService.Notice, accept: Bool) async {
        guard let sharedID = notice.subjectID else { return }
        busy.insert(notice.id)
        defer { busy.remove(notice.id) }

        // Accepting needs the full invite, which the feed doesn't carry.
        let sharing = PlaylistSharingService.shared
        if !sharing.pendingInvites.contains(where: { $0.id == sharedID }) {
            await sharing.refreshPendingInvites()
        }
        guard let invite = sharing.pendingInvites.first(where: { $0.id == sharedID }) else {
            deps.showToast(.failed("That invite is no longer open."))
            await inbox.refresh()
            return
        }

        do {
            try await sharing.respondToInvite(invite, accept: accept, libraryService: deps.libraryService)
            InviteNotifier.shared.clear(notice.id)
            let joined = accept ? sharing.localPlaylistID(forSharedPlaylist: invite.sharedPlaylistID) : nil
            let toast = Toast.done(accept ? "Joined \u{201C}\(invite.record.name)\u{201D}"
                                          : "Declined \u{201C}\(invite.record.name)\u{201D}")
            deps.showToast(joined.map { id in toast.action("View") { Toast.openPlaylist(id) } } ?? toast)
            await inbox.refresh()
            // `materialise` wrote the playlist locally; sync pushes it to other devices.
            if accept { try? await deps.syncService.sync() }
        } catch {
            // Nothing was added locally, so the buttons stay for a retry.
            deps.showToast(.failed(accept ? "Couldn't join that playlist" : "Couldn't decline that invite", error))
        }
    }

    private func canOpen(_ notice: InboxService.Notice) -> Bool {
        if notice.kind == .system || notice.isPost { return !(notice.link ?? "").isEmpty }
        if notice.kind == .follow { return notice.actor != nil }
        return notice.subjectID != nil && !notice.invitePending
    }

    /// Always in the app: the library copy, else the playlist's page. A system notice's link goes
    /// to the browser only when the app has no page for it.
    private func open(_ notice: InboxService.Notice) async {
        let target: InAppLink.Target
        if notice.kind == .follow, let actor = notice.actor {
            #if os(macOS)
            appState.showProfile(actor)
            #else
            iosAppState.openProfile(actor)
            #endif
            return close()
        }
        if notice.kind == .system || notice.isPost, let link = notice.link {
            let page = link.hasPrefix("/") ? String(link.dropFirst()) : link
            guard let url = link.lowercased().hasPrefix("http") ? URL(string: link) : MixtapeLink.web(page) else { return }
            guard let t = await InAppLink.open(url, deps: deps) else {
                openURL(url)
                return close()
            }
            target = t
        } else if let sharedID = notice.subjectID {
            target = await InAppLink.playlist(sharedID, deps: deps)
        } else {
            return
        }

        switch target {
        case .playlist(let playlist):
            #if os(macOS)
            appState.showPlaylist(playlist)
            #else
            iosAppState.openLibraryPlaylist(playlist)
            #endif
        case .page(let summary):
            let owner = notice.actorUsername ?? "someone"
            #if os(macOS)
            appState.showPublicPlaylist(summary, ownerName: owner)
            #else
            dub = PublicPlaylistTarget(summary: summary, ownerName: owner)
            return
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
            return
        }
        close()
    }
}

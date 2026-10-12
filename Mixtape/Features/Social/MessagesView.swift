// Messages, behind the paper plane beside the inbox: every conversation, newest first.
// On Mac the list sits beside the open conversation; on iOS it's pushed inside a full-screen cover.

import SwiftUI

/// Font, colour and button style come from the call site, like InboxButton.
struct MessagesButton: View {

    var hitSize: CGFloat? = nil

    @ObservedObject private var messages = MessagesService.shared
    #if os(macOS)
    @EnvironmentObject private var appState: MacAppState
    #else
    @EnvironmentObject private var iosAppState: IOSAppState
    #endif

    var body: some View {
        let count = messages.unreadCount
        Button {
            #if os(macOS)
            appState.openMessages()
            #else
            iosAppState.openMessages()
            #endif
        } label: {
            Image(systemName: count > 0 ? "paperplane.fill" : "paperplane")
                .unreadBadge(count)
                .frame(width: hitSize, height: hitSize)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(count > 0 ? "Messages, \(count) unread" : "Messages")
    }
}

struct MessagesView: View {

    @ObservedObject private var messages = MessagesService.shared

    #if os(macOS)
    /// The open conversation, highlighted.
    var selected: UUID? = nil
    let open: (UserProfile) -> Void
    let compose: () -> Void
    #else
    @EnvironmentObject private var iosAppState: IOSAppState
    @State private var path: [Route] = []

    private enum Route: Hashable {
        case new, thread(UserProfile), profile(UserProfile)
    }
    #endif

    var body: some View {
        #if os(macOS)
        list
        #else
        NavigationStack(path: $path) {
            list
                .navigationTitle("Messages")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { iosAppState.showMessages = false } label: { Image(systemName: "xmark") }
                            .accessibilityLabel("Close")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { path.append(.new) } label: { Image(systemName: "square.and.pencil") }
                            .accessibilityLabel("New message")
                    }
                }
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .new:
                        NewMessagePicker(pick: { path = [.thread($0)] })
                    case .thread(let person):
                        MessageThreadView(person: person, openProfile: { path.append(.profile(person)) })
                    case .profile(let person):
                        ProfilePageView(profile: person)
                    }
                }
        }
        .tint(Color.mixTextPrimary)
        .onAppear(perform: takeRequest)
        // A profile's Message button while the cover is already up.
        .onChange(of: iosAppState.messagesWith) { _, _ in takeRequest() }
        #endif
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                #if os(macOS)
                HStack {
                    Text("Messages")
                        .font(.mixTitle)
                        .foregroundStyle(Color.mixTextPrimary)
                    Spacer(minLength: 0)
                    Button(action: compose) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Color.mixTextSecondary)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .mixHandCursor()
                    .help("New message")
                    .accessibilityLabel("New message")
                }
                .padding(.horizontal, 16)
                // Clears the floating back control.
                .padding(.top, 50)
                .padding(.bottom, 8)
                #endif

                if !messages.loaded {
                    ProgressView().padding(24)
                } else if messages.threads.isEmpty {
                    Text("No messages yet. Start one from someone's profile, or with New message.")
                        .font(.mixSubtext)
                        .foregroundStyle(Color.mixTextSecondary)
                        .multilineTextAlignment(.center)
                        .padding(32)
                } else {
                    ForEach(messages.threads) { t in
                        Button { select(t.profile) } label: { row(t) }
                            .buttonStyle(.plain)
                            .mixHandCursor()
                            #if os(macOS)
                            .background(t.id == selected ? Color.mixSurface2 : .clear,
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .padding(.horizontal, 6)
                            #endif
                    }
                }
            }
        }
        .background(MixPageBackground())
    }

    private func select(_ person: UserProfile) {
        #if os(macOS)
        open(person)
        #else
        path.append(.thread(person))
        #endif
    }

    /// Their name, your last line or theirs, and a dot while unread.
    private func row(_ t: MessagesService.Thread) -> some View {
        HStack(spacing: 12) {
            AvatarView(url: t.profile.avatarURL, seed: t.profile.username, size: 52)

            VStack(alignment: .leading, spacing: 3) {
                (Text(t.profile.name).bold()
                 + Text(" \u{2022} \(InboxService.age(t.lastAt))").foregroundStyle(Color.mixTextTertiary))
                    .font(.mixBody)
                    .foregroundStyle(Color.mixTextPrimary)
                Text(t.lastFromMe ? t.said(by: "You") : t.lastBody)
                    .font(.mixSubtext)
                    .fontWeight(t.unread > 0 ? .semibold : .regular)
                    .foregroundStyle(t.unread > 0 ? Color.mixTextPrimary : Color.mixTextSecondary)
            }
            .lineLimit(1)

            Spacer(minLength: 0)

            if t.unread > 0 {
                Circle()
                    .fill(Color.mixAccentFill)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel("Unread")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    #if os(iOS)
    private func takeRequest() {
        guard let person = iosAppState.messagesWith else { return }
        iosAppState.messagesWith = nil
        path = [.thread(person)]
    }
    #endif
}

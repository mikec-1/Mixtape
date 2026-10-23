// A community post as a page: play, like, repost, save, then the comments. Same page as
// mixtape-web src/pages/post/[code].astro. Pushed onto Discover on both platforms.

import SwiftUI

struct PostPageView: View {
    let code: String
    let onOpenProfile: (UserProfile) -> Void
    /// Leaves the page after a delete. Nil pops the NavigationStack.
    var onClose: (() -> Void)? = nil

    @Environment(AppDependencies.self) private var deps
    @Environment(PlaybackEngine.self) private var engine
    @Environment(QueueService.self) private var queueService
    @Environment(\.dismiss) private var dismiss

    @State private var post: CommunityPost?
    @State private var artwork: Data?
    @State private var loadFailed = false
    @State private var loaded = false

    @State private var thread: [PostComment] = []
    @State private var threadFailed = false
    @State private var draft = ""
    @State private var replyTo: PostComment?
    @State private var timed = true
    @State private var sending = false

    @State private var confirmingDelete = false
    @State private var deletingComment: PostComment?
    @State private var reporting = false
    @State private var reportingComment: PostComment?
    @State private var reportReason = ""
    @State private var confirmingBlock = false

    private var me: UUID? { deps.authService.currentUser?.id }
    private var mine: Bool { post != nil && me == post?.userID }
    private var isThis: Bool { post != nil && queueService.currentTrack?.id == post?.id }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if let post {
                    hero(post)
                    wave(post)
                    if let caption = post.caption, !caption.isEmpty {
                        Text(caption)
                            .font(.mixBody)
                            .foregroundStyle(Color.mixTextPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: 680, alignment: .leading)
                            .padding(.horizontal, inset)
                    }
                    comments(post)
                } else if loaded {
                    empty(loadFailed ? "Couldn\u{2019}t load this post" : "This post isn\u{2019}t available",
                          loadFailed ? "Check your connection and try again."
                                     : "It may have been deleted, or the link was cut short.")
                } else {
                    ProgressView().tint(Color.mixPrimary)
                        .frame(maxWidth: .infinity).padding(.vertical, 80)
                }
            }
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 48)
        }
        .artworkWash(source: artwork, fallback: ArtworkColors.brandGradient)
        .background(MixPageBackground())
        .navigationTitle(post?.title ?? "Post")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: code) { await load() }
        .mixConfirmationDialog("Delete this post?", isPresented: $confirmingDelete, titleVisibility: .visible,
                               presenting: post) { post in
            Button("Delete", role: .destructive) { Task { await delete(post) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its likes, reposts and comments go with it. Your edit stays in your library.")
        }
        .mixConfirmationDialog("Delete this comment?",
                               isPresented: Binding(get: { deletingComment != nil },
                                                    set: { if !$0 { deletingComment = nil } }),
                               titleVisibility: .visible, presenting: deletingComment) { comment in
            Button("Delete", role: .destructive) { Task { await deleteComment(comment) } }
            Button("Cancel", role: .cancel) { deletingComment = nil }
        } message: { _ in
            Text("Replies to it go too.")
        }
        .mixConfirmationDialog("Block \(post?.author.name ?? "")?", isPresented: $confirmingBlock,
                               titleVisibility: .visible, presenting: post) { post in
            Button("Block", role: .destructive) { Task { await block(post) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("You won\u{2019}t see each other\u{2019}s posts or comments, follows between you end, and neither of you can message the other.")
        }
        .alert(reportingComment == nil ? "Report Post" : "Report Comment", isPresented: $reporting) {
            TextField("Reason", text: $reportReason)
            Button("Report") { Task { await report() } }
                .disabled(reportReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Tell us what\u{2019}s wrong. They won\u{2019}t see who reported it.")
        }
    }

    private var inset: CGFloat {
        #if os(macOS)
        24
        #else
        20
        #endif
    }

    private func empty(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.mixTitle).foregroundStyle(Color.mixTextPrimary)
            Text(detail).font(.mixBody).foregroundStyle(Color.mixTextSecondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }

    // MARK: - Hero

    private func hero(_ post: CommunityPost) -> some View {
        DetailHero(eyebrow: post.edit.label, title: post.title) {
            PlaylistByline(
                members: [BylineMember(id: post.userID, name: post.author.name,
                                       avatarURL: post.author.avatarURL)],
                metadata: subline(post),
                onOpenMember: { _ in onOpenProfile(post.author) })
        } cover: { size in
            ArtworkThumbnail(data: artwork, size: size, cornerRadius: 14, placeholder: MixtapeIcons.track)
        } actions: {
            actions(post)
        }
    }

    private func subline(_ post: CommunityPost) -> String {
        var edit = "Edit of \u{201C}\(post.originalTitle)\u{201D}"
        if let artist = post.originalArtist, !artist.isEmpty { edit += " by \(artist)" }
        return [edit, AddedDateText.relative(post.createdAt), count(post.plays, "play")]
            .joined(separator: " · ")
    }

    private func actions(_ post: CommunityPost) -> some View {
        let playing = isThis && engine.state.isPlaying
        return HStack(spacing: 12) {
            Button { start() } label: {
                Image(systemName: playing ? MixtapeIcons.pause : MixtapeIcons.play)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color.mixOnAccent)
                    .frame(width: 52, height: 52)
                    .background(Color.mixAccentFill, in: Circle())
            }
            .buttonStyle(.plain).mixHandCursor()
            .accessibilityLabel(playing ? "Pause" : "Play")

            reaction(post.liked ? "heart.fill" : "heart", post.likes, on: post.liked, what: "Like") {
                react(like: true)
            }
            if !mine {
                reaction("arrow.2.squarepath", post.reposts, on: post.reposted, what: "Repost") {
                    react(like: false)
                }
            }

            // Your own post is already in your library.
            if !mine {
                Button { save(post) } label: { HeroCircleLabel(systemImage: MixtapeIcons.add) }
                    .buttonStyle(.plain).mixHandCursor()
                    .disabled(me == nil)
                    .help("Save to your library")
                    .accessibilityLabel("Save to your library")
            }

            ShareHeroButton(ShareItem(url: post.link, noun: "Post", title: post.title,
                                      subtitle: post.author.name, artwork: .remote(post.artworkURL)))

            if me != nil {
                Menu {
                    if mine {
                        Button("Delete Post\u{2026}", role: .destructive) { confirmingDelete = true }
                    } else {
                        Button("Report Post\u{2026}") { startReport(nil) }
                        Button("Block \(post.author.name)\u{2026}", role: .destructive) { confirmingBlock = true }
                    }
                } label: {
                    HeroCircleLabel(systemImage: "ellipsis")
                }
                #if os(macOS)
                .menuStyle(.button)
                .buttonStyle(.plain).mixHandCursor()
                .menuIndicator(.hidden)
                #endif
                .frame(width: 40, height: 40)
                .accessibilityLabel("More")
            }
            Spacer(minLength: 0)
        }
    }

    /// Like and repost: a pill with the count, lit while on.
    private func reaction(_ symbol: String, _ n: Int, on: Bool, what: String,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 14, weight: .bold))
                Text(n.formatted()).font(.mixLabel).monospacedDigit()
            }
            .foregroundStyle(on ? Color.mixPrimary : Color.mixTextSecondary)
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(on ? Color.mixPrimary.opacity(0.18) : Color.mixSurface, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.mixSeparator, lineWidth: 0.5))
        }
        .buttonStyle(.plain).mixHandCursor()
        .disabled(me == nil)
        .accessibilityLabel("\(what), \(n)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: - Waveform

    /// The song's shape with its timed comments as faces on the line. Ticks only while it plays.
    @ViewBuilder
    private func wave(_ post: CommunityPost) -> some View {
        let total = isThis && engine.duration > 0 ? engine.duration : post.duration ?? 0
        Group {
            if isThis {
                PlaybackProgress(clock: engine.clock, duration: total) { waveBody(post, total: total, progress: $0) }
            } else {
                waveBody(post, total: total, progress: 0)
            }
        }
        .padding(.horizontal, inset)
    }

    private func waveBody(_ post: CommunityPost, total: Double, progress: Double) -> some View {
        let marks = total > 0 ? thread.compactMap { c -> WaveMark? in
            guard c.parentID == nil, let at = c.atSeconds else { return nil }
            return WaveMark(id: c.id, at: min(at / total, 1), label: "\(c.author.name): \(c.body)",
                            avatar: c.author.avatarURL, name: c.author.username)
        } : []
        return WaveformView(peaks: Waveform.decode(post.waveform), progress: progress, marks: marks,
                            height: waveHeight, duration: total,
                            onSeek: { start(at: $0 * total) }, onMark: { start(at: $0.at * total) })
    }

    private var waveHeight: CGFloat {
        #if os(macOS)
        88
        #else
        64
        #endif
    }

    // MARK: - Comments

    private func comments(_ post: CommunityPost) -> some View {
        let byID = Dictionary(thread.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // One level of replies: a reply to a reply files under the same top comment.
        func topOf(_ c: PostComment) -> PostComment {
            var at = c
            for _ in 0..<50 {
                guard let parent = at.parentID.flatMap({ byID[$0] }) else { break }
                at = parent
            }
            return at
        }
        let tops = thread.filter { topOf($0).id == $0.id }
        let replies = Dictionary(grouping: thread.filter { topOf($0).id != $0.id }, by: { topOf($0).id })

        return VStack(alignment: .leading, spacing: 18) {
            Text(post.comments > 0 ? count(post.comments, "Comment") : "Comments")
                .font(.mixTitle)
                .foregroundStyle(Color.mixTextPrimary)

            if me != nil { compose(post) }

            if threadFailed {
                Text("Couldn\u{2019}t load the comments.").font(.mixCaption).foregroundStyle(Color.mixTextSecondary)
            }
            ForEach(tops) { top in
                VStack(alignment: .leading, spacing: 14) {
                    commentRow(top, to: nil, post: post)
                    ForEach(replies[top.id] ?? []) { reply in
                        let parent = reply.parentID.flatMap { byID[$0] }
                        commentRow(reply, to: parent?.id == top.id ? nil : parent, post: post)
                            .padding(.leading, 42)
                    }
                }
            }
        }
        .frame(maxWidth: 680, alignment: .leading)
        .padding(.horizontal, inset)
    }

    private func compose(_ post: CommunityPost) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let replyTo {
                HStack {
                    Text("Replying to \(replyTo.author.name)")
                        .font(.mixCaption).foregroundStyle(Color.mixTextSecondary)
                    Button("Cancel") { self.replyTo = nil }
                        .buttonStyle(.plain).mixHandCursor()
                        .font(.mixCaptionBold).foregroundStyle(Color.mixPrimary)
                }
            }
            TextField(replyTo == nil ? "Add a comment" : "Add a reply",
                      text: Binding(get: { draft }, set: { draft = String($0.prefix(1000)) }),
                      axis: .vertical)
                .lineLimit(2...6)
                .mixSheetField()
                .disabled(sending)
            HStack {
                // Timed only for top comments, while this post is the one playing.
                if isThis, replyTo == nil {
                    TimedToggle(clock: engine.clock, on: $timed)
                }
                Spacer()
                Button { Task { await send(post) } } label: {
                    Text("Comment")
                        .font(.mixButtonSmall)
                        .foregroundStyle(Color.mixOnAccent)
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .background(Color.mixAccentFill, in: Capsule())
                }
                .buttonStyle(.plain).mixHandCursor()
                .disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func commentRow(_ c: PostComment, to parent: PostComment?, post: CommunityPost) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button { onOpenProfile(c.author) } label: {
                AvatarView(url: c.author.avatarURL, seed: c.author.username, size: 32)
            }
            .buttonStyle(.plain).mixHandCursor()

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Button(c.author.name) { onOpenProfile(c.author) }
                        .buttonStyle(.plain).mixHandCursor()
                        .font(.mixCaptionBold).foregroundStyle(Color.mixTextPrimary)
                    if let parent {
                        Text("to \(parent.author.name)").font(.mixCaption).foregroundStyle(Color.mixTextSecondary)
                    }
                    if let at = c.atSeconds {
                        Button("at \(Self.clock(at))") { start(at: at) }
                            .buttonStyle(.plain).mixHandCursor()
                            .font(.mixCaptionBold).foregroundStyle(Color.mixPrimary)
                            .accessibilityLabel("Play from \(Self.clock(at))")
                    }
                    Text(InboxService.age(c.createdAt)).font(.mixCaption).foregroundStyle(Color.mixTextTertiary)
                }
                .lineLimit(1)
                Text(c.body)
                    .font(.mixBody)
                    .foregroundStyle(Color.mixTextPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if me != nil {
                    HStack(spacing: 14) {
                        Button("Reply") { replyTo = c }
                        if c.userID == me || mine {
                            Button("Delete") { deletingComment = c }
                        }
                        if c.userID != me {
                            Button("Report") { startReport(c) }
                        }
                    }
                    .buttonStyle(.plain).mixHandCursor()
                    .font(.mixCaptionBold).foregroundStyle(Color.mixTextSecondary)
                }
            }
        }
    }

    // MARK: - Actions

    private func load() async {
        do {
            post = try await deps.community.post(code: code)
            loadFailed = false
        } catch {
            loadFailed = true
        }
        loaded = true
        guard let post else { return }
        if let url = post.artworkURL { artwork = try? await URLSession.shared.data(from: url).0 }
        if mine, Waveform.decode(post.waveform)?.count != Waveform.postSlices { Task { await backfillWaveform(post) } }
        await refresh(post.id)
    }

    /// Posts without a current shape get one when the owner opens them.
    private func backfillWaveform(_ post: CommunityPost) async {
        guard let shape = await deps.postWaveform(of: post.track(artwork: nil)) else { return }
        try? await deps.community.setWaveform(post.id, shape)
        if self.post?.id == post.id { self.post?.waveform = shape }
    }

    private func refresh(_ id: UUID) async {
        do {
            thread = try await deps.community.thread(id)
            threadFailed = false
            post?.comments = thread.count
        } catch {
            threadFailed = true
        }
    }

    /// First press counts a play and starts the post; after that it's play/pause. A stamp seeks.
    private func start(at seconds: Double? = nil) {
        guard let post else { return }
        if !isThis {
            deps.community.play(post.id)
            self.post?.plays += 1
            let track = post.track(artwork: artwork)
            Task {
                await engine.play(track: track, in: [track], source: .named(post.title))
                if let seconds { engine.seek(to: seconds) }
            }
        } else if let seconds {
            engine.seek(to: seconds)
            if !engine.state.isPlaying { engine.togglePlayPause() }
        } else {
            engine.togglePlayPause()
        }
    }

    /// Optimistic; put back if the write fails.
    private func react(like: Bool) {
        guard let current = post else { return }
        let on = !(like ? current.liked : current.reposted)
        func apply(_ value: Bool) {
            if like { post?.liked = value; post?.likes += value ? 1 : -1 }
            else { post?.reposted = value; post?.reposts += value ? 1 : -1 }
        }
        apply(on)
        Task {
            do {
                if like { try await deps.community.setLiked(current.id, on) }
                else { try await deps.community.setReposted(current.id, on) }
            } catch {
                apply(!on)
                deps.showToast(.failed(like ? "Couldn\u{2019}t like this post." : "Couldn\u{2019}t repost this post.", error))
            }
        }
    }

    private func save(_ post: CommunityPost) {
        Task {
            do {
                let saved = try await deps.savePost(post)
                deps.showToast(.done(saved.isNew ? "Saved to Liked Songs: \(saved.track.title)"
                                                 : "Already in your library: \(saved.track.title)"))
            } catch {
                deps.showToast(.failed("Couldn\u{2019}t save this song.", error))
            }
        }
    }

    private func delete(_ post: CommunityPost) async {
        do {
            try await deps.community.delete(post)
            deps.showToast(.done("Post deleted"))
            if let onClose { onClose() } else { dismiss() }
        } catch {
            deps.showToast(.failed("Couldn\u{2019}t delete this post.", error))
        }
    }

    private func block(_ post: CommunityPost) async {
        do {
            try await MessagesService.shared.setBlocked(post.author.id, true)
            deps.showToast(.done("Blocked \(post.author.name)."))
            if let onClose { onClose() } else { dismiss() }
        } catch {
            deps.showToast(.failed("Couldn\u{2019}t block them.", error))
        }
    }

    private func deleteComment(_ comment: PostComment) async {
        guard let post else { return }
        do {
            try await deps.community.deleteComment(comment.id)
            if replyTo?.id == comment.id { replyTo = nil }
            await refresh(post.id)
        } catch {
            deps.showToast(.failed("Couldn\u{2019}t delete the comment.", error))
        }
    }

    private func startReport(_ comment: PostComment?) {
        reportingComment = comment
        reportReason = ""
        reporting = true
    }

    private func report() async {
        guard let post else { return }
        let reason = String(reportReason.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        do {
            try await deps.community.report(post.id, comment: reportingComment?.id, reason: reason)
            deps.showToast("Thanks. We\u{2019}ll take a look.")
        } catch {
            deps.showToast(.failed("Couldn\u{2019}t send the report.", error))
        }
    }

    private func send(_ post: CommunityPost) async {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !sending else { return }
        sending = true
        defer { sending = false }
        let at = replyTo == nil && isThis && timed ? engine.clock.currentTime.rounded(.down) : nil
        do {
            try await deps.community.addComment(post.id, body: body, parentID: replyTo?.id, atSeconds: at)
            draft = ""
            replyTo = nil
            await refresh(post.id)
        } catch {
            deps.showToast(.failed(error.localizedDescription))
        }
    }

    private func count(_ n: Int, _ noun: String) -> String {
        "\(n.formatted()) \(noun)\(n == 1 ? "" : "s")"
    }

    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// "At 1:23", ticking with the player. Its own view so the page doesn't redraw every tick.
private struct TimedToggle: View {
    var clock: PlaybackClock
    @Binding var on: Bool

    var body: some View {
        Button { on.toggle() } label: {
            Label("At \(PostPageView.clock(clock.currentTime))",
                  systemImage: on ? "checkmark.circle.fill" : "circle")
                .font(.mixCaptionBold)
                .monospacedDigit()
                .foregroundStyle(on ? Color.mixPrimary : Color.mixTextSecondary)
        }
        .buttonStyle(.plain).mixHandCursor()
        .accessibilityAddTraits(on ? .isSelected : [])
        .help("Pin your comment to this moment")
    }
}

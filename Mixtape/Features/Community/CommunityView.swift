// The Community page: Following, Hot, New and Top, filtered by style. Same page as mixtape-web
// src/pages/community.astro. A sidebar item on Mac, a tab on iOS.

import SwiftUI

struct CommunityView: View {
    let onOpenPost: (String) -> Void
    let onOpenProfile: (UserProfile) -> Void

    @Environment(AppDependencies.self) private var deps

    @State private var feed: CommunityFeed = .hot
    @State private var style: PostStyle?
    @State private var allTime = false
    @State private var refreshes = 0
    @State private var posting: Track?
    @Namespace private var feedPill
    @Namespace private var periodPill
    @Namespace private var stylePill

    private struct Query: Hashable {
        let feed: CommunityFeed, style: PostStyle?, allTime: Bool, refreshes: Int, viewer: UUID?
    }

    private var viewer: UUID? { deps.authService.currentUser?.id }
    private var signedIn: Bool { viewer != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Community").font(.mixDisplay).foregroundStyle(Color.mixTextPrimary)
                if signedIn { YourEdits(library: deps.libraryService) { posting = $0 } }

                chips(CommunityFeed.allCases.filter { $0 != .following || signedIn }, selected: feed,
                      in: feedPill, title: \.title) { feed = $0 }
                if feed == .top {
                    chips([false, true], selected: allTime, in: periodPill,
                          title: { $0 ? "All Time" : "This Week" }) { allTime = $0 }
                }
                if feed != .following {
                    chips([nil] + PostStyle.allCases.map(Optional.some), selected: style,
                          in: stylePill, title: { $0?.title ?? "All" }) { style = $0 }
                }

                PostList(key: Query(feed: feed, style: style, allTime: allTime, refreshes: refreshes,
                                         viewer: viewer),
                         empty: emptyText,
                         load: { [feed, style, allTime, community = deps.community] in
                             try await community.feed(feed, style: feed == .following ? nil : style,
                                                      allTime: allTime, after: $0)
                         },
                         onOpenPost: onOpenPost, onOpenProfile: onOpenProfile)
            }
            .padding(.horizontal, inset)
            .padding(.top, 20)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 48)
        }
        .refreshable { refreshes += 1 }
        .background(MixPageBackground())
        .navigationTitle("Community")
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .onChange(of: signedIn) { _, now in if !now, feed == .following { feed = .hot } }
        .sheet(item: $posting) { track in
            PostSheet(track: track, onOpen: { code in posting = nil; onOpenPost(code) })
                .environment(deps)
        }
    }

    private var inset: CGFloat {
        #if os(macOS)
        24
        #else
        20
        #endif
    }

    private var emptyText: (title: String, message: String) {
        if feed == .following {
            return ("Nothing here yet", "Follow people to see what they post, like and repost.")
        }
        return (style.map { "No \($0.title) posts yet" } ?? "No posts yet",
                "Post an edit from your library and it shows up here.")
    }

    private func chips<T: Hashable>(_ options: [T], selected: T, in pill: Namespace.ID,
                                    title: @escaping (T) -> String,
                                    pick: @escaping (T) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(options, id: \.self) { option in
                    SectionChip(title: title(option), isSelected: option == selected, namespace: pill) { pick(option) }
                }
            }
            .mixAnimation(.mixSnappy, value: selected)
        }
        .scrollClipDisabled()
    }
}

/// Your postable edits, newest first, each with Post. A tip on how to make one when there are none.
private struct YourEdits: View {
    var library: LibraryService
    let onPost: (Track) -> Void

    var body: some View {
        let edits = library.tracks.filter { $0.edit != nil }
            .sorted { $0.dateImported > $1.dateImported }.prefix(12)
        VStack(alignment: .leading, spacing: 8) {
            Text("Your Edits").font(.mixHeadline).foregroundStyle(Color.mixTextPrimary)
            if edits.isEmpty {
                Label("Make one from any song: open its menu, choose Edit Song\u{2026}, save it, then post it here.",
                      systemImage: "slider.horizontal.3")
                    .font(.mixCaption).foregroundStyle(Color.mixTextSecondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(Array(edits)) { card($0) }
                    }
                }
                .scrollClipDisabled()
            }
        }
        .padding(.bottom, 6)
    }

    private func card(_ track: Track) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ArtworkThumbnail(data: track.artworkData, artworkRef: .track(track.id), size: 112,
                             cornerRadius: 8, placeholder: MixtapeIcons.track)
            Text(track.title).font(.mixCaptionBold).foregroundStyle(Color.mixTextPrimary).lineLimit(1)
            Text(track.edit?.label ?? "").font(.mixMicro).foregroundStyle(Color.mixTextSecondary).lineLimit(1)
            Button { onPost(track) } label: {
                Label("Post", systemImage: "paperplane").font(.mixCaptionBold)
            }
            .buttonStyle(.bordered).controlSize(.small).tint(Color.mixPrimary)
            .mixHandCursor()
            .padding(.top, 2)
        }
        .frame(width: 112, alignment: .leading)
    }
}

/// A paged list of posts. `load` gets what's on screen and returns the next page; a new `key` starts over.
struct PostList<Key: Hashable>: View {
    let key: Key
    let empty: (title: String, message: String)
    let load: ([FeedItem]) async throws -> [FeedItem]
    let onOpenPost: (String) -> Void
    let onOpenProfile: (UserProfile) -> Void

    @State private var items: [FeedItem] = []
    @State private var loaded = false
    @State private var failed = false
    @State private var exhausted = false
    @State private var moreFailed = false

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 2) {
            if !loaded {
                ProgressView().tint(Color.mixPrimary).frame(maxWidth: .infinity).padding(.vertical, 60)
            } else if items.isEmpty {
                EmptyStateView(icon: failed ? "wifi.exclamationmark" : "music.note.list",
                               title: failed ? "Couldn\u{2019}t load these posts" : empty.title,
                               message: failed ? "Check your connection and try again." : empty.message)
                    .padding(.top, 30)
                    .frame(maxWidth: .infinity)
            }
            ForEach(items) { item in
                PostRow(item: item, onOpenPost: onOpenPost, onOpenProfile: onOpenProfile)
            }
            if loaded, !exhausted, !items.isEmpty {
                if moreFailed {
                    Button("Try Again") { moreFailed = false }
                        .buttonStyle(.plain).mixHandCursor()
                        .font(.mixButtonSmall).foregroundStyle(Color.mixPrimary)
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                } else {
                    ProgressView().tint(Color.mixPrimary).frame(maxWidth: .infinity).padding(.vertical, 16)
                        .task(id: items.count) { await next() }
                }
            }
        }
        .task(id: key) { await first() }
    }

    private func first() async {
        loaded = false
        items = []
        do {
            let page = try await load([])
            guard !Task.isCancelled else { return }
            items = page
            exhausted = page.count < CommunityService.pageSize
            failed = false
        } catch {
            guard !Task.isCancelled else { return }
            failed = true
        }
        moreFailed = false
        loaded = true
    }

    private func next() async {
        let before = items
        do {
            let page = try await load(before)
            // The filters changed while this page was on its way.
            guard !Task.isCancelled, items == before else { return }
            let seen = Set(before.map(\.id))
            items = before + page.filter { !seen.contains($0.id) }
            exhausted = page.count < CommunityService.pageSize
        } catch {
            if !Task.isCancelled { moreFailed = true }
        }
    }
}

/// SoundCloud style: cover, play, who and what, the waveform with its timed comments, the counts.
/// The cover, play and waveform play it; the rest opens the post.
private struct PostRow: View {
    let item: FeedItem
    let onOpenPost: (String) -> Void
    let onOpenProfile: (UserProfile) -> Void

    @Environment(AppDependencies.self) private var deps
    @Environment(PlaybackEngine.self) private var engine
    @Environment(QueueService.self) private var queueService
    private var marks: PlayingPostMarks { .shared }
    @State private var hovered = false

    private var post: CommunityPost { item.post }
    private var isThis: Bool { queueService.currentTrack?.id == post.id }
    private var playing: Bool { isThis && engine.state.isPlaying }
    private var duration: Double { isThis && engine.duration > 0 ? engine.duration : post.duration ?? 0 }

    #if os(macOS)
    private let coverSize: CGFloat = 96
    private let waveHeight: CGFloat = 44
    #else
    private let coverSize: CGFloat = 76
    private let waveHeight: CGFloat = 34
    #endif

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Button { play() } label: { cover }
                .buttonStyle(.plain).mixHandCursor()
                .accessibilityLabel(playing ? "Pause \(post.title)" : "Play \(post.title)")

            VStack(alignment: .leading, spacing: 6) {
                if let activity = item.activity {
                    Label(activity, systemImage: item.kind == "liked" ? "heart.fill" : "arrow.2.squarepath")
                        .font(.mixCaption).foregroundStyle(Color.mixTextSecondary).lineLimit(1)
                }
                HStack(spacing: 10) {
                    Button { play() } label: {
                        Image(systemName: playing ? MixtapeIcons.pause : MixtapeIcons.play)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.mixOnAccent)
                            .frame(width: 30, height: 30)
                            .background(Color.mixAccentFill, in: Circle())
                    }
                    .buttonStyle(.plain).mixHandCursor()
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Button(post.author.name) { onOpenProfile(post.author) }
                                .buttonStyle(.plain).mixHandCursor()
                                .font(.mixCaptionBold).foregroundStyle(Color.mixTextSecondary)
                            Text("\u{00B7} \(InboxService.age(item.at ?? post.createdAt))")
                                .font(.mixCaption).foregroundStyle(Color.mixTextTertiary)
                        }
                        Text(post.title)
                            .font(.mixBodyBold)
                            .foregroundStyle(isThis ? Color.mixPrimary : Color.mixTextPrimary)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(post.edit.label)
                        .font(.mixMicro.weight(.semibold))
                        .foregroundStyle(Color.mixTextSecondary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                        .lineLimit(1)
                }
                wave
                HStack(spacing: 12) {
                    stat(post.liked ? "heart.fill" : "heart", post.likes)
                    stat("arrow.2.squarepath", post.reposts)
                    stat("bubble.left", post.comments)
                    stat("play.fill", post.plays)
                    Spacer(minLength: 0)
                }
                .font(.mixMicro).foregroundStyle(Color.mixTextTertiary)
            }
        }
        .padding(10)
        .background(hovered ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture { onOpenPost(post.shareCode) }
        .mixHoverCursor { hovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Open Post") { onOpenPost(post.shareCode) }
    }

    /// Ticks only while this post is the one playing.
    @ViewBuilder
    private var wave: some View {
        let peaks = Waveform.decode(post.waveform)
        if isThis {
            PlaybackProgress(clock: engine.clock, duration: duration) { progress in
                WaveformView(peaks: peaks, progress: progress, marks: commentMarks, height: waveHeight,
                             duration: duration, onSeek: seek, onMark: { seek($0.at) })
            }
        } else {
            WaveformView(peaks: peaks, height: waveHeight, duration: duration, onSeek: seek)
        }
    }

    private var commentMarks: [WaveMark] {
        guard marks.post == post.id, duration > 0 else { return [] }
        return marks.comments.compactMap { c in
            c.atSeconds.map { WaveMark(id: c.id, at: min($0 / duration, 1), label: "\(c.author.name): \(c.body)",
                                       avatar: c.author.avatarURL, name: c.author.username) }
        }
    }

    private var cover: some View {
        CachedRemoteImage(url: post.artworkURL) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            ArtworkThumbnail(data: nil, size: coverSize, cornerRadius: 8, placeholder: MixtapeIcons.track)
        }
        .frame(width: coverSize, height: coverSize)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func stat(_ symbol: String, _ n: Int) -> some View {
        Label(n.formatted(), systemImage: symbol).monospacedDigit()
    }

    /// A spot on the waveform: jump there, starting the post if it isn't on.
    private func seek(_ fraction: Double) {
        guard isThis else { return play(at: fraction * (post.duration ?? 0)) }
        engine.seek(to: fraction * duration)
        if !engine.state.isPlaying { engine.togglePlayPause() }
    }

    /// Same as the post page's play: the first press counts a play.
    private func play(at seconds: Double? = nil) {
        guard !isThis else { return engine.togglePlayPause() }
        deps.community.play(post.id)
        Task {
            let artwork = if let url = post.artworkURL { try? await URLSession.shared.data(from: url).0 } else { Data?.none }
            let track = post.track(artwork: artwork)
            await engine.play(track: track, in: [track], source: .named(post.title))
            if let seconds, seconds > 0 { engine.seek(to: seconds) }
        }
    }
}

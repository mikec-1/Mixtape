// PlaylistByline.swift
// Mixtape — SharedUI/Components
//
// The line under a playlist title that says whose it is: overlapping avatars,
// then names, then — on a second line — who it was made for and the counts.
//
// Every playlist header had a grey metadata line and nothing else, which is fine
// while every playlist belongs to the person reading it. Once a library can hold
// a mix the app made and a playlist someone else published, "whose is this?" is
// the first question the header has to answer — and for a collaborative playlist
// the answer is several people, which is why this takes a list rather than a name.
//
// Two lines rather than one. The owner is the headline fact, so it sits beside
// the avatar at body weight with nothing competing for the row; everything that
// qualifies it — "Made for mike", the song count — drops underneath at caption
// size. Strung together on one line the owner was the same 11pt grey as the
// duration, which made the app's own name read as another statistic.
//
// Names are views rather than runs of one string, because each one is a way in:
// tapping an owner opens their profile, and tapping the "made for" name opens
// that person's. `onOpenMember` nil leaves the whole thing inert, which is right
// wherever there's no page to go to.

import SwiftUI

/// One name in a byline. `avatarURL` nil falls back to a monogram, exactly as
/// `AvatarView` does everywhere else.
public struct BylineMember: Identifiable, Hashable, Sendable {

    public let id: UUID
    public let name: String
    public let avatarURL: URL?
    /// Draws the app's own mark rather than a monogram. Mixtape isn't a user and
    /// shouldn't wear an "M" in a circle like one.
    public let isApp: Bool

    public init(id: UUID = UUID(), name: String, avatarURL: URL? = nil, isApp: Bool = false) {
        self.id        = id
        self.name      = name
        self.avatarURL = avatarURL
        self.isApp     = isApp
    }

    /// The app itself, as it appears on every mix it builds.
    public static let mixtape = BylineMember(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A0")!,
        name: "Mixtape",
        isApp: true
    )
}

public struct PlaylistByline: View {

    private let members: [BylineMember]
    /// "79 songs, 4 hr 44 min" — the tail of the second line.
    private let metadata: String?
    /// The person a mix was built for. Rendered as "Made for <name>" under the
    /// owner, the way Spotify labels a playlist it made for you without changing
    /// whose playlist it is. A member rather than a string so the name can be
    /// tapped like any other.
    private let madeFor: BylineMember?
    /// Tapping a name opens that member's page. Nil leaves the byline inert.
    private let onOpenMember: ((BylineMember) -> Void)?

    /// How many faces are drawn before the rest become "+N". Three is where the
    /// stack stops reading as a group and starts reading as a smear.
    private static let maxAvatars = 3

    private static let avatarSize: CGFloat = 28

    public init(members: [BylineMember],
                metadata: String? = nil,
                madeFor: BylineMember? = nil,
                onOpenMember: ((BylineMember) -> Void)? = nil) {
        self.members      = members
        self.metadata     = metadata
        self.madeFor      = madeFor
        self.onOpenMember = onOpenMember
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                avatarStack
                names
            }
            if hasSecondLine { secondLine }
        }
    }

    // MARK: Avatars

    private var avatarStack: some View {
        HStack(spacing: -8) {
            ForEach(shownMembers) { member in
                avatar(for: member)
                    .overlay(Circle().strokeBorder(Color.mixBackground, lineWidth: 2))
                    .zIndex(1)
                    .onTapGesture { onOpenMember?(member) }
                    #if os(macOS)
                    .help(member.name)
                    #endif
            }
        }
        // The names right beside them say all of this, and a screen reader
        // shouldn't hear the byline twice.
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func avatar(for member: BylineMember) -> some View {
        if member.isApp {
            MixtapeMark(size: Self.avatarSize)
        } else {
            AvatarView(url: member.avatarURL, fallbackText: member.name, size: Self.avatarSize)
        }
    }

    private var shownMembers: [BylineMember] {
        Array(members.prefix(Self.maxAvatars))
    }

    // MARK: Lines

    /// "mike, xyz and abc" — the owners, at body weight beside their faces.
    private var names: some View {
        HStack(spacing: 0) {
            ForEach(nameSegments) { segment in
                switch segment.kind {
                case .name(let member):
                    BylineName(text: member.name,
                               font: .mixBodyBold,
                               color: .mixTextPrimary,
                               action: onOpenMember.map { open in { open(member) } })
                case .plain(let text):
                    Text(text)
                        .font(.mixBodyBold)
                        .foregroundStyle(Color.mixTextPrimary)
                }
            }
        }
        .lineLimit(1)
    }

    private var hasSecondLine: Bool {
        madeFor != nil || !(metadata ?? "").isEmpty
    }

    /// "Made for mike  •  30 songs, 1 hr 52 min".
    private var secondLine: some View {
        HStack(spacing: 0) {
            if let madeFor {
                Text("Made for ")
                BylineName(text: madeFor.name,
                           font: .mixSubtext,
                           color: .mixTextSecondary,
                           action: onOpenMember.map { open in { open(madeFor) } })
                if !(metadata ?? "").isEmpty { Text("  •  ") }
            }
            if let metadata, !metadata.isEmpty { Text(metadata) }
        }
        .font(.mixSubtext)
        .foregroundStyle(Color.mixTextSecondary)
        .lineLimit(1)
    }

    // MARK: Name segments

    /// One piece of the owner line: either a member (tappable) or the glue
    /// between two of them. Modelled rather than formatted because a name has to
    /// be its own view to be pressable, and the commas mustn't be.
    private struct Segment: Identifiable {
        enum Kind {
            case name(BylineMember)
            case plain(String)
        }
        let id: String
        let kind: Kind
    }

    /// "mike", "mike and xyz", "mike, xyz and abc", "mike, xyz and 4 others".
    private var nameSegments: [Segment] {
        let all = members
        switch all.count {
        case 0:
            return []
        case 1:
            return [Segment(id: "n0", kind: .name(all[0]))]
        case 2:
            return [Segment(id: "n0", kind: .name(all[0])),
                    Segment(id: "s0", kind: .plain(" and ")),
                    Segment(id: "n1", kind: .name(all[1]))]
        case 3:
            return [Segment(id: "n0", kind: .name(all[0])),
                    Segment(id: "s0", kind: .plain(", ")),
                    Segment(id: "n1", kind: .name(all[1])),
                    Segment(id: "s1", kind: .plain(" and ")),
                    Segment(id: "n2", kind: .name(all[2]))]
        default:
            // The overflow is a count, not a name, so it stays plain — there is
            // no single profile behind "4 others" to open.
            return [Segment(id: "n0", kind: .name(all[0])),
                    Segment(id: "s0", kind: .plain(", ")),
                    Segment(id: "n1", kind: .name(all[1])),
                    Segment(id: "s1", kind: .plain(" and \(all.count - 2) others"))]
        }
    }
}

// MARK: - One tappable name

/// A name that opens something when there's something to open, and is ordinary
/// text when there isn't — so the byline never offers a press that goes nowhere.
private struct BylineName: View {

    let text: String
    let font: Font
    let color: Color
    let action: (() -> Void)?

    @State private var isHovered = false

    var body: some View {
        if let action {
            Button(action: action) {
                Text(text)
                    .font(font)
                    .foregroundStyle(color)
                    // Underline on hover rather than always: a byline full of
                    // permanently underlined names reads as a form, not a
                    // sentence.
                    .underline(isHovered)
            }
            .buttonStyle(.plain).mixHandCursor()
            #if os(macOS)
            .onHover { inside in
                isHovered = inside
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            #endif
            .accessibilityLabel(text)
            .accessibilityHint("Opens \(text)")
        } else {
            Text(text)
                .font(font)
                .foregroundStyle(color)
        }
    }
}

#if DEBUG
#Preview {
    VStack(alignment: .leading, spacing: 24) {
        PlaylistByline(members: [.mixtape],
                       metadata: "30 songs, 1 hr 52 min",
                       madeFor: BylineMember(name: "mike"),
                       onOpenMember: { _ in })

        PlaylistByline(members: [BylineMember(name: "Hannah"), BylineMember(name: "Franzi")],
                       metadata: "53 songs, 3 hr 8 min",
                       onOpenMember: { _ in })

        PlaylistByline(members: [BylineMember(name: "mike"),
                                 BylineMember(name: "xyz"),
                                 BylineMember(name: "abc")],
                       metadata: "12 songs, 44 min")
    }
    .padding()
    .background(Color.mixBackground)
}
#endif

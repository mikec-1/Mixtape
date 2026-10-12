// Byline under a playlist title: avatars and owner names, then a second
// caption line with "Made for" and counts. Takes a list for collaborative
// playlists. Names are tappable views (owner -> profile); nil `onOpenMember`
// makes it inert.

import SwiftUI

/// `avatarURL` nil falls back to the blob `AvatarView` draws from `username`.
public struct BylineMember: Identifiable, Hashable, Sendable {

    public let id: UUID
    public let name: String
    public let username: String?
    public let avatarURL: URL?
    /// Draws the app's mark instead of a monogram.
    public let isApp: Bool

    public init(id: UUID = UUID(), name: String, username: String? = nil, avatarURL: URL? = nil, isApp: Bool = false) {
        self.id        = id
        self.name      = name
        self.username  = username
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
    /// "79 songs, 4 hr 44 min".
    private let metadata: String?
    /// Who a mix was built for, shown as "Made for <name>". A member so it's tappable.
    private let madeFor: BylineMember?
    /// Tapping a name opens that member's page. Nil leaves the byline inert.
    private let onOpenMember: ((BylineMember) -> Void)?

    /// Faces shown before "+N".
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
        // The names beside them say the same; don't read it twice.
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func avatar(for member: BylineMember) -> some View {
        if member.isApp {
            MixtapeMark(size: Self.avatarSize)
        } else {
            AvatarView(url: member.avatarURL, seed: member.username ?? member.name, size: Self.avatarSize)
        }
    }

    private var shownMembers: [BylineMember] {
        Array(members.prefix(Self.maxAvatars))
    }

    // MARK: Lines

    /// "mike, xyz and abc", beside the faces.
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

    /// A name (tappable) or the glue between names. Separate so commas aren't pressable.
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
            // "4 others" has no single profile to open, so it stays plain.
            return [Segment(id: "n0", kind: .name(all[0])),
                    Segment(id: "s0", kind: .plain(", ")),
                    Segment(id: "n1", kind: .name(all[1])),
                    Segment(id: "s1", kind: .plain(" and \(all.count - 2) others"))]
        }
    }
}

// MARK: - One tappable name

/// Tappable only when there's somewhere to go.
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
                    // Underline on hover only.
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

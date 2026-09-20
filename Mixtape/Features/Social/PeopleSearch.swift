// PeopleSearch.swift
// Mixtape — Features/Social
//
// People results for the app's ordinary search field.
//
// Library search is local, synchronous and instant; people search is a network
// round trip. Mixing them would make the fast thing wait for the slow one, so
// this is a separate object with its own debounce that the search views render
// as their own section — songs, albums and artists appear on the keystroke, and
// people drop in underneath a moment later.
//
// Shared by the Discover search on both platforms — and still by the older
// library-only search views — so the debounce, the minimum query length and the
// stale-result guard are written once.

import SwiftUI
import Combine

@MainActor
final class PeopleSearch: ObservableObject {

    @Published private(set) var results: [UserProfile] = []
    @Published private(set) var isSearching = false
    /// Set only when a search actually failed. A network error here must never
    /// take over the view — the library results beside it are still perfectly
    /// good — so it renders as a single quiet line, or not at all.
    @Published private(set) var failed = false

    /// Handles are short; one character matches most of the directory and costs
    /// a round trip to say so.
    static let minimumQueryLength = 2

    private var lastQuery = ""

    /// Drops everything, for when the active scope stops asking for people.
    func clear() {
        results = []
        failed = false
        isSearching = false
        lastQuery = ""
    }

    /// The service is handed in per call rather than held: the views that own one
    /// of these get theirs from the environment, which isn't available at the
    /// moment a `@StateObject` is constructed.
    ///
    /// Runs inside a `.task(id: query)`, so a new keystroke cancels the previous
    /// call before it reaches the network.
    func search(_ raw: String,
                using authService: any AuthServiceProtocol,
                limit: Int = 20) async {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        lastQuery = query

        guard query.count >= Self.minimumQueryLength else {
            results = []
            failed = false
            isSearching = false
            return
        }

        do {
            try await Task.sleep(for: .milliseconds(350))
        } catch {
            return   // superseded by a newer keystroke
        }

        isSearching = true
        failed = false
        defer { isSearching = false }

        do {
            let found = try await authService.searchUsers(matching: query, limit: limit)
            guard query == lastQuery else { return }
            results = found
        } catch is CancellationError {
            return
        } catch {
            results = []
            failed = true
        }
    }
}

// MARK: - Row

/// One person in a results list. Sized to sit next to song rows without
/// out-shouting them: circular avatar, handle, and the join date as the only
/// thing distinguishing two similar names.
struct PersonResultRow: View {

    let profile: UserProfile
    var showsChevron = true

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(url: profile.avatarURL, fallbackText: profile.username, size: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .font(.mixBody)
                    .foregroundStyle(Color.mixTextPrimary)
                    .lineLimit(1)
                Text("@\(profile.username)" + (profile.createdAt.map {
                    " · Joined \($0.formatted(.dateTime.month(.abbreviated).year()))"
                } ?? ""))
                    .font(.mixCaption)
                    .foregroundStyle(Color.mixTextTertiary)
            }

            Spacer(minLength: 10)

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.mixTextTertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(minHeight: 56)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovering ? Color.mixSurface2 : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}

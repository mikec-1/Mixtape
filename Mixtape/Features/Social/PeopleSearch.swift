// People results for the search field. A network search with its own debounce, drawn
// as its own section so the local results don't wait. Shared by the Discover and library
// searches on both platforms.

import SwiftUI
import Combine

@MainActor
final class PeopleSearch: ObservableObject {

    @Published private(set) var results: [UserProfile] = []
    @Published private(set) var isSearching = false
    /// Set only on failure, drawn as one quiet line at most.
    @Published private(set) var failed = false

    /// One character matches most of the directory.
    static let minimumQueryLength = 2

    private var lastQuery = ""

    /// Drops everything, for when the active scope stops asking for people.
    func clear() {
        results = []
        failed = false
        isSearching = false
        lastQuery = ""
    }

    /// The service is passed per call: the owning views get it from the environment,
    /// which isn't available when a `@StateObject` is built. Runs inside `.task(id: query)`.
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

/// One person in a results list: avatar, handle and join date.
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

// Search public profiles by handle (prefix match) and open a read-only profile.
// Presented as a sheet from Settings, sized for a handful of results.

import SwiftUI

public struct FindPeopleView: View {

    @Environment(\.dismiss) private var dismiss

    private let authService: any AuthServiceProtocol
    /// Where a chosen person opens. Nil pushes inside this window; macOS opens a page in the main window.
    private let onSelect: ((UserProfile) -> Void)?

    @State private var query: String = ""
    @State private var results: [UserProfile] = []
    @State private var isSearching = false
    @State private var didSearch = false
    @State private var errorMessage: String?

    public init(authService: any AuthServiceProtocol,
                onSelect: ((UserProfile) -> Void)? = nil) {
        self.authService = authService
        self.onSelect = onSelect
    }

    public var body: some View {
        // Only iOS pushes; on the Mac both callers pass `onSelect`, so no navigation stack.
        #if os(macOS)
        sheet
        #else
        NavigationStack {
            sheet
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: UserProfile.self) { profile in
                    ProfilePageView(profile: profile)
                }
        }
        #endif
    }

    private var sheet: some View {
        MixSheet(title: "Find People",
                 subtitle: "Search public profiles by username.",
                 size: .large,
                 scroll: false) {
            content
        }
        // Debounced search: re-runs whenever the query settles.
        .task(id: query) {
            await runSearch()
        }
    }

    // MARK: - Content

    // The results own their scroll view so the search field stays pinned.
    private var content: some View {
        VStack(spacing: 0) {
            MixSearchField(text: $query,
                           placeholder: "Search by username",
                           isBusy: isSearching,
                           isProminent: true,
                           autoFocus: true)
                .padding(.horizontal, MixSheetMetrics.margin)
                .padding(.bottom, 12)

            resultsArea
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    @ViewBuilder
    private var resultsArea: some View {
        if let errorMessage {
            prompt(icon: "wifi.exclamationmark",
                   title: "Couldn't search",
                   subtitle: errorMessage,
                   tint: .mixDestructive)
        } else if results.isEmpty && didSearch && !trimmedQuery.isEmpty && !isSearching {
            prompt(icon: "person.fill.questionmark",
                   title: "No one found",
                   subtitle: "No account matches “\(trimmedQuery)”.")
        } else if results.isEmpty {
            prompt(icon: "at",
                   title: "Search by username",
                   subtitle: "Handles are exact — try the start of one.")
        } else {
            resultList
        }
    }

    private var resultList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 7) {
                Text(results.count == 1 ? "1 RESULT" : "\(results.count) RESULTS")
                    .font(.mixCaptionBold)
                    .tracking(0.6)
                    .foregroundStyle(Color.mixTextSecondary)
                    .padding(.leading, 4)

                VStack(spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, profile in
                        if let onSelect {
                            Button {
                                onSelect(profile)
                                dismiss()
                            } label: {
                                PersonRow(profile: profile)
                            }
                            .buttonStyle(.plain).mixHandCursor()
                        } else {
                            NavigationLink(value: profile) {
                                PersonRow(profile: profile)
                            }
                            .buttonStyle(.plain).mixHandCursor()
                        }

                        if index < results.count - 1 {
                            Rectangle()
                                .fill(Color.mixSeparator)
                                .frame(height: 0.5)
                                .padding(.leading, 62)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.mixSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.mixSeparator, lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .padding(.horizontal, MixSheetMetrics.margin)
            .padding(.bottom, 20)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    /// A small inline hint by the field rather than a centred empty state.
    private func prompt(icon: String,
                        title: String,
                        subtitle: String,
                        tint: Color = .mixTextTertiary) -> some View {
        VStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(tint)
                .padding(.bottom, 2)
            Text(title)
                .font(.mixBodyBold)
                .foregroundStyle(Color.mixTextSecondary)
            Text(subtitle)
                .font(.mixSubtext)
                .foregroundStyle(Color.mixTextTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.top, 48)
    }

    // MARK: - Search

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runSearch() async {
        let q = trimmedQuery
        guard !q.isEmpty else {
            results = []
            didSearch = false
            errorMessage = nil
            return
        }

        // Debounce. A new keystroke cancels and throws before the network call.
        do {
            try await Task.sleep(for: .milliseconds(350))
        } catch {
            return
        }

        isSearching = true
        errorMessage = nil
        defer { isSearching = false }

        do {
            let found = try await authService.searchUsers(matching: q, limit: 30)
            // Ignore stale results if the query changed while we were waiting.
            guard q == trimmedQuery else { return }
            results = found
            didSearch = true
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
            didSearch = true
        }
    }
}

// MARK: - Row

/// One search hit. The join date tells similar handles apart.
private struct PersonRow: View {

    let profile: UserProfile

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(url: profile.avatarURL, seed: profile.username, size: 38)

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

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.mixTextTertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(minHeight: 52)
        .background(isHovering ? Color.mixSurface2 : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}

// FindPeopleView.swift
// Mixtape — Features/Social
//
// Username discovery: search public profiles by handle (prefix match) and open
// a read-only profile for any result. Presented as a sheet from Settings.
//
// The window is small on purpose. It used to open at 460×520 with a full-bleed
// empty state — a 40pt icon and two lines of instruction floating in the middle
// of a void, under a search box that had 16pt of padding on every side. All of
// that shouted, and the loudest thing on screen was the filled orange Done
// button, which is the one control nobody opens this window to press.
//
// So: the field is the view, the prompt under it is quiet, and Done is plain
// text in the title bar. The window is sized to fit a handful of results rather
// than to fit the largest thing it might ever show.

import SwiftUI

public struct FindPeopleView: View {

    @Environment(\.dismiss) private var dismiss

    private let authService: any AuthServiceProtocol
    /// Where a chosen person should open. When nil the profile is pushed inside
    /// this window; macOS passes a closure instead, because a 420pt sheet is the
    /// wrong frame for a page built to be looked at.
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
        // Only iOS pushes: both macOS call sites hand in `onSelect` so the
        // chosen profile opens as a page in the main window. A navigation stack
        // that never navigates was most of what made this look like a phone
        // screen in a Mac window, so on the Mac there isn't one.
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

    // `scroll: false` above — the results own their scroll view, and the
    // search field has to stay pinned above it rather than scrolling away.
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

    /// The quiet version of an empty state: it sits near the field it's talking
    /// about instead of being centred in whatever space is left over, and it's
    /// sized like a hint rather than a headline.
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

        // Debounce: wait for typing to settle. Cancellation (new keystroke)
        // throws and bails out before hitting the network.
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

/// One search hit. The join date isn't decoration — a list of bare handles gives
/// you nothing to tell two similar names apart by.
private struct PersonRow: View {

    let profile: UserProfile

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(url: profile.avatarURL, fallbackText: profile.username, size: 38)

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

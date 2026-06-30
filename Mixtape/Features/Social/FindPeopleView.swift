// FindPeopleView.swift
// Mixtape — Features/Social
//
// Username discovery: search public profiles by handle (prefix match) and open
// a read-only profile for any result. Presented as a sheet from Settings.

import SwiftUI

public struct FindPeopleView: View {

    @Environment(\.dismiss) private var dismiss

    private let authService: any AuthServiceProtocol

    @State private var query: String = ""
    @State private var results: [UserProfile] = []
    @State private var isSearching = false
    @State private var didSearch = false
    @State private var errorMessage: String?

    public init(authService: any AuthServiceProtocol) {
        self.authService = authService
    }

    public var body: some View {
        NavigationStack {
            content
                .background(Color.mixBackground.ignoresSafeArea())
                .navigationTitle("Find People")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarColorScheme(.dark, for: .navigationBar)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .foregroundStyle(Color.mixPrimary)
                    }
                }
                .navigationDestination(for: UserProfile.self) { profile in
                    UserProfileView(profile: profile)
                }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 520)
        #endif
        // Debounced search: re-runs whenever the query settles.
        .task(id: query) {
            await runSearch()
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            searchField
            Divider().background(Color.mixSeparator)
            resultsList
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.mixTextSecondary)
            TextField("Search by username", text: $query)
                .textFieldStyle(.plain)
                .font(.mixBody)
                .foregroundStyle(Color.mixTextPrimary)
                .autocorrectionDisabled(true)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.mixTextTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(Color.mixSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(16)
    }

    @ViewBuilder
    private var resultsList: some View {
        if let errorMessage {
            messageState(icon: "wifi.exclamationmark", title: "Couldn't search", subtitle: errorMessage)
        } else if isSearching && results.isEmpty {
            ProgressView()
                .controlSize(.regular)
                .tint(Color.mixPrimary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if results.isEmpty && didSearch && !trimmedQuery.isEmpty {
            messageState(icon: "person.fill.questionmark",
                         title: "No users found",
                         subtitle: "No one matches “\(trimmedQuery)”.")
        } else if trimmedQuery.isEmpty {
            messageState(icon: "person.2",
                         title: "Discover listeners",
                         subtitle: "Search for someone by their username to view their profile.")
        } else {
            List {
                ForEach(results) { profile in
                    NavigationLink(value: profile) {
                        row(for: profile)
                    }
                    .listRowBackground(Color.mixSurface)
                }
            }
            .scrollContentBackground(.hidden)
        }
    }

    private func row(for profile: UserProfile) -> some View {
        HStack(spacing: 12) {
            AvatarView(url: profile.avatarURL, fallbackText: profile.username, size: 44)
            Text("@\(profile.username)")
                .font(.mixBodyBold)
                .foregroundStyle(Color.mixTextPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private func messageState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(Color.mixTextTertiary)
            Text(title)
                .font(.mixTitle2)
                .foregroundStyle(Color.mixTextPrimary)
            Text(subtitle)
                .font(.mixBody)
                .foregroundStyle(Color.mixTextSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

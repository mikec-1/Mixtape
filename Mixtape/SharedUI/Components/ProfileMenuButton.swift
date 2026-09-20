// ProfileMenuButton.swift
// Mixtape — SharedUI/Components
//
// The avatar in the corner of the window, and the menu behind it.
//
// Why a menu rather than a button that opens the profile
// ------------------------------------------------------
// Everything scoped to "me" — the public profile, the account, the people
// search, signing out — lived three clicks inside Settings → Account, and the
// corner avatar is the one piece of chrome that can hold all four. Spending it
// on a single destination would have made the profile one click cheaper and left
// the other three exactly where they were. Profile is the first item, so the
// thing this button exists for is still the thing under the cursor.
//
// Settings is deliberately absent even though Spotify lists it: the Mac sidebar
// has a permanent Settings row and the iOS Home bar has a gear right beside this
// avatar. Spotify puts it here because it has nowhere else to.
//
// The two destinations differ by platform and nothing else — macOS drills into
// the content column through MacAppState, iOS presents sheets, because those are
// the shapes each platform already uses for a profile.

import SwiftUI

public struct ProfileMenuButton: View {

    @EnvironmentObject private var deps: AppDependencies
    @Environment(\.openURL) private var openURL
    #if os(macOS)
    @EnvironmentObject private var appState: MacAppState
    #endif

    /// Diameter of the avatar. The surrounding hit target is padded out to match
    /// whatever sits next to it.
    private let size: CGFloat

    /// The real `profiles` row, once it arrives. The handle on that row is what
    /// other people see and can differ from the display name held in the session,
    /// so the menu opens on the local guess and corrects itself rather than
    /// making the button wait on a round trip.
    @State private var resolvedProfile: UserProfile?

    @State private var showSignOutConfirm = false
    @State private var showFindPeople     = false
    #if os(iOS)
    @State private var showMyProfile = false
    @State private var showAccount   = false
    #endif
    #if os(macOS)
    @State private var isHovering = false
    #endif

    public init(size: CGFloat = 26) {
        self.size = size
    }

    // MARK: - Identity

    private var user: AppUser? { deps.authService.currentUser }

    /// The signed-in user seen as a `profiles` row — the shape the profile page
    /// takes for everyone.
    private var me: UserProfile? {
        guard let user else { return nil }
        if let resolved = resolvedProfile, resolved.id == user.id { return resolved }
        return UserProfile(id: user.id,
                           username: user.username ?? user.displayName,
                           displayName: user.displayName,
                           avatarURL: user.avatarURL)
    }

    // MARK: - Body

    public var body: some View {
        // Nothing to show and nowhere to go while signed out. The shells that
        // host this button swap themselves for the auth flow, so this is a guard
        // rather than a state anyone sees.
        if let user {
            menu(for: user)
                #if os(iOS)
                .padding(.horizontal, -max(0, 44 - (size + 2)) / 2)
                #endif
                .task(id: user.id) {
                    resolvedProfile = try? await deps.authService.fetchProfile(id: user.id)
                }
                .sheet(isPresented: $showFindPeople) {
                    #if os(macOS)
                    // A profile is a page in the main window, not something to
                    // read through a 420pt porthole — the sheet hands the choice
                    // back and closes rather than pushing inside itself.
                    FindPeopleView(authService: deps.authService) { profile in
                        appState.showProfile(profile)
                    }
                    #else
                    FindPeopleView(authService: deps.authService)
                    #endif
                }
                #if os(iOS)
                .sheet(isPresented: $showMyProfile) {
                    NavigationStack {
                        if let me {
                            ProfilePageView(profile: me)
                                .environmentObject(deps)
                                .toolbar {
                                    ToolbarItem(placement: .topBarTrailing) {
                                        Button("Done") { showMyProfile = false }
                                            .foregroundStyle(Color.mixPrimary)
                                    }
                                }
                        }
                    }
                }
                .sheet(isPresented: $showAccount) {
                    NavigationStack {
                        AccountSettingsView()
                            .environmentObject(deps)
                            .background(Color.mixBackground.ignoresSafeArea())
                            .navigationTitle("Account")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbarColorScheme(.dark, for: .navigationBar)
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Done") { showAccount = false }
                                        .foregroundStyle(Color.mixPrimary)
                                }
                            }
                    }
                }
                #endif
                .confirmationDialog("Sign Out",
                                    isPresented: $showSignOutConfirm,
                                    titleVisibility: .visible) {
                    Button("Sign Out", role: .destructive) {
                        Task { try? await deps.authService.signOut() }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("You'll need to sign in again to access your synced library.")
                }
        }
    }

    // MARK: - Menu

    private func menu(for user: AppUser) -> some View {
        Menu {
            // Names the account rather than decorating the menu: the sidebar
            // layout, the library and the playlists are all per-account, so
            // "which one am I in" is a real question this is the only place to
            // answer.
            Section(user.displayName) {
                Button {
                    guard let me else { return }
                    #if os(macOS)
                    appState.showProfile(me)
                    #else
                    showMyProfile = true
                    #endif
                } label: {
                    Label("Profile", systemImage: "person.crop.square")
                }

                Button {
                    #if os(macOS)
                    appState.showingAccount = true
                    #else
                    showAccount = true
                    #endif
                } label: {
                    Label("Manage Account", systemImage: "person.text.rectangle")
                }

                Button {
                    openURL(MixtapeLink.web("account"))
                } label: {
                    Label("Account on the Web", systemImage: "arrow.up.forward.square")
                }

                Button {
                    showFindPeople = true
                } label: {
                    Label("Find People", systemImage: "person.2")
                }
            }

            Divider()

            Button(role: .destructive) {
                showSignOutConfirm = true
            } label: {
                Label("Sign Out", systemImage: MixtapeIcons.signOut)
            }
        } label: {
            avatar(for: user)
        }
        #if os(macOS)
        // Same treatment as the Add menu beside it: left alone, a Menu draws
        // itself as a bordered pop-up button, which would be the only
        // chrome-heavy control in the bar.
        .menuStyle(.button)
        .buttonStyle(.plain).mixHandCursor()
        .menuIndicator(.hidden)
        .onHover { hovering in
            withMixAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
        #endif
        .help("Your account")
        .accessibilityLabel("Your account")
    }

    private func avatar(for user: AppUser) -> some View {
        AvatarView(url: me?.avatarURL ?? user.avatarURL,
                   fallbackText: user.displayName,
                   size: size)
            // The neighbours are glyphs that brighten on hover; an avatar has no
            // tint to change, so the ring is what says it's a control and not a
            // status badge.
            #if os(macOS)
            .overlay {
                Circle().strokeBorder(Color.mixTextPrimary.opacity(isHovering ? 0.5 : 0),
                                      lineWidth: 1.5)
            }
            #endif
            .frame(width: size + 2, height: size + 2)
            #if os(iOS)
            // A 44pt target around a ~32pt face; `body` hands the extra back to
            // the layout so the avatar still sits on the page's leading gutter.
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            #else
            .contentShape(Circle())
            #endif
    }
}

// Corner avatar and its menu: profile, account, find people, sign out.
// Profile first. Settings isn't here; both platforms have it next to this.
// macOS drills in through MacAppState, iOS presents sheets.

import SwiftUI

public struct ProfileMenuButton: View {

    @EnvironmentObject private var deps: AppDependencies
    @Environment(\.openURL) private var openURL
    #if os(macOS)
    @EnvironmentObject private var appState: MacAppState
    #endif

    /// Avatar diameter; the hit target is padded out around it.
    private let size: CGFloat

    /// The real `profiles` row once loaded. Its handle can differ from the
    /// session's display name, so the menu starts with the local guess.
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

    /// The signed-in user as a `profiles` row.
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
        // Signed out, the host swaps to the auth flow, so this is just a guard.
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
                    // Profiles open in the main window; the sheet hands back and closes.
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
                .mixConfirmationDialog("Sign Out",
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
            // Names the account, since layout, library and playlists are per-account.
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
        // Otherwise a Menu draws as a bordered pop-up button.
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
            // Hover ring marks it as a control, since an avatar has no tint to change.
            #if os(macOS)
            .overlay {
                Circle().strokeBorder(Color.mixTextPrimary.opacity(isHovering ? 0.5 : 0),
                                      lineWidth: 1.5)
            }
            #endif
            .frame(width: size + 2, height: size + 2)
            #if os(iOS)
            // 44pt target around the face; `body` gives the extra back to the layout.
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            #else
            .contentShape(Circle())
            #endif
    }
}

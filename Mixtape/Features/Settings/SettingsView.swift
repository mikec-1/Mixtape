// The Settings shell: decides which pane is on screen. Two columns on macOS, a root list
// that pushes on iOS. Search is indexed in SettingsCategory.swift and a hit tints its row
// (`settingsHighlight`).

import SwiftUI
#if os(macOS)
import AppKit
#endif

public struct SettingsView: View {

    @StateObject private var vm: SettingsViewModel
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var deps: AppDependencies

    @ObservedObject private var route = SettingsRoute.shared

    @State private var query = ""
    /// The row search wants pointed at, cleared a few seconds after it lands.
    @State private var highlight: String?
    #if os(macOS)
    private var selection: SettingsCategory {
        get { route.category }
        nonmutating set { route.category = newValue }
    }
    #else
    @State private var path: [SettingsCategory] = []
    #endif

    public init(
        authService:    SupabaseAuthService,
        syncService:    SupabaseSyncService,
        libraryService: LibraryService,
        importService:  ImportService,
        statsService:   ListeningStatsService,
        profileStats:   ProfileStatsService,
        downloadManager: DownloadManager
    ) {
        _vm = StateObject(wrappedValue: SettingsViewModel(
            authService:    authService,
            syncService:    syncService,
            libraryService: libraryService,
            importService:  importService,
            statsService:   statsService,
            profileStats:   profileStats,
            downloadManager: downloadManager
        ))
    }

    private var categories: [SettingsCategory] {
        SettingsCategory.visible(isSignedIn: vm.currentUser != nil,
                                 isDeveloper: vm.isDeveloper)
    }

    private var results: [SettingsSearchEntry] {
        SettingsSearchIndex.results(for: query,
                                    isSignedIn: vm.currentUser != nil,
                                    isDeveloper: vm.isDeveloper)
    }

    // MARK: - Body

    public var body: some View {
        shell
            .environment(\.settingsHighlight, highlight)
            .tint(Color.mixPrimary)
            // A deep link from outside Settings. See SettingsRoute.
            .onChange(of: route.request) { _, request in
                guard let request else { return }
                #if os(macOS)
                selection = request.category
                #else
                path = [request.category]
                #endif
                // Connections reads `opensSpotifyLibrary` after it appears, so it consumes that itself.
                if !request.opensSpotifyLibrary { route.consume() }
            }
            .onAppear {
                guard let request = route.request else { return }
                #if os(macOS)
                selection = request.category
                #else
                path = [request.category]
                #endif
                if !request.opensSpotifyLibrary { route.consume() }
            }
    }

    #if os(macOS)

    /// Categories pinned left, the chosen page on the right, like System Settings.
    private var shell: some View {
        HStack(spacing: 0) {
            categoryColumn
                .frame(width: 214)
                .background(Color.mixSurface2.opacity(0.5))

            Rectangle()
                .fill(Color.mixSeparator)
                .frame(width: 0.5)

            pane(for: visibleSelection)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(MixPageBackground())
        .navigationTitle("Settings")
    }

    /// Signing out removes Account and losing the role removes Developer.
    private var visibleSelection: SettingsCategory {
        categories.contains(selection) ? selection : .general
    }

    private var categoryColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings")
                .font(.mixTitle2)
                .foregroundStyle(Color.mixTextPrimary)
                .padding(.horizontal, 14)
                .padding(.top, 18)
                .padding(.bottom, 12)

            MixSearchField(text: $query, placeholder: "Search settings")
                .padding(.horizontal, 10)
                .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if query.isEmpty {
                        ForEach(categories) { category in
                            SidebarCategoryRow(category: category,
                                               isSelected: category == visibleSelection) {
                                selection = category
                                highlight = nil
                            }
                        }
                    } else {
                        searchResultList
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 14)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    #else

    /// iOS: a list of categories that push their own screens.
    private var shell: some View {
        NavigationStack(path: $path) {
            ZStack {
                Color.mixBackground.ignoresSafeArea()
                rootList
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .tint(Color.mixPrimary)
                }
            }
            .navigationDestination(for: SettingsCategory.self) { category in
                pane(for: category)
                    .background(Color.mixBackground.ignoresSafeArea())
                    .navigationTitle(category.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarColorScheme(.dark, for: .navigationBar)
            }
        }
    }

    private var rootList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                MixSearchField(text: $query, placeholder: "Search settings")

                if query.isEmpty {
                    SettingsCard {
                        ForEach(categories) { category in
                            RootCategoryRow(category: category) {
                                path = [category]
                                highlight = nil
                            }
                        }
                    }
                } else {
                    searchResultList
                }
            }
            .frame(maxWidth: SettingsMetrics.pageMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    #endif

    // MARK: - Search results

    @ViewBuilder
    private var searchResultList: some View {
        if results.isEmpty {
            Text("No settings match “\(query)”.")
                .font(.mixSubtext)
                .foregroundStyle(Color.mixTextTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 12)
        } else {
            SettingsCard {
                ForEach(results) { entry in
                    SettingsButtonRow(title: entry.title,
                                      subtitle: entry.category.title,
                                      icon: entry.category.icon,
                                      role: .plain,
                                      showsChevron: true) {
                        open(entry)
                    }
                }
            }
        }
    }

    /// Opens the hit's page and highlights the row, then lets the tint fade.
    private func open(_ entry: SettingsSearchEntry) {
        #if os(macOS)
        selection = entry.category
        #else
        path = [entry.category]
        #endif
        query     = ""
        highlight = entry.id

        let target = entry.id
        Task {
            try? await Task.sleep(for: .seconds(3))
            if highlight == target { withMixAnimation { highlight = nil } }
        }
    }

    // MARK: - Panes

    @ViewBuilder
    private func pane(for category: SettingsCategory) -> some View {
        switch category {
        case .account:     AccountPane(vm: vm)
        case .general:     GeneralPane()
        case .playback:    PlaybackPane(engine: deps.playbackEngine, equalizer: deps.equalizer)
        case .downloads:   DownloadsPane(manager: deps.downloadManager)
        case .storage:     StoragePane(manager: deps.downloadManager)
        case .sync:        SyncPane(vm: vm)
        case .connections: ConnectionsPane(vm: vm)
        case .about:       AboutPane()
        case .developer:   DeveloperPane(vm: vm)
        case .dangerZone:  DangerZonePane(vm: vm)
        }
    }
}

// MARK: - Category rows

/// Coloured chips only at the category level.
private struct CategoryIcon: View {
    let category: SettingsCategory
    var size: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(category.tint.opacity(0.18))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: category.icon)
                    .font(.system(size: size * 0.5, weight: .medium))
                    .foregroundStyle(category.tint)
            )
    }
}

#if os(macOS)
/// No summary line; the page beside it shows what the category holds.
private struct SidebarCategoryRow: View {

    let category: SettingsCategory
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                CategoryIcon(category: category, size: 22)
                Text(category.title)
                    .font(.mixBody)
                    .foregroundStyle(Color.mixTextPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.mixPrimary.opacity(0.18)
                          : (isHovering ? Color.mixSurface : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).mixHandCursor()
        .onHover { isHovering = $0 }
    }
}
#else
/// Includes the one-line summary so the root list is scannable.
private struct RootCategoryRow: View {

    let category: SettingsCategory
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                CategoryIcon(category: category)
                VStack(alignment: .leading, spacing: 2) {
                    Text(category.title)
                        .font(.mixBody)
                        .foregroundStyle(Color.mixTextPrimary)
                    Text(category.summary)
                        .font(.mixCaption)
                        .foregroundStyle(Color.mixTextTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 10)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.mixTextTertiary)
            }
            .padding(.horizontal, SettingsMetrics.rowPadH)
            .padding(.vertical, 10)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).mixHandCursor()
    }
}
#endif

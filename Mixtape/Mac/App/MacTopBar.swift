// Fixed top bar: search centred on the window, Add and Sync on the right. Back/forward are
// a titlebar accessory (see MacHistoryButtons); each sidebar draws its own toggle.
// Not an NSToolbar: `.principal` centres in the content column, and the titlebar sits outside
// the ⌘+/⌘- zoom transform. Traffic lights are in window points and don't zoom, so clearances
// are physical points divided by `uiScale`.

#if os(macOS)
import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

struct MacTopBar: View {

    @EnvironmentObject private var appState: MacAppState
    @EnvironmentObject private var deps:     AppDependencies
    @EnvironmentObject private var sync:     SupabaseSyncService

    /// The bar feeds the type-ahead panel and owns its keyboard; MacRootView draws it.
    @ObservedObject private var suggestions = SearchSuggestionsStore.shared

    /// So a blur can close the panel without racing a click on a row.
    @State private var fieldFocused = false

    /// Karaoke rebuilds the window and AppKit gives the orphaned focus to the
    /// field, which opened suggestions. Focus is refused until this passes.
    @State private var focusLockedUntil = Date.distantPast

    /// The chrome's current colour (wash top or fullscreen-lyrics background). Nil -> app background.
    let tint: Color?

    // MARK: - Metrics (physical window points, unscaled)

    /// Width the three window buttons plus their margins occupy.
    private static let trafficLightWidth: CGFloat = 78
    /// Floor for the bar's height so the traffic lights always have room.
    private static let minPhysicalHeight: CGFloat = 46
    private static let idealHeight:       CGFloat = 52
    /// Shared with the suggestions panel so it matches the field.
    static let searchMaxWidth:            CGFloat = 420
    /// Small so the pill nearly fills the bar.
    static let searchInset:               CGFloat = 6

    /// Bar height in the scaled space, for overlays that must clear it.
    static func height(for scale: CGFloat) -> CGFloat {
        max(idealHeight, minPhysicalHeight / max(scale, 0.1))
    }

    /// Width of the back/forward arrows AppKit floats over the leading edge.
    private static let historyWidth:       CGFloat = 66

    /// Kept clear on both sides so the centred field stays on the window's centre line and
    /// never slides under the controls. Shared with the suggestions panel: at high zoom this,
    /// not `searchMaxWidth`, sets the field's width.
    static func sideReserve(for scale: CGFloat) -> CGFloat {
        trafficLightWidth / max(scale, 0.1) + 52 + historyWidth
    }

    private var barHeight: CGFloat { Self.height(for: appState.uiScale) }
    private var sideReserve: CGFloat { Self.sideReserve(for: appState.uiScale) }


    // MARK: - Body

    var body: some View {
        ZStack {
            // Bottom layer: everything the controls don't claim drags the window.
            WindowDragArea()

            // Centred on the window, sidebar or not.
            MacSearchField(
                text: $appState.searchText,
                prompt: "What do you want to listen to?",
                focusToken: appState.searchFocusToken,
                onMoveDown: { appState.focusResults() },
                onArrowDown: { suggestions.moveHighlight(.down) },
                onArrowUp:   { suggestions.moveHighlight(.up) },
                onSubmit: {
                    // Return opens the highlighted row, otherwise commits the query.
                    if let picked = suggestions.highlightedSuggestion {
                        activateSuggestion(picked, appState: appState, deps: deps)
                    } else if !appState.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                        suggestions.rememberTerm(appState.searchText)
                        appState.showSearchResults()
                        DiscoverSessionStore.shared.commitSearch()
                    }
                    suggestions.dismiss()
                },
                onCancel: {
                    guard suggestions.isShowing else { return false }
                    suggestions.dismiss()
                    return true
                },
                onFocusChange: { focused in
                    fieldFocused = focused
                    if focused {
                        refreshSuggestions()
                    } else {
                        scheduleDismissIfStillUnfocused()
                    }
                },
                acceptsFocus: { Date.now >= focusLockedUntil },
                height: barHeight - Self.searchInset * 2
            )
            .frame(maxWidth: Self.searchMaxWidth)
            .padding(.horizontal, sideReserve)

            // Placeholder for the back/forward arrows, which are a titlebar accessory. See MacHistoryButtons.

            HStack(spacing: 4) {
                Spacer(minLength: 0)
                InboxButton(hitSize: 28)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.mixTextSecondary)
                    .buttonStyle(.plain)
                    .mixHandCursor()
                    .help("Inbox")
                    .environmentObject(deps)
                    .environmentObject(appState)
                MessagesButton(hitSize: 28)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.mixTextSecondary)
                    .buttonStyle(.plain)
                    .mixHandCursor()
                    .help("Messages")
                    .environmentObject(appState)
                MacAddMenu()
                    .environmentObject(deps)
                    .environmentObject(appState)
                MacSyncButton()
                    .environmentObject(deps)
                    .environmentObject(sync)
                // Outermost, where every desktop app that has one puts it.
                ProfileMenuButton()
                    .environmentObject(deps)
                    .environmentObject(appState)
            }
            .padding(.trailing, 14)
        }
        // One frame, not two stacked: stacked frames let the bar size to its content and centre.
        .frame(maxWidth: .infinity, minHeight: barHeight, maxHeight: barHeight)
        // Same hairline as the sidebar and content panes.
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.mixSeparator)
                .frame(height: 1)
                .allowsHitTesting(false)
        }
        .background {
            ZStack {
                MixPageBackground(glass: true)
                tint
            }
            // Must not intercept clicks, or the window stops being draggable here.
            .allowsHitTesting(false)
        }
        .onChange(of: appState.searchText) { _, _ in refreshSuggestions() }
        .onChange(of: appState.karaokeActive) { _, _ in focusLockedUntil = .now + 1 }
        // A section change parks the query, so close the panel too.
        .onChange(of: appState.selection) { _, _ in
            suggestions.clear()
            if fieldFocused { refreshSuggestions() }
        }
        // Un-committing (e.g. a playlist drill-down) closes the panel; refocusing the field reopens it.
        .onChange(of: appState.searchCommitted) { _, committed in
            if !committed { suggestions.dismiss() }
        }
    }

    // MARK: - Suggestions

    private func refreshSuggestions() {
        suggestions.update(query: appState.searchText,
                           using: deps.itunesClient,
                           library: deps.libraryService)
    }

    /// Clicking a row blurs the field first, so wait a beat before dismissing.
    private func scheduleDismissIfStillUnfocused() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            if !fieldFocused { suggestions.dismiss() }
        }
    }

}

// MARK: - Window drag area
// Window drag for the empty bar (`WindowDragGesture` needs macOS 15). Views drawn above
// still get their own clicks. Double-click keeps the system titlebar behaviour.

struct WindowDragArea: NSViewRepresentable {

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

// MARK: - History Controls
// Back/forward buttons, hosted by AppKit as a titlebar accessory. SwiftUI-drawn arrows in
// that corner rendered but never got clicks: AppKit's chrome owns hit-testing there.
// They stay at 100% under ⌘+/⌘-, like the traffic lights beside them.

private struct MacHistoryButton: View {

    let icon: String
    let label: String
    let shortcut: KeyEquivalent
    let isEnabled: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isEnabled ? Color.mixTextSecondary : Color.mixTextTertiary.opacity(0.5))
                .frame(width: 28, height: 28)
                .background {
                    if isHovering && isEnabled {
                        Circle().fill(Color.mixTextPrimary.opacity(0.08))
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain).mixHandCursor()
        .disabled(!isEnabled)
        .onHover { isHovering = $0 }
        .help("\(label) (⌘\(String(shortcut.character)))")
    }
}

/// Hand-styled to match MacTopBar. Greyed, not hidden, at the ends so they don't move.
/// The HStack gives NSHostingView a single root view.
struct MacHistoryButtons: View {

    @EnvironmentObject private var appState: MacAppState
    /// The recap and the song editor cover the window, titlebar included.
    @ObservedObject var recap: RecapService

    private var covered: Bool { recap.presented != nil || appState.editTrack != nil }

    var body: some View {
        HStack(spacing: 2) {
            MacHistoryButton(icon: "chevron.left",
                             label: "Back",
                             shortcut: "[",
                             isEnabled: appState.canGoBack) {
                appState.goBack()
            }

            MacHistoryButton(icon: "chevron.right",
                             label: "Forward",
                             shortcut: "]",
                             isEnabled: appState.canGoForward) {
                appState.goForward()
            }
        }
        .opacity(covered ? 0 : 1)
        .allowsHitTesting(!covered)
    }
}

// MARK: - Sync Button
// Device-to-device sync only; it never scans the export folder, which would resurrect deleted songs.

private struct MacSyncButton: View {
    @EnvironmentObject private var deps: AppDependencies
    @EnvironmentObject private var sync: SupabaseSyncService
    @State private var isSpinning = false

    var body: some View {
        Button {
            run(everything: false)
        } label: {
            Image(systemName: "arrow.trianglehead.2.clockwise")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.mixTextSecondary)
                .mixPulse(isActive: isSpinning)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).mixHandCursor()
        .help("Sync library (\u{2318}R)")
        // Menu commands can't reach this environment, so they post and this listens.
        .onReceive(NotificationCenter.default.publisher(for: .mixSyncLibrary)) { note in
            run(everything: note.object as? Bool == true)
        }
    }

    /// `everything` also forces each Spotify link to re-read. Kept off the plain sync to avoid rate limits.
    private func run(everything: Bool) {
        guard !isSpinning else { return }
        isSpinning = true
        Task {
            deps.downloadManager.reEvaluateDownloads()
            try? await sync.sync()
            if everything {
                await deps.spotifyFollowService.syncAll(force: true)
            }
            isSpinning = false
        }
    }
}

public extension Notification.Name {
    /// Object is `true` for "sync everything", absent or false for the library.
    static let mixSyncLibrary = Notification.Name("mix.syncLibrary")
}

// MARK: - Add Menu
// "+" for every way music enters the library, each named by source.

private struct MacAddMenu: View {
    @EnvironmentObject private var deps:     AppDependencies
    @EnvironmentObject private var appState: MacAppState

    @State private var isImporting  = false
    @State private var showSpotify  = false
    @State private var showPlaylist = false
    @State private var showGenerateMix = false
    @State private var showSmartPlaylist = false

    /// One value so both link sheets can't show at once.
    @State private var linkService: LinkImportView.Service?

    private func openSpotifyLibrary() {
        SettingsRoute.shared.openSpotifyLibrary()
        appState.goToSection(.settings)
    }

    var body: some View {
        Menu {
            Button("Import Files\u{2026}")            { isImporting  = true }
            // One entry per service so it's clear YouTube is supported.
            Button("Import Spotify Link\u{2026}")     { linkService  = .spotify }
            Button("Import YouTube Link\u{2026}")     { linkService  = .youTube }
            Button("Import Spotify Playlist\u{2026}") { showSpotify  = true }
            // Opens the picker in Settings.
            Button("Import Spotify Library\u{2026}")  { openSpotifyLibrary() }
            Divider()
            Button("New Playlist\u{2026}")            { showPlaylist = true }
            Button("Smart Playlist\u{2026}")          { showSmartPlaylist = true }
            Button("Generate a Mix\u{2026}")          { showGenerateMix = true }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.mixTextSecondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        // Otherwise a Menu draws as a bordered pop-up with a chevron.
        .menuStyle(.button)
        .buttonStyle(.plain).mixHandCursor()
        .menuIndicator(.hidden)
        .help("Add music")
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.audio, .mp3, .mpeg4Audio, .aiff, .wav],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            Task { @MainActor in
                for r in await deps.importService.importTracks(from: urls) {
                    if case .imported(_, let review) = r {
                        appState.enqueueReview(review)
                    }
                }
            }
        }
        .sheet(item: $linkService) { service in
            LinkImportView(service: service)
                .environmentObject(deps)
                .environmentObject(appState)
        }
        .sheet(isPresented: $showSpotify) {
            SpotifyImportView(spotifyClient: deps.spotifyClient,
                              importService: deps.spotifyImportService,
                              auth: deps.spotifyAuth,
                              followService: deps.spotifyFollowService,
                              ledger: deps.spotifyImportLedger)
                .environmentObject(deps)
        }
        .sheet(isPresented: $showPlaylist) {
            PlaylistEditorSheet()
                .environmentObject(deps)
        }
        .sheet(isPresented: $showSmartPlaylist) {
            SmartPlaylistEditorView(service: deps.smartPlaylistService)
                .environmentObject(deps)
        }
        .sheet(isPresented: $showGenerateMix) {
            GenerateMixSheet()
                .environmentObject(deps)
        }
    }
}

#endif

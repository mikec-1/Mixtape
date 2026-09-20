// MacTopBar.swift
// Mixtape — Mac/App
//
// The window's fixed top bar: search centred on the window, Add and Sync on the
// right. The sidebar toggle isn't in this bar — the sidebar and
// the rail each draw their own, beside the thing it folds. Back and forward aren't either; they're in a
// titlebar accessory, for the hit-testing reason described down at
// MacHistoryButtons.
//
// Why this isn't an NSToolbar
// ---------------------------
// It used to be one. Two things were wrong with that and both had the same root
// cause — the toolbar lives in the titlebar, which is not part of the app's
// content:
//   • `ToolbarItem(placement: .principal)` centres inside the *content column*,
//     not the window, so the search field jumped sideways every time the sidebar
//     opened or closed.
//   • MacRootView zooms the whole UI with a `scaleEffect` (⌘+ / ⌘−). The
//     titlebar sits outside that transform, so the toolbar buttons stayed at
//     100 % while everything under them grew or shrank.
// Moving the bar into the content (with `.windowStyle(.hiddenTitleBar)` on the
// scene) puts it inside the zoom transform and lets it span the full window,
// which is what Spotify and Music do.
//
// Traffic lights
// --------------
// With a hidden titlebar the close/minimise/zoom buttons float over our content.
// They are drawn by AppKit in *window* points and never take part in the zoom
// transform, so every clearance below is expressed in physical points and
// divided back out by `uiScale` — a fixed logical inset would have slid under
// them at 70 %.

#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct MacTopBar: View {

    @EnvironmentObject private var appState: MacAppState
    @EnvironmentObject private var deps:     AppDependencies
    @EnvironmentObject private var sync:     SupabaseSyncService

    /// Drives the type-ahead panel. The bar feeds it and owns its keyboard, but
    /// MacRootView draws it — see MacSearchSuggestions for why it can't live here.
    @ObservedObject private var suggestions = SearchSuggestionsStore.shared

    /// Tracked so a blur can close the panel without racing a click on one of
    /// its rows. See `scheduleDismissIfStillUnfocused`.
    @State private var fieldFocused = false

    /// Flat colour the window chrome is currently wearing — the top stop of the
    /// artwork wash, or the fullscreen-lyrics background. The bar paints it so
    /// the wash runs unbroken from the very top of the window into the content
    /// below, exactly as the tinted titlebar used to. Nil → plain app background.
    let tint: Color?

    // MARK: - Metrics (physical window points, unscaled)

    /// Width the three window buttons plus their margins occupy.
    private static let trafficLightWidth: CGFloat = 78
    /// Floor for the bar's height so the traffic lights always have room.
    private static let minPhysicalHeight: CGFloat = 46
    private static let idealHeight:       CGFloat = 52
    /// Internal so the suggestions panel — which MacRootView draws, not us — can
    /// match the field's width exactly instead of guessing at it.
    static let searchMaxWidth:            CGFloat = 420
    /// Clearance above and below the search pill. Small on purpose: the field is
    /// meant to read as the bar's own content, nearly its full height, rather
    /// than a thin capsule floating in an empty strip.
    static let searchInset:               CGFloat = 6

    /// Bar height in the *scaled* coordinate space MacRootView lays out in.
    /// Exposed so overlays anchored to the top of the window (zoom HUD, error
    /// toast) can clear the bar instead of landing on the search field.
    static func height(for scale: CGFloat) -> CGFloat {
        max(idealHeight, minPhysicalHeight / max(scale, 0.1))
    }

    /// The back/forward arrows that overlap this bar without being in it. AppKit
    /// floats them over us from the titlebar, so they aren't in this layout — but
    /// they occupy the leading edge, and the reserve below has to know about them.
    private static let historyWidth:       CGFloat = 66

    /// Space kept clear on *both* sides so the centred field can never slide
    /// under the controls. Symmetric on purpose: an asymmetric reserve would
    /// shift the field off the window's centre line, which is the whole bug.
    ///
    /// Static and internal so the suggestions panel can reproduce the field's
    /// geometry exactly. At high zoom the logical window gets narrow enough that
    /// the reserve, not `searchMaxWidth`, is what sets the field's width — a
    /// panel that only copied the cap would end up wider than the field it hangs
    /// from.
    ///
    /// Symmetric and constant on purpose: the figure is the widest case and it
    /// never moves, so nothing here can drag the search field off the window's
    /// centre line — the exact bug that took this out of an NSToolbar.
    ///
    /// This used to carry another 40 for the split view's automatic sidebar
    /// toggle. That toggle is gone (MacRootView removes it; the sidebar draws its
    /// own inside its header), so the reserve no longer holds a lane open for it.
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

            // Centred on the ZStack, which spans the window — so it is centred on
            // the window, sidebar or no sidebar.
            MacSearchField(
                text: $appState.searchText,
                // Constant now. The prompt used to change with the section
                // because the search did — "Search library" outside Discover,
                // which was both a promise the box couldn't keep (it only ever
                // matched files already on the disk) and an invitation not to
                // bother typing. One box, one promise: it searches everything.
                prompt: "What do you want to listen to?",
                focusToken: appState.searchFocusToken,
                onMoveDown: { appState.focusResults() },
                onArrowDown: { suggestions.moveHighlight(.down) },
                onArrowUp:   { suggestions.moveHighlight(.up) },
                onSubmit: {
                    // Return on a highlighted row opens it; otherwise it commits
                    // the query. The search is already running either way, so
                    // committing means showing its results: Discover unwinds
                    // whatever artist or album page the user was reading, which
                    // typing on its own deliberately no longer does — and
                    // `showSearchResults` clears whatever is drawn over the
                    // content column, fullscreen lyrics included, so there is
                    // something to see when it does.
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
                height: barHeight - Self.searchInset * 2
            )
            .frame(maxWidth: Self.searchMaxWidth)
            .padding(.horizontal, sideReserve)

            // The back/forward arrows look like they belong here and aren't:
            // they live in the window's toolbar, because that leading corner is
            // AppKit's and nothing SwiftUI draws there can be clicked. The
            // `sideReserve` above still holds their width so the search field
            // clears them. See MacHistoryButtons.

            HStack(spacing: 4) {
                Spacer(minLength: 0)
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
        // One flexible frame rather than .frame(height:) + .frame(maxWidth:):
        // stacked frames leave the bar free to size to its content's ideal width
        // first and then sit *centred* in the window, which would put the whole
        // layout back at the mercy of what's in it.
        .frame(maxWidth: .infinity, minHeight: barHeight, maxHeight: barHeight)
        // The same hairline the sidebar and the content panes draw, so the bar
        // is bounded rather than bleeding into whatever is scrolling under it.
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.mixSeparator)
                .frame(height: 1)
                .allowsHitTesting(false)
        }
        .background {
            (tint ?? Color.mixBackground)
                // Must not intercept clicks, or it would sit on top of the drag
                // layer and the window would stop being draggable by its top edge.
                .allowsHitTesting(false)
        }
        .onChange(of: appState.searchText) { _, _ in refreshSuggestions() }
        // A section change parks the query, so it retires the panel with it —
        // the rows belong to a search the user has just walked away from.
        .onChange(of: appState.selection) { _, _ in
            suggestions.clear()
            if fieldFocused { refreshSuggestions() }
        }
        // Un-committing is the general form of that: the text stays in the
        // field, and nothing it drives is left on screen — the panel included.
        // Drilling into a playlist un-commits without touching `selection`, so
        // this is what closes the panel there. Clicking back into the field
        // re-opens it via `onFocusChange` above, which is the whole way back to
        // an abandoned search short of retyping it.
        .onChange(of: appState.searchCommitted) { _, committed in
            if !committed { suggestions.dismiss() }
        }
    }

    // MARK: - Suggestions

    /// Everywhere, now. This used to be gated on being in Discover, because
    /// anywhere else the field only narrowed the list already on screen and a
    /// dropdown offering to navigate away would have been arguing with it. The
    /// field searches the catalogue from every section now, so the panel is
    /// never the odd one out.
    private func refreshSuggestions() {
        suggestions.update(query: appState.searchText,
                           using: deps.itunesClient,
                           library: deps.libraryService)
    }

    /// Clicking a row resigns the field's focus before the tap lands, so
    /// dismissing on blur immediately would close the panel out from under the
    /// click. Re-checking after a beat lets the tap win; a click that genuinely
    /// went elsewhere still closes it.
    private func scheduleDismissIfStillUnfocused() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            if !fieldFocused { suggestions.dismiss() }
        }
    }

}

// MARK: - Window drag area
//
// macOS 15 has `.gesture(WindowDragGesture())`; the deployment target is macOS
// 14, so this is the AppKit fallback. AppKit hit-tests the content view before
// it delivers a mouseDown, and NSHostingView resolves that hit through SwiftUI's
// own z-order — so anything drawn *above* this layer (the search field, the
// buttons) still claims its own clicks, and only presses that fall through to
// empty bar reach here.
//
// `performDrag(with:)` is kept as a second path: if AppKit ever delivers the
// mouseDown instead of intercepting it on `mouseDownCanMoveWindow`, the drag
// still starts. Double-clicking the bar keeps the system titlebar behaviour
// (zoom or minimise, per System Settings) because AppKit owns the event.

private struct WindowDragArea: NSViewRepresentable {

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
//
// The back/forward pair — and the one navigation control in this window that is
// deliberately *not* drawn by SwiftUI.
//
// It was, twice: inside this bar's ZStack, then as an overlay on the root view,
// above everything the app draws. Both times the arrows rendered perfectly and
// ignored every click, while ⌘[ and ⌘] kept working — which is the tell, because
// a key equivalent never goes through hit testing. Moving them around the SwiftUI
// tree was never going to help. That corner is the leading edge of the window
// chrome, where AppKit's titlebar and the split view's full-height sidebar both
// sit above our content in the real NSView hierarchy, and z-order inside SwiftUI
// has no vote in what AppKit's `hitTest:` returns.
//
// So they go where the chrome is. The window's toolbar was the first try and it
// did make them clickable, but it could not put them in the right place: a
// `.navigation` item is laid out after the automatic sidebar toggle whichever
// column declares it, and taking that toggle away with
// `.toolbar(removing: .sidebarToggle)` to get in front of it only moved the whole
// cluster into the detail region — past the sidebar's edge, ~250pt from the
// traffic lights it should be sitting beside.
//
// A left titlebar accessory has neither problem. AppKit lays it out immediately
// after the traffic lights, ahead of everything the toolbar holds, and its view
// is a real subview of NSTitlebarContainerView, so it hit-tests like any other
// piece of chrome. MacRootView installs it; the sidebar toggle stays automatic
// and stays at the sidebar's trailing edge, untouched.
//
// The cost is the one that moved the search field *out* of the toolbar: chrome up
// there sits outside the ⌘+/⌘− transform and stays at 100 % while the rest of the
// UI scales. It lands differently for these two. The field had to line up with
// the content it searches; the arrows have unscaled AppKit chrome on both sides —
// traffic lights to their left, sidebar toggle to their right — so staying at
// 100 % keeps them consistent with their neighbours instead of drifting from them.

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

/// Hand-styled rather than left as plain system buttons — circular hover halo,
/// the bar's own text colours, no bezel. Where they live is forced (see above);
/// how they look isn't, and these have to read as part of MacTopBar's row of
/// controls rather than as window furniture that wandered in.
///
/// Greyed rather than hidden at the ends of the history: a control that vanishes
/// when it can't be used takes its neighbour's position with it, and an arrow
/// that moves is an arrow you have to look for. Same reason browsers and Spotify
/// keep the dead one on screen.
///
/// The HStack is not decoration. This is hosted by an NSHostingView, which needs
/// one root view to lay out — handed a bare pair it stacks them on top of each
/// other.
struct MacHistoryButtons: View {

    @EnvironmentObject private var appState: MacAppState

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
    }
}

// MARK: - Sync Button
//
// Device to device, and nothing else. This used to scan the export folder for
// new files before syncing, which meant "Sync" could add songs nobody had asked
// for: the folder is full of copies Mixtape wrote, and a copy whose track has
// since been deleted looks exactly like new music to a scanner. Deleting a song
// on the phone and pressing this on the Mac brought it back.
//
// The export folder is an output. What this button is for is the library on the
// server: a song added on the phone, the web, or another Mac arrives here.

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
        // The menu commands are built outside the window and can't reach this
        // view's environment, so they post and this listens — the same
        // arrangement the sidebar toggle uses.
        .onReceive(NotificationCenter.default.publisher(for: .mixSyncLibrary)) { note in
            run(everything: note.object as? Bool == true)
        }
    }

    /// `everything` adds the Spotify links, each forced past its own
    /// "has anything changed?" shortcut. Kept off the plain sync because that
    /// one is pressed constantly and every forced link is a full read of a
    /// playlist — the thing that earns a rate limit.
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
//
// One "+" that owns every way music enters the library. File import and Spotify
// import used to be two icon-only toolbar buttons whose symbols
// ("square.and.arrow.down", "music.note.list") gave no hint which was which; as
// menu items they get to say so in words. Every entry names its source and what
// it takes — a link, a playlist — because the menu is the only place anyone
// finds out which sources exist.

private struct MacAddMenu: View {
    @EnvironmentObject private var deps:     AppDependencies
    @EnvironmentObject private var appState: MacAppState

    @State private var isImporting  = false
    @State private var showSpotify  = false
    @State private var showPlaylist = false
    @State private var showGenerateMix = false
    @State private var showSmartPlaylist = false

    /// Which link sheet is up, if any. One piece of state rather than two
    /// booleans so the two entries can't both be showing.
    @State private var linkService: LinkImportView.Service?

    private func openSpotifyLibrary() {
        SettingsRoute.shared.openSpotifyLibrary()
        appState.goToSection(.settings)
    }

    var body: some View {
        Menu {
            Button("Import Files\u{2026}")            { isImporting  = true }
            // Named per service rather than one "Add from a Link": the single
            // entry gave no sign YouTube was supported at all, and the menu is
            // the only place anyone would find out.
            Button("Import Spotify Link\u{2026}")     { linkService  = .spotify }
            Button("Import YouTube Link\u{2026}")     { linkService  = .youTube }
            Button("Import Spotify Playlist\u{2026}") { showSpotify  = true }
            // Not a sheet any more: Spotify is a connection, and the picker
            // it belongs to opens inside the window, in Settings.
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
        // In the toolbar a Menu drew itself as a borderless icon. Out here the
        // default style is a bordered pop-up button, which would be the only
        // chrome-heavy control in the bar — .button + .plain matches the others.
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
                for url in urls {
                    let r = await deps.importService.importTrack(from: url)
                    if case .imported(_, let review) = r {
                        appState.enqueueReview(review)
                    }
                }
            }
        }
        .sheet(item: $linkService) { service in
            LinkImportView(service: service)
                .environmentObject(deps)
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

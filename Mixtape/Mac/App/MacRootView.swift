// MacRootView.swift
// Mixtape — Mac/App
//
// The single main window for the macOS app.
// Layout: MacTopBar pinned at top + a hand-rolled split (sidebar + content) +
// player bar pinned at bottom. There is no NSToolbar — see MacTopBar for why,
// and no NavigationSplitView either — see `splitView` for why.
//
// Also:
//   • Keyboard shortcuts via NSEvent local monitor (Space / Cmd+Left / Cmd+Right)
//   • Drag-to-import: drop audio files anywhere on the window

#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

import Combine

/// Fades a bar out of karaoke without taking its space back: the lyrics are
/// laid out against a stable window, so a collapsing bar would make them jump
/// every time the mouse stopped moving.
private struct KaraokeChrome: ViewModifier {
    let hidden: Bool
    func body(content: Content) -> some View {
        content
            .opacity(hidden ? 0 : 1)
            .allowsHitTesting(!hidden)
            .accessibilityHidden(hidden)
    }
}

@MainActor
struct MacRootView: View {

    @StateObject  private var appState = MacAppState()
    @StateObject  private var keyHandler = KeyboardShortcutHandler()

    @EnvironmentObject private var deps:    AppDependencies
    @EnvironmentObject private var engine:  PlaybackEngine
    @EnvironmentObject private var library: LibraryService
    @EnvironmentObject private var sync:    SupabaseSyncService
    @Environment(\.mixChrome) private var chrome

    @State private var isDropTargeted   = false
    @State private var showZoomHUD      = false
    @State private var showMergeDuplicates = false
    // Solid colour applied to the window titlebar/toolbar so the header matches
    // the fullscreen-lyrics background. nil restores the default window chrome.
    // Cached (not recomputed per playback tick) — refreshed on track/mode change.
    @State private var lyricsHeaderColor: NSColor? = nil
    // Top colour of whatever artwork wash the current screen is painting, so the
    // titlebar can carry the gradient up through the window chrome.
    @ObservedObject private var washTint = ArtworkWashTint.shared
    // The type-ahead panel under the search field. MacTopBar fills it and drives
    // its keyboard; we only draw it, because it has to paint over the split view.
    @ObservedObject private var suggestions = SearchSuggestionsStore.shared
    // Custom right-panel state — replaces SwiftUI .inspector which can't be
    // prevented from drag-dismissing.
    @State      private var rightPanelWidth: CGFloat  = 300
    // @GestureState is reset automatically by SwiftUI when the gesture ends,
    // and its value survives re-renders during the drag (unlike @State).
    @GestureState private var panelDragStart: CGFloat? = nil
    // Sidebar width, persisted: a column someone has dragged to a width is a
    // preference, not a per-launch accident. (The right panel predates this and
    // still resets; left alone rather than changed in passing.)
    @AppStorage("mixtape.sidebarWidth") private var storedSidebarWidth: Double = 220
    @GestureState private var sidebarDragStart: CGFloat? = nil

    private var sidebarWidth: CGFloat { CGFloat(storedSidebarWidth) }
    private let sidebarMinWidth: CGFloat = 200
    private let sidebarMaxWidth: CGFloat = 280

    private let panelMinWidth: CGFloat = 220
    private let panelMaxWidth: CGFloat = 400

    /// Karaoke chrome auto-hide. See the `onContinuousHover` above.
    @State private var chromeAwake = true
    @State private var chromeSleep: Task<Void, Never>?
    @State private var lastWake = Date.distantPast

    private var chromeHidden: Bool { appState.karaokeActive && !chromeAwake }

    private func wakeChrome() {
        showChrome(true)
        // `onContinuousHover` fires for every mouse-move event; rebuilding the
        // sleep task on each one is a cancel and an allocation per pixel of
        // travel. Half a second of slack is invisible against a 3s timer.
        let now = Date()
        guard now.timeIntervalSince(lastWake) > 0.5 || chromeSleep == nil else { return }
        lastWake = now
        chromeSleep?.cancel()
        chromeSleep = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, appState.karaokeActive else { return }
            showChrome(false)
        }
    }

    private func showChrome(_ awake: Bool) {
        guard chromeAwake != awake else { return }
        // The pointer goes with the bars. Left on screen it sits over a lyric
        // and keeps it lit, which is the one thing on a still screen that still
        // moves. `setHiddenUntilMouseMoves` is AppKit's own version of this
        // rule, so the first twitch brings it back with the chrome.
        if appState.karaokeActive { NSCursor.setHiddenUntilMouseMoves(!awake) }
        withMixAnimation(.easeInOut(duration: 0.35)) { chromeAwake = awake }
    }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                // ── Split view + fixed top bar ───────────────────────────────
                // The bar is a `safeAreaInset` rather than a plain sibling above
                // the split view, and that is load-bearing. NavigationSplitView
                // is AppKit underneath, and with `.hiddenTitleBar` the window
                // turns on full-size content — so the split view draws across the
                // *whole* window regardless of where the VStack puts it. As an
                // earlier sibling the bar was laid out correctly and then painted
                // straight over (along with the traffic lights), which looked
                // exactly like it had never been added. `safeAreaInset` reserves
                // the height *and* draws the bar above the split view, and hands
                // the inset down so the columns' scroll views start below it.
                //
                // Still not a toolbar: spanning the whole window is what keeps the
                // search field on the window's centre line when the sidebar opens,
                // and living inside this VStack is what puts it inside the zoom
                // transform below, so ⌘+/⌘− moves it with everything else.
                splitView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        MacTopBar(tint: chromeTintColor)
                            .environmentObject(appState)
                            .environmentObject(deps)
                            .environmentObject(sync)
                            .modifier(KaraokeChrome(hidden: chromeHidden))
                    }

                // ── Player bar (true layout position — not a safeAreaInset) ──────
                // In karaoke the bar is an overlay instead (below), so the
                // lyrics run the full height of the window: as a sibling it
                // reserved 72pt the words could never scroll into, and the next
                // line appeared out of that dead strip rather than rising into
                // it.
                if !karaokeTakeover {
                    MacPlayerBar()
                        .environmentObject(appState)
                }
            }
            .overlay(alignment: .bottom) {
                if karaokeTakeover {
                    MacPlayerBar()
                        .environmentObject(appState)
                        .modifier(KaraokeChrome(hidden: chromeHidden))
                }
            }
            // Painted behind everything, bars included, so the wash is
            // continuous when they fade out. Only in karaoke; every other
            // screen draws its own background.
            .background {
                if appState.karaokeActive { KaraokeBackdrop() }
            }
            // In karaoke the top bar and the player bar fade out and come back
            // on the first mouse move — the words are the point, and a bar you
            // can reach by wiggling the mouse is not a bar you have lost.
            // `onContinuousHover` covers the whole window, chrome included, so
            // moving *onto* a faded bar is what brings it back.
            .onContinuousHover { phase in
                guard appState.karaokeActive else { return }
                if case .active = phase { wakeChrome() }
            }
            .onChange(of: appState.karaokeActive) { _, active in
                // Entering hides the chrome *now*: pressing the button is the
                // statement of intent, and a 3s grace period just reads as the
                // button not having worked.
                chromeSleep?.cancel()
                showChrome(!active)
            }
            // ── Search suggestions ────────────────────────────────────────────
            // Belongs to the search field, but attached here rather than to the
            // top bar: SwiftUI paints a VStack's children in order, so an overlay
            // on the bar would be drawn under the split view below it and get
            // clipped to the bar's height. Hung off the VStack it paints last,
            // and — being inside the scaleEffect that follows — it scales and
            // stays aligned with the field at every zoom level.
            .overlay(alignment: .top) {
                if suggestions.isShowing {
                    ZStack(alignment: .top) {
                        // Click-catcher under the panel. Escape closed it and so
                        // did a genuine focus change, but clicking into the
                        // window's content doesn't reliably resign the field's
                        // focus on macOS — so the panel could sit there over a
                        // page the user had already moved on to. Transparent,
                        // fills the window, and swallows the click that
                        // dismisses it, the way a popover does everywhere else.
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { suggestions.dismiss() }
                            // Everything below the bar, and nothing above it.
                            // Covering the bar too would mean a click into the
                            // search field — to move the caret, or to reach the
                            // Add/Sync/Profile buttons — closed the panel
                            // instead of landing where the user aimed.
                            .padding(.top, MacTopBar.height(for: appState.uiScale))

                        MacSearchSuggestions(store: suggestions) { picked in
                            activateSuggestion(picked, appState: appState, deps: deps)
                            suggestions.dismiss()
                        }
                        // Same reserve and same centring as the field, so the two
                        // line up at every zoom level rather than only where the
                        // 420pt cap happens to be what's limiting both.
                        .padding(.horizontal, MacTopBar.sideReserve(for: appState.uiScale))
                        .padding(.top, MacTopBar.height(for: appState.uiScale) - 4)
                    }
                    .transition(.opacity)
                }
            }
            .mixAnimation(.easeOut(duration: 0.12), value: suggestions.isShowing)
            // Scale the layout frame down so scaleEffect fills the window exactly.
            .frame(
                width:  geo.size.width  / appState.uiScale,
                height: geo.size.height / appState.uiScale,
                alignment: .topLeading
            )
            .scaleEffect(appState.uiScale, anchor: .topLeading)
            // macOS SwiftUI workaround: force the hit-testing bounds to the physical window
            // size with the same alignment to correct the click coordinate mapping.
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            // Zoom snaps. A spring here made the whole window overshoot and settle
            // — every control drifting past its final position and back, which is
            // what "the whole app kinda moves" was describing. Explicitly nil
            // rather than simply dropping the modifier so no ambient transaction
            // (a button action, a sidebar animation) can pick the change up.
            .mixAnimation(nil, value: appState.uiScale)
            // ── Zoom HUD ──────────────────────────────────────────────────────
            .overlay(alignment: .top) {
                if showZoomHUD {
                    zoomHUD
                        // Below the top bar, not on top of the search field.
                        .padding(.top, MacTopBar.height(for: appState.uiScale) + 8)
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                }
            }
            .mixAnimation(.easeInOut(duration: 0.18), value: showZoomHUD)
        }
        // With `.windowStyle(.hiddenTitleBar)` the content owns the full window.
        // If AppKit still hands SwiftUI a titlebar-sized top safe area, the top
        // bar would start below the traffic lights instead of behind them; this
        // is a no-op when there is no inset.
        .ignoresSafeArea(.container, edges: .top)
        // ── Window constraints ────────────────────────────────────────────
        .frame(minWidth: 960, minHeight: 560)
        .background(Color.mixBackground)
        // ── Carry the current screen's colour up into the window chrome ─────
        .background(WindowChromeTint())
        // ── Back / forward, hung in the titlebar itself ─────────────────────
        .background(HistoryTitlebarAccessory(appState: appState))
        .onAppear { refreshLyricsHeaderColor() }
        .onChange(of: appState.lyricsPresented)   { _, _ in refreshLyricsHeaderColor() }
        .onChange(of: appState.lyricsFullscreen)  { _, _ in refreshLyricsHeaderColor() }
        .onChange(of: engine.queue.currentTrack?.id) { _, _ in refreshLyricsHeaderColor() }
        // ── Escape closes the right panel (Queue or Get-Info / Now Playing) ──
        // .onExitCommand is the macOS-native Esc hook; it routes to the first
        // responder's cancel/exit command without disturbing the NSEvent monitor
        // used for Space / Cmd+Left / Cmd+Right.
        .onExitCommand {
            if appState.commandPaletteOpen {
                appState.commandPaletteOpen = false
            } else if appState.lyricsPresented && appState.lyricsFullscreen {
                appState.lyricsPresented = false
            } else if appState.isRightPanelOpen {
                appState.closePanel()
            }
        }
        .mixAnimation(.easeInOut(duration: 0.25), value: appState.lyricsPresented)
        .mixAnimation(.easeInOut(duration: 0.25), value: appState.lyricsFullscreen)
        // ── Error toast ───────────────────────────────────────────────────
        .overlay(alignment: .top) {
            if let msg = engine.errorMessage {
                MacErrorToast(message: msg)
                    .padding(.horizontal, 20)
                    // This overlay sits outside the zoom transform, so the bar's
                    // height has to be converted back to physical points to clear it.
                    .padding(.top, MacTopBar.height(for: appState.uiScale) * appState.uiScale + 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .mixAnimation(.spring(response: 0.35, dampingFraction: 0.85), value: engine.errorMessage)
        // ── "Added to <somewhere>" pill ───────────────────────────────────
        // Bottom centre, clearing the player bar. Like the error toast above,
        // this overlay sits outside the zoom transform, so the bar's height has
        // to be converted back to physical points to clear it.
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                // "Link copied to clipboard" and the other one-line confirmations.
                ZStack {
                    if let message = deps.toastMessage {
                        MacMessageToast(message: message)
                            .transition(SavedToastHost.transition)
                    }
                }
                .mixAnimation(SavedToastHost.animation, value: deps.toastMessage)
                SavedToastHost(center: deps.savedToasts)
            }
            .padding(.bottom, MacPlayerBar.height * appState.uiScale + 14)
        }
        // ── "Saved in" panel ──────────────────────────────────────────────
        // Bottom-leading, above the player bar, and deliberately not a sheet:
        // nothing behind it dims and the app keeps playing and scrolling while
        // it's open. See `SavedInPanel`.
        .overlay(alignment: .bottomLeading) {
            SavedInPanelHost(center: deps.savedInPanel,
                             bottomGap: MacPlayerBar.height * appState.uiScale + 14)
        }
        // ── "<song> downloading — 80%" ────────────────────────────────────
        // The same corner, directly above the player bar's own track info, so
        // the song being fetched appears where the song being played will —
        // and above the Saved In panel when that is open, rather than under it.
        // Outside the zoom transform for the same reason the toast is, hence
        // the same conversion of the bar's height.
        .overlay(alignment: .bottomLeading) {
            PreparingBarSlot(coordinator: deps.onlineCoordinator,
                             savedIn: deps.savedInPanel,
                             baseGap: MacPlayerBar.height * appState.uiScale + 14)
        }
        // ── Keyboard shortcuts ────────────────────────────────────────────
        .background {
            Group {
                // Settings
                Button("") { appState.goToSection(.settings) }
                    .keyboardShortcut(",", modifiers: .command)
                // Command palette — Cmd+K
                Button("") { appState.commandPaletteOpen.toggle() }
                    .keyboardShortcut("k", modifiers: .command)
                // Zoom in — Cmd++ (Shift+=). The View menu item owns Cmd+=;
                // this catches the shifted variant the menu doesn't see on its own.
                Button("") { appState.zoomIn() }
                    .keyboardShortcut("+", modifiers: .command)
            }
            .opacity(0)
        }
        // ── Command palette ───────────────────────────────────────────────
        // An overlay rather than a .sheet: a sheet animates the whole window
        // and can't be dismissed by clicking outside it, which is the one
        // gesture every palette supports.
        .overlay {
            if appState.commandPaletteOpen {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.28)
                        .ignoresSafeArea()
                        .onTapGesture { appState.commandPaletteOpen = false }

                    MacCommandPalette()
                        .environmentObject(appState)
                        .environmentObject(library)
                        .environmentObject(engine)
                        .padding(.top, 90)
                }
                .transition(.opacity)
            }
        }
        .mixAnimation(.easeOut(duration: 0.12), value: appState.commandPaletteOpen)
        // ── Show zoom HUD briefly on scale change ─────────────────────────
        .onChange(of: appState.uiScale) { _, _ in
            showZoomHUD = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                showZoomHUD = false
            }
        }
        // ── Metadata review sheet ─────────────────────────────────────────
        .sheet(item: Binding(
            get: { appState.pendingReview },
            set: { _ in appState.dequeueReview() }
        )) { item in
            MacMetadataReviewSheet(item: item)
                .environmentObject(deps)
                .environmentObject(appState)
        }
        // ── Lyrics ▸ add/edit your own ────────────────────────────────────
        // Presented here, from the main window, rather than from MacLyricsView:
        // in windowed mode that view is inside a `.popover`, which hosts its own
        // window, and a sheet put up from there dismisses into a context that's
        // going away. See `MacAppState.lyricsEditorTrack`.
        .sheet(item: $appState.lyricsEditorTrack) { track in
            LyricsEditorSheet(track: track)
                .environmentObject(deps)
        }
        // ── Library ▸ Merge Duplicate Songs ───────────────────────────────
        .sheet(isPresented: $showMergeDuplicates) {
            MergeDuplicatesSheet().environmentObject(deps)
        }
        .onReceive(NotificationCenter.default.publisher(for: .mixMergeDuplicates)) { _ in
            showMergeDuplicates = true
        }
        // ⌃⌘S. It used to be NavigationSplitView's own menu item; the column is
        // hand-rolled now, so the View menu gets one of ours (see MixtapeApp)
        // and it arrives here.
        .onReceive(NotificationCenter.default.publisher(for: .mixToggleSidebar)) { _ in
            appState.toggleSidebar()
        }
        // View menu zoom + navigation commands — post ➜ receive ➜ call.
        // Grouped into a ViewModifier to keep the body's modifier chain short
        // enough for the Swift type-checker to handle in reasonable time.
        .modifier(ViewMenuCommands(appState: appState, deps: deps))
        .environmentObject(appState)
    }

    // MARK: - Window chrome tint

    /// Fullscreen lyrics wins, since it paints its own full-bleed background.
    /// Otherwise the titlebar takes the first colour of the current screen's
    /// artwork wash, so the gradient runs behind the chrome instead of starting
    /// abruptly underneath it. Nil on screens with no wash — Settings, Search —
    /// which get the standard system titlebar back.
    ///
    /// The lyrics colour is *cached* state, and the mode is checked here rather
    /// than trusting that cache to have been cleared: leaving lyrics by a route
    /// that didn't refresh it left the whole window chrome wearing the lyrics
    /// background over the page it had gone back to.
    private var chromeTint: NSColor? {
        if appState.lyricsPresented, appState.lyricsFullscreen,
           let lyricsHeaderColor { return lyricsHeaderColor }
        guard let wash = washTint.color else { return nil }
        return WindowChromeTint.flatten(wash, over: Color.mixBackground)
    }

    /// The same colour handed to MacTopBar so the wash reaches the very top of
    /// the window. The titlebar used to carry it; now that the titlebar is hidden
    /// the top bar has to, or the wash would start on a hard edge under the bar.
    ///
    /// This is also what "adapts in fullscreen lyrics" means here: `chromeTint`
    /// already resolves to the lyrics background in that mode, so the bar keeps
    /// blending into it exactly as the tinted titlebar did. The bar stays visible
    /// on purpose — it did before too, and it is the only way back to search.
    private var chromeTintColor: Color? {
        chromeTint.map { Color(nsColor: $0) }
    }

    // MARK: - Lyrics header tint

    /// Recompute the window chrome colour to match the fullscreen-lyrics
    /// background: the dominant album colour darkened by the same 0.45 black
    /// overlay the lyrics view paints (so RGB × 0.55). nil when not fullscreen.
    private func refreshLyricsHeaderColor() {
        guard appState.lyricsPresented && appState.lyricsFullscreen else {
            lyricsHeaderColor = nil
            return
        }
        let colors = ArtworkColors.dominantColors(from: engine.queue.currentTrack?.displayArtwork)
        let base = colors.first.map { NSColor($0) } ?? NSColor(white: 0.16, alpha: 1)
        guard let rgb = base.usingColorSpace(.deviceRGB) else {
            lyricsHeaderColor = base
            return
        }
        lyricsHeaderColor = NSColor(red:   rgb.redComponent   * 0.55,
                                    green: rgb.greenComponent * 0.55,
                                    blue:  rgb.blueComponent  * 0.55,
                                    alpha: 1)
    }

    // MARK: - Zoom HUD

    private var zoomHUD: some View {
        let pct = Int(appState.uiScale * 100)
        return HStack(spacing: 6) {
            Image(systemName: pct > 100 ? "plus.magnifyingglass" : pct < 100 ? "minus.magnifyingglass" : "arrow.uturn.backward")
                .font(.system(size: 11))
            Text(pct == 100 ? "Zoom reset" : "\(pct)%")
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(Color.mixTextPrimary)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(chrome.material(.regularMaterial, flat: .mixSurface2), in: Capsule())
    }

    // ── Split view + all its modifiers ────────────────────────────────────
    //
    // The right panel is a custom HStack layout rather than SwiftUI's .inspector.
    // .inspector cannot be prevented from drag-dismissing (the binding setter is
    // ignored when the user drags past min width), so we manage the panel ourselves.

    private var splitView: some View {
        HStack(spacing: 0) {
            // ── Sidebar column ────────────────────────────────────────────
            // Hand-rolled, rather than NavigationSplitView's own column, and the
            // collapse animation is the whole reason. The rail and the full
            // sidebar are two different views, so folding one down to the other
            // meant two animations running at once: ours moved the rail in and
            // out of this stack, while the split view ran AppKit's column
            // collapse — different curve, different duration, started on a
            // different frame and not ours to retime. They finished out of step
            // often enough to watch the rail arrive before the sidebar had left.
            //
            // Here the width is one number animated once (at the bottom of this
            // stack), and the two views cross-fade inside it.
            //
            // Nothing else NavigationSplitView offered is missed: the detail
            // column was already a flat router with no NavigationStack in it
            // (see MacContentRouter), and the sidebar's material and its
            // drag-to-resize are reproduced below.
            if !karaokeTakeover {
                sidebarColumn
                sidebarDivider
            }

            // ── Main content ──────────────────────────────────────────────
            Group {
                // Fullscreen lyrics take over the main content column — staying
                // inside the chrome (sidebar, top bar, player bar, right panel)
                // rather than floating as a window overlay.
                if appState.lyricsPresented && appState.lyricsFullscreen {
                    MacLyricsView()
                        .environmentObject(engine)
                        .environmentObject(appState)
                        .environmentObject(deps)
                        .transition(.opacity)
                } else {
                    MacContentRouter()
                        .environmentObject(appState)
                        .environmentObject(deps)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // ── Titlebar height ballast ───────────────────────────────────
            // An empty toolbar is not the same window as a toolbar with one
            // item in it: AppKit gives the first a short titlebar and the
            // second a tall one, and the traffic lights (plus our history
            // accessory, which sits beside them) are centred in whichever it
            // gets. The automatic sidebar toggle used to be that one item on
            // every page; with it gone, Home — which contributes no toolbar
            // items of its own — had no NSToolbar at all and collapsed to a
            // 32pt titlebar, while a playlist page, which contributes a
            // save-to-disk button, stayed at 52. Measured: the close button
            // sat at y=940 on Home and y=930 on a playlist, so the arrows
            // beside it jumped 10pt every time you navigated.
            //
            // So the toolbar keeps exactly one permanent tenant: 1×28 of
            // nothing. It draws no pixels and takes no clicks, it just refuses
            // to let the toolbar be empty, which is what the height depends on.
            //
            // Two other ways were measured and rejected: a 52pt-tall titlebar
            // accessory (AppKit clamps the accessory to the titlebar instead of
            // the other way round — still 32), and installing a bare NSToolbar
            // by hand (works, but its own style lands the chrome at 66 or 40,
            // never the 52 the rest of the window is built around).
            .toolbar {
                if #available(macOS 26.0, *) {
                    ToolbarItem(placement: .navigation) { ballast }
                        // macOS 26 draws a glass platter behind every toolbar
                        // item, and a 1pt-wide item becomes a 1pt-wide sliver of
                        // glass — a stray vertical hairline in the titlebar,
                        // sitting wherever the toolbar's leading edge happens to
                        // be rather than on the sidebar's divider. The tenant is
                        // meant to be invisible; this is what makes it so.
                        .sharedBackgroundVisibility(.hidden)
                } else {
                    // Nothing to hide before 26: toolbar items had no background.
                    ToolbarItem(placement: .navigation) { ballast }
                }
            }

            // No `.toolbar(.hidden, for: .windowToolbar)` here, deliberately.
            // Search / Add / Sync live in MacTopBar now, so hiding the toolbar
            // reads as tidy-up — but it takes the whole NSTitlebarContainerView
            // with it, and the traffic lights live inside that container. They
            // still report isHidden = false while nothing draws, which is a very
            // confusing way to lose the close/minimise/zoom buttons.
            // `.windowStyle(.hiddenTitleBar)` already suppresses the title, and
            // the toolbar is now empty except for whatever the current page puts
            // there — the split view's automatic sidebar toggle is removed at the
            // sidebar column above, since the sidebar draws its own.
            //
            // ⌘⌫ still deletes the selection even though the button is gone;
            // ⌘F focuses the search field now that `.searchable` isn't providing it.
            //
            // Back and forward are *not* in here — the toolbar can't
            // place them beside the traffic lights. See HistoryTitlebarAccessory.
            .background {
                MacDeleteCommand()
                    .environmentObject(deps)
                    .environmentObject(appState)
                    .environmentObject(engine)
            }
            .background {
                Button("") { appState.focusSearch() }
                    .keyboardShortcut("f", modifiers: .command)
                    .opacity(0)
                    .frame(width: 0, height: 0)
            }
            // ── Keyboard shortcuts ────────────────────────────────────────
            .onAppear  {
                keyHandler.start(engine: engine)
                let userID = deps.authService.currentUser?.id.uuidString
                appState.currentUserID = userID
                PlaylistMetadataService.shared.currentUserID = userID
            }
            .onDisappear { keyHandler.stop() }
            .onChange(of: deps.authService.currentUser) { _, newUser in
                let userID = newUser?.id.uuidString
                appState.currentUserID = userID
                PlaylistMetadataService.shared.currentUserID = userID
            }

            // ── Custom right panel ────────────────────────────────────────
            if appState.isRightPanelOpen {
                panelDivider
                rightPanelContent
                    .frame(width: rightPanelWidth)
                    .frame(maxHeight: .infinity)
                    // Same background and same wash as the sidebar on the other
                    // side, so the window is one colour from edge to edge rather
                    // than a tinted middle between two flat columns.
                    .background(alignment: .top) {
                        // In karaoke the panel lets the root's backdrop through
                        // instead of painting its own column: a flat slab of
                        // background beside the words broke the wash in half.
                        if appState.karaokeActive {
                            Color.black.opacity(0.10).ignoresSafeArea()
                        } else {
                            ZStack(alignment: .top) {
                                Color.mixBackground
                                ArtworkWashGradient(colors: washTint.stops,
                                                    intensity: washTint.chromeIntensity)
                            }
                            .ignoresSafeArea()
                        }
                    }
            }
        }
        // ── Drag-to-import ────────────────────────────────────────────────
        // On the stack rather than on the content column: a file dropped on the
        // sidebar is still a file dropped on the window.
        //
        // `.fileURL` is the identifier Finder vends for file drops; `.audio`
        // alone does not reliably match a Finder file drag.
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            importDroppedFiles(providers)
        }
        .overlay {
            if isDropTargeted {
                dropOverlay
                    .transition(.opacity)
                    .ignoresSafeArea()
            }
        }
        .mixAnimation(.easeInOut(duration: 0.14), value: isDropTargeted)
        .mixAnimation(.spring(response: 0.28, dampingFraction: 0.88), value: appState.isRightPanelOpen)
        // The one animator for the fold. Everything the collapse moves — the
        // column's width, the cross-fade inside it, the content taking up the
        // slack — is driven from this single change, so there is nothing left
        // to fall out of step with anything else.
        .mixAnimation(.spring(response: 0.34, dampingFraction: 0.9), value: appState.sidebarCollapsed)
    }

    // ── Sidebar column ────────────────────────────────────────────────────

    /// The full sidebar and the rail, cross-fading inside one animated width.
    ///
    /// Both are always in the hierarchy, and both keep their own natural width
    /// the whole time — so nothing *inside* either view re-lays-out while the
    /// column moves, because nothing inside either view changes size. The clip
    /// does the work: the container's width animates and the contents sit still
    /// and get revealed or covered.
    ///
    /// That's what makes it cheap enough to stay smooth with a long playlist
    /// list in it. The old arrangement re-laid-out the whole sidebar on every
    /// frame of the collapse *and* built the rail from scratch on the first one,
    /// which is the other half of why it stuttered.
    /// Karaoke is a takeover, not a pane: while it is up the sidebar and the
    /// right panel step aside so the words have the whole window. Neither
    /// stored state is touched — leaving karaoke puts both back as they were.
    private var karaokeTakeover: Bool { appState.karaokeActive }

    private var sidebarColumn: some View {
        ZStack(alignment: .leading) {
            MacSidebarView()
                .environmentObject(appState)
                .frame(width: sidebarWidth)
                .opacity(appState.sidebarCollapsed ? 0 : 1)
                // The hidden one is still on screen as far as hit-testing is
                // concerned; opacity 0 doesn't decline clicks.
                .allowsHitTesting(!appState.sidebarCollapsed)
                .accessibilityHidden(appState.sidebarCollapsed)

            MacSidebarRail()
                .environmentObject(appState)
                .opacity(appState.sidebarCollapsed ? 1 : 0)
                .allowsHitTesting(appState.sidebarCollapsed)
                .accessibilityHidden(!appState.sidebarCollapsed)
        }
        .frame(width: appState.sidebarCollapsed ? MacSidebarRail.width : sidebarWidth,
               alignment: .leading)
        .frame(maxHeight: .infinity)
        // The window's own colour, carried across from the page.
        //
        // This used to be an NSVisualEffectView in rich chrome — the translucency
        // NavigationSplitView supplies behind a native sidebar. `.behindWindow`
        // blending samples what is *behind the window*, which is the desktop
        // wallpaper: the sidebar took a different grey depending on where the
        // window sat and changed colour when the wallpaper did, for no reason the
        // app could explain. Here it takes the same background and the same
        // artwork ramp the content column is drawing, so the wash runs
        // continuously from the top bar, across the sidebar, into the page.
        //
        // On the container rather than on either view, so it stays perfectly
        // still through the collapse cross-fade instead of fading with the thing
        // in front of it.
        .background(alignment: .top) {
            ZStack(alignment: .top) {
                Color.mixBackground
                ArtworkWashGradient(colors: washTint.stops, intensity: washTint.chromeIntensity)
            }
            .ignoresSafeArea()
        }
        .clipped()
    }

    /// The line between sidebar and content — and, expanded, the grab handle
    /// that resizes it. Mirrors `panelDivider` on the other side of the window.
    private var sidebarDivider: some View {
        Rectangle()
            .fill(Color(NSColor.separatorColor))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .overlay {
                // Nothing to drag when it's a rail: the rail is one fixed size.
                if !appState.sidebarCollapsed {
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .frame(width: 8)
                        .onHover { hovering in
                            if hovering { NSCursor.resizeLeftRight.push() }
                            else        { NSCursor.pop() }
                        }
                        .gesture(
                            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                .updating($sidebarDragStart) { _, state, _ in
                                    if state == nil { state = sidebarWidth }
                                }
                                .onChanged { value in
                                    let start = sidebarDragStart ?? sidebarWidth
                                    let width = start + value.translation.width
                                    storedSidebarWidth = Double(
                                        max(sidebarMinWidth, min(sidebarMaxWidth, width)))
                                }
                        )
                }
            }
    }

    // ── Panel divider with drag-to-resize ─────────────────────────────────

    private var panelDivider: some View {
        Rectangle()
            .fill(Color(NSColor.separatorColor))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            // Invisible wider hit area centred on the 1-pt line
            .overlay(
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .frame(width: 8)
                    .onHover { hovering in
                        if hovering { NSCursor.resizeLeftRight.push() }
                        else        { NSCursor.pop() }
                    }
                    .gesture(
                        // .global keeps translation relative to screen origin so it
                        // doesn't shift as the divider itself moves during the drag.
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            // Capture width at drag start; @GestureState survives
                            // re-renders and auto-resets when the gesture ends.
                            .updating($panelDragStart) { _, state, _ in
                                if state == nil { state = rightPanelWidth }
                            }
                            .onChanged { value in
                                let start = panelDragStart ?? rightPanelWidth
                                let newWidth = start - value.translation.width
                                rightPanelWidth = max(panelMinWidth, min(panelMaxWidth, newWidth))
                            }
                    )
            )
    }

    // ── Right panel content ───────────────────────────────────────────────

    /// One view for all three panels — the tab bar, the close button and the
    /// switch between Now Playing / Queue / Recent live in `MacRightPanelView`.
    private var rightPanelContent: some View {
        MacRightPanelView()
            .environmentObject(engine)
            .environmentObject(library)
            .environmentObject(appState)
    }

    // MARK: - Drop overlay

    private var dropOverlay: some View {
        ZStack {
            Color.black.opacity(0.35)

            VStack(spacing: 16) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(Color.mixPrimary)
                    .mixPulse(isActive: isDropTargeted)

                Text("Drop to Import")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.mixTextPrimary)

                Text("Release to add to your library")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.mixTextSecondary)
            }
            .padding(40)
            .background(chrome.material(.regularMaterial, flat: .mixSurface2),
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.mixPrimary.opacity(0.5), lineWidth: 1.5)
            )
        }
    }

    // MARK: - Drag import handler

    private static let audioImportExtensions = Set(
        ["mp3", "m4a", "aiff", "aif", "wav", "flac", "ogg", "opus"]
    )

    /// Returns true when at least one provider can supply a file URL we will try to
    /// import. Dropping files from Finder into a sandboxed app does NOT reliably vend
    /// a `URL` via `loadObject(ofClass: URL.self)` — the provider supplies a file-URL
    /// representation under the `public.file-url` type (often `Data`/`NSURL`). We
    /// resolve that explicitly and fall back to `loadObject` only if needed.
    /// The toolbar's permanent tenant (see the height note in `body`): 1×28 of
    /// nothing, so the window always has a toolbar and always gets the tall
    /// titlebar. Not `EmptyView` — SwiftUI drops an item with no content, which
    /// would put the toolbar back to empty.
    private var ballast: some View {
        Color.clear.frame(width: 1, height: 28)
    }

    private func importDroppedFiles(_ providers: [NSItemProvider]) -> Bool {
        let fileURLType = UTType.fileURL.identifier
        var willHandleAny = false

        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(fileURLType) else { continue }
            willHandleAny = true

            provider.loadItem(forTypeIdentifier: fileURLType, options: nil) { item, _ in
                let resolved = Self.resolveFileURL(from: item)
                if let resolved {
                    Self.importIfAudio(resolved, deps: deps, appState: appState)
                } else {
                    // Last-ditch fallback for providers that only respond to the
                    // class-based API.
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        if let url { Self.importIfAudio(url, deps: deps, appState: appState) }
                    }
                }
            }
        }

        return willHandleAny
    }

    /// Resolves a `public.file-url` item into a `URL`, handling the several concrete
    /// types `loadItem` can hand back: `URL`, `NSURL`, or `Data`.
    private static func resolveFileURL(from item: NSSecureCoding?) -> URL? {
        switch item {
        case let url as URL:
            return url
        case let nsurl as NSURL:
            return nsurl as URL
        case let data as Data:
            // The file-URL representation is typically the URL's absolute string
            // encoded as UTF-8; `URL(dataRepresentation:)` decodes exactly that.
            if let url = URL(dataRepresentation: data, relativeTo: nil) {
                return url
            }
            if let str = String(data: data, encoding: .utf8) {
                return URL(string: str) ?? URL(fileURLWithPath: str)
            }
            return nil
        default:
            return nil
        }
    }

    /// Filters by audio extension, then runs the import on the main actor with
    /// security-scoped access so the sandboxed app can actually read the file.
    private static func importIfAudio(
        _ url: URL,
        deps: AppDependencies,
        appState: MacAppState
    ) {
        guard url.isFileURL,
              audioImportExtensions.contains(url.pathExtension.lowercased())
        else { return }

        Task { @MainActor in
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }

            let result = await deps.importService.importTrack(from: url)
            if case .imported(_, let review) = result {
                appState.enqueueReview(review)
            }
        }
    }
}

// MARK: - Keyboard Shortcut Handler
//
// Installs an NSEvent local monitor for the window. @StateObject ties its
// lifetime to MacRootView, so the monitor is always active while the window
// is on screen and is cleaned up when the view disappears.
//
// Shortcuts:
//   Space         → play / pause  (blocked when a text field is focused)
//   Cmd+Right (⌘→) → next track
//   Cmd+Left  (⌘←) → previous / restart

private final class KeyboardShortcutHandler: ObservableObject {

    private var monitor: Any?

    func start(engine: PlaybackEngine) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak engine] event in
            guard let engine else { return event }

            // Never steal events from text input (search field, any NSTextField/NSTextView)
            let fr = NSApp.keyWindow?.firstResponder
            if fr is NSText { return event }

            let cmd = event.modifierFlags.contains(.command)

            switch event.keyCode {
            case 49 where !cmd:             // Space — play / pause
                Task { @MainActor in engine.togglePlayPause() }
                return nil                  // consume

            case 124 where cmd:             // Cmd + Right — next track
                Task { @MainActor in await engine.playNext() }
                return nil

            case 123 where cmd:             // Cmd + Left — previous / restart
                Task { @MainActor in await engine.playPrevious() }
                return nil

            default:
                return event
            }
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }

    deinit { stop() }
}

// MARK: - View Menu Commands

/// Wires View-menu and File-menu notifications to their `MacAppState`/
/// `LibraryService` methods. Extracted into a `ViewModifier` so the main
/// body's modifier chain stays short enough for the Swift type-checker.
private struct ViewMenuCommands: ViewModifier {

    let appState: MacAppState
    let deps:     AppDependencies

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .mixZoomIn))     { _ in appState.zoomIn() }
            .onReceive(NotificationCenter.default.publisher(for: .mixZoomOut))    { _ in appState.zoomOut() }
            .onReceive(NotificationCenter.default.publisher(for: .mixActualSize)) { _ in appState.resetZoom() }
            .onReceive(NotificationCenter.default.publisher(for: .mixGoBack))     { _ in appState.goBack() }
            .onReceive(NotificationCenter.default.publisher(for: .mixGoForward))  { _ in appState.goForward() }
            .onReceive(NotificationCenter.default.publisher(for: .mixNewPlaylist)) { _ in createNewPlaylist() }
    }

    /// Creates a blank playlist using the same "My Playlist #N" default name
    /// as `PlaylistEditorSheet`, then navigates straight to it.
    private func createNewPlaylist() {
        let count = deps.libraryService.playlists.filter { !$0.isSystem && !$0.isDeleted }.count
        let name  = "My Playlist #\(count + 1)"
        let playlist = deps.libraryService.createPlaylist(name: name)
        appState.showPlaylist(playlist)
    }
}

// MARK: - Delete Command
//
// Invisible: it exists to keep ⌘⌫ working (and to own the confirmation
// dialog) now that the trash button is gone from the toolbar. Deleting from
// the list itself goes through the row's right-click menu.

private struct MacDeleteCommand: View {

    @EnvironmentObject private var deps:     AppDependencies
    @EnvironmentObject private var appState: MacAppState
    @EnvironmentObject private var engine:   PlaybackEngine

    @ObservedObject private var editing = MacTextEditingMonitor.shared

    /// What the dialog will say, worked out on the press.
    ///
    /// This lives in `.commands`, so its body is re-evaluated every time
    /// `MacAppState` publishes anything at all — and while a playlist is open,
    /// `confirmMessage` counted the songs a delete would orphan, which reads
    /// every favourite and walks every playlist in the library. Selecting rows
    /// publishes constantly, so the scan ran constantly, for a dialog that
    /// wasn't on screen.
    @State private var prompt: Prompt?

    private struct Prompt {
        var title:   String
        var message: String
        var label:   String
    }

    var body: some View {
        Button("") { prompt = makePrompt() }
            // Disabled while a field has the keyboard, which is what lets the
            // ⌘⌫ through to it — a key equivalent on an enabled button is
            // consumed before the responder chain ever sees the event.
            .disabled(!appState.canDelete || editing.isEditing)
            .keyboardShortcut(.delete, modifiers: .command)
            .opacity(0)
            .confirmationDialog(prompt?.title ?? "",
                                isPresented: Binding(get: { prompt != nil },
                                                     set: { if !$0 { prompt = nil } }),
                                titleVisibility: .visible) {
                Button(prompt?.label ?? "Delete", role: .destructive) { performDelete() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(prompt?.message ?? "")
            }
    }

    private func makePrompt() -> Prompt {
        Prompt(title: confirmTitle, message: confirmMessage, label: deleteButtonLabel)
    }

    // MARK: - Derived labels

    private var confirmTitle: String {
        if !appState.selectedTrackIDs.isEmpty {
            return TrackDeletionPrompt.title(count: appState.selectedTrackIDs.count)
        }
        if let id = appState.selectedPlaylistID,
           let pl = deps.libraryService.playlist(id: id) {
            return "Delete \"\(pl.name)\""
        }
        return "Delete"
    }

    private var confirmMessage: String {
        if !appState.selectedTrackIDs.isEmpty {
            return TrackDeletionPrompt.message(count: appState.selectedTrackIDs.count)
        }
        guard let id = appState.selectedPlaylistID else { return "" }
        return PlaylistDeletionPrompt.message(
            songCount: deps.libraryService.songCountRemovedWithPlaylist(id: id),
            isReadOnly: deps.libraryService.playlist(id: id)?.isEditable == false)
    }

    private var deleteButtonLabel: String {
        if !appState.selectedTrackIDs.isEmpty {
            return TrackDeletionPrompt.confirmLabel(count: appState.selectedTrackIDs.count)
        }
        return "Delete Playlist"
    }

    // MARK: - Action

    private func performDelete() {
        if !appState.selectedTrackIDs.isEmpty {
            let ids = Array(appState.selectedTrackIDs)
            appState.clearDeleteSelection()
            for id in ids { engine.stopIfPlaying(trackID: id) }
            // One write for the whole selection: deleting song by song reloads
            // the library and re-syncs after every one of them.
            deps.libraryService.deleteTracks(ids: ids)
        } else if let id = appState.selectedPlaylistID {
            appState.clearDeleteSelection()
            deps.libraryService.deletePlaylist(id: id)
        }
    }
}

// MARK: - Downloading card, stacked

/// The "downloading" card, which shares the bottom-leading corner with the
/// Saved In panel. When the panel is open the card steps up to sit flush on top
/// of it; when it closes the card drops back onto the player bar.
///
/// Its own view, rather than a padding expression in `MacRootView`, so that
/// opening the panel redraws this corner and nothing else — the same reason
/// `SavedInPanelCenter` is separate from `AppDependencies` to begin with.
private struct PreparingBarSlot: View {

    @ObservedObject var coordinator: OnlinePlaybackCoordinator
    @ObservedObject var savedIn: SavedInPanelCenter

    /// Where the card sits with nothing under it: clear of the player bar.
    let baseGap: CGFloat

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                TrackPreparingBar(coordinator: coordinator)
                    // Lined up with the panel's edge, and with the artwork and
                    // title in the player bar below both of them.
                    .padding(.leading, SavedInPanelHost.leadingInset)
                    .padding(.bottom, bottom(inWindowOfHeight: geo.size.height))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .mixAnimation(.spring(response: 0.32, dampingFraction: 0.88), value: savedIn.request)
    }

    private func bottom(inWindowOfHeight height: CGFloat) -> CGFloat {
        guard savedIn.request != nil else { return baseGap }
        let stacked = baseGap + SavedInPanelHost.height + SavedInPanelHost.stackGap
        // A short window has no room for the panel *and* the card above it.
        // Overlays don't clip, so left alone the card would simply be drawn
        // off the top of the window; better it overlaps the panel's top edge
        // than disappears.
        return min(stacked, max(baseGap, height - Self.cardClearance))
    }

    /// Roughly the collapsed card's height plus a little air.
    private static let cardClearance: CGFloat = 76
}

// MARK: - Error Toast

private struct MacErrorToast: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(Color.mixDestructive)
            Text(message)
                .font(.system(.callout, weight: .medium))
                .foregroundStyle(Color.mixTextPrimary)
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.mixSurface2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.mixDestructive.opacity(0.4), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
    }
}

/// A slim confirmation in the theme's opposite colour, as Spotify does — light on
/// a dark window, dark on a light one, so it reads against any page.
private struct MacMessageToast: View {
    let message: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        Text(message)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(dark ? Color.black : Color.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            // No width frame: a flexible frame stretches the fill to its maximum.
            .background(dark ? Color.white : Color(white: 0.14),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
            .padding(.horizontal, 40)
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel(message)
    }
}

// MARK: - History controls in the titlebar

/// Hangs the back/forward pair off the window's titlebar as a left accessory.
///
/// The arrows have to be inside real window chrome to be clickable at all (see
/// MacHistoryButtons for how that was learned), and the toolbar — the obvious
/// piece of chrome — can't put them where they belong. A `.navigation` item
/// lands after the automatic sidebar toggle no matter which column declares it,
/// and removing that toggle to get ahead of it only moved the whole cluster into
/// the detail region, well past the sidebar's edge and a long way from the
/// traffic lights. A left titlebar accessory is laid out by AppKit directly
/// after the traffic lights, which is the spot these occupied when they were
/// still being drawn (unclickably) by MacTopBar.
///
/// It is also a real NSView inside NSTitlebarContainerView, so it wins the same
/// hit-testing argument the toolbar won.
private struct HistoryTitlebarAccessory: NSViewRepresentable {

    let appState: MacAppState

    /// Install-once. `updateNSView` runs on every state change, and
    /// `addTitlebarAccessoryViewController` appends unconditionally — without
    /// this you get a fresh pair of arrows marching rightwards across the
    /// titlebar every time the history changes.
    final class Coordinator {
        var installed = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let probe = NSView(frame: .zero)
        // The window is nil until this view is in a hierarchy, hence the hop —
        // same reason WindowChromeTint below does it.
        DispatchQueue.main.async { install(from: probe, coordinator: context.coordinator) }
        return probe
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { install(from: nsView, coordinator: context.coordinator) }
    }

    /// Tags our accessory on the window. The coordinator only remembers *this*
    /// view's install, and MacRootView is rebuilt on sign-in — a fresh view, a
    /// fresh coordinator, a second pair of arrows. The window outlives both, so
    /// it's the one that decides: any older pair is removed before this one goes in.
    private static let identifier = NSUserInterfaceItemIdentifier("mix.historyAccessory")

    private func install(from view: NSView, coordinator: Coordinator) {
        guard !coordinator.installed, let window = view.window else { return }

        for (index, existing) in window.titlebarAccessoryViewControllers.enumerated().reversed()
            where existing.identifier == Self.identifier {
            window.removeTitlebarAccessoryViewController(at: index)
        }

        let host = NSHostingView(rootView: MacHistoryButtons().environmentObject(appState))
        // An accessory doesn't size itself from SwiftUI's intrinsic content the
        // way a toolbar item does; it gets the frame it's given. Two 28pt
        // controls with 2pt between them, plus a little slack.
        host.frame = NSRect(x: 0, y: 0, width: 62, height: 28)

        let controller = NSTitlebarAccessoryViewController()
        controller.view = host
        controller.layoutAttribute = .left
        controller.identifier = Self.identifier
        window.addTitlebarAccessoryViewController(controller)

        coordinator.installed = true
    }
}

// MARK: - Window chrome tint

/// Keeps the host NSWindow's titlebar transparent and separator-free so MacTopBar
/// can paint the full width of the chrome itself.
private struct WindowChromeTint: NSViewRepresentable {

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { apply(to: view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { apply(to: nsView.window) }
    }

    private func apply(to window: NSWindow?) {
        guard let window else { return }
        // Both of these are now unconditional. The scene uses
        // `.windowStyle(.hiddenTitleBar)`, so restoring an opaque titlebar (or the
        // automatic separator) on the nil branch — which is what this used to do —
        // would drop a grey slab and a hairline straight across MacTopBar.
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle     = .none
        // Deliberately NOT the wash colour. The window background is the backdrop
        // AppKit's materials sample, and the track table's column-header bar is one
        // of them — tinting the window painted a slab of the wash's *top* colour
        // across a header sitting far enough down the page that the gradient there
        // has already faded out. MacTopBar draws the tint in front of this anyway,
        // so all the window itself needs is the neutral system background.
        window.backgroundColor = .windowBackgroundColor
    }

    /// The wash's top colour is translucent — it's designed to sit over the app
    /// background. A titlebar can only take an opaque colour, so composite the
    /// two by hand rather than handing AppKit something see-through.
    static func flatten(_ color: Color, over background: Color) -> NSColor {
        guard let top  = NSColor(color).usingColorSpace(.deviceRGB),
              let base = NSColor(background).usingColorSpace(.deviceRGB)
        else { return NSColor(color) }

        let a = top.alphaComponent
        return NSColor(
            red:   top.redComponent   * a + base.redComponent   * (1 - a),
            green: top.greenComponent * a + base.greenComponent * (1 - a),
            blue:  top.blueComponent  * a + base.blueComponent  * (1 - a),
            alpha: 1
        )
    }
}

#endif

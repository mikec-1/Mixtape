// The main macOS window: MacTopBar, a hand-rolled sidebar/content split, and the player bar.
// No NSToolbar (see MacTopBar) and no NavigationSplitView (see `splitView`).
// Also handles Space/⌘<-/⌘-> via an NSEvent monitor and drag-to-import onto the window.

#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

import Combine

/// Fades a bar out in karaoke without giving back its space, so the lyrics don't jump.
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
    // Titlebar colour matching the fullscreen-lyrics background, nil for default chrome.
    // Refreshed on track/mode change, not per playback tick.
    @State private var lyricsHeaderColor: NSColor? = nil
    // Top colour of the current screen's artwork wash, carried up through the chrome.
    @ObservedObject private var washTint = ArtworkWashTint.shared
    @ObservedObject private var theme = ThemeManager.shared
    // Type-ahead panel under the search field. MacTopBar drives it; we draw it so it paints over the split view.
    @ObservedObject private var suggestions = SearchSuggestionsStore.shared
    // Custom right panel: `.inspector` can't be stopped from drag-dismissing.
    @State      private var rightPanelWidth: CGFloat  = 300
    // Resets itself when the drag ends and survives re-renders during it.
    @GestureState private var panelDragStart: CGFloat? = nil
    // Persisted sidebar width. The right panel still resets per launch.
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
        // `onContinuousHover` fires per mouse move; don't rebuild the sleep task every time.
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
        // Hide the pointer with the bars so it doesn't keep a lyric lit. It returns on the first move.
        if appState.karaokeActive { NSCursor.setHiddenUntilMouseMoves(!awake) }
        withMixAnimation(.easeInOut(duration: 0.35)) { chromeAwake = awake }
    }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                // The bar is a `safeAreaInset`, not a sibling: with `.hiddenTitleBar` the split view draws
                // across the whole window and would paint over a sibling. Kept inside the zoom transform so ⌘+/⌘- scales it.
                splitView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        MacTopBar(tint: chromeTintColor)
                            .environmentObject(appState)
                            .environmentObject(deps)
                            .environmentObject(sync)
                            .modifier(KaraokeChrome(hidden: chromeHidden))
                    }

                // Player bar. In karaoke it's an overlay instead so the lyrics get the full height.
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
            // Karaoke only: painted behind the bars so the wash stays continuous when they fade.
            .background {
                if appState.karaokeActive { KaraokeBackdrop() }
            }
            // Karaoke bars fade out and return on the first mouse move anywhere in the window.
            .onContinuousHover { phase in
                guard appState.karaokeActive else { return }
                if case .active = phase { wakeChrome() }
            }
            .onChange(of: appState.karaokeActive) { _, active in
                // Entering hides the chrome immediately.
                chromeSleep?.cancel()
                showChrome(!active)
            }
            // Search suggestions. Hung off the VStack so it paints over the split view and stays inside the zoom transform.
            .overlay(alignment: .top) {
                if suggestions.isShowing {
                    ZStack(alignment: .top) {
                        // Click-catcher: clicking the content doesn't reliably resign the field on macOS, so swallow the click and close.
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { suggestions.dismiss() }
                            // Below the bar only, so clicks in the field and its buttons still land.
                            .padding(.top, MacTopBar.height(for: appState.uiScale))

                        MacSearchSuggestions(store: suggestions) { picked in
                            activateSuggestion(picked, appState: appState, deps: deps)
                            suggestions.dismiss()
                        }
                        // Same reserve and centring as the field, so they line up at every zoom.
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
            // macOS workaround: pin hit-testing bounds to the window so clicks map correctly.
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            // Zoom snaps. Explicitly nil so no ambient transaction animates it.
            .mixAnimation(nil, value: appState.uiScale)
            // Zoom HUD
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
        // With `.hiddenTitleBar`, ignore any leftover titlebar safe area so the bar sits behind the traffic lights.
        .ignoresSafeArea(.container, edges: .top)
        // Window constraints
        .frame(minWidth: 960, minHeight: 560)
        .background(MixPageBackground())
        // Carry the current screen's colour up into the window chrome
        .background(WindowChromeTint())
        // Back / forward, hung in the titlebar itself
        .background(HistoryTitlebarAccessory(appState: appState, recap: deps.recap))
        .onAppear { refreshLyricsHeaderColor() }
        .onChange(of: appState.lyricsPresented)   { _, _ in refreshLyricsHeaderColor() }
        .onChange(of: appState.lyricsFullscreen)  { _, _ in refreshLyricsHeaderColor() }
        .onChange(of: engine.queue.currentTrack?.id) { _, _ in refreshLyricsHeaderColor() }
        // Escape closes the right panel. `.onExitCommand` doesn't interfere with the NSEvent monitor.
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
        // Messages and the "Added to ..." card, bottom centre above the player bar. Outside the zoom transform too.
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                VersionCheckHost(coordinator: deps.onlineCoordinator, queue: engine.queue)
                // Every app message, playback errors included.
                ToastHost(center: deps.toasts)
                    .padding(.horizontal, 40)
                SavedToastHost(center: deps.savedToasts)
            }
            .padding(.bottom, MacPlayerBar.height * appState.uiScale + 14)
        }
        // "Saved in" panel. Not a sheet: nothing dims and the app keeps working. See `SavedInPanel`.
        .overlay(alignment: .bottomLeading) {
            SavedInPanelHost(center: deps.savedInPanel,
                             bottomGap: MacPlayerBar.height * appState.uiScale + 14)
        }
        // "Downloading" card, above the player bar's track info and above the Saved In panel when open.
        .overlay(alignment: .bottomLeading) {
            PreparingBarSlot(coordinator: deps.onlineCoordinator,
                             savedIn: deps.savedInPanel,
                             baseGap: MacPlayerBar.height * appState.uiScale + 14)
        }
        // Keyboard shortcuts
        .background {
            Group {
                // Settings
                Button("") { appState.goToSection(.settings) }
                    .keyboardShortcut(",", modifiers: .command)
                // ⌘K
                Button("") { appState.commandPaletteOpen.toggle() }
                    .keyboardShortcut("k", modifiers: .command)
                // ⌘+ (Shift+=). The View menu owns ⌘=.
                Button("") { appState.zoomIn() }
                    .keyboardShortcut("+", modifiers: .command)
            }
            .opacity(0)
        }
        // Command palette. An overlay, not a sheet, so clicking outside dismisses it.
        .overlay {
            if appState.commandPaletteOpen {
                // Its own AppKit view, or clicks can land on the track tables underneath.
                AppKitLayer {
                    ZStack(alignment: .top) {
                        Color.black.opacity(0.28)
                            .ignoresSafeArea()
                            .onTapGesture { appState.commandPaletteOpen = false }

                        MacCommandPalette()
                            .environmentObject(deps)
                            .environmentObject(appState)
                            .environmentObject(library)
                            .environmentObject(engine)
                            .padding(.top, 90)
                    }
                }
                .transition(.opacity)
            }
        }
        .mixAnimation(.easeOut(duration: 0.12), value: appState.commandPaletteOpen)
        // Show zoom HUD briefly on scale change
        .onChange(of: appState.uiScale) { _, _ in
            showZoomHUD = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                showZoomHUD = false
            }
        }
        // Metadata review sheet
        .sheet(item: Binding(
            get: { appState.pendingReview },
            set: { _ in appState.dequeueReview() }
        )) { item in
            MacMetadataReviewSheet(item: item)
                .environmentObject(deps)
                .environmentObject(appState)
        }
        // Lyrics editor, presented from the main window. See `MacAppState.lyricsEditorTrack`.
        .sheet(item: $appState.lyricsEditorTrack) { track in
            LyricsEditorSheet(track: track)
                .environmentObject(deps)
        }
        .sheet(item: $appState.lyricCard) { card in
            LyricCardSheet(track: card.track, lyrics: card.lyrics)
                .environmentObject(deps)
        }
        // Get Info
        .sheet(item: $appState.infoTrack) { track in
            GetInfoSheet(track: track,
                         isOnline: deps.onlineCoordinator.hasActiveOnlineSession,
                         followsPlayback: false)
                .environmentObject(engine)
                .environmentObject(deps)
                .environmentObject(deps.queueService)
        }
        .sheet(item: $appState.editTrack) { track in
            SongEditorSheet(track: track, onOpenPost: { appState.showPost(code: $0) })
                .environmentObject(deps)
        }
        .sheet(item: $appState.postTrack) { track in
            PostSheet(track: track, onOpen: { appState.showPost(code: $0) })
                .environmentObject(deps)
        }
        // Library > Merge Duplicate Songs
        .sheet(item: $appState.dubRequest) { request in
            DubSheet(playlist: request.playlist,
                     tracks: request.playlist.trackIDs.compactMap { deps.libraryService.track(id: $0) },
                     recipient: request.recipient)
                .environmentObject(deps)
        }
        .sheet(isPresented: $showMergeDuplicates) {
            MergeDuplicatesSheet().environmentObject(deps)
        }
        .onReceive(NotificationCenter.default.publisher(for: .mixMergeDuplicates)) { _ in
            showMergeDuplicates = true
        }
        // ⌃⌘S from the View menu (see MixtapeApp).
        .onReceive(NotificationCenter.default.publisher(for: .mixSpotlightArtist)) { _ in
            if let name = SpotlightIndex.takePendingArtist() { appState.openDiscoverArtist(named: name) }
        }
        .onAppear {
            if let name = SpotlightIndex.takePendingArtist() { appState.openDiscoverArtist(named: name) }
            openTappedNotification()
        }
        .onReceive(NotificationCenter.default.publisher(for: .mixNotificationTap)) { _ in openTappedNotification() }
        .onReceive(NotificationCenter.default.publisher(for: .mixToggleSidebar)) { _ in
            appState.toggleSidebar()
        }
        // View menu zoom + navigation commands, in a ViewModifier to keep the type-checker fast.
        .modifier(ViewMenuCommands(appState: appState, deps: deps))
        .environmentObject(appState)
    }

    private func openTappedNotification() {
        switch InviteNotifier.shared.takePendingTap() {
        case .messages(let person): appState.openMessages(with: person)
        case .jam(let code): Task { await deps.jam.join(code: code) }
        case .album(let title, let artist): appState.showOnlineAlbum(title: title, artistName: artist, trackID: nil)
        case nil: break
        }
    }

    // MARK: - Window chrome tint

    /// Fullscreen lyrics colour wins, else the top of the artwork wash, nil for screens without one.
    /// Checks the mode rather than trusting the cached lyrics colour to have been cleared.
    private var chromeTint: NSColor? {
        if appState.lyricsPresented, appState.lyricsFullscreen,
           let lyricsHeaderColor { return lyricsHeaderColor }
        guard let wash = washTint.color else { return nil }
        return WindowChromeTint.flatten(wash, over: Color.mixBackground)
    }

    /// Same colour for MacTopBar, so the wash reaches the top of the window.
    private var chromeTintColor: Color? {
        // Over a background colour the wash stays translucent, so the colour shows through as below.
        if theme.backdrop != nil, !(appState.lyricsPresented && appState.lyricsFullscreen) {
            return washTint.color
        }
        return chromeTint.map { Color(nsColor: $0) }
    }

    // MARK: - Lyrics header tint

    /// Chrome colour for fullscreen lyrics: the dominant album colour under the view's 0.45 black overlay (RGB x 0.55).
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

    // Split view. The right panel is a custom HStack because `.inspector` ignores its binding on drag-dismiss.

    private var splitView: some View {
        HStack(spacing: 0) {
            // Sidebar column. Hand-rolled so the collapse is one animated width instead of two
            // out-of-step animations (ours and AppKit's column collapse).
            if !karaokeTakeover {
                sidebarColumn
                sidebarDivider
            }

            // Main content
            Group {
                // Fullscreen lyrics replace the content column but stay inside the chrome.
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
            // Titlebar height ballast: AppKit gives an empty toolbar a 32pt titlebar and a non-empty one 52pt,
            // so pages without toolbar items shifted the traffic lights. One invisible 1x28 item keeps it at 52.
            .toolbar {
                if #available(macOS 26.0, *) {
                    ToolbarItem(placement: .navigation) { ballast }
                        // macOS 26 draws a glass platter per item; hide it or the 1pt item shows as a hairline.
                        .sharedBackgroundVisibility(.hidden)
                } else {
                    // Nothing to hide before 26: toolbar items had no background.
                    ToolbarItem(placement: .navigation) { ballast }
                }
            }

            // Don't hide the toolbar: that removes NSTitlebarContainerView and the traffic lights with it.
            // ⌘⌫ and ⌘F still work without toolbar buttons. Back/forward live in HistoryTitlebarAccessory.
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
            // Keyboard shortcuts
            .onAppear  {
                keyHandler.start(engine: engine, recap: deps.recap)
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

            // Custom right panel
            if appState.isRightPanelOpen {
                panelDivider
                rightPanelContent
                    .frame(width: rightPanelWidth)
                    .frame(maxHeight: .infinity)
                    // Same background and wash as the sidebar, so the window reads as one colour.
                    .background(alignment: .top) {
                        // In karaoke let the root backdrop through, so the wash isn't split.
                        if appState.karaokeActive {
                            Color.black.opacity(0.10).ignoresSafeArea()
                        } else {
                            ZStack(alignment: .top) {
                                MixPageBackground()
                                ArtworkWashGradient(colors: washTint.stops,
                                                    intensity: washTint.chromeIntensity)
                            }
                            .ignoresSafeArea()
                        }
                    }
            }
        }
        // Drag-to-import, on the whole stack so the sidebar accepts drops too.
        // `.fileURL` is what Finder vends; `.audio` doesn't reliably match.
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
        // The single animator for the fold, so width, cross-fade and content all move together.
        .mixAnimation(.spring(response: 0.34, dampingFraction: 0.9), value: appState.sidebarCollapsed)
    }

    // Sidebar column

    /// Karaoke hides the sidebar and right panel without touching their stored state.
    private var karaokeTakeover: Bool { appState.karaokeActive }

    /// Sidebar and rail cross-fade inside one animated, clipped width, so neither re-lays-out mid-collapse.
    private var sidebarColumn: some View {
        ZStack(alignment: .leading) {
            MacSidebarView()
                .environmentObject(appState)
                .frame(width: sidebarWidth)
                .opacity(appState.sidebarCollapsed ? 0 : 1)
                // Opacity 0 still takes clicks.
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
        // The window's colour and wash, not an NSVisualEffectView (which sampled the wallpaper).
        // On the container so it stays still through the cross-fade.
        .background(alignment: .top) {
            ZStack(alignment: .top) {
                MixPageBackground()
                ArtworkWashGradient(colors: washTint.stops, intensity: washTint.chromeIntensity)
            }
            .ignoresSafeArea()
        }
        .clipped()
    }

    /// Sidebar/content divider; drag to resize when expanded. Mirrors `panelDivider`.
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

    // Panel divider with drag-to-resize

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
                        // Global space so the translation doesn't shift as the divider moves.
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
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

    // Right panel content

    /// One view for all three panels; see `MacRightPanelView`.
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

    nonisolated private static let audioImportExtensions = Set(
        ["mp3", "m4a", "aiff", "aif", "wav", "flac", "ogg", "opus"]
    )

    /// The toolbar's permanent tenant (see the ballast note in `body`). Not `EmptyView`,
    /// which SwiftUI drops.
    private var ballast: some View {
        Color.clear.frame(width: 1, height: 28)
    }

    /// True if any provider has a file URL. Finder drops into a sandboxed app vend `public.file-url`
    /// data rather than a `URL` object, so resolve that first and fall back to `loadObject`.
    private func importDroppedFiles(_ providers: [NSItemProvider]) -> Bool {
        let fileURLType = UTType.fileURL.identifier
        var willHandleAny = false

        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(fileURLType) else { continue }
            willHandleAny = true
            // Not marked Sendable, but built to be called again from its own callbacks.
            nonisolated(unsafe) let provider = provider

            provider.loadItem(forTypeIdentifier: fileURLType, options: nil) { [deps, appState] item, _ in
                let resolved = Self.resolveFileURL(from: item)
                if let resolved {
                    Self.importIfAudio(resolved, deps: deps, appState: appState)
                } else {
                    // Fallback for providers that only answer the class-based API.
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        if let url { Self.importIfAudio(url, deps: deps, appState: appState) }
                    }
                }
            }
        }

        return willHandleAny
    }

    /// `loadItem` can hand back `URL`, `NSURL` or `Data`.
    nonisolated private static func resolveFileURL(from item: NSSecureCoding?) -> URL? {
        switch item {
        case let url as URL:
            return url
        case let nsurl as NSURL:
            return nsurl as URL
        case let data as Data:
            // Usually the absolute string as UTF-8.
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

    /// Filters by audio extension and imports with security-scoped access.
    nonisolated private static func importIfAudio(
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

            let result = await deps.importService.importTracks(from: [url]).first
            if case .imported(_, let review) = result {
                appState.enqueueReview(review)
            }
        }
    }
}

// MARK: - Keyboard Shortcut Handler
// Window keyboard shortcuts via an NSEvent local monitor, alive as long as MacRootView.
// Space: play/pause (not in text fields; under Full Keyboard Access only when Tab gave focus).
// ⌘->: next. ⌘<-: previous/restart.

private final class KeyboardShortcutHandler: ObservableObject {

    private var monitor: Any?

    /// Whether focus arrived by Tab. A clicked control keeps focus under Full Keyboard Access,
    /// so Space would re-press it instead of pausing.
    private var focusFromKeyboard = false

    func start(engine: PlaybackEngine, recap: RecapService) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self, weak engine, weak recap] event in
            guard let self, let engine else { return event }
            // The recap story pauses itself with Space.
            if recap?.presented != nil { return event }
            if event.type == .leftMouseDown { self.focusFromKeyboard = false; return event }
            if event.keyCode == 48 { self.focusFromKeyboard = true }   // Tab / ⇧Tab

            let cmd = event.modifierFlags.contains(.command)

            // Leave text input alone, ⌘-arrows included, or the menu's key equivalents eat line start/end.
            let fr = NSApp.keyWindow?.firstResponder
            if let fr = fr as? NSText {
                guard cmd, (123...126).contains(event.keyCode) else { return event }
                fr.keyDown(with: event)
                return nil
            }

            switch event.keyCode {
            case 49 where !cmd:  // Space: play / pause
                // Full Keyboard Access presses the focused control with Space; `SpaceFallback` handles
                // it if nothing did. Tables would spend it on type-select, so they keep play/pause.
                if focusFromKeyboard, NSApp.isFullKeyboardAccessEnabled,
                   !(fr is NSTableView), let window = event.window {
                    SpaceFallback.install(in: window, engine: engine)
                    return event
                }
                Task { @MainActor in engine.togglePlayPause() }
                return nil                  // consume

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

/// After the window in the responder chain, so it only gets a Space nothing else used.
private final class SpaceFallback: NSResponder {
    weak var engine: PlaybackEngine?

    static func install(in window: NSWindow, engine: PlaybackEngine) {
        if let existing = window.nextResponder as? SpaceFallback { existing.engine = engine; return }
        let fallback = SpaceFallback()
        fallback.engine = engine
        fallback.nextResponder = window.nextResponder
        window.nextResponder = fallback
    }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 49, let engine else { return super.keyDown(with: event) }
        engine.togglePlayPause()
    }

    // Views that run `interpretKeyEvents` hand an unwanted Space up as text.
    override func insertText(_ insertString: Any) {
        guard (insertString as? String) == " ", let engine else { return super.insertText(insertString) }
        engine.togglePlayPause()
    }
}

// MARK: - View Menu Commands

/// Wires View and File menu notifications to `MacAppState`/`LibraryService`. A ViewModifier
/// to keep the body short for the type-checker.
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
            .onReceive(NotificationCenter.default.publisher(for: .mixShowInfo)) { _ in
                if let track = deps.playbackEngine.queue.currentTrack { appState.showInspector(for: track) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .mixNewPlaylist)) { _ in createNewPlaylist() }
            .onReceive(NotificationCenter.default.publisher(for: .mixFocusSearch)) { _ in appState.focusSearch() }
            // "Open your tape" at the end of a recap.
            .onReceive(NotificationCenter.default.publisher(for: .mixOpenSmartPlaylist)) { note in
                if let playlist = note.object as? SmartPlaylist { appState.showSmartPlaylist(playlist) }
            }
            // View on a toast.
            .onReceive(NotificationCenter.default.publisher(for: .mixOpenPlaylist)) { note in
                if let id = note.object as? UUID, let playlist = deps.libraryService.playlist(id: id) {
                    appState.showPlaylist(playlist)
                }
            }
    }

    /// Blank playlist with `PlaylistEditorSheet`'s "My Playlist #N" name, then opens it.
    private func createNewPlaylist() {
        let count = deps.libraryService.playlists.filter { !$0.isSystem && !$0.isDeleted }.count
        let name  = "My Playlist #\(count + 1)"
        let playlist = deps.libraryService.createPlaylist(name: name)
        appState.showPlaylist(playlist)
    }
}

// MARK: - Delete Command
// Invisible: keeps ⌘⌫ working and owns the confirmation dialog.

private struct MacDeleteCommand: View {

    @EnvironmentObject private var deps:     AppDependencies
    @EnvironmentObject private var appState: MacAppState
    @EnvironmentObject private var engine:   PlaybackEngine

    @ObservedObject private var editing = MacTextEditingMonitor.shared

    /// Dialog text, computed on press. The body re-runs on every `MacAppState` publish and the
    /// orphan count walks the whole library.
    @State private var prompt: Prompt?

    private struct Prompt {
        var title:   String
        var message: String
        var label:   String
    }

    var body: some View {
        Button("") { prompt = makePrompt() }
            // Disabled while a field is editing so ⌘⌫ reaches it.
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
            // One write for the whole selection.
            SupabaseSyncService.allowBulk("user-remove")
            deps.libraryService.deleteTracks(ids: ids)
        } else if let id = appState.selectedPlaylistID {
            appState.clearDeleteSelection()
            SupabaseSyncService.allowBulk("delete-playlists")
            deps.libraryService.deletePlaylist(id: id)
        }
    }
}

// MARK: - Downloading card, stacked

/// The downloading card, stacked on the Saved In panel when open, otherwise on the player bar.
/// Its own view so opening the panel redraws only this corner.
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
                    // Aligned with the panel edge and the player bar's artwork.
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
        // In a short window, overlap the panel rather than draw off the top.
        return min(stacked, max(baseGap, height - Self.cardClearance))
    }

    /// Roughly the collapsed card's height plus a little air.
    private static let cardClearance: CGFloat = 76
}

// MARK: - History controls in the titlebar

/// Back/forward as a left titlebar accessory, laid out right after the traffic lights.
/// They must be real chrome to be clickable (see MacHistoryButtons), and the toolbar can't place them there.
private struct HistoryTitlebarAccessory: NSViewRepresentable {

    let appState: MacAppState
    let recap: RecapService

    /// Install once: `updateNSView` runs on every change and adding an accessory always appends.
    final class Coordinator {
        var installed = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let probe = NSView(frame: .zero)
        // The window is nil until the view is in a hierarchy.
        DispatchQueue.main.async { install(from: probe, coordinator: context.coordinator) }
        return probe
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { install(from: nsView, coordinator: context.coordinator) }
    }

    /// Tags our accessory so a rebuilt MacRootView (e.g. on sign-in) replaces the old pair.
    private static let identifier = NSUserInterfaceItemIdentifier("mix.historyAccessory")

    private func install(from view: NSView, coordinator: Coordinator) {
        guard !coordinator.installed, let window = view.window else { return }

        for (index, existing) in window.titlebarAccessoryViewControllers.enumerated().reversed()
            where existing.identifier == Self.identifier {
            window.removeTitlebarAccessoryViewController(at: index)
        }

        let host = NSHostingView(rootView: MacHistoryButtons(recap: recap).environmentObject(appState))
        // Accessories don't self-size: two 28pt buttons plus spacing.
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

/// Keeps the titlebar transparent and separator-free so MacTopBar paints the chrome.
/// SwiftUI content in its own NSHostingView, so it sits above AppKit views in hit-testing.
private struct AppKitLayer<Content: View>: NSViewRepresentable {
    @ViewBuilder let content: Content

    func makeNSView(context: Context) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: AnyView(content.environment(\.self, context.environment)))
        host.sizingOptions = []
        return host
    }

    func updateNSView(_ host: NSHostingView<AnyView>, context: Context) {
        host.rootView = AnyView(content.environment(\.self, context.environment))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSHostingView<AnyView>, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

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
        // Unconditional: the scene uses `.hiddenTitleBar`, so an opaque titlebar would cover MacTopBar.
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle     = .none
        // Not the wash colour: AppKit materials sample the window background (e.g. the table
        // header), and MacTopBar draws the tint anyway.
        window.backgroundColor = .windowBackgroundColor
    }

    /// A titlebar needs an opaque colour, so composite the translucent wash over the background.
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

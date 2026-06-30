// MacRootView.swift
// Mixtape — Mac/App
//
// The single main window for the macOS app.
// Layout: NavigationSplitView (sidebar + content) + player bar pinned at bottom.
// Search lives in the NSToolbar via .searchable.
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

@MainActor
struct MacRootView: View {

    @StateObject  private var appState = MacAppState()
    @StateObject  private var keyHandler = KeyboardShortcutHandler()

    @EnvironmentObject private var deps:    AppDependencies
    @EnvironmentObject private var engine:  PlaybackEngine
    @EnvironmentObject private var library: LibraryService
    @EnvironmentObject private var sync:    SupabaseSyncService

    @State private var isDropTargeted   = false
    @State private var showZoomHUD      = false
    // Solid colour applied to the window titlebar/toolbar so the header matches
    // the fullscreen-lyrics background. nil restores the default window chrome.
    // Cached (not recomputed per playback tick) — refreshed on track/mode change.
    @State private var lyricsHeaderColor: NSColor? = nil
    // Custom right-panel state — replaces SwiftUI .inspector which can't be
    // prevented from drag-dismissing.
    @State      private var rightPanelWidth: CGFloat  = 300
    // @GestureState is reset automatically by SwiftUI when the gesture ends,
    // and its value survives re-renders during the drag (unlike @State).
    @GestureState private var panelDragStart: CGFloat? = nil

    private let panelMinWidth: CGFloat = 220
    private let panelMaxWidth: CGFloat = 400

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                // ── Split view (takes all remaining height above the player bar) ──
                splitView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // ── Player bar (true layout position — not a safeAreaInset) ──────
                MacPlayerBar()
                    .environmentObject(appState)
            }
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
            .animation(.spring(response: 0.22, dampingFraction: 0.9), value: appState.uiScale)
            // ── Zoom HUD ──────────────────────────────────────────────────────
            .overlay(alignment: .top) {
                if showZoomHUD {
                    zoomHUD
                        .padding(.top, 10)
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                }
            }
            .animation(.easeInOut(duration: 0.18), value: showZoomHUD)
        }
        // ── Window constraints ────────────────────────────────────────────
        .frame(minWidth: 960, minHeight: 560)
        .background(Color.mixBackground)
        // ── Tint the window titlebar/toolbar to match fullscreen lyrics ─────
        .background(WindowChromeTint(color: lyricsHeaderColor))
        .onAppear { refreshLyricsHeaderColor() }
        .onChange(of: appState.lyricsPresented)   { _, _ in refreshLyricsHeaderColor() }
        .onChange(of: appState.lyricsFullscreen)  { _, _ in refreshLyricsHeaderColor() }
        .onChange(of: engine.queue.currentTrack?.id) { _, _ in refreshLyricsHeaderColor() }
        // ── Escape closes the right panel (Queue or Get-Info / Now Playing) ──
        // .onExitCommand is the macOS-native Esc hook; it routes to the first
        // responder's cancel/exit command without disturbing the NSEvent monitor
        // used for Space / Cmd+Left / Cmd+Right.
        .onExitCommand {
            if appState.lyricsPresented && appState.lyricsFullscreen {
                appState.lyricsPresented = false
            } else if appState.isRightPanelOpen {
                appState.closePanel()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: appState.lyricsPresented)
        .animation(.easeInOut(duration: 0.25), value: appState.lyricsFullscreen)
        // ── Error toast ───────────────────────────────────────────────────
        .overlay(alignment: .top) {
            if let msg = engine.errorMessage {
                MacErrorToast(message: msg)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: engine.errorMessage)
        // ── Keyboard shortcuts ────────────────────────────────────────────
        .background {
            Group {
                // Settings
                Button("") { appState.selection = .settings }
                    .keyboardShortcut(",", modifiers: .command)
                // Zoom in — Cmd+= (no Shift) and Cmd++ (Shift+=)
                Button("") { appState.zoomIn() }
                    .keyboardShortcut("=", modifiers: .command)
                Button("") { appState.zoomIn() }
                    .keyboardShortcut("+", modifiers: .command)
                // Zoom out — Cmd+-
                Button("") { appState.zoomOut() }
                    .keyboardShortcut("-", modifiers: .command)
                // Reset zoom — Cmd+0
                Button("") { appState.resetZoom() }
                    .keyboardShortcut("0", modifiers: .command)
            }
            .opacity(0)
        }
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
        .environmentObject(appState)
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
        let colors = ArtworkColors.dominantColors(from: engine.queue.currentTrack?.artworkData)
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
        .background(.regularMaterial, in: Capsule())
    }

    // ── Split view + all its modifiers ────────────────────────────────────
    //
    // The right panel is a custom HStack layout rather than SwiftUI's .inspector.
    // .inspector cannot be prevented from drag-dismissing (the binding setter is
    // ignored when the user drags past min width), so we manage the panel ourselves.

    private var splitView: some View {
        HStack(spacing: 0) {
            // ── Main content ──────────────────────────────────────────────
            NavigationSplitView(columnVisibility: $appState.columnVisibility) {
                MacSidebarView()
                    .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
                    .environmentObject(appState)
            } detail: {
                // Fullscreen lyrics take over the main content column — staying
                // inside the chrome (sidebar, toolbar, player bar, right panel)
                // rather than floating as a window overlay.
                if appState.lyricsPresented && appState.lyricsFullscreen {
                    MacLyricsView()
                        .environmentObject(engine)
                        .environmentObject(appState)
                        .transition(.opacity)
                } else {
                    MacContentRouter()
                        .environmentObject(appState)
                        .environmentObject(deps)
                }
            }
            // ── Toolbar ───────────────────────────────────────────────────
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    MacSyncButton()
                        .environmentObject(sync)
                }
                ToolbarItem(placement: .automatic) {
                    MacImportButton()
                }
                ToolbarItem(placement: .automatic) {
                    MacSpotifyImportButton()
                        .environmentObject(deps)
                }
                ToolbarItem(placement: .automatic) {
                    MacAddToPlaylistButton()
                        .environmentObject(deps)
                        .environmentObject(appState)
                }
                ToolbarItem(placement: .automatic) {
                    MacDeleteButton()
                        .environmentObject(deps)
                        .environmentObject(appState)
                        .environmentObject(engine)
                }
            }
            // ── Search ────────────────────────────────────────────────────
            .searchable(
                text: $appState.searchText,
                placement: .toolbar,
                prompt: "Search library"
            )
            // ── Drag-to-import ────────────────────────────────────────────
            // `.fileURL` is the identifier Finder vends for file drops; `.audio`
            // alone does not reliably match a Finder file drag.
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                importDroppedFiles(providers)
            }
            // ── Drop overlay ──────────────────────────────────────────────
            .overlay {
                if isDropTargeted {
                    dropOverlay
                        .transition(.opacity)
                        .ignoresSafeArea()
                }
            }
            .animation(.easeInOut(duration: 0.14), value: isDropTargeted)
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
                    .background(Color.mixBackground)
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.88), value: appState.isRightPanelOpen)
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

    @ViewBuilder
    private var rightPanelContent: some View {
        switch appState.rightPanel {
        case .nowPlaying:
            if let track = appState.inspectorTrack {
                MacTrackInspector(fallbackTrack: track)
                    .environmentObject(engine)
                    .environmentObject(library)
                    .environmentObject(appState)
            }
        case .queue:
            MacQueuePanelView()
                .environmentObject(engine)
        case nil:
            EmptyView()
        }
    }

    // MARK: - Drop overlay

    private var dropOverlay: some View {
        ZStack {
            Color.black.opacity(0.35)

            VStack(spacing: 16) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(Color.mixPrimary)
                    .symbolEffect(.pulse, isActive: isDropTargeted)

                Text("Drop to Import")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.mixTextPrimary)

                Text("Release to add to your library")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.mixTextSecondary)
            }
            .padding(40)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
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
            if case .imported(let track, let candidate) = result {
                appState.enqueueReview(MetadataReviewItem(track: track, candidate: candidate))
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

// MARK: - Sync Button

private struct MacSyncButton: View {
    @EnvironmentObject private var deps: AppDependencies
    @EnvironmentObject private var sync: SupabaseSyncService
    @State private var isSpinning = false

    var body: some View {
        Button {
            isSpinning = true
            Task {
                deps.downloadManager.reEvaluateDownloads()
                await deps.importService.scanExportDirectoryForNewFiles()
                try? await sync.sync()
                isSpinning = false
            }
        } label: {
            Image(systemName: "arrow.trianglehead.2.clockwise")
                .symbolEffect(.pulse, isActive: isSpinning)
        }
        .help("Sync library")
    }
}

// MARK: - Import Button

private struct MacImportButton: View {
    @EnvironmentObject private var deps:     AppDependencies
    @EnvironmentObject private var appState: MacAppState
    @State private var isImporting = false

    var body: some View {
        Button {
            isImporting = true
        } label: {
            Image(systemName: "square.and.arrow.down")
        }
        .help("Import music")
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.audio, .mp3, .mpeg4Audio, .aiff, .wav],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            Task { @MainActor in
                for url in urls {
                    let r = await deps.importService.importTrack(from: url)
                    if case .imported(let track, let candidate) = r {
                        appState.enqueueReview(MetadataReviewItem(track: track, candidate: candidate))
                    }
                }
            }
        }
    }
}

// MARK: - Spotify Import Button

private struct MacSpotifyImportButton: View {
    @EnvironmentObject private var deps: AppDependencies
    @State private var showSheet = false

    var body: some View {
        Button {
            showSheet = true
        } label: {
            Image(systemName: "music.note.list")
        }
        .help("Import from Spotify")
        .sheet(isPresented: $showSheet) {
            SpotifyImportView(spotifyClient: deps.spotifyClient,
                              importService: deps.spotifyImportService,
                              auth: deps.spotifyAuth)
                .environmentObject(deps)
                .frame(minWidth: 460, minHeight: 420)
        }
    }
}

// MARK: - Delete Button

private struct MacDeleteButton: View {

    @EnvironmentObject private var deps:     AppDependencies
    @EnvironmentObject private var appState: MacAppState
    @EnvironmentObject private var engine:   PlaybackEngine

    @State private var showConfirm = false

    var body: some View {
        Button {
            showConfirm = true
        } label: {
            Image(systemName: "trash")
                .foregroundStyle(appState.canDelete ? Color.mixDestructive : Color.mixTextTertiary)
        }
        .help(helpText)
        .disabled(!appState.canDelete)
        .keyboardShortcut(.delete, modifiers: .command)
        .confirmationDialog(confirmTitle, isPresented: $showConfirm, titleVisibility: .visible) {
            Button(deleteButtonLabel, role: .destructive) { performDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
    }

    // MARK: - Derived labels

    private var helpText: String {
        if !appState.selectedTrackIDs.isEmpty {
            let n = appState.selectedTrackIDs.count
            return n == 1 ? "Delete selected song (⌘⌫)" : "Delete \(n) songs (⌘⌫)"
        }
        if let id = appState.selectedPlaylistID,
           let pl = deps.libraryService.playlist(id: id) {
            return "Delete playlist \"\(pl.name)\" (⌘⌫)"
        }
        return "Delete (nothing selected)"
    }

    private var confirmTitle: String {
        if !appState.selectedTrackIDs.isEmpty {
            let n = appState.selectedTrackIDs.count
            return n == 1 ? "Delete Song" : "Delete \(n) Songs"
        }
        if let id = appState.selectedPlaylistID,
           let pl = deps.libraryService.playlist(id: id) {
            return "Delete \"\(pl.name)\""
        }
        return "Delete"
    }

    private var confirmMessage: String {
        if !appState.selectedTrackIDs.isEmpty {
            let n = appState.selectedTrackIDs.count
            return n == 1
                ? "This will permanently remove the song from your library on all devices."
                : "This will permanently remove \(n) songs from your library on all devices."
        }
        return "This will delete the playlist. Your songs won't be affected."
    }

    private var deleteButtonLabel: String {
        if !appState.selectedTrackIDs.isEmpty {
            let n = appState.selectedTrackIDs.count
            return n == 1 ? "Delete Song" : "Delete \(n) Songs"
        }
        return "Delete Playlist"
    }

    // MARK: - Action

    private func performDelete() {
        if !appState.selectedTrackIDs.isEmpty {
            let ids = appState.selectedTrackIDs
            appState.clearDeleteSelection()
            for id in ids {
                engine.stopIfPlaying(trackID: id)
                deps.libraryService.deleteTrack(id: id)
            }
        } else if let id = appState.selectedPlaylistID {
            appState.clearDeleteSelection()
            deps.libraryService.deletePlaylist(id: id)
        }
    }
}

// MARK: - Add to Playlist Button

private struct MacAddToPlaylistButton: View {
    @EnvironmentObject private var deps:     AppDependencies
    @EnvironmentObject private var appState: MacAppState

    var body: some View {
        let selectedCount = appState.selectedTrackIDs.count
        let targetPlaylists = deps.libraryService.playlists.filter { pl in
            if pl.isAllSongs || pl.isDeleted { return false }
            // Only show playlist if it does NOT contain ALL of the selected tracks.
            return !appState.selectedTrackIDs.allSatisfy { pl.trackIDs.contains($0) }
        }

        Menu {
            if targetPlaylists.isEmpty {
                Text("No playlists available")
                    .disabled(true)
            } else {
                ForEach(targetPlaylists) { playlist in
                    Button(playlist.name) {
                        let ids = Array(appState.selectedTrackIDs)
                        for id in ids {
                            deps.libraryService.addTrack(id: id, toPlaylist: playlist.id)
                        }
                        let trackWord = ids.count == 1 ? "song" : "songs"
                        let destName = playlist.name
                        deps.showToast("Added \(ids.count) \(trackWord) to \(destName)")
                        appState.clearDeleteSelection()
                    }
                }
            }
        } label: {
            Image(systemName: "folder.badge.plus")
        }
        .help(helpText(selectedCount))
        .disabled(appState.selectedTrackIDs.isEmpty)
    }

    private func helpText(_ count: Int) -> String {
        if count == 0 {
            return "Add to Playlist (select songs first)"
        } else if count == 1 {
            return "Add selected song to playlist"
        } else {
            return "Add \(count) selected songs to playlist"
        }
    }
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
        .background(Color.mixSurface2, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.mixDestructive.opacity(0.4), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
    }
}

// MARK: - Window chrome tint

/// Tints the host NSWindow's titlebar/toolbar a solid colour (with a transparent
/// titlebar so the window background shows through the toolbar). A nil colour
/// restores the standard system chrome.
private struct WindowChromeTint: NSViewRepresentable {
    let color: NSColor?

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
        if let color {
            window.titlebarAppearsTransparent = true
            window.backgroundColor = color
        } else {
            window.titlebarAppearsTransparent = false
            window.backgroundColor = .windowBackgroundColor
        }
    }
}

#endif

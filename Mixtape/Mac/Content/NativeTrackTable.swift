// NativeTrackTable.swift
// Mixtape — Mac/Content
//
// NSViewRepresentable wrapping NSScrollView+NSTableView for the Songs list.
//
// Why AppKit here?
//   SwiftUI Table on macOS hosts one full SwiftUI render-tree per visible row.
//   At 10 000+ tracks that creates noticeable frame drops while scrolling.
//   NSTableView recycles NSView cells directly, keeping the cell count equal
//   to the number of *visible* rows regardless of library size.
//
// Interaction model:
//   Single click       — select row(s)
//   Click the artwork  — play immediately (the badge that fades in on hover)
//   Double click       — play immediately
//   Return key         — play first selected
//   Right-click        — context menu (Play Now / Play Next / Add to Queue / Get Info)
//   Column header      — sort ascending / descending (Title · Artist · Album)

#if os(macOS)
import AppKit
import Combine
import SwiftUI

// MARK: - NativeTrackTable

struct NativeTrackTable: NSViewRepresentable {

    // MARK: Inputs

    let  tracks:         [Track]
    let  currentTrackID: Track.ID?
    let  isPlaying:      Bool
    @Binding var selectedIDs: Set<Track.ID>

    /// The app's active colour scheme. Used to force the wrapped AppKit table's
    /// `appearance` to match — `.preferredColorScheme` alone doesn't reliably
    /// propagate into NSViewRepresentable, which left song text stuck at the
    /// previous appearance's colour (e.g. white-on-white in light mode).
    @Environment(\.colorScheme) private var colorScheme

    // MARK: Callbacks (all called on the main thread)

    var onPlay:               (Track, [Track]) -> Void
    var onPlayNext:           (Track)          -> Void
    var onAddToQueue:         (Track)          -> Void
    var onGetInfo:            (Track)          -> Void
    /// Called when a row drag starts (true) and ends (false), so the sidebar can
    /// switch its playlist rows from "reorder" to "drop songs here" affordances.
    var onDragTracksChanged:  ((Bool)   -> Void)?
    /// "Go to Artist" — passed one credited artist name (features are split, so a
    /// track by "A feat. B" offers both). Nil hides the menu item.
    var onGoToArtist:         ((String) -> Void)?
    /// "Go to Album" — passed the track whose album should be opened.
    var onGoToAlbum:          ((Track)  -> Void)?
    /// Clicking a name in the Artist column. Passed the single credited artist
    /// that was clicked, never the whole "A, B feat. C" credit — the column
    /// renders one click target per name. Nil leaves the column as plain text.
    var onOpenArtistLink:     ((String) -> Void)? = nil
    /// Clicking the Album column. Nil leaves it as plain text.
    var onOpenAlbumLink:      ((Track)  -> Void)? = nil
    /// "Remove from Library" — passed the whole selection, so the caller can
    /// delete it in one write rather than one sync round per song.
    var onRemove:             ([Track])        -> Void
    var onToggleFavourite:    (Track)          -> Void = { _ in }
    var onAddToPlaylist:      ([Track], UUID)  -> Void = { _, _ in }
    /// Called when the user picks "Move to Artist Folder…" from the context menu.
    var onMoveToArtistFolder: ((Track) -> Void)?

    // MARK: Playlist pages
    //
    // A playlist is a list a song can leave without leaving the library, which
    // the Songs/Albums/Artists tables have no equivalent of. Nil on those.

    /// "Remove from Playlist" — nil hides the item entirely, which is what a
    /// read-only playlist (a mix, or someone else's) wants.
    var onRemoveFromPlaylist:   (([Track]) -> Void)? = nil
    /// What that item is called for a given number of songs. Favourites removes
    /// a favourite rather than a row, and says so.
    var removeFromPlaylistTitle: (Int) -> String = {
        $0 > 1 ? "Remove \($0) Songs from Playlist" : "Remove from Playlist"
    }
    /// Whether the permanent, syncing library delete is offered. Off on a
    /// playlist page: there, "remove" means remove from this list.
    var showsRemoveFromLibrary: Bool = true
    /// The playlist being shown, kept out of its own "Add to Playlist" submenu.
    var excludedPlaylistID:     UUID? = nil
    /// "Find in Discover", for a collaborator's song this device can't reach.
    var onFindInDiscover:       ((Track) -> Void)? = nil
    /// "Choose Playlist…" at the foot of the Add to Playlist submenu — the sheet,
    /// which is the only route to a playlist that doesn't exist yet. Nil leaves
    /// the submenu as a plain list of the playlists there are.
    var onChoosePlaylist:       (([Track]) -> Void)? = nil

    // MARK: Online pages
    //
    // A page whose rows aren't in the library yet — the mix page, which is a
    // playlist made of songs Discover found. Nil on every library table, where
    // "add to library" is a thing you can't do to a song that is in it.

    /// "Add to Library" — passed the targets that aren't in the library yet.
    var onAddToLibrary: (([Track]) -> Void)? = nil
    /// Whether a row is already a library song. Only consulted when
    /// `onAddToLibrary` is set; everywhere else the rows came *from* the
    /// library, so the honest default is yes.
    var isInLibrary: (Track.ID) -> Bool = { _ in true }

    // MARK: Data for context-menu enrichment
    var isFavourited: (Track.ID) -> Bool = { _ in false }
    var playlists:    [Playlist]         = []
    var availability: (Track.ID) -> TrackAvailability = { _ in .streamOnly }
    var onDownload:       ((Track) -> Void)? = nil
    var onRemoveDownload: ((Track.ID) -> Void)? = nil
    /// "Save a File Copy" — passed the whole selection, so a page that can
    /// export in one go asks for the destination folder once.
    var onSaveToDisk:         (([Track]) -> Void)? = nil
    /// After "Copy Song Link", so the page can say so — the menu has no `deps`.
    var onLinkCopied:         (() -> Void)? = nil
    /// Whether Download can actually do anything for this track.
    ///
    /// A row that can't be downloaded gets no Download item at all. It used to
    /// get a disabled one carrying the reason ("Add this mix to your library to
    /// download it"), which put a dead end where an action belongs — and the
    /// action it named is already in this menu, a few rows up.
    var canDownload: (Track) -> Bool = { _ in true }

    /// The current UI zoom scale (from MacAppState.uiScale).
    /// Passed through so AppKit layers can render at the correct pixel density
    /// before `scaleEffect` upscales them — prevents blurriness at zoom > 1.
    var scale: CGFloat = 1.0

    /// Size to the rows instead of scrolling internally, for pages where the
    /// whole page is one SwiftUI `ScrollView`. Without this the table keeps its
    /// own scroller and the page ends up with two scroll views fighting over
    /// the wheel — and a short window can't give the table enough height to
    /// show anythinat all.
    var fitsContent: Bool = false

    /// The page's own sort, when the page has a control for it.
    ///
    /// Set means the rows arrive in order already and the table must not sort
    /// them again — it only mirrors the state into its column headers, so the
    /// little arrow still marks the column being sorted by, and writes header
    /// clicks back here. Two sorts of the same list, one in AppKit and one in
    /// SwiftUI, can only ever disagree.
    ///
    /// Nil keeps the old behaviour: the coordinator owns the order and the
    /// column headers are the only way to change it.
    var sort: Binding<TrackSort>? = nil

    /// How much room a row gets. See `RowMetrics`.
    ///
    /// This is the page's choice — dense library table or roomy detail page.
    /// The user's density setting is applied on top of it by
    /// `effectiveMetrics`, which is what everything actually draws from, so no
    /// call site has to know the setting exists.
    var metrics: RowMetrics = .compact

    /// Whether each row is numbered with its position in the list.
    ///
    /// A playlist page wants it — the number is how you say "the fourth one" to
    /// somebody, and how you see at a glance where you are in a long list. The
    /// library tables don't: a row's position in Songs is an accident of the
    /// current sort and means nothing.
    ///
    /// Adds a fixed narrow column in front of Title — see `columnSpecs`.
    var showsIndex: Bool = false

    /// Mixtape's own generated lists (mixes, Release Radar) have no import date
    /// worth showing — every row would read "just now" — so they drop the
    /// column. It comes back the moment the list is saved to the library.
    var showsDateAdded: Bool = true

    @Environment(\.mixDensity) private var density

    /// `metrics` at the user's chosen density — the only one anything draws from.
    var effectiveMetrics: RowMetrics { metrics.at(density) }

    /// Songs whose audio is being fetched right now, drawn with a spinner over
    /// the cover. Fed from `PlaybackEngine.routingTrackIDs`.
    ///
    /// A song that has to be found online takes seconds to start, and without
    /// this the click has no visible effect at all until it does — which reads
    /// as the click having missed.
    var resolvingIDs: Set<Track.ID> = []

    // MARK: - Row Metrics

    /// A row's proportions.
    ///
    /// The library tables are dense on purpose: Songs is ten thousand rows and
    /// the job there is to fit as many on screen as stay readable. A detail page
    /// is one playlist, and can afford the taller row with the bigger cover and
    /// title that the playlist page wore before it moved to this table.
    struct RowMetrics: Equatable {
        var rowHeight:     CGFloat
        var artwork:       CGFloat
        /// Inset from the row's leading edge to the artwork.
        var leading:       CGFloat
        /// Artwork → title gap.
        var titleGap:      CGFloat
        var titleSize:     CGFloat
        /// Weight of a title that isn't the current track (which is always bold).
        var titleWeight:   NSFont.Weight
        /// Artist, album and date.
        var secondarySize: CGFloat
        var durationSize:  CGFloat

        static let compact = RowMetrics(
            rowHeight: 46, artwork: 34, leading: 8, titleGap: 10,
            titleSize: 14, titleWeight: .regular,
            secondarySize: 13, durationSize: 11
        )

        /// The playlist page's proportions: a 44pt cover and a 15pt semibold
        /// title, the same numbers its SwiftUI rows used.
        static let roomy = RowMetrics(
            rowHeight: 58, artwork: 44, leading: 12, titleGap: 12,
            titleSize: 15, titleWeight: .semibold,
            secondarySize: 14, durationSize: 12
        )

        /// The same proportions at the user's chosen density.
        ///
        /// A ratio rather than a third hand-tuned preset: the two above are
        /// already a deliberate pair, and a Compact set written from scratch
        /// would drift out of step with them the first time either is touched.
        /// Type sizes come down by a whole point instead — 13.2pt text is
        /// blurry where 13pt is sharp.
        func at(_ density: MixDensity) -> RowMetrics {
            guard density == .compact else { return self }
            var m = self
            m.rowHeight     = (rowHeight * 0.82).rounded()
            m.artwork       = (artwork   * 0.82).rounded()
            m.leading       = max(6, (leading  * 0.8).rounded())
            m.titleGap      = max(6, (titleGap * 0.8).rounded())
            m.titleSize     = titleSize     - 1
            m.secondarySize = secondarySize - 1
            m.durationSize  = durationSize  - 1
            return m
        }
    }

    // MARK: - NSViewRepresentable

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = MelTableView()
        tv.style                              = .inset
        tv.usesAlternatingRowBackgroundColors = false
        tv.allowsMultipleSelection            = true
        tv.rowHeight                          = effectiveMetrics.rowHeight
        tv.columnAutoresizingStyle            = .uniformColumnAutoresizingStyle
        tv.backgroundColor                    = .clear
        tv.doubleAction                       = #selector(Coordinator.rowDoubleClicked(_:))
        tv.target                             = context.coordinator
        tv.delegate                           = context.coordinator
        tv.dataSource                         = context.coordinator
        // Rows drag out onto the sidebar's playlists (copy, never move — the
        // song stays in this list).
        tv.setDraggingSourceOperationMask(.copy, forLocal: true)

        // Right-click menu, Return key and pointer tracking forwarded to coordinator
        tv.menuBuilder    = { [weak c = context.coordinator] row in c?.buildContextMenu(row: row) }
        tv.onReturnKey    = { [weak c = context.coordinator] in    c?.playFirstSelected() }
        tv.onHoverChange  = { [weak c = context.coordinator] old, new in
            c?.hoverChanged(from: old, to: new)
        }

        for spec in columnSpecs {
            let col     = NSTableColumn(identifier: .init(spec.id))
            col.title   = spec.title
            col.minWidth = spec.minW
            col.width   = spec.width
            // Columns built in code default to autoresize-only, which is why the
            // dividers in the header looked draggable and weren't. A list of
            // songs is exactly the place someone wants a wider Title and a
            // narrower Date Added.
            col.resizingMask = spec.isFixed ? [] : [.userResizingMask, .autoresizingMask]
            if spec.sortKey != nil {
                col.sortDescriptorPrototype = NSSortDescriptor(key: spec.sortKey!, ascending: true)
            }
            tv.addTableColumn(col)
        }

        // Replaces the stock header, which paints itself with a system effect.
        // See `MelTableHeaderView`.
        tv.headerView = MelTableHeaderView()

        context.coordinator.tableView = tv

        let sv = fitsContent ? PassthroughScrollView() : NSScrollView()
        sv.documentView        = tv
        sv.hasVerticalScroller = !fitsContent
        sv.autohidesScrollers  = true
        sv.borderType          = .noBorder
        sv.drawsBackground     = false
        if fitsContent {
            sv.verticalScrollElasticity = .none
        }

        // Apply initial contentsScale so the table renders at the right pixel
        // density if a non-default zoom is already active on first appearance.
        let initialCS = (NSScreen.main?.backingScaleFactor ?? 2.0) * scale
        sv.wantsLayer = true
        sv.layer?.contentsScale = initialCS
        tv.wantsLayer = true
        tv.layer?.contentsScale = initialCS

        sv.appearance = nsAppearance

        // Live-scroll notifications drive the grey tiles. `boundsDidChange` is
        // needed as well as the live-scroll pair: dragging the scroller knob and
        // scroll-wheel momentum both move the clip view without ever sending
        // `willStartLiveScroll`.
        sv.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observeScrolling(of: sv)

        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        // Keep the AppKit table in sync with the app's Light/Dark setting.
        sv.appearance = nsAppearance
        context.coordinator.update(parent: self)
    }

    /// In `fitsContent` mode the table asks for exactly the height its rows and
    /// header need, so the enclosing page can scroll past it. Measured off the
    /// live views rather than guessed — the header is whatever AppKit decided
    /// it should be for this style and text size.
    func sizeThatFits(_ proposal: ProposedViewSize,
                      nsView: NSScrollView,
                      context: Context) -> CGSize? {
        guard fitsContent else { return nil }
        let table  = nsView.documentView as? NSTableView
        // Floor of 28: on the first pass the header may not have been laid out
        // yet, and under-measuring here would clip the last row for good.
        let header = max(table?.headerView?.frame.height ?? 0, 28)
        let rows   = CGFloat(tracks.count) * (table?.rowHeight ?? effectiveMetrics.rowHeight)
        return CGSize(width:  proposal.width ?? 10,
                      height: header + rows + 6)   // 6: the .inset style's own bottom slack
    }

    /// Maps the SwiftUI colour scheme to an explicit AppKit appearance.
    private var nsAppearance: NSAppearance? {
        NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
    }

    // MARK: - Column Specs

    private struct ColSpec {
        let id: String; let title: String
        let minW: CGFloat; let width: CGFloat
        let sortKey: String?
        /// Fixed width, and no divider to drag. Only the number column: it is
        /// exactly as wide as a number, and there is nothing in it anyone could
        /// want more room for.
        var isFixed: Bool = false
    }

    /// The row number gets a column of its own rather than a slot inside the
    /// title cell.
    ///
    /// Same pixels either way, but only a column makes the *header* leave a gap
    /// above the numbers — inside the title cell they sat under "Title", which
    /// labelled them as part of the song's name and pushed the sortable header
    /// off the songs it sorts. The numbers aren't the title; they're the list's
    /// own counting, and they get their own unlabelled space in front of it.
    /// The iOS list has drawn it this way all along (see `TrackListHeader`).
    /// The numbers are right-aligned, so this column's width *is* the gap in
    /// front of them. Compact takes a point off the digits and shrinks
    /// everything around them; leaving the column at 50 left that gap behind at
    /// its full size, which reads as a stray indent rather than a tighter list.
    /// 42 is the same four-digit budget one size down — 30pt of usable width
    /// after the text cell's 6pt either side, against 28.9pt of monospaced
    /// digits at 12pt.
    private var indexColumnWidth: CGFloat { density == .compact ? 42 : 50 }

    /// Wide enough for the glyph plus the breathing room either side that stops
    /// it colliding with the date on its left and the duration on its right.
    private var rowActionColumnWidth: CGFloat { density == .compact ? 28 : 32 }

    /// Whether this column saves rather than favourites.
    ///
    /// A heart claims a song as a favourite, which is a thing you can only say
    /// about a song you have. On a page made of songs Discover found, the
    /// question in front of the user is "do I want this at all", and the answer
    /// is the plus / check that `SaveToLibraryButton` gives everywhere else in
    /// Discover — including on the ones already saved, where the filled check is
    /// the answer and a heart would be a different question.
    ///
    /// `onAddToLibrary` is exactly that distinction already: it is nil on every
    /// library table, because adding to the library is not a thing you can do to
    /// a song that's in it.
    var showsSaveControl: Bool { onAddToLibrary != nil }

    fileprivate func rowActionState(for track: Track) -> TrackRowActionCell.State {
        guard showsSaveControl else {
            return isFavourited(track.id) ? .favourited : .notFavourited
        }
        return isInLibrary(track.id) ? .saved : .notSaved
    }

    private var columnSpecs: [ColSpec] {
        var specs: [ColSpec] = []
        if showsIndex {
            // Wide enough for four digits at the roomy metrics' 13pt monospaced
            // font, plus the text cell's own 6pt either side. At 36 the usable
            // width was 24pt, which is three digits' worth on a good day — a
            // playlist past 99 songs drew every row as "2…".
            specs.append(.init(id: "index", title: "", minW: indexColumnWidth,
                               width: indexColumnWidth, sortKey: nil, isFixed: true))
        }
        specs += [
        .init(id: "title",       title: "Title",      minW: 160, width: 280, sortKey: "title"),
        .init(id: "artistName",  title: "Artist",     minW:  80, width: 160, sortKey: "artistName"),
        .init(id: "albumTitle",  title: "Album",      minW:  80, width: 160, sortKey: "albumTitle"),
        // The heart, or the save control on a page whose songs aren't in the
        // library yet — see `showsSaveControl`. Unlabelled and unsortable,
        // exactly as wide as the glyph, in the slot the iOS row keeps in front
        // of the duration (`TrackColumns.heart`).
        .init(id: "rowAction",   title: "",           minW: rowActionColumnWidth,
              width: rowActionColumnWidth, sortKey: nil, isFixed: true),
        .init(id: "duration",    title: "Duration",   minW:  50, width:  62, sortKey: "duration"),
        ]
        if showsDateAdded {
            specs.insert(.init(id: "dateAdded", title: "Date Added", minW: 70,
                               width: 100, sortKey: "dateImported"),
                         at: specs.count - 2)
        }
        return specs
    }
}

// MARK: - Coordinator

extension NativeTrackTable {

    // Note: not @MainActor at class level so ObjC/AppKit delegate calls route
    // correctly; AppKit guarantees all delegate/dataSource calls on main thread.
    final class Coordinator: NSObject {

        var parent: NativeTrackTable

        // Local sorted copy — the coordinator owns sort order.
        var tracks: [Track] = []

        weak var tableView: MelTableView?

        // Tracks what we last loaded so updateNSView skips no-op reloads.
        private var lastDisplayHash: Int        = 0
        private var lastScale:       CGFloat    = 1.0

        // Prevents a SwiftUI→AppKit→SwiftUI selection feedback loop.
        private var suppressSelectionSync = false

        // MARK: - Scroll state

        /// Fires `RowScrollState.end()` once the clip view has been still for a
        /// beat. There is no "momentum finished" notification, so quiet time is
        /// the only honest signal that the user has stopped.
        private var scrollIdleTimer: Timer?

        func observeScrolling(of sv: NSScrollView) {
            let nc = NotificationCenter.default
            nc.addObserver(self, selector: #selector(scrollMoved),
                           name: NSView.boundsDidChangeNotification, object: sv.contentView)
            nc.addObserver(self, selector: #selector(scrollMoved),
                           name: NSScrollView.willStartLiveScrollNotification, object: sv)
            nc.addObserver(self, selector: #selector(scrollMoved),
                           name: NSScrollView.didEndLiveScrollNotification, object: sv)
        }

        @objc private func scrollMoved() {
            RowScrollState.shared.begin()
            scrollIdleTimer?.invalidate()
            scrollIdleTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: false) { _ in
                MainActor.assumeIsolated { RowScrollState.shared.end() }
            }
        }

        deinit {
            scrollIdleTimer?.invalidate()
            NotificationCenter.default.removeObserver(self)
        }

        init(parent: NativeTrackTable) {
            self.parent = parent
            self.tracks = parent.tracks
        }

        // MARK: - Update (called from updateNSView on every SwiftUI re-render)

        func update(parent: NativeTrackTable) {
            let prev  = self.parent
            self.parent = parent
            guard let tv = tableView else { return }

            syncSortDescriptors(tv)

            // A density change moves more than the row height: cell constraints
            // and fonts are baked in when a cell is configured, so the rows have
            // to be rebuilt as well — the same reason a zoom change does.
            let metricsChanged = parent.effectiveMetrics != prev.effectiveMetrics
            if tv.rowHeight != parent.effectiveMetrics.rowHeight {
                tv.rowHeight = parent.effectiveMetrics.rowHeight
            }
            // Columns are built once, in `makeNSView`. The index one is the
            // only fixed-width column whose width depends on the density, so
            // it's the only one that has to be told.
            if metricsChanged,
               let idx = tv.tableColumns.first(where: { $0.identifier.rawValue == "index" }),
               idx.width != parent.indexColumnWidth {
                idx.minWidth = parent.indexColumnWidth
                idx.width    = parent.indexColumnWidth
            }
            if metricsChanged,
               let fav = tv.tableColumns.first(where: { $0.identifier.rawValue == "rowAction" }),
               fav.width != parent.rowActionColumnWidth {
                fav.minWidth = parent.rowActionColumnWidth
                fav.width    = parent.rowActionColumnWidth
            }

            // Detect UI zoom change — need to re-render cells at new pixel density.
            let scaleChanged = abs(parent.scale - lastScale) > 0.001
            if scaleChanged {
                lastScale = parent.scale
                let cs = (NSScreen.main?.backingScaleFactor ?? 2.0) * parent.scale
                if let sv = tv.enclosingScrollView {
                    applyContentsScale(cs, to: sv)
                }
                applyContentsScale(cs, to: tv)
            }

            // Re-apply sort to new data when the track set OR displayed content
            // changed. Ids alone don't detect enrichment edits (title/artist/
            // album change, same id), which is why this is a hash of what's
            // drawn rather than a list of ids.
            //
            // It used to be both — an `[UUID]` compared against the last one,
            // *and* this hash. The list was redundant: `displayHash` combines
            // every id in order, so nothing can change the ids without changing
            // the hash. All the array did was allocate one UUID per track on
            // every SwiftUI update pass, which on a large library is the single
            // biggest allocation in the update path.
            let newHash     = displayHash(of: parent.tracks)
            let needsReload = newHash != lastDisplayHash || scaleChanged || metricsChanged
            if needsReload {
                lastDisplayHash = newHash
                // Sorted upstream when the page owns the order — see `sort`.
                tracks = parent.sort == nil
                    ? sorted(parent.tracks, by: tv.sortDescriptors.first)
                    : parent.tracks
                tv.reloadData()
            } else if prev.currentTrackID != parent.currentTrackID
                    || prev.isPlaying      != parent.isPlaying {
                // Only the playing state changed — refresh the visible rows
                // cheaply.
                //
                // Every column, not column 0: the playing row is drawn by two of
                // them — the orange number in "index" and the now-playing bars
                // in "title" — and which one is at index 0 depends on whether
                // this table shows numbers at all. Reloading a hardcoded 0 left
                // the bars missing until something else forced a full reload,
                // which is why they only ever appeared after leaving the page
                // and coming back.
                let visible = tv.rows(in: tv.visibleRect)
                if visible.location != NSNotFound && visible.length > 0,
                   tv.numberOfColumns > 0 {
                    tv.reloadData(
                        forRowIndexes: IndexSet(integersIn: visible.location ..< NSMaxRange(visible)),
                        columnIndexes: IndexSet(integersIn: 0 ..< tv.numberOfColumns)
                    )
                }
            } else {
                // Favouriting or saving doesn't change a single drawn character, so no
                // hash notices it — but the heart has to fill the moment the
                // library says so, whether that came from this column or from
                // the context menu. Only the rows on screen, and only the one
                // column, so this stays cheap enough to do on every pass.
                refreshRowActions(tv)
            }

            // Sync selection SwiftUI → AppKit (only for external changes).
            let desired = IndexSet(
                tracks.indices.filter { parent.selectedIDs.contains(tracks[$0].id) }
            )
            if tv.selectedRowIndexes != desired {
                suppressSelectionSync = true
                tv.selectRowIndexes(desired, byExtendingSelection: false)
                suppressSelectionSync = false
            }
        }

        private func displayHash(of source: [Track]) -> Int {
            var h = Hasher()
            h.combine(source.count)
            for t in source {
                h.combine(t.id)
                h.combine(t.title)
                h.combine(t.artistName)
                h.combine(t.albumTitle)
                h.combine(t.artworkData != nil)
                
                h.combine(parent.resolvingIDs.contains(t.id))

                let status = parent.availability(t.id)
                switch status {
                case .streamOnly:  h.combine(0)
                case .downloading: h.combine(1)
                case .offline:     h.combine(2)
                case .local:       h.combine(3)
                case .failed:      h.combine(4)
                }
            }
            return h.finalize()
        }

        // MARK: - Crisp rendering helper
        //
        // Sets wantsLayer + contentsScale on a view and every descendant so that
        // when scaleEffect upscales the SwiftUI container, AppKit views have already
        // rendered at the correct pixel density and nothing looks blurry.
        //
        // contentsScale = screenBackingScale × uiZoom
        //   e.g. Retina (2×) at 130 % zoom → 2 × 1.3 = 2.6 px/pt
        //
        func applyContentsScale(_ cs: CGFloat, to view: NSView) {
            view.wantsLayer = true
            view.layer?.contentsScale = cs
            for sub in view.subviews { applyContentsScale(cs, to: sub) }
        }

        // MARK: - Sort helpers

        /// Draws the page's sort in the column headers.
        ///
        /// Assigning `sortDescriptors` calls the delegate straight back, which
        /// would bounce the same value into the binding and, on a page that
        /// rebuilds on it, run round again — hence the flag.
        private func syncSortDescriptors(_ tv: NSTableView) {
            guard let sort = parent.sort?.wrappedValue else { return }
            let wanted: [NSSortDescriptor] = sort.field.sortDescriptorKey.map {
                [NSSortDescriptor(key: $0, ascending: sort.ascending)]
            } ?? []
            let current = tv.sortDescriptors
            guard current.first?.key != wanted.first?.key
                    || current.first?.ascending != wanted.first?.ascending else { return }
            suppressSortWriteBack = true
            tv.sortDescriptors = wanted
            suppressSortWriteBack = false
        }

        /// Set while `syncSortDescriptors` is assigning, so the delegate call it
        /// provokes isn't mistaken for the user clicking a header.
        private var suppressSortWriteBack = false

        /// The sort a header click means, for a table whose page owns the order.
        /// Nil when there is nothing to report: no page sort, or the descriptors
        /// were just written by `syncSortDescriptors` in the first place.
        func sortPicked(from descriptors: [NSSortDescriptor]) -> TrackSort? {
            guard !suppressSortWriteBack, parent.sort != nil else { return nil }
            guard let d = descriptors.first,
                  let key = d.key,
                  let field = TrackSortField(sortDescriptorKey: key)
            else { return TrackSort() }        // no column: back to the list's own order
            return TrackSort(field: field, ascending: d.ascending)
        }

        private func sorted(_ source: [Track], by d: NSSortDescriptor?) -> [Track] {
            guard let d else { return source }
            return source.sorted { a, b in
                switch d.key {
                case "title":        return d.ascending ? a.title        < b.title        : a.title        > b.title
                case "artistName":   return d.ascending ? a.artistName   < b.artistName   : a.artistName   > b.artistName
                case "albumTitle":   return d.ascending ? a.albumTitle   < b.albumTitle   : a.albumTitle   > b.albumTitle
                case "dateImported": return d.ascending ? a.dateImported < b.dateImported : a.dateImported > b.dateImported
                case "duration":     return d.ascending ? a.duration     < b.duration     : a.duration     > b.duration
                default:             return false
                }
            }
        }

        /// The brand orange, for the row that's playing.
        static let nowPlayingColor = NSColor(red: 1.0, green: 107/255, blue: 0, alpha: 1)

        // Shared short-date formatter — "Jun 10, 2026"
        // MARK: - Playback helpers

        func playFirstSelected() {
            guard let id = parent.selectedIDs.first,
                  let track = tracks.first(where: { $0.id == id }) else { return }
            parent.onPlay(track, tracks)
        }

        func play(row: Int) {
            guard row >= 0, row < tracks.count else { return }
            parent.onPlay(tracks[row], tracks)
        }

        // MARK: - Hover
        //
        // Only the two affected rows are touched, so pointer movement never
        // triggers a reload — at 10 000 rows that matters.

        /// Re-asks `isFavourited` for the visible rows and updates their hearts
        /// in place — no reload, so scrolling and selection are untouched.
        private func refreshRowActions(_ tv: NSTableView) {
            let column = rowActionColumn
            guard column >= 0 else { return }
            let visible = tv.rows(in: tv.visibleRect)
            guard visible.location != NSNotFound, visible.length > 0 else { return }
            for row in visible.location ..< NSMaxRange(visible) where row < tracks.count {
                (tv.view(atColumn: column, row: row, makeIfNecessary: false)
                    as? TrackRowActionCell)?
                    .configure(parent.rowActionState(for: tracks[row]),
                               size: parent.effectiveMetrics.secondarySize + 2)
            }
        }

        /// The heart column's index, or -1 while the table has none.
        private var rowActionColumn: Int {
            tableView?.column(withIdentifier: .init("rowAction")) ?? -1
        }

        func hoverChanged(from old: Int, to new: Int) {
            guard let tv = tableView else { return }
            for row in [old, new] where row >= 0 && row < tracks.count {
                let hovered = (row == new)
                (tv.rowView(atRow: row, makeIfNecessary: false) as? MacListRowView)?
                    .setHovered(hovered)
                (tv.view(atColumn: 0, row: row, makeIfNecessary: false) as? TrackTitleCell)?
                    .setHovered(hovered)
                if rowActionColumn >= 0 {
                    (tv.view(atColumn: rowActionColumn, row: row, makeIfNecessary: false)
                        as? TrackRowActionCell)?.setHovered(hovered)
                }
            }
        }

        // MARK: - Context Menu

        func buildContextMenu(row: Int) -> NSMenu? {
            guard row >= 0, row < tracks.count else { return nil }
            let track = tracks[row]

            // Right-clicking an unselected row selects it.
            if let tv = tableView, !tv.selectedRowIndexes.contains(row) {
                tv.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }

            let menu    = NSMenu()
            // Every item below acts on the whole selection when the clicked row
            // is part of it — the Finder rule — and on that row alone otherwise.
            let targets = self.targets(for: track)
            let many    = targets.count > 1
            let favoured = targets.allSatisfy { parent.isFavourited($0.id) }

            // Playback
            menu.addItem(menuItem(many ? "Play \(targets.count) Songs" : "Play Now",
                                  action: #selector(menuPlayNow(_:)),  tracks: targets))
            menu.addItem(menuItem(many ? "Play \(targets.count) Songs Next" : "Play Next",
                                  action: #selector(menuPlayNext(_:)), tracks: targets))
            menu.addItem(menuItem(many ? "Add \(targets.count) Songs to Queue" : "Add to Queue",
                                  action: #selector(menuAddQueue(_:)), tracks: targets))
            menu.addItem(.separator())

            // Favourite toggle — a mixed selection favourites rather than
            // unfavourites, so one click can't quietly undo half of it.
            let favVerb  = favoured ? "Remove" : "Add"
            let favWhere = favoured ? "from Liked Songs" : "to Liked Songs"
            let favTitle = many ? "\(favVerb) \(targets.count) Songs \(favWhere)"
                                : "\(favVerb) \(favWhere)"
            let favIcon  = NSImage(systemSymbolName: favoured ? "heart.fill" : "heart", accessibilityDescription: nil)
            let favItem  = menuItem(favTitle, action: #selector(menuToggleFavourite(_:)), tracks: targets)
            favItem.image = favIcon
            menu.addItem(favItem)

            // "Add to Library", for a page of songs that aren't in it. Directly
            // under the favourite because the two are the same kind of wish —
            // keep this — and above the playlist submenu, which is where the
            // wish gets more specific.
            if parent.onAddToLibrary != nil {
                let unsaved = targets.filter { !parent.isInLibrary($0.id) }
                if !unsaved.isEmpty {
                    let title = unsaved.count > 1 ? "Add \(unsaved.count) Songs to Library"
                                                  : "Add to Library"
                    let item = menuItem(title, action: #selector(menuAddToLibrary(_:)), tracks: unsaved)
                    item.image = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: nil)
                    menu.addItem(item)
                }
            }

            // A collaborator's song with no audio behind it: nothing here can
            // download it or copy it, but Discover can often find the same
            // record online.
            if !many, track.isUnresolvableShare, parent.onFindInDiscover != nil {
                let item = menuItem("Find in Discover", action: #selector(menuFindInDiscover(_:)), track: track)
                item.image = NSImage(systemSymbolName: "sparkle.magnifyingglass", accessibilityDescription: nil)
                menu.addItem(item)
            }

            // Add to Playlist submenu. A mix or someone else's playlist is left
            // out: it would take the songs, fail the guard in LibraryService and
            // look like nothing happened.
            let targetPlaylists = parent.playlists.filter {
                !$0.isAllSongs && !$0.isDeleted && $0.isEditable
                    && $0.id != parent.excludedPlaylistID
            }
            if !targetPlaylists.isEmpty || parent.onChoosePlaylist != nil {
                let sub = NSMenu()
                for pl in targetPlaylists {
                    let item = NSMenuItem(title: pl.name, action: #selector(menuAddToPlaylist(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = AddToPlaylistPayload(tracks: targets, playlistID: pl.id)
                    sub.addItem(item)
                }
                // The sheet, which is the only way to reach a playlist that
                // doesn't exist yet.
                if parent.onChoosePlaylist != nil {
                    if !targetPlaylists.isEmpty { sub.addItem(.separator()) }
                    sub.addItem(menuItem("Choose Playlist\u{2026}",
                                         action: #selector(menuChoosePlaylist(_:)),
                                         tracks: targets))
                }
                let subItem = NSMenuItem(title: many ? "Add \(targets.count) Songs to Playlist" : "Add to Playlist",
                                         action: nil, keyEquivalent: "")
                subItem.submenu = sub
                subItem.image = NSImage(systemSymbolName: "text.badge.plus", accessibilityDescription: nil)
                menu.addItem(subItem)
            }

            // Navigation — how people actually move around a music library:
            // from a song to the artist or album it belongs to. Only ever about
            // one song, so a multi-row selection doesn't offer it.
            let credits = many ? [] : ImportService.creditedArtists(from: track.artistName)
            if !many, parent.onGoToArtist != nil || parent.onGoToAlbum != nil {
                menu.addItem(.separator())
            }
            if parent.onGoToArtist != nil, !credits.isEmpty {
                let icon = NSImage(systemSymbolName: "music.mic", accessibilityDescription: nil)
                if credits.count == 1 {
                    let item = NSMenuItem(title: "Go to Artist",
                                          action: #selector(menuGoToArtist(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = credits[0]
                    item.image = icon
                    menu.addItem(item)
                } else {
                    // A featured track has more than one artist to go to, so the
                    // item becomes a submenu instead of guessing at the primary.
                    let sub = NSMenu()
                    for name in credits {
                        let item = NSMenuItem(title: name,
                                              action: #selector(menuGoToArtist(_:)), keyEquivalent: "")
                        item.target = self
                        item.representedObject = name
                        sub.addItem(item)
                    }
                    let subItem = NSMenuItem(title: "Go to Artist", action: nil, keyEquivalent: "")
                    subItem.submenu = sub
                    subItem.image = icon
                    menu.addItem(subItem)
                }
            }
            if !many, parent.onGoToAlbum != nil, !track.albumTitle.isEmpty {
                let item = menuItem("Go to Album", action: #selector(menuGoToAlbum(_:)), track: track)
                item.image = NSImage(systemSymbolName: "square.stack", accessibilityDescription: nil)
                menu.addItem(item)
            }

            if !many {
                menu.addItem(.separator())
                let link = MixtapeLink.track(track)
                let copy = NSMenuItem(title: "Copy Song Link", action: #selector(menuCopyLink(_:)), keyEquivalent: "")
                copy.target = self
                copy.representedObject = link
                copy.image = NSImage(systemSymbolName: "link", accessibilityDescription: nil)
                menu.addItem(copy)
                // The system's own Share item, services submenu and all.
                menu.addItem(NSSharingServicePicker(items: [link]).standardShareMenuItem)
            }

            menu.addItem(.separator())
            if !many {
                let item = menuItem("Get Info", action: #selector(menuGetInfo(_:)), track: track)
                item.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
                menu.addItem(item)
            }

            // Move to Artist Folder — shown only when a handler is wired up, and
            // only for one song: it renames that song's folder on disk.
            if !many, parent.onMoveToArtistFolder != nil {
                let moveItem = menuItem(
                    "Move to Artist Folder\u{2026}",
                    action: #selector(menuMoveToArtistFolder(_:)),
                    track: track
                )
                moveItem.image = NSImage(systemSymbolName: "person.badge.plus", accessibilityDescription: nil)
                menu.addItem(moveItem)
            }

            if parent.onSaveToDisk != nil {
                let saveItem = menuItem(many ? "Save \(targets.count) File Copies" : "Save a File Copy",
                                        action: #selector(menuSaveToDisk(_:)), tracks: targets)
                saveItem.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: nil)
                menu.addItem(saveItem)
            }

            menu.addItem(.separator())

            if many {
                // A selection is usually a mix of states, so it gets counts of
                // what can still happen rather than one row's five-way status.
                let removable = targets.filter { parent.availability($0.id).isRemovableDownload }
                let fetchable = targets.filter {
                    let status = parent.availability($0.id)
                    guard !status.isAvailableOffline, !status.isDownloading else { return false }
                    return parent.canDownload($0)
                }
                if parent.onDownload != nil, !fetchable.isEmpty {
                    let item = menuItem("Download \(fetchable.count) Songs",
                                        action: #selector(menuDownload(_:)), tracks: fetchable)
                    item.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
                    menu.addItem(item)
                }
                if parent.onRemoveDownload != nil, !removable.isEmpty {
                    let item = menuItem("Remove \(removable.count) Downloads",
                                        action: #selector(menuRemoveDownload(_:)), tracks: removable)
                    item.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
                    menu.addItem(item)
                }
                if !fetchable.isEmpty || !removable.isEmpty { menu.addItem(.separator()) }
            } else {

            let status = parent.availability(track.id)
            if status.isRemovableDownload {
                let removeDownloadItem = menuItem("Remove Download", action: #selector(menuRemoveDownload(_:)), tracks: targets)
                removeDownloadItem.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
                menu.addItem(removeDownloadItem)
                menu.addItem(.separator())
            } else if parent.onDownload != nil, status.isDownloading || parent.canDownload(track) {
                // The Mac table had no way to download a single song at all —
                // the only route was making a playlist offline. A track that
                // can't be downloaded gets no row here; only a download already
                // running keeps one, and that one reports progress.
                let title: String
                switch status {
                case .downloading: title = "Downloading\u{2026}"
                case .failed:      title = "Retry Download"
                default:           title = "Download"
                }
                let item = menuItem(title, action: #selector(menuDownload(_:)), tracks: targets)
                item.image = NSImage(
                    systemSymbolName: status == .failed ? "arrow.clockwise.circle" : "arrow.down.circle",
                    accessibilityDescription: nil
                )
                if status.isDownloading { item.action = nil }
                menu.addItem(item)
                menu.addItem(.separator())
            }

            }

            // Leaving *this* playlist — never a delete, never a confirmation:
            // the song stays in the library and the row comes back with one
            // drag. Offered above the library delete because on a playlist page
            // it is what "remove" nearly always means.
            if parent.onRemoveFromPlaylist != nil {
                let title = parent.removeFromPlaylistTitle(targets.count)
                let item  = menuItem(title, action: #selector(menuRemoveFromPlaylist(_:)), tracks: targets)
                item.attributedTitle = NSAttributedString(
                    string: title,
                    attributes: [.foregroundColor: NSColor.systemRed]
                )
                menu.addItem(item)
            }

            // Remove from library (destructive)
            if parent.showsRemoveFromLibrary {
                let removeTitle = many ? "Remove \(targets.count) Songs from Library" : "Remove from Library"
                let removeItem = menuItem(removeTitle, action: #selector(menuRemove(_:)), tracks: targets)
                removeItem.attributedTitle = NSAttributedString(
                    string: removeTitle,
                    attributes: [.foregroundColor: NSColor.systemRed]
                )
                menu.addItem(removeItem)
            }
            return menu
        }

        /// The songs a menu item should act on: the selection when the clicked
        /// row belongs to it, that row alone otherwise. Read from the table
        /// rather than `parent.selectedIDs` so it is right even in the same
        /// run loop pass that a right-click changed the selection — and in row
        /// order, so "Play 5 Songs" plays them top to bottom.
        private func targets(for track: Track) -> [Track] {
            guard let tv = tableView else { return [track] }
            let selected = tv.selectedRowIndexes.compactMap {
                $0 < tracks.count ? tracks[$0] : nil
            }
            guard selected.count > 1, selected.contains(where: { $0.id == track.id }) else {
                return [track]
            }
            return selected
        }

        private func menuItem(_ title: String, action: Selector, track: Track) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = track
            return item
        }

        private func menuItem(_ title: String, action: Selector, tracks: [Track]) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = tracks
            return item
        }

        // MARK: - ObjC Menu Actions

        @objc func rowDoubleClicked(_ sender: Any) {
            guard let tv = tableView else { return }
            let row = tv.clickedRow
            guard row >= 0, row < tracks.count else { return }
            parent.onPlay(tracks[row], tracks)
        }

        @objc func menuPlayNow(_ item: NSMenuItem) {
            guard let targets = item.representedObject as? [Track], let first = targets.first else { return }
            // One song plays in the context of the whole table, as it always
            // has; a selection *is* the context — that is what was picked.
            parent.onPlay(first, targets.count > 1 ? targets : tracks)
        }

        @objc func menuPlayNext(_ item: NSMenuItem) {
            guard let targets = item.representedObject as? [Track] else { return }
            // Reversed: each insert goes directly after the current song, so
            // inserting bottom-up leaves the selection in its own order.
            for track in targets.reversed() { parent.onPlayNext(track) }
        }

        @objc func menuAddQueue(_ item: NSMenuItem) {
            guard let targets = item.representedObject as? [Track] else { return }
            for track in targets { parent.onAddToQueue(track) }
        }

        @objc func menuGetInfo(_ item: NSMenuItem) {
            guard let t = item.representedObject as? Track else { return }
            parent.onGetInfo(t)
        }

        @objc func menuToggleFavourite(_ item: NSMenuItem) {
            guard let targets = item.representedObject as? [Track] else { return }
            // The menu decided the verb from "are they *all* favourited"; only
            // the songs that disagree with the destination get flipped, so a
            // mixed selection ends up all favourited rather than inverted.
            let favouriting = !targets.allSatisfy { parent.isFavourited($0.id) }
            for track in targets where parent.isFavourited(track.id) != favouriting {
                parent.onToggleFavourite(track)
            }
        }

        @objc func menuAddToLibrary(_ item: NSMenuItem) {
            guard let tracks = item.representedObject as? [Track] else { return }
            parent.onAddToLibrary?(tracks)
        }

        @objc func menuAddToPlaylist(_ item: NSMenuItem) {
            guard let payload = item.representedObject as? AddToPlaylistPayload else { return }
            parent.onAddToPlaylist(payload.tracks, payload.playlistID)
        }

        @objc func menuRemoveFromPlaylist(_ item: NSMenuItem) {
            guard let targets = item.representedObject as? [Track] else { return }
            parent.onRemoveFromPlaylist?(targets)
        }

        @objc func menuFindInDiscover(_ item: NSMenuItem) {
            guard let t = item.representedObject as? Track else { return }
            parent.onFindInDiscover?(t)
        }

        @objc func menuChoosePlaylist(_ item: NSMenuItem) {
            guard let targets = item.representedObject as? [Track] else { return }
            parent.onChoosePlaylist?(targets)
        }

        @objc func menuGoToArtist(_ item: NSMenuItem) {
            guard let name = item.representedObject as? String else { return }
            parent.onGoToArtist?(name)
        }

        @objc func menuCopyLink(_ item: NSMenuItem) {
            guard let url = item.representedObject as? URL else { return }
            copyToClipboard(url.absoluteString)
            parent.onLinkCopied?()
        }

        @objc func menuGoToAlbum(_ item: NSMenuItem) {
            guard let t = item.representedObject as? Track else { return }
            parent.onGoToAlbum?(t)
        }

        @objc func menuMoveToArtistFolder(_ item: NSMenuItem) {
            guard let t = item.representedObject as? Track else { return }
            parent.onMoveToArtistFolder?(t)
        }

        @objc func menuRemove(_ item: NSMenuItem) {
            guard let targets = item.representedObject as? [Track], !targets.isEmpty else { return }
            // An AppKit menu can't raise a SwiftUI dialog, so this stays an
            // NSAlert — but the words come from the same place as ⌘⌫ and the
            // playlist row's menu. It used to promise "deleted from this
            // device", which was never true: the delete syncs.
            let count             = targets.count
            let alert             = NSAlert()
            alert.messageText     = TrackDeletionPrompt.title(count: count,
                                                              name: count == 1 ? targets[0].title : nil)
            alert.informativeText = TrackDeletionPrompt.message(count: count)
            alert.alertStyle      = .warning
            alert.addButton(withTitle: TrackDeletionPrompt.confirmLabel(count: count))
            alert.addButton(withTitle: "Cancel")
            alert.buttons.first?.hasDestructiveAction = true
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            parent.onRemove(targets)
        }

        @objc func menuDownload(_ item: NSMenuItem) {
            guard let targets = item.representedObject as? [Track] else { return }
            for track in targets { parent.onDownload?(track) }
        }

        @objc func menuRemoveDownload(_ item: NSMenuItem) {
            guard let targets = item.representedObject as? [Track] else { return }
            for track in targets { parent.onRemoveDownload?(track.id) }
        }

        @objc func menuSaveToDisk(_ item: NSMenuItem) {
            guard let targets = item.representedObject as? [Track] else { return }
            parent.onSaveToDisk?(targets)
        }
    }
}

// MARK: - NSTableViewDataSource

extension NativeTrackTable.Coordinator: NSTableViewDataSource {

    func numberOfRows(in tableView: NSTableView) -> Int { tracks.count }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange old: [NSSortDescriptor]) {
        // A page that owns the order gets told; the sorted rows come back down
        // through `update(parent:)` a frame later.
        if let binding = parent.sort {
            if let picked = sortPicked(from: tableView.sortDescriptors) {
                binding.wrappedValue = picked
            }
            return
        }
        tracks = sorted(tracks, by: tableView.sortDescriptors.first)
        tableView.reloadData()
    }

    // MARK: - Dragging rows out (→ sidebar playlists)

    /// Each dragged row writes a prefixed track id. The prefix is what lets the
    /// sidebar tell an "add these songs" drop apart from a playlist reorder,
    /// since both payloads are otherwise just UUID strings.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row >= 0, row < tracks.count else { return nil }
        let item = NSPasteboardItem()
        item.setString(MacAppState.trackDragPayload(tracks[row].id), forType: .string)
        return item
    }

    func tableView(_ tableView: NSTableView,
                   draggingSession session: NSDraggingSession,
                   willBeginAt screenPoint: NSPoint,
                   forRowIndexes rowIndexes: IndexSet) {
        parent.onDragTracksChanged?(true)
    }

    func tableView(_ tableView: NSTableView,
                   draggingSession session: NSDraggingSession,
                   endedAt screenPoint: NSPoint,
                   operation: NSDragOperation) {
        parent.onDragTracksChanged?(false)
    }
}

// MARK: - NSTableViewDelegate

extension NativeTrackTable.Coordinator: NSTableViewDelegate {

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard row < tracks.count else { return nil }
        let track  = tracks[row]
        let colID  = tableColumn?.identifier.rawValue ?? ""
        let isCurrent = track.id == parent.currentTrackID
        let cs = (NSScreen.main?.backingScaleFactor ?? 2.0) * parent.scale

        let cell: NSView?
        switch colID {

        case "index":
            // Monospaced so a column of them lines up, and orange on the row
            // that's playing — the same two rules the number followed when it
            // lived inside the title cell.
            let size = parent.effectiveMetrics.secondarySize - 1
            let c = textCell(tableView, id: colID, value: "\(row + 1)",
                             color: isCurrent ? Self.nowPlayingColor : .tertiaryLabelColor,
                             size: size)
            c.textField?.font      = .monospacedDigitSystemFont(ofSize: size, weight: .regular)
            c.textField?.alignment = .right
            cell = c

        case "title":
            let c = tableView.makeView(withIdentifier: .init("title"), owner: nil)
                    as? TrackTitleCell ?? TrackTitleCell()
            c.apply(metrics: parent.effectiveMetrics)
            c.configure(track: track,
                        isCurrent: isCurrent,
                        isPlaying: parent.isPlaying,
                        availability: parent.availability(track.id),
                        isResolving: parent.resolvingIDs.contains(track.id))
            // Clicking the artwork plays without waiting for a double click —
            // the one-click affordance the badge is advertising.
            c.onArtworkClick = { [weak self] in self?.play(row: row) }
            c.setHovered((tableView as? MelTableView)?.hoveredRow == row)
            cell = c

        case "artistName":
            // One click target per credited name: a song by "c4rl, Yungpalo" is
            // two artists, and clicking either has to land on that artist rather
            // than searching for the whole credit string.
            let names = ImportService.creditedArtists(from: track.artistName)
            let c = linkCell(tableView, id: colID)
            c.configure(names: names.isEmpty ? [track.artistName] : names,
                        font:  .systemFont(ofSize: parent.effectiveMetrics.secondarySize),
                        color: .secondaryLabelColor,
                        onSelect: parent.onOpenArtistLink.map { open in
                            { index in
                                guard index < names.count else { return }
                                open(names[index])
                            }
                        })
            cell = c

        case "albumTitle":
            let c = linkCell(tableView, id: colID)
            let canOpen = !track.albumTitle.isEmpty
            c.configure(names: [track.albumTitle],
                        font:  .systemFont(ofSize: parent.effectiveMetrics.secondarySize),
                        color: .secondaryLabelColor,
                        onSelect: (canOpen ? parent.onOpenAlbumLink : nil).map { open in
                            { _ in open(track) }
                        })
            cell = c

        case "dateAdded":
            // Worded, not dated — see `AddedDateText`. The exact stamp the
            // phrase stands for goes on the tooltip, which is the only place
            // the precise date was ever actually wanted.
            let dateCell = textCell(tableView, id: colID,
                                    value: AddedDateText.relative(track.dateImported),
                                    color: .secondaryLabelColor,
                                    size: parent.effectiveMetrics.secondarySize)
            dateCell.toolTip = AddedDateText.exact(track.dateImported)
            cell = dateCell

        case "rowAction":
            let c = tableView.makeView(withIdentifier: .init("rowAction"), owner: nil)
                    as? TrackRowActionCell ?? TrackRowActionCell()
            c.configure(parent.rowActionState(for: track),
                        size: parent.effectiveMetrics.secondarySize + 2)
            c.onToggle = { [weak self] in
                guard let self, row < self.tracks.count else { return }
                let track = self.tracks[row]
                if let add = self.parent.onAddToLibrary {
                    // The check is the answer, not a second button: unsaving can
                    // take a downloaded file with it, and it lives in the menu.
                    guard !self.parent.isInLibrary(track.id) else { return }
                    add([track])
                } else {
                    self.parent.onToggleFavourite(track)
                }
            }
            c.setHovered((tableView as? MelTableView)?.hoveredRow == row)
            cell = c

        case "duration":
            let c = textCell(tableView, id: colID, value: track.formattedDuration,
                             color: .tertiaryLabelColor, size: parent.effectiveMetrics.durationSize)
            c.textField?.font      = .monospacedDigitSystemFont(ofSize: parent.effectiveMetrics.durationSize,
                                                                weight: .regular)
            c.textField?.alignment = .right
            cell = c

        default:
            cell = nil
        }

        if let cell { applyContentsScale(cs, to: cell) }
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = MacListRowView()
        view.setHovered((tableView as? MelTableView)?.hoveredRow == row)
        let cs = (NSScreen.main?.backingScaleFactor ?? 2.0) * parent.scale
        applyContentsScale(cs, to: view)
        return view
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelectionSync, let tv = tableView else { return }
        let ids = Set(tv.selectedRowIndexes.compactMap {
            $0 < tracks.count ? tracks[$0].id : nil
        })
        parent.selectedIDs = ids
    }

    // MARK: - Cell factory helpers

    private func textCell(_ tv: NSTableView, id: String,
                          value: String, color: NSColor, size: CGFloat) -> NSTableCellView {
        let cellID = NSUserInterfaceItemIdentifier(id)
        let cell   = tv.makeView(withIdentifier: cellID, owner: nil) as? NSTableCellView
                  ?? makeTextCell(id: cellID)

        cell.textField?.stringValue = value
        cell.textField?.textColor   = color
        cell.textField?.font        = .systemFont(ofSize: size)
        return cell
    }

    private func linkCell(_ tv: NSTableView, id: String) -> TrackLinkCell {
        let cellID = NSUserInterfaceItemIdentifier(id)
        return tv.makeView(withIdentifier: cellID, owner: nil) as? TrackLinkCell
            ?? TrackLinkCell(id: cellID)
    }

    private func makeTextCell(id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id

        let tf = NSTextField()
        tf.isEditable          = false
        tf.isBordered          = false
        tf.drawsBackground     = false
        tf.lineBreakMode       = .byTruncatingTail
        tf.maximumNumberOfLines = 1
        tf.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(tf)
        cell.textField = tf

        NSLayoutConstraint.activate([
            tf.leadingAnchor .constraint(equalTo: cell.leadingAnchor,  constant: 6),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            tf.centerYAnchor .constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

// MARK: - TrackTitleCell  (artwork thumbnail + title + now-playing indicator)

/// Whether a track table is being scrolled right now.
///
/// A cached cover is otherwise painted synchronously, which is why scrolling
/// back up over rows you have already seen filled every thumbnail instantly —
/// the settle delay never applied, because nothing was being loaded. Rows check
/// this before taking the cache path, so the grey tile means the same thing in
/// both directions: "you are moving, this is not for reading yet".
///
/// One flag for the whole app rather than one per table: only one table can be
/// under the pointer at a time, and a cell has no back-reference to its scroll
/// view to consult a per-table one.
@MainActor
final class RowScrollState {
    static let shared = RowScrollState()
    private(set) var isScrolling = false

    /// Cells that want telling when the scroll stops.
    private var observers: [ObjectIdentifier: () -> Void] = [:]

    func begin() { isScrolling = true }

    func end() {
        guard isScrolling else { return }
        isScrolling = false
        // Everything on screen repaints from cache, so this is near-free.
        for notify in observers.values { notify() }
    }

    func observe(_ owner: AnyObject, _ block: @escaping () -> Void) {
        observers[ObjectIdentifier(owner)] = block
    }

    func stopObserving(_ owner: AnyObject) {
        observers.removeValue(forKey: ObjectIdentifier(owner))
    }
}

/// SF Symbols reused by every row.
///
/// `NSImage(systemSymbolName:)` is a lookup and an allocation, and the cell
/// calls it on every recycle — which during a scroll is every row that crosses
/// the viewport. The glyphs are immutable and tiny in number, so they are made
/// once. Tinting stays per-view (`contentTintColor`), so sharing is safe.
@MainActor
private enum RowSymbol {
    private static var cache: [String: NSImage] = [:]

    static func image(_ name: String, description: String? = nil) -> NSImage? {
        if let hit = cache[name] { return hit }
        guard let made = NSImage(systemSymbolName: name, accessibilityDescription: description) else { return nil }
        cache[name] = made
        return made
    }
}

private final class TrackTitleCell: NSTableCellView {

    private let artworkView  = NSImageView()
    private let downloadView = NSImageView()
    private let titleLabel   = NSTextField()
    private let titleStack   = NSStackView()
    private let waveView     = NSImageView()
    private let playBadge    = NSView()
    private let playIcon     = NSImageView()
    private let loadingBadge = NSView()
    private let spinner      = NSProgressIndicator()

    /// Invoked when the user clicks the artwork (the hover play affordance).
    var onArtworkClick: (() -> Void)?

    // Held so the row's proportions can be changed without rebuilding the cell.
    private var artworkLeading: NSLayoutConstraint!
    private var artworkWidth:   NSLayoutConstraint!
    private var artworkHeight:  NSLayoutConstraint!
    private var titleLeading:   NSLayoutConstraint!
    private var metrics: NativeTrackTable.RowMetrics = .compact
    /// Kept so hovering a row that's still fetching doesn't swap the spinner
    /// out for a play triangle — the click already landed.
    private var isResolving = false

    /// The in-flight cover load for whatever track this cell currently shows.
    ///
    /// One per cell, not one per row: `NSTableView` recycles cells, so a row
    /// leaving the top of the viewport *is* the row arriving at the bottom
    /// being configured. Cancelling here is what makes a scrollbar drag free —
    /// the rows flicked past never get as far as a decode.
    private var artworkTask: Task<Void, Never>?
    /// How long a row must be still before its cover is worth fetching.
    private static let settleDelay: Duration = .milliseconds(280)
    /// What this cell is currently showing, so a scroll-end repaint knows what
    /// to ask for without the table having to reconfigure every visible row.
    /// The whole track, not just its id: a row from a mix carries its cover
    /// inline and there is nothing in the store to look it up from.
    private var currentTrack: Track?
    /// Guards against a load that finishes after its cell has been reused.
    /// `Task.isCancelled` alone is not enough: the cancel and the hand-off can
    /// race, and the loser would paint the wrong cover onto the wrong row.
    private var artworkToken = 0

    override init(frame: NSRect) { super.init(frame: frame); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    deinit { MainActor.assumeIsolated { RowScrollState.shared.stopObserving(self) } }

    private func setup() {
        identifier = .init("title")

        // Artwork
        artworkView.imageScaling = .scaleProportionallyUpOrDown
        artworkView.wantsLayer   = true
        artworkView.layer?.cornerRadius  = 3
        artworkView.layer?.masksToBounds = true

        // Download view
        downloadView.imageScaling = .scaleProportionallyUpOrDown
        downloadView.wantsLayer   = true

        // Title label
        titleLabel.isEditable       = false
        titleLabel.isBordered       = false
        titleLabel.drawsBackground  = false
        titleLabel.lineBreakMode    = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        textField = titleLabel

        // Title Stack
        titleStack.orientation = .horizontal
        titleStack.alignment = .centerY
        titleStack.spacing = 6
        titleStack.addArrangedSubview(downloadView)
        titleStack.addArrangedSubview(titleLabel)

        // Waveform "now playing" dot
        waveView.image              = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)
        waveView.contentTintColor   = NSColor(red: 1.0, green: 107/255, blue: 0, alpha: 1)
        waveView.isHidden           = true

        // Play affordance — a scrim over the artwork with a centred triangle,
        // revealed on hover so the row advertises its one-click action.
        playBadge.wantsLayer            = true
        playBadge.layer?.backgroundColor = NSColor(white: 0, alpha: 0.55).cgColor
        playBadge.layer?.cornerRadius    = 3
        playBadge.isHidden               = true

        playIcon.image            = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play")
        playIcon.contentTintColor = .white
        playIcon.imageScaling     = .scaleProportionallyUpOrDown

        // The same scrim again, for a song that has to be found online before
        // it can play. Over the cover rather than beside the title because
        // that's where the click landed, and it's what every other list in the
        // app already does (see `MixSongRow`, `TrackRowView`).
        loadingBadge.wantsLayer             = true
        loadingBadge.layer?.backgroundColor = NSColor(white: 0, alpha: 0.55).cgColor
        loadingBadge.layer?.cornerRadius    = 3
        loadingBadge.isHidden               = true

        spinner.style        = .spinning
        spinner.controlSize  = .small
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        // Forced dark so the spinner is light against the scrim, whatever the
        // app's appearance is.
        spinner.appearance   = NSAppearance(named: .darkAqua)

        [artworkView, playBadge, loadingBadge, titleStack, waveView].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        playIcon.translatesAutoresizingMaskIntoConstraints = false
        playBadge.addSubview(playIcon)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        loadingBadge.addSubview(spinner)

        artworkLeading = artworkView.leadingAnchor.constraint(equalTo: leadingAnchor,
                                                              constant: metrics.leading)
        artworkWidth   = artworkView.widthAnchor .constraint(equalToConstant: metrics.artwork)
        artworkHeight  = artworkView.heightAnchor.constraint(equalToConstant: metrics.artwork)
        titleLeading   = titleStack.leadingAnchor.constraint(equalTo: artworkView.trailingAnchor,
                                                             constant: metrics.titleGap)

        NSLayoutConstraint.activate([
            loadingBadge.leadingAnchor .constraint(equalTo: artworkView.leadingAnchor),
            loadingBadge.trailingAnchor.constraint(equalTo: artworkView.trailingAnchor),
            loadingBadge.topAnchor     .constraint(equalTo: artworkView.topAnchor),
            loadingBadge.bottomAnchor  .constraint(equalTo: artworkView.bottomAnchor),

            spinner.centerXAnchor.constraint(equalTo: loadingBadge.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: loadingBadge.centerYAnchor),
            spinner.widthAnchor  .constraint(equalToConstant: 16),
            spinner.heightAnchor .constraint(equalToConstant: 16),

            playBadge.leadingAnchor.constraint(equalTo: artworkView.leadingAnchor),
            playBadge.trailingAnchor.constraint(equalTo: artworkView.trailingAnchor),
            playBadge.topAnchor.constraint(equalTo: artworkView.topAnchor),
            playBadge.bottomAnchor.constraint(equalTo: artworkView.bottomAnchor),

            playIcon.centerXAnchor.constraint(equalTo: playBadge.centerXAnchor),
            playIcon.centerYAnchor.constraint(equalTo: playBadge.centerYAnchor),
            playIcon.widthAnchor  .constraint(equalToConstant: 13),
            playIcon.heightAnchor .constraint(equalToConstant: 13),

            artworkLeading,
            artworkView.centerYAnchor .constraint(equalTo: centerYAnchor),
            artworkWidth,
            artworkHeight,

            titleLeading,
            titleStack.trailingAnchor.constraint(equalTo: waveView.leadingAnchor,     constant: -4),
            titleStack.centerYAnchor .constraint(equalTo: centerYAnchor),

            waveView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            waveView.centerYAnchor .constraint(equalTo: centerYAnchor),
            waveView.widthAnchor   .constraint(equalToConstant: 13),
            waveView.heightAnchor  .constraint(equalToConstant: 13),

            downloadView.widthAnchor .constraint(equalToConstant: 12),
            downloadView.heightAnchor.constraint(equalToConstant: 12),
        ])
    }

    /// Re-proportions a recycled cell. Cheap and idempotent — a table only ever
    /// hands out one set of metrics, so this is a no-op after the first call.
    func apply(metrics m: NativeTrackTable.RowMetrics) {
        guard m != metrics else { return }
        metrics = m
        artworkLeading.constant = m.leading
        artworkWidth.constant   = m.artwork
        artworkHeight.constant  = m.artwork
        titleLeading.constant   = m.titleGap
        // A 3pt radius on a 44pt cover reads as a square; keep the corner in
        // proportion with the artwork it's rounding.
        let radius = m.artwork >= 40 ? CGFloat(5) : CGFloat(3)
        artworkView.layer?.cornerRadius  = radius
        playBadge.layer?.cornerRadius    = radius
        loadingBadge.layer?.cornerRadius = radius
    }

    // MARK: - Deferred artwork

    /// Puts a cover on the row without ever decoding one on the main thread.
    ///
    /// The old code did `NSImage(data: track.displayArtwork)` right here, which
    /// is a full JPEG decode *and* a fault of the blob out of the store — tens
    /// of milliseconds, times every row `NSTableView` recycles. Dragging the
    /// scrollbar does dozens of those per frame, which is the whole of the jank.
    ///
    /// Now: a cached cover still appears in the same runloop pass, so a slow
    /// scroll through rows you have already seen looks exactly as it did. Only
    /// a genuine miss defers, and it shows the grey tile until it lands.
    private func loadArtwork(for track: Track) {
        artworkTask?.cancel()
        artworkTask = nil
        artworkToken &+= 1
        currentTrack = track
        let token   = artworkToken
        let bucket  = ArtworkDecodeCache.bucket(forPointSize: metrics.artwork)
        let scrolling = RowScrollState.shared.isScrolling

        // Bytes the row already carries always win, and are never in the store
        // to be found: a track in a mix, or anything from Discover, holds a
        // cover that was downloaded for the view and never imported. This is
        // the same precedence `displayArtwork` applies — dropping it is what
        // left every unsaved mix row showing a music note.
        if let data = track.artworkData, !data.isEmpty {
            if !scrolling, let hit = ArtworkDecodeCache.shared.cachedImage(for: data, bucket: bucket) {
                showArtwork(hit)
                return
            }
            showPlaceholder()
            observeScrollEnd()
            artworkTask = Task { [weak self] in
                try? await Task.sleep(for: Self.settleDelay)
                guard !Task.isCancelled, let self, !RowScrollState.shared.isScrolling else { return }
                let image = await Task.detached(priority: .utility) {
                    ArtworkDecodeCache.shared.decodedImage(for: data, bucket: bucket)
                }.value
                guard !Task.isCancelled, token == self.artworkToken else { return }
                guard let image else { return self.showMissing() }
                self.showArtwork(image, fade: true)
            }
            return
        }

        let source = ArtworkSource.row(.track(track.id))

        // While the list is moving, even a cover already decoded stays hidden.
        // Painting cached art during a scroll is what made the way back up look
        // completely different from the way down.
        if !scrolling, let hit = ArtworkImageLoader.shared.cached(source, bucket: bucket) {
            showArtwork(hit)
            return
        }

        showPlaceholder()
        observeScrollEnd()
        artworkTask = Task { [weak self] in
            // The settle delay is what makes a flick cost nothing: rows only
            // passing through are cancelled before they ask for bytes. Long
            // enough that a deliberate scroll never fills in behind you.
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled, let self, !RowScrollState.shared.isScrolling else { return }
            let image = await ArtworkImageLoader.shared.image(for: source, bucket: bucket)
            guard !Task.isCancelled, token == self.artworkToken else { return }
            guard let image else { return self.showMissing() }
            self.showArtwork(image, fade: true)
        }
    }

    private func observeScrollEnd() {
        RowScrollState.shared.observe(self) { [weak self] in
            guard let self, let track = self.currentTrack else { return }
            self.loadArtwork(for: track)
        }
    }

    private func showArtwork(_ image: NSImage, fade: Bool = false) {
        if fade {
            let t = CATransition()
            t.type = .fade
            t.duration = 0.18
            artworkView.layer?.add(t, forKey: "cover")
        }
        artworkView.image = image
        artworkView.contentTintColor = nil
        artworkView.layer?.backgroundColor = NSColor.clear.cgColor
    }

    /// The grey tile. Deliberately not the music note: a note means "this song
    /// has no cover", and saying that about a row that simply has not been
    /// decoded yet would be a lie that flickers.
    private func showPlaceholder() {
        artworkView.image = nil
        artworkView.contentTintColor = nil
        artworkView.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
    }

    /// Settled, and there really is no cover.
    private func showMissing() {
        artworkView.image = RowSymbol.image("music.note")
        artworkView.contentTintColor = .tertiaryLabelColor
        artworkView.layer?.backgroundColor = NSColor.clear.cgColor
    }

    func configure(track: Track,
                   isCurrent: Bool,
                   isPlaying: Bool,
                   availability: TrackAvailability,
                   isResolving: Bool) {
        // Fetching the audio. Held on the cell as well, because a recycled row
        // gets `setHovered` from the table without being reconfigured.
        self.isResolving = isResolving
        loadingBadge.isHidden = !isResolving
        if isResolving {
            spinner.startAnimation(nil)
            playBadge.isHidden = true
        } else {
            spinner.stopAnimation(nil)
        }

        // Artwork — deferred. See `loadArtwork`.
        loadArtwork(for: track)

        // Title + colour
        titleLabel.stringValue = track.title
        titleLabel.font        = .systemFont(ofSize: metrics.titleSize,
                                             weight: isCurrent ? .bold : metrics.titleWeight)
        // Bold weight (above) already marks the current track; use the adaptive
        // label colour so it stays readable in light mode (.white was invisible).
        titleLabel.textColor   = .labelColor

        // Download view. Which glyph and colour belongs to which state is
        // decided once, on TrackAvailability, and shared with the SwiftUI rows —
        // this side only translates it into AppKit.
        downloadView.removeAllSymbolEffects()
        if let symbol = availability.badgeSymbol {
            downloadView.isHidden = false
            downloadView.image = RowSymbol.image(symbol, description: availability.badgeDescription)
            downloadView.contentTintColor = {
                switch availability.badgeTint {
                case .positive: return .systemGreen
                case .active:   return NSColor(red: 1.0, green: 107/255, blue: 0, alpha: 1)
                case .negative: return .systemRed
                }
            }()
            downloadView.toolTip = availability.badgeDescription
            if availability.badgePulses {
                downloadView.addSymbolEffect(.pulse, options: .repeating)
            }
        } else {
            downloadView.isHidden = true
            downloadView.image = nil
            downloadView.toolTip = nil
        }

        // Now-playing indicator — remove any stale effect then re-add if needed.
        waveView.isHidden = !isCurrent
        waveView.removeAllSymbolEffects()
        if isCurrent && isPlaying {
            waveView.addSymbolEffect(.pulse, options: .repeating)
        }
    }

    func setHovered(_ hovered: Bool) {
        // A row that's still finding its audio keeps the spinner: swapping it
        // for "press play" the moment the pointer moves would say the click
        // hadn't registered.
        playBadge.isHidden = !hovered || isResolving
    }

    /// Only the artwork claims a click; the rest of the row is the table's, so
    /// selection, extend-select and double-click to play keep working.
    func clickAction(at point: NSPoint) -> (() -> Void)? {
        guard artworkView.frame.contains(point) else { return nil }
        return onArtworkClick
    }
}

// MARK: - Cells that claim their own clicks

/// A cell with a region that means something more specific than "this row".
///
/// The table asks before it selects, because a view-based `NSTableView` will
/// never ask the cell: it decides whether a subview may see a `mouseDown` by
/// calling `validateProposedFirstResponder(_:for:)`, which answers no for plain
/// views and for static text fields, and then keeps the event for selection.
/// That default is what makes clicking anywhere on a row select it, so the
/// answer isn't to weaken it — it's for the table to look for a click target
/// itself before falling back to selecting. An override on the cell alone never
/// runs at all.
private protocol TrackCellClickTarget: NSView {
    /// `point` is in the cell's own coordinates. Nil hands the click back.
    func clickAction(at point: NSPoint) -> (() -> Void)?
}

extension TrackTitleCell: TrackCellClickTarget {}
extension TrackLinkCell:  TrackCellClickTarget {}
extension TrackRowActionCell: TrackCellClickTarget {}

// MARK: - TrackLinkCell  (comma-separated, individually clickable names)

/// The Artist and Album columns. Renders its names as separate click targets
/// joined by ", " — a credit naming three people is three links, not one link
/// that would have to guess which of them the user meant.
///
/// It stays plain secondary text until the pointer is actually over a name,
/// which underlines that name alone. The table's whole look is "a list, not a
/// web page", and permanently coloured links would undo that.
private final class TrackLinkCell: NSTableCellView {

    private let stack = NSStackView()
    private var names: [String] = []
    private var font:  NSFont   = .systemFont(ofSize: 13)
    private var color: NSColor  = .secondaryLabelColor

    init(id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id
        stack.orientation = .horizontal
        stack.alignment   = .centerY
        stack.spacing     = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor .constraint(equalTo: leadingAnchor,  constant: 6),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            stack.centerYAnchor .constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// `onSelect` receives the index of the clicked name. Nil renders the whole
    /// line as ordinary, non-interactive text.
    func configure(names newNames: [String],
                   font newFont: NSFont,
                   color newColor: NSColor,
                   onSelect: ((Int) -> Void)?) {

        if newNames != names || newFont != font || newColor != color {
            names = newNames
            font  = newFont
            color = newColor
            rebuild()
        }

        var linkIndex = 0
        for view in stack.arrangedSubviews {
            guard let label = view as? LinkLabel, label.isLink else { continue }
            let index = linkIndex
            label.onClick = onSelect.map { select in { select(index) } }
            linkIndex += 1
        }
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        // The ", " rides on the name *before* it rather than living in a label
        // of its own. A separate separator label can't truncate — a stack view
        // squeezes the names and keeps every view — so a narrow column read
        // "Ed Sheeran, Camila Cab…, " with a comma dangling after nothing.
        // Carried this way, the comma truncates with the name it belongs to.
        for (index, name) in names.enumerated() {
            let text = index < names.count - 1 ? name + ", " : name
            let label = LinkLabel(text: text, font: font, color: color, isLink: true)
            // Later names give way first, so the artist a song is filed under
            // survives a narrow column and the fourth guest is what truncates.
            label.setContentCompressionResistancePriority(
                NSLayoutConstraint.Priority(rawValue: 250 - Float(index)), for: .horizontal)
            stack.addArrangedSubview(label)
        }
    }

    // MARK: Clicks
    //
    // Worked out here rather than in the label, because a non-editable,
    // non-selectable NSTextField is transparent to hit testing — that's what
    // lets a click on a song title select its row — so the labels can't tell
    // which name was under the pointer. The click itself arrives via the table
    // (see `TrackCellClickTarget`); a click on the gap after the last name
    // returns nil and belongs to the row.

    func clickAction(at point: NSPoint) -> (() -> Void)? {
        link(at: point)
    }

    private func link(at point: NSPoint) -> (() -> Void)? {
        for case let label as LinkLabel in stack.arrangedSubviews {
            guard label.isLink, let onClick = label.onClick else { continue }
            if label.convert(label.bounds, to: self).contains(point) { return onClick }
        }
        return nil
    }
}

/// One name in a `TrackLinkCell`, carrying the ", " that follows it.
private final class LinkLabel: NSTextField {

    let isLink: Bool
    var onClick: (() -> Void)? {
        didSet {
            // Losing the action (a reused row landing on a page with no
            // navigation) has to drop the hover styling with it.
            if onClick == nil, isHovering { isHovering = false }
            restyle()
            window?.invalidateCursorRects(for: self)
        }
    }

    private let text:  String
    private let base:  NSColor
    private var isHovering = false

    init(text: String, font: NSFont, color: NSColor, isLink: Bool) {
        self.text   = text
        self.base   = color
        self.isLink = isLink
        super.init(frame: .zero)
        self.font              = font
        isEditable             = false
        isSelectable           = false
        isBordered             = false
        drawsBackground        = false
        lineBreakMode          = .byTruncatingTail
        maximumNumberOfLines   = 1
        translatesAutoresizingMaskIntoConstraints = false
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var isInteractive: Bool { isLink && onClick != nil }

    private func restyle() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        var attrs: [NSAttributedString.Key: Any] = [
            .font:            font ?? NSFont.systemFont(ofSize: 13),
            .foregroundColor: isHovering ? NSColor.labelColor : base,
            .paragraphStyle:  paragraph,
        ]
        if isHovering { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        attributedStringValue = NSAttributedString(string: text, attributes: attrs)
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        guard isInteractive, !isHovering else { return }
        isHovering = true
        restyle()
    }

    override func mouseExited(with event: NSEvent) {
        guard isHovering else { return }
        isHovering = false
        restyle()
    }

    override func resetCursorRects() {
        guard isInteractive else { return super.resetCursorRects() }
        addCursorRect(bounds, cursor: .pointingHand)
    }

    // MARK: Clicks
    //
    // Everything that isn't a plain left click on a live link goes back up the
    // view hierarchy, so ⌘/⇧-click still extends the table's selection and a
    // double click on the artist column still plays the row. NSControl's own
    // mouseDown would swallow all of it.

    override func mouseDown(with event: NSEvent) {
        guard isInteractive, event.clickCount == 1,
              event.modifierFlags.isDisjoint(with: [.command, .shift, .option]),
              let onClick
        else {
            superview?.mouseDown(with: event)
            return
        }
        onClick()
    }

    /// Right-click belongs to the row, not the name — the track context menu is
    /// what the user is reaching for.
    override func menu(for event: NSEvent) -> NSMenu? {
        superview?.menu(for: event) ?? super.menu(for: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        superview?.rightMouseDown(with: event)
    }
}

// MARK: - AddToPlaylistPayload  (carries track + target playlist ID through ObjC representedObject)

private final class AddToPlaylistPayload: NSObject {
    let tracks:     [Track]
    let playlistID: UUID
    init(tracks: [Track], playlistID: UUID) {
        self.tracks     = tracks
        self.playlistID = playlistID
    }
}

// MARK: - PassthroughScrollView
//
// The `fitsContent` table's scroll view. It's sized to its rows so it never has
// anywhere to scroll, but AppKit still swallows the wheel event on the way past
// — which would leave a dead zone over the song list on a page that scrolls as
// a whole. Handing the event straight up the responder chain gives the page
// back its scroll.

private final class PassthroughScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

// MARK: - TrackRowActionCell  (the heart / save column)

/// One glyph, centred in its own narrow column between Date Added and Duration.
///
/// Which glyph depends on the page, not on the row — see `showsSaveControl`. A
/// library table hearts; a Discover page saves. The "on" state (a filled heart,
/// a filled check) is permanent information about the song, so it shows whether
/// or not the pointer is near it. The "off" state is an invitation, and only
/// appears on hover: a column of grey outlines down an entire library would be
/// louder than the songs beside it, and would read as a state rather than as the
/// button it is. Same rule the iOS row follows.
fileprivate final class TrackRowActionCell: NSTableCellView {

    enum State {
        case favourited, notFavourited, saved, notSaved

        var symbol: String {
            switch self {
            case .favourited:    return "heart.fill"
            case .notFavourited: return "heart"
            case .saved:         return "checkmark.circle.fill"
            case .notSaved:      return "plus.circle"
            }
        }
        /// Whether the glyph stands on its own, without the pointer.
        var isPersistent: Bool {
            self == .favourited || self == .saved
        }
        var label: String {
            switch self {
            case .favourited:    return "Liked"
            case .notFavourited: return "Like"
            case .saved:         return "In your library"
            case .notSaved:      return "Add to Library"
            }
        }
    }

    var onToggle: (() -> Void)?

    private let icon = NSImageView()
    private var state: State = .notFavourited
    private var isHovered    = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("rowAction")

        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ state: State, size: CGFloat) {
        self.state = state
        icon.image = NSImage(systemSymbolName: state.symbol, accessibilityDescription: state.label)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: size, weight: state == .saved ? .semibold : .regular
        )
        icon.contentTintColor = state.isPersistent
            ? NSColor(red: 1.0, green: 107 / 255, blue: 0, alpha: 1)   // BrandAccent
            : .tertiaryLabelColor
        toolTip = state.label
        applyVisibility()
    }

    func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        applyVisibility()
    }

    private func applyVisibility() {
        icon.isHidden = !(state.isPersistent || isHovered)
    }

    /// The whole cell is the button, but only while the glyph is actually
    /// showing — an invisible click target that swallowed row selection on a
    /// non-hovered row would be a hole in the table. A filled check is
    /// information rather than a control, and hands its click back too.
    func clickAction(at point: NSPoint) -> (() -> Void)? {
        guard !icon.isHidden, state != .saved else { return nil }
        return onToggle
    }
}

// MARK: - MacListRowView  (flat rows, hover highlight, orange selection)
//
// Zebra striping was replaced by a single flat background plus a hover
// highlight: it reads as one continuous list instead of a spreadsheet, and the
// row under the pointer is what tells you where you are.

private final class MacListRowView: NSTableRowView {

    private var isHovered = false

    func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        needsDisplay = true
    }

    // We draw our own (light orange) selection, so the row is never visually
    // "emphasized". Without this, AppKit flips selected cells' text to white
    // (alternateSelectedControlTextColor), making song titles invisible on the
    // light selection highlight. Forcing `.normal` keeps our `.labelColor` text.
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override var isEmphasized: Bool {
        get { false }
        set { }
    }

    /// Translucent so it layers over whatever the content background is, in
    /// either appearance, without having to know the exact base colour.
    private static let hoverColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.07)
            : NSColor(white: 0, alpha: 0.05)
    }

    // App primary orange (#FF6B00) at 22% opacity — matches the sidebar row highlight style.
    private static let selectionColor = NSColor(red: 1.0, green: 107/255, blue: 0, alpha: 0.22)

    override func drawBackground(in dirtyRect: NSRect) {
        guard isHovered, !isSelected else { return }
        Self.hoverColor.setFill()
        Self.rowPath(in: bounds).fill()
    }

    /// Replace the system accent-colour selection fill with the app's orange.
    override func drawSelection(in dirtyRect: NSRect) {
        Self.selectionColor.setFill()
        Self.rowPath(in: bounds).fill()
    }

    private static func rowPath(in bounds: NSRect) -> NSBezierPath {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 2), xRadius: 6, yRadius: 6)
    }
}

// MARK: - MelTableHeaderView  (the column titles, drawn on the page)

/// The Title / Artist / Album strip.
///
/// It draws its own titles and never calls `super.draw`, which is the whole
/// point. `NSTableHeaderView` paints a translucent slab of its own before the
/// cells — that slab is what made the strip read as a grey band laid across the
/// page, and no fill colour underneath could change it, because it was on top.
/// With nothing of the app's behind it either (the table is `.clear` inside a
/// scroll view with `drawsBackground = false`, so the artwork wash shows through
/// the rows), the slab's translucency blended against what was behind the
/// *window* and the strip came out blue over a blue wallpaper — the same bug the
/// sidebar had while it was still an NSVisualEffectView, and it has the same
/// answer: draw the app's own colour.
///
/// So: the page's own colour, the titles, a rule on each column boundary and one
/// hairline underneath. The boundary rules are the only thing that says a column
/// can be dragged wider — the resize cursor appears once the pointer is already
/// on the edge, which is no use to someone who doesn't know to go looking.
///
/// "The page's own colour" is not a token. The page is `mixBackground` with the
/// artwork wash over it, and this band sits partway down that ramp, so a flat
/// token here reads as a dark stripe cut out of a warm page. The fill is the
/// ramp itself, evaluated at this view's distance from the top of the window —
/// the same thing `ArtworkWashGradient` exists to let the sidebar do. One sample
/// is enough: across a band one line of text tall, the slice is flat.
///
/// Only `draw` is overridden. Column dragging, resizing and sort clicks are all
/// event handling, which is untouched.
final class MelTableHeaderView: NSTableHeaderView {

    private var washObserver: AnyCancellable?

    override var isOpaque: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { washObserver = nil; return }
        // Navigating to another playlist republishes the tint, and the cover's
        // colours often arrive after the page does. Either way the band has to
        // repaint or it keeps the previous page's colour.
        washObserver = ArtworkWashTint.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.needsDisplay = true }
    }

    /// The band's distance from the window top changes whenever the banner above
    /// it re-wraps, which is a resize away.
    override func layout() {
        super.layout()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // `bounds`, not `dirtyRect`: a resize or a column drag repaints a sliver,
        // and filling only the sliver would leave the rest showing the desktop.
        pageColour().setFill()
        bounds.fill()

        guard let table = tableView else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor(Color.mixTextSecondary),
        ]

        for column in 0..<table.numberOfColumns {
            let rect = headerRect(ofColumn: column)
            guard rect.intersects(dirtyRect) else { continue }

            let spec  = table.tableColumns[column]
            let label = NSAttributedString(string: spec.title, attributes: attributes)
            // Room on the leading edge so the label doesn't sit against the
            // rule that divides it from the column before.
            var text  = rect
            text.origin.x   += 11
            text.size.width -= 11 + 6

            // The sort arrow, when this is the column being sorted by. AppKit
            // hands it over as an image; drawing it is normally `super`'s job.
            if let arrow = table.indicatorImage(in: spec) {
                let size = arrow.size
                let box  = NSRect(x: text.maxX - size.width,
                                  y: text.midY - size.height / 2,
                                  width: size.width, height: size.height)
                arrow.draw(in: box)
                text.size.width -= size.width + 4
            }

            // Centred by measurement rather than by the cell's own insets: the
            // stock cell sits the title a few points high once its bezel is
            // gone, and this band is only as tall as one line of text.
            let height = label.size().height
            label.draw(in: NSRect(x: text.minX, y: text.midY - height / 2,
                                  width: max(0, text.width), height: height))
        }

        NSColor(Color.mixSeparator).setFill()

        // A rule on every column boundary but the last: it's the grab handle,
        // and it's inset top and bottom so it reads as a divider between two
        // labels rather than a border around each one.
        for column in 0..<(table.numberOfColumns - 1) {
            let edge = headerRect(ofColumn: column).maxX
            guard edge < bounds.maxX else { continue }
            NSRect(x: edge - 0.5, y: bounds.minY + 6,
                   width: 1, height: bounds.height - 12).fill()
        }

        // One hairline, so the list still starts somewhere.
        NSRect(x: bounds.minX, y: bounds.maxY - 0.5, width: bounds.width, height: 0.5).fill()
    }

    // MARK: The page's colour, at this height

    /// `mixBackground` with the wash composited over it, sampled at this band's
    /// vertical centre. Falls back to the flat ground when there is no wash, or
    /// when the band has fallen past the end of the ramp.
    private func pageColour() -> NSColor {
        let ground = NSColor(Color.mixBackground).usingColorSpace(.sRGB)
                  ?? NSColor(Color.mixBackground)
        let tint = ArtworkWashTint.shared
        guard tint.stops.count == 2, let host = window?.contentView else { return ground }

        // The ramp starts at the top of the window's content: the content column
        // and the sidebar both ignore the top safe area, which is what makes the
        // wash run continuously across the two.
        let here = convert(bounds, to: host)
        let top  = host.isFlipped ? here.minY : host.bounds.height - here.maxY
        let t    = (top + bounds.height / 2) / ArtworkWash.height
        guard t >= 0, t < 1, let (lo, hi) = Self.bracket(t) else { return ground }

        let span = hi.location - lo.location
        let f    = span > 0 ? (t - lo.location) / span : 0

        guard let a = NSColor(tint.stops[lo.stop]).usingColorSpace(.sRGB),
              let b = NSColor(tint.stops[hi.stop]).usingColorSpace(.sRGB)
        else { return ground }

        // Premultiplied, because that is how a gradient crosses between two stops
        // of different colour *and* different opacity. Interpolating the two
        // separately puts a muddy step in the middle of the crossover.
        let strength = CGFloat(tint.intensity)
        let aA = lo.opacity * strength
        let bA = hi.opacity * strength
        let alpha = aA + (bA - aA) * f

        func channel(_ ca: CGFloat, _ cb: CGFloat, _ under: CGFloat) -> CGFloat {
            let premultiplied = ca * aA + (cb * bA - ca * aA) * f
            return premultiplied + under * (1 - alpha)      // source-over onto the ground
        }

        return NSColor(srgbRed: channel(a.redComponent,   b.redComponent,   ground.redComponent),
                       green:   channel(a.greenComponent, b.greenComponent, ground.greenComponent),
                       blue:    channel(a.blueComponent,  b.blueComponent,  ground.blueComponent),
                       alpha:   1)
    }

    /// The ramp `ArtworkWashGradient` draws, as data. Kept in step with it by
    /// hand — the two have to agree exactly or this band is a seam.
    private struct Stop {
        let location: CGFloat
        /// Index into `ArtworkWashTint.stops`.
        let stop: Int
        let opacity: CGFloat
    }

    private static let ramp: [Stop] = [
        Stop(location: 0.00, stop: 0, opacity: CGFloat(ArtworkWash.topOpacity)),
        Stop(location: 0.22, stop: 0, opacity: 0.48),
        Stop(location: 0.48, stop: 1, opacity: 0.28),
        Stop(location: 0.74, stop: 1, opacity: 0.10),
        Stop(location: 1.00, stop: 1, opacity: 0.00),
    ]

    private static func bracket(_ t: CGFloat) -> (Stop, Stop)? {
        for i in 0..<(ramp.count - 1) where t <= ramp[i + 1].location {
            return (ramp[i], ramp[i + 1])
        }
        return nil
    }
}

// MARK: - MelTableView  (right-click menu, Return key, pointer tracking)

final class MelTableView: NSTableView {

    var menuBuilder: ((Int) -> NSMenu?)?
    var onReturnKey: (() -> Void)?
    /// (previousRow, newRow) — either may be -1 for "none".
    var onHoverChange: ((Int, Int) -> Void)?

    private(set) var hoveredRow: Int = -1
    private var hoverTrackingArea: NSTrackingArea?

    override func menu(for event: NSEvent) -> NSMenu? {
        let pt  = convert(event.locationInWindow, from: nil)
        let row = self.row(at: pt)
        return menuBuilder?(row) ?? super.menu(for: event)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:          // Return / Enter
            onReturnKey?()
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: Clicks inside a row

    /// A plain single click is offered to the cell under the pointer first — the
    /// artwork's play badge, an artist or album name — and only becomes a
    /// selection if the cell doesn't want it. Modified and repeated clicks are
    /// never offered: ⌘/⇧-click extend the selection and a double click plays,
    /// and a link that stole those would break the table.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1,
           event.modifierFlags.isDisjoint(with: [.command, .shift, .option, .control]),
           let action = clickAction(for: event) {
            action()
            return
        }
        // A click on the empty space under the last row means "never mind these
        // rows". AppKit's own behaviour is to keep the selection, which leaves a
        // highlighted song following you around the page.
        if row(at: convert(event.locationInWindow, from: nil)) < 0,
           event.modifierFlags.isDisjoint(with: [.command, .shift]) {
            deselectAll(nil)
            return
        }
        super.mouseDown(with: event)
    }

    private func clickAction(for event: NSEvent) -> (() -> Void)? {
        let point  = convert(event.locationInWindow, from: nil)
        let row    = self.row(at: point)
        let column = self.column(at: point)
        guard row >= 0, column >= 0,
              let cell = view(atColumn: column, row: row, makeIfNecessary: false)
                         as? TrackCellClickTarget
        else { return nil }
        return cell.clickAction(at: cell.convert(event.locationInWindow, from: nil))
    }

    // MARK: Hover tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        // .inVisibleRect keeps the area pinned to the scrolled-visible region,
        // so it doesn't need re-creating as the table scrolls.
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        setHoveredRow(row(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHoveredRow(-1)
    }

    private func setHoveredRow(_ newRow: Int) {
        guard newRow != hoveredRow else { return }
        let old = hoveredRow
        hoveredRow = newRow
        onHoverChange?(old, newRow)
    }
}

#endif

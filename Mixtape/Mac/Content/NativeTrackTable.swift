// NSTableView-backed Songs list. SwiftUI Table builds a render tree per row and
// drops frames past ~10k tracks; NSTableView recycles cells.
// Click selects, click the artwork or double click plays, Return plays the
// selection, right-click opens the context menu, headers sort.

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

    /// Forces the AppKit table's appearance: `.preferredColorScheme` doesn't reach it reliably.
    @Environment(\.colorScheme) private var colorScheme

    // MARK: Callbacks (all called on the main thread)

    var onPlay:               (Track, [Track]) -> Void
    var onPlayNext:           (Track)          -> Void
    var onAddToQueue:         (Track)          -> Void
    var onGetInfo:            (Track)          -> Void
    /// Shown only for songs the user imported. Nil hides the item.
    var onEditMetadata:       ((Track)  -> Void)? = nil
    /// The song editor. Nil hides the item.
    var onEditSong:           ((Track)  -> Void)? = nil
    /// Posts an edit to the community. Nil hides the item.
    var onPostSong:           ((Track)  -> Void)? = nil
    /// Drag start/end, so the sidebar can switch playlist rows to drop targets.
    var onDragTracksChanged:  ((Bool)   -> Void)?
    /// Passed one credited name (features are split). Nil hides the item.
    var onGoToArtist:         ((String) -> Void)?
    var onGoToAlbum:          ((Track)  -> Void)?
    /// Nil hides the item.
    var onSongRadio:          ((Track)  -> Void)? = nil
    /// Passed the single clicked name, not the whole credit. Nil = plain text.
    var onOpenArtistLink:     ((String) -> Void)? = nil
    /// Clicking the Album column. Nil leaves it as plain text.
    var onOpenAlbumLink:      ((Track)  -> Void)? = nil
    /// Passed the whole selection so the caller deletes in one write.
    var onRemove:             ([Track])        -> Void
    var onToggleFavourite:    (Track)          -> Void = { _ in }
    var onAddToPlaylist:      ([Track], UUID)  -> Void = { _, _ in }
    /// Called when the user picks "Move to Artist Folder..." from the context menu.
    var onMoveToArtistFolder: ((Track) -> Void)?

    // MARK: Playlist pages
    // A song can leave a playlist without leaving the library. Nil on library tables.

    /// Nil hides the item (read-only playlists).
    var onRemoveFromPlaylist:   (([Track]) -> Void)? = nil
    /// Favourites says "remove a favourite" instead.
    var removeFromPlaylistTitle: (Int) -> String = {
        $0 > 1 ? "Remove \($0) Songs from Playlist" : "Remove from Playlist"
    }
    /// Off on playlist pages, where remove means remove from this list.
    var showsRemoveFromLibrary: Bool = true
    /// The playlist being shown, kept out of its own "Add to Playlist" submenu.
    var excludedPlaylistID:     UUID? = nil
    /// "Find in Discover", for a collaborator's song this device can't reach.
    var onFindInDiscover:       ((Track) -> Void)? = nil
    /// The sheet at the foot of Add to Playlist. Nil leaves just the list.
    var onChoosePlaylist:       (([Track]) -> Void)? = nil
    /// "Start New Side Here". Nil hides the item.
    var onStartSide:            ((Track) -> Void)? = nil
    /// Only consulted when `onStartSide` is set.
    var canStartSide:           (Track) -> Bool = { _ in true }

    // MARK: Online pages
    // Rows not in the library yet (the mix page). Nil on library tables.

    /// "Add to Library": passed the targets that aren't in the library yet.
    var onAddToLibrary: (([Track]) -> Void)? = nil
    /// Only consulted when `onAddToLibrary` is set.
    var isInLibrary: (Track.ID) -> Bool = { _ in true }

    // MARK: Data for context-menu enrichment
    var isFavourited: (Track.ID) -> Bool = { _ in false }
    var playlists:    [Playlist]         = []
    var availability: (Track.ID) -> TrackAvailability = { _ in .streamOnly }
    var onDownload:       ((Track) -> Void)? = nil
    var onRemoveDownload: ((Track.ID) -> Void)? = nil
    /// Whole selection, so the destination is asked for once.
    var onSaveToDisk:         (([Track]) -> Void)? = nil
    /// The menu has no `deps`, so the page shows the toast.
    var onLinkCopied:         (() -> Void)? = nil
    /// No Download item at all when false, never a disabled one.
    var canDownload: (Track) -> Bool = { _ in true }

    /// UI zoom, so AppKit layers render at the right density before `scaleEffect`.
    var scale: CGFloat = 1.0

    /// Size to the rows instead of scrolling, for pages that are one `ScrollView`.
    var fitsContent: Bool = false

    /// The page's sort, when it has a control for it. Set means rows arrive sorted;
    /// the table only mirrors it into the headers and writes header clicks back.
    /// Nil: the coordinator owns the order.
    var sort: Binding<TrackSort>? = nil

    /// The page's row size. `effectiveMetrics` applies the user's density on top.
    var metrics: RowMetrics = .compact

    /// Row numbers in a fixed column before Title. Playlists want them, library
    /// tables don't (position there is just the sort).
    var showsIndex: Bool = false

    /// Off for generated lists (mixes, Release Radar), where every row is "just now".
    var showsDateAdded: Bool = true

    @Environment(\.mixDensity) private var density

    /// `metrics` at the user's chosen density, the only one anything draws from.
    var effectiveMetrics: RowMetrics { metrics.at(density) }

    /// Songs whose audio is being fetched, drawn with a spinner over the cover.
    /// Fed from `PlaybackEngine.routingTrackIDs`.
    var resolvingIDs: Set<Track.ID> = []

    // MARK: - Row Metrics

    /// Row proportions: dense for library tables, roomy for detail pages.
    struct RowMetrics: Equatable {
        var rowHeight:     CGFloat
        var artwork:       CGFloat
        /// Inset from the row's leading edge to the artwork.
        var leading:       CGFloat
        /// Artwork -> title gap.
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

        /// The playlist page: 44pt cover, 15pt semibold title.
        static let roomy = RowMetrics(
            rowHeight: 58, artwork: 44, leading: 12, titleGap: 12,
            titleSize: 15, titleWeight: .semibold,
            secondarySize: 14, durationSize: 12
        )

        /// Scaled by ratio rather than a third preset. Type drops by a whole point
        /// since fractional sizes render blurry.
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
        // Rows drag onto sidebar playlists as a copy.
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
            // Code-built columns default to autoresize-only; this makes dividers draggable.
            col.resizingMask = spec.isFixed ? [] : [.userResizingMask, .autoresizingMask]
            if spec.sortKey != nil {
                col.sortDescriptorPrototype = NSSortDescriptor(key: spec.sortKey!, ascending: true)
            }
            tv.addTableColumn(col)
        }

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

        // Initial contentsScale, in case a zoom is already active.
        let initialCS = (NSScreen.main?.backingScaleFactor ?? 2.0) * scale
        sv.wantsLayer = true
        sv.layer?.contentsScale = initialCS
        tv.wantsLayer = true
        tv.layer?.contentsScale = initialCS

        sv.appearance = nsAppearance

        // Drives the grey tiles. `boundsDidChange` catches knob drags and momentum,
        // which never send `willStartLiveScroll`.
        sv.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observeScrolling(of: sv)

        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        // Keep the AppKit table in sync with the app's Light/Dark setting.
        sv.appearance = nsAppearance
        context.coordinator.update(parent: self)
    }

    /// In `fitsContent` mode, ask for exactly the rows + header height,
    /// measured from the live views.
    func sizeThatFits(_ proposal: ProposedViewSize,
                      nsView: NSScrollView,
                      context: Context) -> CGSize? {
        guard fitsContent else { return nil }
        let table  = nsView.documentView as? NSTableView
        // The header may not be laid out on the first pass; under-measuring clips the last row.
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
        /// No resizing. Only the number column.
        var isFixed: Bool = false
    }

    /// A separate column so the header leaves a gap above the numbers (matches
    /// iOS `TrackListHeader`). Right-aligned, so the width is the gap: 42 fits four
    /// digits at the compact size.
    private var indexColumnWidth: CGFloat { density == .compact ? 42 : 50 }

    /// Glyph plus room so it doesn't touch the date or duration.
    private var rowActionColumnWidth: CGFloat { density == .compact ? 28 : 32 }

    /// Save (plus/check) instead of a heart, on pages of songs not in the library.
    /// `onAddToLibrary` is nil on every library table.
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
            // Four digits at 13pt monospaced plus the cell's 6pt insets.
            specs.append(.init(id: "index", title: "", minW: indexColumnWidth,
                               width: indexColumnWidth, sortKey: nil, isFixed: true))
        }
        specs += [
        .init(id: "title",       title: "Title",      minW: 160, width: 280, sortKey: "title"),
        .init(id: "artistName",  title: "Artist",     minW:  80, width: 160, sortKey: "artistName"),
        .init(id: "albumTitle",  title: "Album",      minW:  80, width: 160, sortKey: "albumTitle"),
        // Heart or save control (`showsSaveControl`). Same slot as iOS `TrackColumns.heart`.
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

    // Not @MainActor at class level so ObjC delegate calls route correctly;
    // AppKit already calls these on the main thread.
    final class Coordinator: NSObject {

        var parent: NativeTrackTable

        // Sorted local copy.
        var tracks: [Track] = []

        weak var tableView: MelTableView?

        // Tracks what we last loaded so updateNSView skips no-op reloads.
        private var lastDisplayHash: Int        = 0
        private var lastScale:       CGFloat    = 1.0
        /// Held so an upstream edit has to copy: the same storage next time means the same rows.
        private var lastSource:      [Track]    = []
        private var lastSelection:   Set<Track.ID> = []

        // Prevents a SwiftUI->AppKit->SwiftUI selection feedback loop.
        private var suppressSelectionSync = false

        // MARK: - Scroll state

        /// Ends `RowScrollState` once the clip view has been still for a beat.
        /// There's no "momentum finished" notification.
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

            // Cell constraints and fonts are baked in at configure time, so rows rebuild.
            let metricsChanged = parent.effectiveMetrics != prev.effectiveMetrics
            if tv.rowHeight != parent.effectiveMetrics.rowHeight {
                tv.rowHeight = parent.effectiveMetrics.rowHeight
            }
            // The index column is the only fixed-width one that depends on density.
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

            // Detect UI zoom change: need to re-render cells at new pixel density.
            let scaleChanged = abs(parent.scale - lastScale) > 0.001
            if scaleChanged {
                lastScale = parent.scale
                let cs = (NSScreen.main?.backingScaleFactor ?? 2.0) * parent.scale
                if let sv = tv.enclosingScrollView {
                    applyContentsScale(cs, to: sv)
                }
                applyContentsScale(cs, to: tv)
            }

            // A hash of what's drawn, not just ids, so enrichment edits (same id) re-sort too.
            // A resize re-renders the page every frame with the same array, so skip hashing every row.
            let sameSource = parent.tracks.count == lastSource.count && parent.tracks.withUnsafeBufferPointer { a in
                lastSource.withUnsafeBufferPointer { a.baseAddress == $0.baseAddress }
            }
            let newHash     = sameSource ? lastDisplayHash : displayHash(of: parent.tracks)
            lastSource      = parent.tracks
            let needsReload = newHash != lastDisplayHash || scaleChanged || metricsChanged
            if needsReload {
                lastDisplayHash = newHash
                // Sorted upstream when the page owns the order.
                tracks = parent.sort == nil
                    ? sorted(parent.tracks, by: tv.sortDescriptors.first)
                    : parent.tracks
                tv.reloadData()
            } else {
                // Only rows whose playing or loading state moved, all columns, since both "index" and
                // "title" draw it. A skip used to reload every visible row.
                let rows = changedStatusRows(tv, prev: prev)
                if !rows.isEmpty, tv.numberOfColumns > 0 {
                    tv.reloadData(forRowIndexes: rows,
                                  columnIndexes: IndexSet(integersIn: 0 ..< tv.numberOfColumns))
                }
                // Favourite/save state changes no drawn text, so refresh the action column directly.
                refreshRowActions(tv)
            }

            // Sync selection SwiftUI -> AppKit (only for external changes).
            if needsReload || parent.selectedIDs != lastSelection { syncSelection(tv) }
        }

        /// Selects the rows of `parent.selectedIDs`. A scan of every row, so only after a change.
        func syncSelection(_ tv: NSTableView) {
            lastSelection = parent.selectedIDs
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
            }
            return h.finalize()
        }

        /// Loading and download state each title cell was last drawn with. Off-screen rows read it fresh when
        /// they scroll in, so a song starting to load no longer reloads and re-sorts every row.
        private var drawnStatus: [Track.ID: Int] = [:]

        /// Visible rows whose loading state differs from what their cells drew, plus the old and new
        /// playing rows when that moved.
        private func changedStatusRows(_ tv: NSTableView, prev: NativeTrackTable) -> IndexSet {
            let visible = tv.rows(in: tv.visibleRect)
            guard visible.location != NSNotFound else { return [] }
            let playingMoved = prev.currentTrackID != parent.currentTrackID || prev.isPlaying != parent.isPlaying
            var rows = IndexSet()
            for row in visible.location ..< NSMaxRange(visible) where row < tracks.count {
                let id = tracks[row].id
                if drawnStatus[id] != statusCode(id)
                    || (playingMoved && (id == prev.currentTrackID || id == parent.currentTrackID)) {
                    rows.insert(row)
                }
            }
            return rows
        }

        private func statusCode(_ id: Track.ID) -> Int {
            let base: Int
            switch parent.availability(id) {
            case .streamOnly:  base = 0
            case .downloading: base = 1
            case .offline:     base = 2
            case .local:       base = 3
            case .failed:      base = 4
            }
            return parent.resolvingIDs.contains(id) ? base + 8 : base
        }

        // MARK: - Crisp rendering helper
        // Sets wantsLayer + contentsScale down the tree so AppKit renders at
        // screen scale x UI zoom before `scaleEffect` upscales it.
        func applyContentsScale(_ cs: CGFloat, to view: NSView) {
            view.wantsLayer = true
            view.layer?.contentsScale = cs
            for sub in view.subviews { applyContentsScale(cs, to: sub) }
        }

        // MARK: - Sort helpers

        /// Mirrors the page's sort into the headers. Setting `sortDescriptors` calls the
        /// delegate back, hence the suppress flag.
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

        /// Nil when there's no page sort or we just wrote the descriptors ourselves.
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
        // Only the two affected rows are touched, never a reload.

        /// Updates the visible rows' hearts in place.
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
            // Items act on the selection if the clicked row is in it (Finder rule), else that row.
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

            // A mixed selection favourites rather than unfavourites.
            let favVerb  = favoured ? "Remove" : "Add"
            let favWhere = favoured ? "from Liked Songs" : "to Liked Songs"
            let favTitle = many ? "\(favVerb) \(targets.count) Songs \(favWhere)"
                                : "\(favVerb) \(favWhere)"
            let favIcon  = NSImage(systemSymbolName: favoured ? "heart.fill" : "heart", accessibilityDescription: nil)
            let favItem  = menuItem(favTitle, action: #selector(menuToggleFavourite(_:)), tracks: targets)
            favItem.image = favIcon
            menu.addItem(favItem)
            // Saving is liking, so there's no separate Add to Library.

            // A collaborator's song with no audio: Discover can often find it online.
            if !many, track.isUnresolvableShare, parent.onFindInDiscover != nil {
                let item = menuItem("Find in Discover", action: #selector(menuFindInDiscover(_:)), track: track)
                item.image = NSImage(systemSymbolName: "sparkle.magnifyingglass", accessibilityDescription: nil)
                menu.addItem(item)
            }

            // Mixes and others' playlists are left out; LibraryService would reject the add.
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

            // Go to artist/album, single song only.
            let credits = many ? [] : ImportService.creditedArtists(from: track.artistName)
            if !many, parent.onGoToArtist != nil || parent.onGoToAlbum != nil
                       || parent.onSongRadio != nil {
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
                    // A featured track gets a submenu, one per artist.
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
            if !many, parent.onSongRadio != nil {
                let item = menuItem("Go to Song Radio",
                                    action: #selector(menuSongRadio(_:)), track: track)
                item.image = NSImage(systemSymbolName: "dot.radiowaves.left.and.right",
                                     accessibilityDescription: nil)
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
            if !many, track.origin == .imported, parent.onEditMetadata != nil {
                let item = menuItem("Edit Metadata", action: #selector(menuEditMetadata(_:)), track: track)
                item.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
                menu.addItem(item)
            }
            if !many, track.canEdit, parent.onEditSong != nil {
                let item = menuItem("Edit Song\u{2026}", action: #selector(menuEditSong(_:)), track: track)
                item.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil)
                menu.addItem(item)
            }
            if !many, track.edit != nil, parent.onPostSong != nil {
                let item = menuItem("Post\u{2026}", action: #selector(menuPostSong(_:)), track: track)
                item.image = NSImage(systemSymbolName: "paperplane", accessibilityDescription: nil)
                menu.addItem(item)
            }

            // Only when there's a file.
            if !many, let url = track.fileOnDisk {
                let item = NSMenuItem(title: "Show in Finder",
                                      action: #selector(menuShowInFinder(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = url
                item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
                menu.addItem(item)
            }

            // Single song only; renames its folder on disk.
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
                // A selection gets counts per action rather than one row's status.
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
                // Undownloadable tracks get no row; a running download keeps one with progress.
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

            if !many, parent.onStartSide != nil, parent.canStartSide(track) {
                menu.addItem(menuItem("Start New Side Here", action: #selector(menuStartSide(_:)), track: track))
                menu.addItem(.separator())
            }

            // Leaves this playlist only, no confirmation. Above the library delete since
            // that's what "remove" usually means here.
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

        /// Selection if the clicked row is in it, else that row. Read from the table
        /// (not `parent.selectedIDs`) so it's right in the same pass a right-click
        /// changed the selection, and in row order.
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

        @objc func menuShowInFinder(_ item: NSMenuItem) {
            guard let url = item.representedObject as? URL else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }

        @objc func menuPlayNow(_ item: NSMenuItem) {
            guard let targets = item.representedObject as? [Track], let first = targets.first else { return }
            // One song plays in the context of the table; a selection is its own context.
            parent.onPlay(first, targets.count > 1 ? targets : tracks)
        }

        @objc func menuPlayNext(_ item: NSMenuItem) {
            guard let targets = item.representedObject as? [Track] else { return }
            // Reversed so inserting after the current song keeps selection order.
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

        @objc func menuEditMetadata(_ item: NSMenuItem) {
            guard let t = item.representedObject as? Track else { return }
            parent.onEditMetadata?(t)
        }

        @objc func menuEditSong(_ item: NSMenuItem) {
            guard let t = item.representedObject as? Track else { return }
            parent.onEditSong?(t)
        }

        @objc func menuPostSong(_ item: NSMenuItem) {
            guard let t = item.representedObject as? Track else { return }
            parent.onPostSong?(t)
        }

        @objc func menuToggleFavourite(_ item: NSMenuItem) {
            guard let targets = item.representedObject as? [Track] else { return }
            // Only flip the songs that disagree, so a mixed selection ends up all favourited.
            let favouriting = !targets.allSatisfy { parent.isFavourited($0.id) }
            for track in targets where parent.isFavourited(track.id) != favouriting {
                parent.onToggleFavourite(track)
            }
        }

        @objc func menuAddToPlaylist(_ item: NSMenuItem) {
            guard let payload = item.representedObject as? AddToPlaylistPayload else { return }
            parent.onAddToPlaylist(payload.tracks, payload.playlistID)
        }

        @objc func menuRemoveFromPlaylist(_ item: NSMenuItem) {
            guard let targets = item.representedObject as? [Track] else { return }
            parent.onRemoveFromPlaylist?(targets)
        }

        @objc func menuStartSide(_ item: NSMenuItem) {
            guard let track = item.representedObject as? Track else { return }
            parent.onStartSide?(track)
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

        @objc func menuSongRadio(_ item: NSMenuItem) {
            guard let t = item.representedObject as? Track else { return }
            parent.onSongRadio?(t)
        }

        @objc func menuMoveToArtistFolder(_ item: NSMenuItem) {
            guard let t = item.representedObject as? Track else { return }
            parent.onMoveToArtistFolder?(t)
        }

        @objc func menuRemove(_ item: NSMenuItem) {
            guard let targets = item.representedObject as? [Track], !targets.isEmpty else { return }
            // NSAlert since AppKit can't raise a SwiftUI dialog. Same wording as ⌘⌫.
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
        // The sorted rows come back via `update(parent:)`.
        if let binding = parent.sort {
            if let picked = sortPicked(from: tableView.sortDescriptors) {
                binding.wrappedValue = picked
            }
            return
        }
        tracks = sorted(tracks, by: tableView.sortDescriptors.first)
        tableView.reloadData()
        syncSelection(tableView)
    }

    // MARK: - Dragging rows out (-> sidebar playlists)

    /// Prefixed id so the sidebar can tell a song drop from a playlist reorder.
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
            // Monospaced, orange on the playing row.
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
            drawnStatus[track.id] = statusCode(track.id)
            // Clicking the artwork plays on a single click.
            c.onArtworkClick = { [weak self] in self?.play(row: row) }
            c.setHovered((tableView as? MelTableView)?.hoveredRow == row)
            cell = c

        case "artistName":
            // One click target per credited name.
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
            // Relative wording (`AddedDateText`); exact date on the tooltip.
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
                    // The check isn't a toggle: unsaving can delete a file, so it lives in the menu.
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

/// Whether any track table is scrolling. Rows check it before painting a cached
/// cover, so the grey tile shows in both scroll directions. One flag for the app:
/// only one table is under the pointer and cells can't see their scroll view.
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

/// Cached SF Symbols, since cells recycle constantly while scrolling.
/// Tinting stays per view, so sharing is safe.
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
    private let editBadge    = NSTextField(labelWithString: "\u{2009}EDIT\u{2009}")
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
    /// So hovering a fetching row doesn't swap the spinner for a play icon.
    private var isResolving = false

    /// Per cell (cells recycle), so cancelling here skips decodes for rows flicked past.
    private var artworkTask: Task<Void, Never>?
    /// How long a row must be still before its cover is worth fetching.
    private static let settleDelay: Duration = .milliseconds(280)
    /// Whole track, since mix rows carry their cover inline.
    private var currentTrack: Track?
    /// Guards against a load finishing after the cell was reused;
    /// `Task.isCancelled` alone can race.
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
        titleStack.addArrangedSubview(editBadge)

        // Same look as `MixEditBadge`. The title truncates first.
        editBadge.font            = .systemFont(ofSize: 8, weight: .heavy)
        editBadge.textColor       = .windowBackgroundColor
        editBadge.drawsBackground = true
        editBadge.backgroundColor = .secondaryLabelColor
        editBadge.wantsLayer      = true
        editBadge.layer?.cornerRadius  = 3
        editBadge.layer?.masksToBounds = true
        editBadge.setAccessibilityLabel("Edit")
        editBadge.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Waveform "now playing" dot
        waveView.image              = RowSymbol.image("waveform")
        waveView.contentTintColor   = NSColor(red: 1.0, green: 107/255, blue: 0, alpha: 1)
        waveView.isHidden           = true

        // Play badge: scrim + triangle, shown on hover.
        playBadge.wantsLayer            = true
        playBadge.layer?.backgroundColor = NSColor(white: 0, alpha: 0.55).cgColor
        playBadge.layer?.cornerRadius    = 3
        playBadge.isHidden               = true

        playIcon.image            = RowSymbol.image("play.fill", description: "Play")
        playIcon.contentTintColor = .white
        playIcon.imageScaling     = .scaleProportionallyUpOrDown

        // Spinner scrim for songs being found online, same as `MixSongRow` / `TrackRowView`.
        loadingBadge.wantsLayer             = true
        loadingBadge.layer?.backgroundColor = NSColor(white: 0, alpha: 0.55).cgColor
        loadingBadge.layer?.cornerRadius    = 3
        loadingBadge.isHidden               = true

        spinner.style        = .spinning
        spinner.controlSize  = .small
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        // Dark so the spinner stays light on the scrim.
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

    /// Idempotent; a table only uses one set of metrics.
    func apply(metrics m: NativeTrackTable.RowMetrics) {
        guard m != metrics else { return }
        metrics = m
        artworkLeading.constant = m.leading
        artworkWidth.constant   = m.artwork
        artworkHeight.constant  = m.artwork
        titleLeading.constant   = m.titleGap
        // Keep the corner in proportion with the artwork.
        let radius = m.artwork >= 40 ? CGFloat(5) : CGFloat(3)
        artworkView.layer?.cornerRadius  = radius
        playBadge.layer?.cornerRadius    = radius
        loadingBadge.layer?.cornerRadius = radius
    }

    // MARK: - Deferred artwork

    /// Never decodes on the main thread. A cached cover paints immediately,
    /// a miss shows the grey tile until it loads.
    private func loadArtwork(for track: Track) {
        artworkTask?.cancel()
        artworkTask = nil
        artworkToken &+= 1
        currentTrack = track
        let token   = artworkToken
        let bucket  = ArtworkDecodeCache.bucket(forPointSize: metrics.artwork)
        let scrolling = RowScrollState.shared.isScrolling

        // Inline bytes win (mix/Discover rows aren't in the store), same as `displayArtwork`.
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

        // Hide even cached covers while scrolling so up and down look the same.
        if !scrolling, let hit = ArtworkImageLoader.shared.cached(source, bucket: bucket) {
            showArtwork(hit)
            return
        }

        showPlaceholder()
        observeScrollEnd()
        artworkTask = Task { [weak self] in
            // Settle delay: rows only passing through are cancelled before loading.
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

    /// Grey tile, not the music note: the note means "no cover".
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
        // Kept on the cell too, since `setHovered` arrives without a reconfigure.
        self.isResolving = isResolving
        loadingBadge.isHidden = !isResolving
        if isResolving {
            spinner.startAnimation(nil)
            playBadge.isHidden = true
        } else {
            spinner.stopAnimation(nil)
        }

        loadArtwork(for: track)

        // Title + colour
        titleLabel.stringValue = track.title
        editBadge.isHidden     = track.origin != .edit
        titleLabel.font        = .systemFont(ofSize: metrics.titleSize,
                                             weight: isCurrent ? .bold : metrics.titleWeight)
        // Bold already marks the current track; `.labelColor` keeps it readable in light mode.
        titleLabel.textColor   = .labelColor

        // Glyph/colour per state comes from TrackAvailability, shared with SwiftUI rows.
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

        waveView.isHidden = !isCurrent
        waveView.removeAllSymbolEffects()
        if isCurrent && isPlaying {
            waveView.addSymbolEffect(.pulse, options: .repeating)
        }
    }

    func setHovered(_ hovered: Bool) {
        // Keep the spinner on hover while resolving.
        playBadge.isHidden = !hovered || isResolving
    }

    /// Only the artwork claims a click; the rest selects as normal.
    func clickAction(at point: NSPoint) -> (() -> Void)? {
        guard artworkView.frame.contains(point) else { return nil }
        return onArtworkClick
    }
}

// MARK: - Cells that claim their own clicks

/// A cell with a click target more specific than the row. The table asks the cell
/// before selecting, since view-based NSTableView never lets plain views see mouseDown.
private protocol TrackCellClickTarget: NSView {
    /// `point` is in the cell's own coordinates. Nil hands the click back.
    func clickAction(at point: NSPoint) -> (() -> Void)?
}

extension TrackTitleCell: TrackCellClickTarget {}
extension TrackLinkCell:  TrackCellClickTarget {}
extension TrackRowActionCell: TrackCellClickTarget {}

// MARK: - TrackLinkCell  (comma-separated, individually clickable names)

/// Artist/Album column: each name is its own link, underlined on hover only.
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

    /// `onSelect` gets the clicked name's index. Nil = plain text.
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

    /// Reuses the labels already there, since scrolling hands this cell a new row every few frames.
    private func rebuild() {
        var labels = stack.arrangedSubviews.compactMap { $0 as? LinkLabel }
        while labels.count > names.count { labels.removeLast().removeFromSuperview() }

        // The ", " rides on the preceding name so it truncates with it.
        for (index, name) in names.enumerated() {
            let text = index < names.count - 1 ? name + ", " : name
            if index < labels.count {
                labels[index].update(text: text, font: font, color: color)
                continue
            }
            let label = LinkLabel(text: text, font: font, color: color, isLink: true)
            // Later names truncate first.
            label.setContentCompressionResistancePriority(
                NSLayoutConstraint.Priority(rawValue: 250 - Float(index)), for: .horizontal)
            stack.addArrangedSubview(label)
        }
    }

    // MARK: Clicks
    // Non-editable text fields don't hit-test, so the cell works out which name was
    // clicked. Clicks arrive via the table; the gap after the last name returns nil.

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
            // Set on every configure; only having an action or not changes anything.
            guard (oldValue == nil) != (onClick == nil) else { return }
            // A reused row with no action drops its hover styling.
            if onClick == nil, isHovering { isHovering = false }
            restyle()
            window?.invalidateCursorRects(for: self)
        }
    }

    private var text:  String
    private var base:  NSColor
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

    func update(text newText: String, font newFont: NSFont, color newColor: NSColor) {
        text = newText
        base = newColor
        font = newFont
        restyle()
    }

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
        // .inVisibleRect follows the bounds on its own, so one area is enough.
        guard trackingAreas.isEmpty else { return }
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
    // Anything other than a plain left click on a link goes up the chain, so
    // ⌘/⇧-click and double click still work.

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

    /// Right-click belongs to the row.
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
// `fitsContent` scroll view: never scrolls, so wheel events go straight up
// the responder chain to the page.

private final class PassthroughScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

// MARK: - TrackRowActionCell  (the heart / save column)

/// Heart or save glyph between Date Added and Duration. The "on" state always
/// shows; the "off" state only on hover. Same rule as iOS.
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
            case .notSaved:      return "Add to Liked Songs"
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
        icon.image = RowSymbol.image(state.symbol, description: state.label)
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

    /// Only clickable while the glyph shows. A filled check hands the click back.
    func clickAction(at point: NSPoint) -> (() -> Void)? {
        guard !icon.isHidden, state != .saved else { return nil }
        return onToggle
    }
}

// MARK: - MacListRowView  (flat rows, hover highlight, orange selection)
// Flat rows with a hover highlight instead of zebra striping.

private final class MacListRowView: NSTableRowView {

    private var isHovered = false

    func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        needsDisplay = true
    }

    // We draw our own selection; `.normal` stops AppKit turning the text white.
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override var isEmphasized: Bool {
        get { false }
        set { }
    }

    /// Translucent so it works over any background.
    private static let hoverColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.07)
            : NSColor(white: 0, alpha: 0.05)
    }

    // Brand orange at 22%, matching the sidebar.
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

/// The column header strip. Never calls `super.draw`: the stock header paints
/// a translucent slab that picks up the window background.
/// Fills with the page colour, the backdrop colour's field and the artwork wash
/// sampled at this height (see `ArtworkWashGradient`), then titles, column rules (the only resize hint) and a bottom hairline.
/// Only `draw` is overridden; events are untouched.
/// With hardware acceleration the field is a shader in a subview, so everything above it
/// moves to a second subview (a view's own drawing sits under its subviews).
final class MelTableHeaderView: NSTableHeaderView {

    private var washObserver: AnyCancellable?
    private var fieldHost: FieldHost?
    private var titles: Titles?

    override var isOpaque: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { washObserver = nil; return }
        if HardwareAcceleration.isOn, fieldHost == nil {
            let host = FieldHost(rootView: BackdropFieldView(origin: .zero, size: .zero))
            let titles = Titles()
            titles.header = self
            for view in [host, titles] as [NSView] {
                view.frame = bounds
                view.autoresizingMask = [.width, .height]
                addSubview(view)
            }
            (fieldHost, self.titles) = (host, titles)
        }
        // Repaint when the wash changes (new page or late cover colours) or the backdrop moves.
        washObserver = ArtworkWashTint.shared.changed
            .merge(with: BackdropRenderer.shared.changed)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.needsDisplay = true
                self?.placeField()
            }
    }

    /// The band's offset from the window top changes when the banner above re-wraps.
    override func layout() {
        super.layout()
        needsDisplay = true
        placeField()
    }

    override var needsDisplay: Bool {
        didSet { if needsDisplay { titles?.needsDisplay = true } }
    }

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        super.setNeedsDisplay(invalidRect)
        titles?.setNeedsDisplay(invalidRect)
    }

    /// Lines the shader's field up with the window, as `drawBackdrop` does.
    private func placeField() {
        guard let fieldHost, let host = window?.contentView else { return }
        let field = convert(host.bounds, from: host)
        let view = BackdropFieldView(origin: CGPoint(x: -field.minX, y: -field.minY), size: field.size)
        if fieldHost.rootView.origin != view.origin || fieldHost.rootView.size != view.size {
            fieldHost.rootView = view
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // `bounds`, not `dirtyRect`, or a partial repaint leaves gaps.
        Self.ground.setFill()
        bounds.fill()
        if titles == nil { drawContent(dirtyRect) }
    }

    /// Everything over the page colour: the CPU backdrop, wash, titles and rules.
    fileprivate func drawContent(_ dirtyRect: NSRect) {
        drawBackdrop()
        if let wash = washColour() {
            wash.setFill()
            bounds.fill(using: .sourceOver)
        }

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

            // Sort arrow; normally `super` draws it.
            if let arrow = table.indicatorImage(in: spec) {
                let size = arrow.size
                let box  = NSRect(x: text.maxX - size.width,
                                  y: text.midY - size.height / 2,
                                  width: size.width, height: size.height)
                arrow.draw(in: box)
                text.size.width -= size.width + 4
            }

            // Centred by measurement; the stock cell sits high without its bezel.
            let height = label.size().height
            label.draw(in: NSRect(x: text.minX, y: text.midY - height / 2,
                                  width: max(0, text.width), height: height))
        }

        NSColor(Color.mixSeparator).setFill()

        // Divider on every boundary but the last, inset top and bottom.
        for column in 0..<(table.numberOfColumns - 1) {
            let edge = headerRect(ofColumn: column).maxX
            guard edge < bounds.maxX else { continue }
            NSRect(x: edge - 0.5, y: bounds.minY + 6,
                   width: 1, height: bounds.height - 12).fill()
        }

        // One hairline, so the list still starts somewhere.
        NSRect(x: bounds.minX, y: bounds.maxY - 0.5, width: bounds.width, height: 0.5).fill()
    }

    private final class FieldHost: NSHostingView<BackdropFieldView> {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    private final class Titles: NSView {
        weak var header: MelTableHeaderView?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) { header?.drawContent(dirtyRect) }
    }

    // MARK: The page's colour, at this height

    private static var ground: NSColor {
        NSColor(Color.mixBackground).usingColorSpace(.sRGB) ?? NSColor(Color.mixBackground)
    }

    /// The slice of the window-wide field behind this band, as `MixPageBackground` draws it.
    private func drawBackdrop() {
        guard let field = BackdropRenderer.shared.image, let host = window?.contentView else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        NSGraphicsContext.saveGraphicsState()
        bounds.clip()
        NSImage(cgImage: field, size: .zero)
            .draw(in: convert(host.bounds, from: host), from: .zero, operation: .sourceOver,
                  fraction: MixPageBackground.opacity(dark: dark), respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The wash sampled at the band's centre, un-premultiplied for a source-over fill.
    private func washColour() -> NSColor? {
        let tint = ArtworkWashTint.shared
        guard tint.stops.count == 2, let host = window?.contentView else { return nil }

        // The ramp starts at the top of the content (both columns ignore the safe area).
        let here = convert(bounds, to: host)
        let top  = host.isFlipped ? here.minY : host.bounds.height - here.maxY
        let t    = (top + bounds.height / 2) / ArtworkWash.height
        guard t >= 0, t < 1, let (lo, hi) = Self.bracket(t) else { return nil }

        let span = hi.location - lo.location
        let f    = span > 0 ? (t - lo.location) / span : 0

        guard let a = NSColor(tint.stops[lo.stop]).usingColorSpace(.sRGB),
              let b = NSColor(tint.stops[hi.stop]).usingColorSpace(.sRGB)
        else { return nil }

        // Premultiplied so stops with different opacity blend cleanly.
        let strength = CGFloat(tint.intensity)
        let aA = lo.opacity * strength
        let bA = hi.opacity * strength
        let alpha = aA + (bA - aA) * f
        guard alpha > 0 else { return nil }

        func channel(_ ca: CGFloat, _ cb: CGFloat) -> CGFloat {
            (ca * aA + (cb * bA - ca * aA) * f) / alpha
        }

        return NSColor(srgbRed: channel(a.redComponent,   b.redComponent),
                       green:   channel(a.greenComponent, b.greenComponent),
                       blue:    channel(a.blueComponent,  b.blueComponent),
                       alpha:   alpha)
    }

    /// The `ArtworkWashGradient` stops as data. Keep the two in sync by hand.
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
    /// (previousRow, newRow); either may be -1 for "none".
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

    /// A plain single click goes to the cell first (play badge, links), else selects.
    /// Modified and repeated clicks are never offered.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1,
           event.modifierFlags.isDisjoint(with: [.command, .shift, .option, .control]),
           let action = clickAction(for: event) {
            action()
            return
        }
        // Clicking below the last row clears the selection.
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

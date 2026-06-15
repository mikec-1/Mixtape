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
//   Single click   — select row(s)
//   Double click   — play immediately
//   Return key     — play first selected
//   Right-click    — context menu (Play Now / Play Next / Add to Queue / Get Info)
//   Column header  — sort ascending / descending (Title · Artist · Album)

#if os(macOS)
import AppKit
import SwiftUI

// MARK: - NativeTrackTable

struct NativeTrackTable: NSViewRepresentable {

    // MARK: Inputs

    let  tracks:         [Track]
    let  currentTrackID: Track.ID?
    let  isPlaying:      Bool
    @Binding var selectedIDs: Set<Track.ID>

    // MARK: Callbacks (all called on the main thread)

    var onPlay:               (Track, [Track]) -> Void
    var onPlayNext:           (Track)          -> Void
    var onAddToQueue:         (Track)          -> Void
    var onGetInfo:            (Track)          -> Void
    var onRemove:             (Track)          -> Void
    var onToggleFavourite:    (Track)          -> Void = { _ in }
    var onAddToPlaylist:      (Track, UUID)    -> Void = { _, _ in }
    /// Called when the user picks "Move to Artist Folder…" from the context menu.
    var onMoveToArtistFolder: ((Track) -> Void)?

    // MARK: Data for context-menu enrichment
    var isFavourited: (Track.ID) -> Bool = { _ in false }
    var playlists:    [Playlist]         = []
    var downloadStatus: (Track.ID) -> DownloadStatus = { _ in .notDownloaded }
    var onRemoveDownload: ((Track.ID) -> Void)? = nil
    var onSaveToDisk:         ((Track) -> Void)? = nil

    /// The current UI zoom scale (from MacAppState.uiScale).
    /// Passed through so AppKit layers can render at the correct pixel density
    /// before `scaleEffect` upscales them — prevents blurriness at zoom > 1.
    var scale: CGFloat = 1.0

    // MARK: - NSViewRepresentable

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = MelTableView()
        tv.style                              = .inset
        tv.usesAlternatingRowBackgroundColors = false
        tv.allowsMultipleSelection            = true
        tv.rowHeight                          = 46
        tv.columnAutoresizingStyle            = .uniformColumnAutoresizingStyle
        tv.backgroundColor                    = .clear
        tv.doubleAction                       = #selector(Coordinator.rowDoubleClicked(_:))
        tv.target                             = context.coordinator
        tv.delegate                           = context.coordinator
        tv.dataSource                         = context.coordinator

        // Right-click menu and Return key forwarded to coordinator
        tv.menuBuilder    = { [weak c = context.coordinator] row in c?.buildContextMenu(row: row) }
        tv.onReturnKey    = { [weak c = context.coordinator] in    c?.playFirstSelected() }

        for spec in columnSpecs {
            let col     = NSTableColumn(identifier: .init(spec.id))
            col.title   = spec.title
            col.minWidth = spec.minW
            col.width   = spec.width
            if spec.sortKey != nil {
                col.sortDescriptorPrototype = NSSortDescriptor(key: spec.sortKey!, ascending: true)
            }
            tv.addTableColumn(col)
        }

        context.coordinator.tableView = tv

        let sv = NSScrollView()
        sv.documentView        = tv
        sv.hasVerticalScroller = true
        sv.autohidesScrollers  = true
        sv.borderType          = .noBorder
        sv.drawsBackground     = false

        // Apply initial contentsScale so the table renders at the right pixel
        // density if a non-default zoom is already active on first appearance.
        let initialCS = (NSScreen.main?.backingScaleFactor ?? 2.0) * scale
        sv.wantsLayer = true
        sv.layer?.contentsScale = initialCS
        tv.wantsLayer = true
        tv.layer?.contentsScale = initialCS

        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        context.coordinator.update(parent: self)
    }

    // MARK: - Column Specs

    private struct ColSpec {
        let id: String; let title: String
        let minW: CGFloat; let width: CGFloat
        let sortKey: String?
    }

    private let columnSpecs: [ColSpec] = [
        .init(id: "title",       title: "Title",      minW: 160, width: 280, sortKey: "title"),
        .init(id: "artistName",  title: "Artist",     minW:  80, width: 160, sortKey: "artistName"),
        .init(id: "albumTitle",  title: "Album",      minW:  80, width: 160, sortKey: "albumTitle"),
        .init(id: "dateAdded",   title: "Date Added", minW:  70, width: 100, sortKey: "dateImported"),
        .init(id: "duration",    title: "Duration",   minW:  50, width:  62, sortKey: nil),
    ]
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
        private var lastTrackIDs:    [Track.ID] = []
        private var lastDisplayHash: Int        = 0
        private var lastScale:       CGFloat    = 1.0

        // Prevents a SwiftUI→AppKit→SwiftUI selection feedback loop.
        private var suppressSelectionSync = false

        init(parent: NativeTrackTable) {
            self.parent = parent
            self.tracks = parent.tracks
        }

        // MARK: - Update (called from updateNSView on every SwiftUI re-render)

        func update(parent: NativeTrackTable) {
            let prev  = self.parent
            self.parent = parent
            guard let tv = tableView else { return }

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

            // Re-apply sort to new data when the track set OR displayed content changed.
            // IDs alone don't detect enrichment edits (title/artist/album change, same ID).
            let newIDs      = parent.tracks.map(\.id)
            let newHash     = displayHash(of: parent.tracks)
            let needsReload = newIDs != lastTrackIDs || newHash != lastDisplayHash || scaleChanged
            if needsReload {
                lastTrackIDs    = newIDs
                lastDisplayHash = newHash
                tracks = sorted(parent.tracks, by: tv.sortDescriptors.first)
                tv.reloadData()
            } else if prev.currentTrackID != parent.currentTrackID
                    || prev.isPlaying      != parent.isPlaying {
                // Only the playing state changed — refresh the title column cheaply.
                let visible = tv.rows(in: tv.visibleRect)
                if visible.location != NSNotFound && visible.length > 0 {
                    tv.reloadData(
                        forRowIndexes: IndexSet(integersIn: visible.location ..< NSMaxRange(visible)),
                        columnIndexes: IndexSet(integer: 0)
                    )
                }
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
            for t in source {
                h.combine(t.id)
                h.combine(t.title)
                h.combine(t.artistName)
                h.combine(t.albumTitle)
                h.combine(t.artworkData != nil)
                
                let status = parent.downloadStatus(t.id)
                switch status {
                case .notDownloaded: h.combine(0)
                case .downloading:   h.combine(1)
                case .downloaded:    h.combine(2)
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

        private func sorted(_ source: [Track], by d: NSSortDescriptor?) -> [Track] {
            guard let d else { return source }
            return source.sorted { a, b in
                switch d.key {
                case "title":        return d.ascending ? a.title        < b.title        : a.title        > b.title
                case "artistName":   return d.ascending ? a.artistName   < b.artistName   : a.artistName   > b.artistName
                case "albumTitle":   return d.ascending ? a.albumTitle   < b.albumTitle   : a.albumTitle   > b.albumTitle
                case "dateImported": return d.ascending ? a.dateImported < b.dateImported : a.dateImported > b.dateImported
                default:             return false
                }
            }
        }

        // Shared short-date formatter — "Jun 10, 2026"
        private static let dateFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .none
            return f
        }()

        // MARK: - Playback helpers

        func playFirstSelected() {
            guard let id = parent.selectedIDs.first,
                  let track = tracks.first(where: { $0.id == id }) else { return }
            parent.onPlay(track, tracks)
        }

        // MARK: - Context Menu

        func buildContextMenu(row: Int) -> NSMenu? {
            guard row >= 0, row < tracks.count else { return nil }
            let track = tracks[row]

            // Right-clicking an unselected row selects it.
            if let tv = tableView, !tv.selectedRowIndexes.contains(row) {
                tv.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }

            let menu  = NSMenu()
            let favoured = parent.isFavourited(track.id)

            // Playback
            menu.addItem(menuItem("Play Now",    action: #selector(menuPlayNow(_:)),  track: track))
            menu.addItem(menuItem("Play Next",   action: #selector(menuPlayNext(_:)), track: track))
            menu.addItem(menuItem("Add to Queue",action: #selector(menuAddQueue(_:)), track: track))
            menu.addItem(.separator())

            // Favourite toggle
            let favTitle = favoured ? "Remove from Favourites" : "Add to Favourites"
            let favIcon  = NSImage(systemSymbolName: favoured ? "heart.fill" : "heart", accessibilityDescription: nil)
            let favItem  = menuItem(favTitle, action: #selector(menuToggleFavourite(_:)), track: track)
            favItem.image = favIcon
            menu.addItem(favItem)

            // Add to Playlist submenu
            let targetPlaylists = parent.playlists.filter { !$0.isAllSongs && !$0.isDeleted }
            if !targetPlaylists.isEmpty {
                let sub = NSMenu()
                for pl in targetPlaylists {
                    let item = NSMenuItem(title: pl.name, action: #selector(menuAddToPlaylist(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = AddToPlaylistPayload(track: track, playlistID: pl.id)
                    sub.addItem(item)
                }
                let subItem = NSMenuItem(title: "Add to Playlist", action: nil, keyEquivalent: "")
                subItem.submenu = sub
                menu.addItem(subItem)
            }

            menu.addItem(.separator())
            menu.addItem(menuItem("Get Info", action: #selector(menuGetInfo(_:)), track: track))

            // Move to Artist Folder — shown only when a handler is wired up
            if parent.onMoveToArtistFolder != nil {
                let moveItem = menuItem(
                    "Move to Artist Folder\u{2026}",
                    action: #selector(menuMoveToArtistFolder(_:)),
                    track: track
                )
                moveItem.image = NSImage(systemSymbolName: "person.badge.plus", accessibilityDescription: nil)
                menu.addItem(moveItem)
            }

            if parent.onSaveToDisk != nil {
                let saveItem = menuItem("Save to Disk", action: #selector(menuSaveToDisk(_:)), track: track)
                saveItem.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
                menu.addItem(saveItem)
            }

            menu.addItem(.separator())

            let status = parent.downloadStatus(track.id)
            if status != .notDownloaded {
                let removeDownloadItem = menuItem("Remove Download", action: #selector(menuRemoveDownload(_:)), track: track)
                removeDownloadItem.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
                menu.addItem(removeDownloadItem)
                menu.addItem(.separator())
            }

            // Remove from library (destructive)
            let removeItem = menuItem("Remove from Library", action: #selector(menuRemove(_:)), track: track)
            removeItem.attributedTitle = NSAttributedString(
                string: "Remove from Library",
                attributes: [.foregroundColor: NSColor.systemRed]
            )
            menu.addItem(removeItem)
            return menu
        }

        private func menuItem(_ title: String, action: Selector, track: Track) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = track
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
            guard let t = item.representedObject as? Track else { return }
            parent.onPlay(t, tracks)
        }

        @objc func menuPlayNext(_ item: NSMenuItem) {
            guard let t = item.representedObject as? Track else { return }
            parent.onPlayNext(t)
        }

        @objc func menuAddQueue(_ item: NSMenuItem) {
            guard let t = item.representedObject as? Track else { return }
            parent.onAddToQueue(t)
        }

        @objc func menuGetInfo(_ item: NSMenuItem) {
            guard let t = item.representedObject as? Track else { return }
            parent.onGetInfo(t)
        }

        @objc func menuToggleFavourite(_ item: NSMenuItem) {
            guard let t = item.representedObject as? Track else { return }
            parent.onToggleFavourite(t)
        }

        @objc func menuAddToPlaylist(_ item: NSMenuItem) {
            guard let payload = item.representedObject as? AddToPlaylistPayload else { return }
            let playlistID = payload.playlistID
            if parent.selectedIDs.contains(payload.track.id) {
                let selectedTracks = tracks.filter { parent.selectedIDs.contains($0.id) }
                for track in selectedTracks {
                    parent.onAddToPlaylist(track, playlistID)
                }
            } else {
                parent.onAddToPlaylist(payload.track, playlistID)
            }
        }

        @objc func menuMoveToArtistFolder(_ item: NSMenuItem) {
            guard let t = item.representedObject as? Track else { return }
            parent.onMoveToArtistFolder?(t)
        }

        @objc func menuRemove(_ item: NSMenuItem) {
            guard let t = item.representedObject as? Track else { return }
            // Confirm before deleting — standard macOS alert.
            let alert             = NSAlert()
            alert.messageText     = "Remove \"\(t.title)\" from your library?"
            alert.informativeText = "The audio file will be deleted from this device."
            alert.alertStyle      = .warning
            alert.addButton(withTitle: "Remove")
            alert.addButton(withTitle: "Cancel")
            alert.buttons.first?.hasDestructiveAction = true
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            parent.onRemove(t)
        }

        @objc func menuRemoveDownload(_ item: NSMenuItem) {
            guard let t = item.representedObject as? Track else { return }
            if parent.selectedIDs.contains(t.id) {
                let selectedTracks = tracks.filter { parent.selectedIDs.contains($0.id) }
                for track in selectedTracks {
                    parent.onRemoveDownload?(track.id)
                }
            } else {
                parent.onRemoveDownload?(t.id)
            }
        }

        @objc func menuSaveToDisk(_ item: NSMenuItem) {
            guard let t = item.representedObject as? Track else { return }
            if parent.selectedIDs.contains(t.id) {
                let selectedTracks = tracks.filter { parent.selectedIDs.contains($0.id) }
                for track in selectedTracks {
                    parent.onSaveToDisk?(track)
                }
            } else {
                parent.onSaveToDisk?(t)
            }
        }
    }
}

// MARK: - NSTableViewDataSource

extension NativeTrackTable.Coordinator: NSTableViewDataSource {

    func numberOfRows(in tableView: NSTableView) -> Int { tracks.count }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange old: [NSSortDescriptor]) {
        tracks = sorted(tracks, by: tableView.sortDescriptors.first)
        tableView.reloadData()
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

        case "title":
            let c = tableView.makeView(withIdentifier: .init("title"), owner: nil)
                    as? TrackTitleCell ?? TrackTitleCell()
            c.configure(track: track, isCurrent: isCurrent, isPlaying: parent.isPlaying, downloadStatus: parent.downloadStatus(track.id))
            cell = c

        case "artistName":
            cell = textCell(tableView, id: colID, value: track.artistName,
                            color: .secondaryLabelColor, size: 13)

        case "albumTitle":
            cell = textCell(tableView, id: colID, value: track.albumTitle,
                            color: .secondaryLabelColor, size: 13)

        case "dateAdded":
            cell = textCell(tableView, id: colID,
                            value: Self.dateFormatter.string(from: track.dateImported),
                            color: .secondaryLabelColor, size: 13)

        case "duration":
            let c = textCell(tableView, id: colID, value: track.formattedDuration,
                             color: .tertiaryLabelColor, size: 12)
            c.textField?.font      = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            c.textField?.alignment = .right
            cell = c

        default:
            cell = nil
        }

        if let cell { applyContentsScale(cs, to: cell) }
        return cell
    }

    // Custom alternating row backgrounds: even = #121212, odd = #1C1C1C.
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = AlternatingRowView()
        view.isEvenRow = (row % 2 == 0)
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

private final class TrackTitleCell: NSTableCellView {

    private let artworkView  = NSImageView()
    private let downloadView = NSImageView()
    private let titleLabel   = NSTextField()
    private let titleStack   = NSStackView()
    private let waveView     = NSImageView()

    override init(frame: NSRect) { super.init(frame: frame); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

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

        [artworkView, titleStack, waveView].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }

        NSLayoutConstraint.activate([
            artworkView.leadingAnchor .constraint(equalTo: leadingAnchor, constant: 8),
            artworkView.centerYAnchor .constraint(equalTo: centerYAnchor),
            artworkView.widthAnchor   .constraint(equalToConstant: 34),
            artworkView.heightAnchor  .constraint(equalToConstant: 34),

            titleStack.leadingAnchor .constraint(equalTo: artworkView.trailingAnchor, constant: 10),
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

    func configure(track: Track, isCurrent: Bool, isPlaying: Bool, downloadStatus: DownloadStatus) {
        // Artwork
        if let data = track.artworkData, let img = NSImage(data: data) {
            artworkView.image = img
            artworkView.contentTintColor = nil
        } else {
            artworkView.image            = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)
            artworkView.contentTintColor = .tertiaryLabelColor
        }

        // Title + colour
        titleLabel.stringValue = track.title
        titleLabel.font        = isCurrent ? .boldSystemFont(ofSize: 14) : .systemFont(ofSize: 14)
        titleLabel.textColor   = isCurrent ? .white : .labelColor

        // Download view
        downloadView.removeAllSymbolEffects()
        switch downloadStatus {
        case .downloaded:
            downloadView.isHidden = false
            downloadView.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)
            downloadView.contentTintColor = .systemGreen
        case .downloading:
            downloadView.isHidden = false
            downloadView.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
            downloadView.contentTintColor = NSColor(red: 1.0, green: 107/255, blue: 0, alpha: 1)
            downloadView.addSymbolEffect(.pulse, options: .repeating)
        case .notDownloaded:
            downloadView.isHidden = true
            downloadView.image = nil
        }

        // Now-playing indicator — remove any stale effect then re-add if needed.
        waveView.isHidden = !isCurrent
        waveView.removeAllSymbolEffects()
        if isCurrent && isPlaying {
            waveView.addSymbolEffect(.pulse, options: .repeating)
        }
    }
}

// MARK: - AddToPlaylistPayload  (carries track + target playlist ID through ObjC representedObject)

private final class AddToPlaylistPayload: NSObject {
    let track:      Track
    let playlistID: UUID
    init(track: Track, playlistID: UUID) {
        self.track      = track
        self.playlistID = playlistID
    }
}

// MARK: - AlternatingRowView  (explicit dark/darker alternating backgrounds + orange selection)

private final class AlternatingRowView: NSTableRowView {
    var isEvenRow: Bool = true

    // Even rows match the app background (#121212); odd rows are slightly lighter (#1C1C1C).
    private static let evenColor      = NSColor(red: 18/255,  green: 18/255,  blue: 18/255,  alpha: 1)
    private static let oddColor       = NSColor(red: 28/255,  green: 28/255,  blue: 28/255,  alpha: 1)
    // App primary orange (#FF6B00) at 22% opacity — matches the sidebar row highlight style.
    private static let selectionColor = NSColor(red: 1.0,     green: 107/255, blue: 0,        alpha: 0.22)

    override func drawBackground(in dirtyRect: NSRect) {
        (isEvenRow ? Self.evenColor : Self.oddColor).setFill()
        dirtyRect.fill()
    }

    /// Replace the system accent-colour selection fill with the app's orange.
    override func drawSelection(in dirtyRect: NSRect) {
        Self.selectionColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 2), xRadius: 6, yRadius: 6).fill()
    }
}

// MARK: - MelTableView  (NSTableView subclass for right-click menu + Return key)

final class MelTableView: NSTableView {

    var menuBuilder: ((Int) -> NSMenu?)?
    var onReturnKey: (() -> Void)?

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
}

#endif

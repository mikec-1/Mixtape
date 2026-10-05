// The Mac editor covers the whole window, like a music app: transport and Save on top, the song as a
// timeline with its parts above one lane per stem, and the sound settings in a panel on the right.

#if os(macOS)
import SwiftUI
import AppKit
import Combine

extension SongEditor {

    static let laneHeaderWidth: CGFloat = 210
    static let rulerHeight: CGFloat = 28
    static let partsHeight: CGFloat = 52

    var studio: some View {
        VStack(spacing: 0) {
            studioBar
            if let loadError {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 30)).foregroundStyle(Color.mixTextSecondary)
                    Text(loadError).font(.mixBody).foregroundStyle(Color.mixTextPrimary)
                    Button("Close") { close() }.controlSize(.large)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    timeline
                    Rectangle().fill(Color.mixSeparator).frame(width: 1)
                    inspector
                }
                statusBar
            }
        }
        .background(MixPageBackground())
        .overlay { if let saved { savedCard(saved) } }
        .confirmationDialog("Leave without saving?", isPresented: $confirmingClose) {
            Button("Discard Edit", role: .destructive) { close() }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("Your changes to this song will be lost.")
        }
        // Takes the keyboard from whatever list had it underneath.
        .onAppear { DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) } }
        .onDisappear { undos?.removeAllActions(withTarget: preview) }
        .onChange(of: snapshot) { old, new in record(old, new) }
        .onChange(of: preview.position) { old, new in follow(old, new) }
        // View > Zoom works on the timeline while the studio is open.
        .onReceive(NotificationCenter.default.publisher(for: .mixZoomIn)) { _ in setZoom(zoom * 2) }
        .onReceive(NotificationCenter.default.publisher(for: .mixZoomOut)) { _ in setZoom(zoom / 2) }
        .onReceive(NotificationCenter.default.publisher(for: .mixActualSize)) { _ in setZoom(1) }
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidCloseUndoGroup)
            .merge(with: NotificationCenter.default.publisher(for: .NSUndoManagerDidUndoChange),
                   NotificationCenter.default.publisher(for: .NSUndoManagerDidRedoChange))) { _ in undoTick += 1 }
    }

    // MARK: - Undo

    /// Everything undo puts back.
    struct Snapshot: Equatable {
        var speed, reverb, bass: Double
        var pitch: Double?
        var levels: [String: Double]
        var sections: [SongEdit.Section]?
    }

    var snapshot: Snapshot {
        Snapshot(speed: speed, reverb: reverb, bass: bass, pitch: pitch, levels: levels, sections: sections)
    }

    /// Changes less than a moment apart, like one slider drag, undo in one step.
    func record(_ old: Snapshot, _ new: Snapshot) {
        if new == restoring { restoring = nil; return }
        guard opened != nil else { return }
        if Date().timeIntervalSince(lastChange) > 0.6 { registerUndo(back: old) }
        lastChange = Date()
    }

    /// The window's undo manager, so Edit > Undo and ⌘Z work, and the Name field keeps its own undo.
    var undos: UndoManager? { undoManager ?? NSApp.keyWindow?.undoManager }

    func registerUndo(back state: Snapshot) {
        undos?.registerUndo(withTarget: preview) { _ in restore(state) }
    }

    func restore(_ state: Snapshot) {
        // Registered while undoing, this becomes the redo.
        registerUndo(back: snapshot)
        lastChange = .distantPast
        guard state != snapshot else { return }
        restoring = state
        speed = state.speed
        reverb = state.reverb
        bass = state.bass
        pitch = state.pitch
        levels = state.levels
        sections = state.sections
    }

    /// Changed since it opened and not saved yet.
    var unsaved: Bool {
        guard saved == nil, let opened, var now = edit, !now.isOriginal else { return false }
        if stemFiles == nil { now.stems = opened.stems }
        return now != opened
    }

    func leave() {
        if unsaved { confirmingClose = true } else { close() }
    }

    // MARK: - Top bar

    var studioBar: some View {
        ZStack {
            WindowDragArea()
            transport
            HStack(spacing: 12) {
                Button(action: leave) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).mixHandCursor()
                .foregroundStyle(Color.mixTextSecondary)
                .keyboardShortcut(.cancelAction)
                .disabled(progress != nil)
                .help("Back to your music (Esc)")
                .accessibilityLabel("Close editor")

                ArtworkThumbnail(data: original?.artworkData,
                                 artworkRef: .track(original?.id ?? track.id),
                                 size: 32, cornerRadius: 5, placeholder: MixtapeIcons.track)
                VStack(alignment: .leading, spacing: 1) {
                    Text(original?.displayTitle ?? track.displayTitle)
                        .font(.mixLabel.weight(.semibold))
                        .foregroundStyle(Color.mixTextPrimary)
                    Text(original?.artistName ?? track.artistName)
                        .font(.mixCaption)
                        .foregroundStyle(Color.mixTextSecondary)
                }
                .lineLimit(1)
                .frame(maxWidth: 200, alignment: .leading)

                Spacer(minLength: 0)

                // The undo stack isn't observable; this reads the tick its notifications bump.
                let _ = undoTick
                iconButton("arrow.uturn.backward", "Undo (⌘Z)") { undos?.undo() }
                    .disabled(progress != nil || undos?.canUndo != true)
                iconButton("arrow.uturn.forward", "Redo (⇧⌘Z)") { undos?.redo() }
                    .disabled(progress != nil || undos?.canRedo != true)
                    .padding(.trailing, 6)

                if progress != nil {
                    Button("Stop") { saveTask?.cancel() }
                }
                Button(action: save) {
                    HStack(spacing: 6) {
                        if progress != nil { ProgressView().controlSize(.small) }
                        Text(progress != nil ? "Saving…" : "Save")
                    }
                    .font(.mixButtonSmall)
                    .foregroundStyle(canSave ? Color.mixOnAccent : Color.mixTextTertiary)
                    .padding(.horizontal, 16).frame(height: 30)
                    .background(Capsule().fill(canSave ? Color.mixPrimary : Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain).mixHandCursor()
                .keyboardShortcut("s")
                .disabled(!canSave || saved != nil || progress != nil)
                .help("Save as a new song (⌘S)")
            }
            .padding(.leading, 84)
            .padding(.trailing, 14)
        }
        .frame(height: 52)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.mixSeparator).frame(height: 1) }
    }

    /// Skip, play and the time, centred on the window.
    var transport: some View {
        HStack(spacing: 10) {
            Button { naming = false; preview.seek(to: 0) } label: {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).mixHandCursor()
            .foregroundStyle(Color.mixTextSecondary)
            .keyboardShortcut(plainKey(.return))
            .help("Back to the start (Return)")
            .accessibilityLabel("Back to the start")
            skipButton(-5).keyboardShortcut(plainKey(.leftArrow))
            Button { preview.toggle() } label: {
                Image(systemName: preview.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.mixOnAccent)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.mixPrimary))
            }
            .buttonStyle(.plain).mixHandCursor()
            .keyboardShortcut(plainKey(.space))
            .help(preview.isPlaying ? "Pause (Space)" : "Play (Space)")
            .accessibilityLabel(preview.isPlaying ? "Pause preview" : "Play preview")
            skipButton(5).keyboardShortcut(plainKey(.rightArrow))
            Text("\(clock(preview.position / speed)) / \(clock(preview.duration / speed))")
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(Color.mixTextPrimary)
                .padding(.horizontal, 10).frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
        }
        // The saved card owns Return.
        .disabled(source == nil || busy || saved != nil)
    }

    // MARK: - Timeline

    /// Names of the lanes: the song, or its stems once split.
    var lanes: [String?] { stemFiles == nil ? [nil] : SongEdit.stemNames }

    var timeline: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                rulerCorner.frame(height: Self.rulerHeight)
                rowLine
                partsHeader.frame(height: Self.partsHeight)
                rowLine
                ForEach(lanes, id: \.self) { lane in
                    laneHeader(lane).frame(minHeight: 64, maxHeight: .infinity)
                    rowLine
                }
            }
            .frame(width: Self.laneHeaderWidth)
            .background(Color.primary.opacity(0.03))
            Rectangle().fill(Color.mixSeparator).frame(width: 1)
            VStack(spacing: 0) {
                ruler.frame(height: Self.rulerHeight)
                rowLine
                partsStrip.frame(height: Self.partsHeight)
                rowLine
                ForEach(lanes, id: \.self) { lane in
                    laneWave(lane).frame(minHeight: 64, maxHeight: .infinity)
                    rowLine
                }
            }
            .overlay { playhead }
            .overlay(alignment: .bottom) { if zoom > 1 { scroller } }
            .background(TimelineScroll(onScroll: { scrollTo(scroll + $0 / zoom) },
                                       onZoom: { setZoom(zoom * $0, anchor: $1) }))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var rowLine: some View { Rectangle().fill(Color.mixSeparator).frame(height: 1) }

    /// 0...1 across the visible timeline to its time in the arrangement, then play from there.
    func seek(fraction: Double) {
        naming = false
        preview.seek(to: (scroll + fraction / zoom) * preview.duration)
    }

    // MARK: - Zoom

    static let maxZoom = 16.0

    /// 0...1 of the arrangement to 0...1 across the visible timeline.
    func visible(_ fraction: Double) -> Double { (fraction - scroll) * zoom }

    func scrollTo(_ start: Double) {
        scroll = min(max(start, 0), 1 - 1 / zoom)
    }

    /// Zooms around `anchor`, 0...1 across the timeline: the playhead when it's on screen, else the middle.
    func setZoom(_ level: Double, anchor: Double? = nil) {
        let playhead = preview.duration > 0 ? visible(preview.position / preview.duration) : 0
        let a = anchor ?? ((0...1).contains(playhead) ? playhead : 0.5)
        let at = scroll + a / zoom
        zoom = min(max(level, 1), Self.maxZoom)
        scrollTo(at - a / zoom)
    }

    /// Keeps the playhead on screen when it runs off the edge or jumps, but leaves you be if you scrolled away.
    func follow(_ old: TimeInterval, _ new: TimeInterval) {
        guard zoom > 1, preview.duration > 0, dragging == nil else { return }
        let was = visible(old / preview.duration), now = visible(new / preview.duration)
        guard !(0...1).contains(now), (0...1).contains(was) || abs(new - old) > 1 else { return }
        scrollTo(new / preview.duration - 0.05 / zoom)
    }

    /// The part of a whole-arrangement waveform that's on screen.
    func window(_ peaks: [Float]) -> [Float] {
        guard zoom > 1, !peaks.isEmpty else { return peaks }
        let n = Double(peaks.count)
        let from = min(max(Int(scroll * n), 0), peaks.count - 1)
        let to = min(max(Int(((scroll + 1 / zoom) * n).rounded(.up)), from + 1), peaks.count)
        return Array(peaks[from..<to])
    }

    /// Which stretch is on screen. Drag it, or click along it, to move.
    var scroller: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(Color.primary.opacity(0.3))
                    .frame(width: w / zoom)
                    .offset(x: scroll * w)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in scrollTo(v.location.x / w - 0.5 / zoom) })
        }
        .frame(height: 6)
        .padding(.horizontal, 4)
        .padding(.bottom, 2)
        .help("Scroll sideways, or pinch to zoom")
    }

    var canSeek: Bool { source != nil && !busy }

    /// Where each part after the first starts, 0...1.
    var partEdges: [Double] {
        guard !isWholeSong, let sections else { return [] }
        return (1..<max(sections.count, 1)).map { arrangedStart(of: $0) / max(preview.duration, 0.01) }
    }

    var rulerCorner: some View {
        HStack {
            Text("Tracks").font(.mixCaptionBold).foregroundStyle(Color.mixTextSecondary)
            Spacer(minLength: 0)
            if stemFiles != nil {
                Menu {
                    ForEach(SongEdit.stemPresets, id: \.name) { preset in
                        Button(preset.name) {
                            levels = Dictionary(uniqueKeysWithValues: SongEdit.stemNames.map { ($0, preset.stems?[$0] ?? 1) })
                        }
                    }
                } label: {
                    Text("Mix").font(.mixCaptionBold)
                }
                .menuStyle(.button).buttonStyle(.borderless).fixedSize()
                .disabled(busy)
                .help("Quick stem mixes")
            }
        }
        .padding(.horizontal, 12)
    }

    /// Minutes and seconds on the edited song's clock. Click to jump.
    var ruler: some View {
        let total = preview.duration / max(speed, 0.01)
        let from = scroll * total, shown = total / zoom
        return GeometryReader { geo in
            Canvas { ctx, size in
                guard total > 0 else { return }
                let step = [1.0, 2, 5, 10, 15, 30, 60, 120, 300].first { $0 / shown * size.width >= 70 } ?? 600
                var t = (from / step).rounded(.down) * step
                while t <= from + shown {
                    let x = (t - from) / shown * size.width
                    ctx.fill(Path(CGRect(x: x, y: size.height - 8, width: 1, height: 8)),
                             with: .color(Color.mixTextTertiary))
                    ctx.draw(Text(clock(t)).font(.system(size: 10, weight: .medium).monospacedDigit())
                                .foregroundStyle(Color.mixTextSecondary),
                             at: CGPoint(x: x + 4, y: 4), anchor: .topLeading)
                    let half = x + step / 2 / shown * size.width
                    if half >= 0, half < size.width {
                        ctx.fill(Path(CGRect(x: half, y: size.height - 4, width: 1, height: 4)),
                                 with: .color(Color.mixTextTertiary.opacity(0.6)))
                    }
                    t += step
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { at in if canSeek { seek(fraction: at.x / max(geo.size.width, 1)) } }
        }
    }

    var playhead: some View {
        GeometryReader { geo in
            let x = preview.duration > 0 ? visible(preview.position / preview.duration) * geo.size.width : 0
            ZStack(alignment: .topLeading) {
                ForEach(partEdges, id: \.self) { edge in
                    Rectangle().fill(Color.mixPrimary.opacity(0.35)).frame(width: 1)
                        .offset(x: visible(edge) * geo.size.width)
                }
                Rectangle().fill(Color.mixPrimary).frame(width: 1.5).offset(x: x)
                PlayheadCap().fill(Color.mixPrimary).frame(width: 11, height: 7).offset(x: x - 5)
            }
        }
        .clipped()
        .allowsHitTesting(false)
    }

    // MARK: - Parts

    var partsHeader: some View {
        HStack(spacing: 6) {
            Label("Parts", systemImage: "scissors").font(.mixLabel).foregroundStyle(Color.mixTextPrimary)
            Spacer(minLength: 0)
            if sections != nil {
                iconButton("square.split.2x1", "Split at the playhead (⌘T)") { splitAtPlayhead() }
                    .keyboardShortcut("t")
                    .disabled(busy || (sections?.count ?? 0) >= SongEdit.maxSections)
                iconButton("trash", "Remove the part under the playhead (⌫)") { removeCurrentPart() }
                    .keyboardShortcut(plainKey(.delete))
                    .disabled(busy || (sections?.count ?? 0) < 2)
                iconButton("arrow.counterclockwise", "Back to the whole song") { sections = nil }
                    .disabled(busy)
            }
        }
        .padding(.horizontal, 12)
    }

    func removeCurrentPart() {
        guard let sections, sections.count > 1 else { return }
        let now = preview.now
        let i = sections.indices.first { now < arrangedStart(of: $0) + sections[$0].span } ?? sections.count - 1
        self.sections?.remove(at: i)
    }

    @ViewBuilder
    var partsStrip: some View {
        if let sections, preview.duration > 0 {
            GeometryReader { geo in
                let w = geo.size.width
                // Points per second of the arrangement.
                let scale = w * zoom / preview.duration
                ZStack(alignment: .topLeading) {
                    ForEach(Array(sections.enumerated()), id: \.offset) { i, part in
                        let x = (arrangedStart(of: i) - scroll * preview.duration) * scale + (dragging == i ? dragOffset : 0)
                        let full = part.span * scale
                        // Only the part that's on screen, so nothing off screen takes clicks.
                        let from = max(x, 0), to = min(x + full, w)
                        if to - from > 1 || dragging == i {
                            partBlock(i, part, count: sections.count, full: full - 2, cut: from - x)
                                .frame(width: max(to - from - 2, 2))
                                .offset(x: from + 1)
                                .zIndex(dragging == i ? 1 : 0)
                                .gesture(partDrag(i, scale: scale))
                        }
                    }
                    if let i = dragging {
                        let slot = dropSlot(i, scale: scale)
                        if slot != i {
                            let at = arrangedStart(of: slot < i ? slot : slot + 1)
                            Capsule().fill(Color.mixPrimary)
                                .frame(width: 3)
                                .offset(x: (at - scroll * preview.duration) * scale - 1.5)
                                .allowsHitTesting(false)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
                .padding(.vertical, 6)
                .coordinateSpace(name: "parts")
            }
            .disabled(busy)
        } else {
            HStack(spacing: 10) {
                Text("The whole song plays once.").font(.mixCaption).foregroundStyle(Color.mixTextSecondary)
                Button { sections = [SongEdit.Section(start: 0, end: preview.length)] } label: {
                    Label("Cut into Parts", systemImage: "scissors").font(.mixLabel)
                }
                .buttonStyle(.plain).mixHandCursor()
                .foregroundStyle(Color.mixPrimary)
                .disabled(source == nil || busy)
                .help("Then press ⌘T to cut at the playhead, and loop, move or drop the parts")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Where part `i` lands if let go now, counted among the others.
    func dropSlot(_ i: Int, scale: CGFloat) -> Int {
        guard let sections, scale > 0 else { return i }
        let middle = arrangedStart(of: i) + sections[i].span / 2 + dragOffset / scale
        return sections.indices.filter { $0 != i && arrangedStart(of: $0) + sections[$0].span / 2 < middle }.count
    }

    /// Drag a part along the strip to play it somewhere else.
    func partDrag(_ i: Int, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("parts"))
            .onChanged { v in
                naming = false
                dragging = i
                dragOffset = v.translation.width
            }
            .onEnded { _ in
                let slot = dropSlot(i, scale: scale)
                dragging = nil
                dragOffset = 0
                guard slot != i, var moved = sections else { return }
                moved.insert(moved.remove(at: i), at: slot)
                sections = moved
            }
    }

    /// One part on the strip. Click jumps to it, drag moves it, the menu loops, moves, copies or drops it.
    /// `full` is its whole width; `cut` how much of that is off the left edge of the timeline.
    func partBlock(_ i: Int, _ part: SongEdit.Section, count: Int, full: CGFloat, cut: CGFloat) -> some View {
        let starts = arrangedStart(of: i)
        let playing = (starts..<starts + part.span).contains(preview.position)
        let lifted = dragging == i
        return RoundedRectangle(cornerRadius: 6)
            .fill(Color.mixPrimary.opacity(playing || lifted ? 0.32 : 0.16))
            .overlay(alignment: .leading) {
                // A line where each loop starts again.
                ZStack(alignment: .leading) {
                    ForEach(1..<max(part.times, 1), id: \.self) { k in
                        Rectangle().fill(Color.mixPrimary.opacity(0.5)).frame(width: 1)
                            .offset(x: full * Double(k) / Double(part.times) - cut)
                    }
                }
                .allowsHitTesting(false)
            }
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.mixPrimary.opacity(playing || lifted ? 0.9 : 0.45), lineWidth: 1))
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(part.times > 1 ? "\(i + 1)  ×\(part.times)" : "\(i + 1)")
                        .font(.mixCaptionBold.monospacedDigit())
                        .foregroundStyle(Color.mixTextPrimary)
                    Text("\(clock(part.start)) – \(clock(part.end))")
                        .font(.mixMicro.monospacedDigit())
                        .foregroundStyle(Color.mixTextSecondary)
                }
                .lineLimit(1)
                .padding(.horizontal, 6).padding(.vertical, 4)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .onTapGesture { naming = false; preview.seek(to: starts) }
            .mixHandCursor()
            .help("Part \(i + 1). Click to play from here, drag to move it, right-click to loop, copy or remove it")
            .contextMenu {
                Button("Play from Here") { preview.seek(to: starts); preview.play() }
                Divider()
                if part.times < SongEdit.maxLoops {
                    Button("Play One More Time") { sections?[i].times += 1 }
                }
                if part.times > 1 {
                    Button("Play One Less Time") { sections?[i].times -= 1 }
                }
                if i > 0 {
                    Button("Move Left") { sections?.swapAt(i, i - 1) }
                }
                if i < count - 1 {
                    Button("Move Right") { sections?.swapAt(i, i + 1) }
                }
                if count < SongEdit.maxSections {
                    Button("Duplicate") { sections?.insert(part, at: i + 1) }
                }
                if count > 1 {
                    Divider()
                    Button("Remove", role: .destructive) { sections?.remove(at: i) }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Part \(i + 1), \(clock(part.start)) to \(clock(part.end)), plays \(part.times) times")
            .accessibilityAddTraits(.isButton)
    }

    // MARK: - Lanes

    static func stemIcon(_ name: String) -> String {
        switch name {
        case "vocals": "music.mic"
        case "drums": "metronome"
        case "bass": "guitars"
        default: "pianokeys"
        }
    }

    @ViewBuilder
    func laneHeader(_ lane: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let lane {
                let level = levels[lane] ?? 1
                let solo = level > 0.005 && SongEdit.stemNames.allSatisfy { $0 == lane || (levels[$0] ?? 1) < 0.005 }
                HStack(spacing: 6) {
                    Image(systemName: Self.stemIcon(lane)).frame(width: 18).foregroundStyle(Color.mixPrimary)
                    Text(lane.capitalized).font(.mixLabel).foregroundStyle(Color.mixTextPrimary)
                    Spacer(minLength: 0)
                    laneToggle("M", on: level < 0.005, help: level < 0.005 ? "Unmute" : "Mute") {
                        levels[lane] = level < 0.005 ? 1 : 0
                    }
                    laneToggle("S", on: solo, help: solo ? "Hear every stem" : "Hear only this") {
                        levels = Dictionary(uniqueKeysWithValues: SongEdit.stemNames.map { ($0, solo || $0 == lane ? 1 : 0) })
                    }
                }
                HStack(spacing: 6) {
                    Slider(value: Binding(get: { levels[lane] ?? 1 }, set: { levels[lane] = $0 }), in: 0...1)
                        .controlSize(.small)
                        .tint(Color.mixPrimary)
                        .accessibilityLabel("\(lane.capitalized) level")
                    Text(level < 0.005 ? "Off" : "\(Int((level * 100).rounded()))%")
                        .font(.mixCaption.monospacedDigit())
                        .foregroundStyle(Color.mixTextSecondary)
                        .frame(width: 32, alignment: .trailing)
                }
            } else {
                Label("Full Song", systemImage: "waveform").font(.mixLabel).foregroundStyle(Color.mixTextPrimary)
                if !StemSeparator.isAvailable {
                    Text("Stems need a Mac with Apple silicon.").font(.mixCaption).foregroundStyle(Color.mixTextSecondary)
                } else if let splitting {
                    ProgressView(value: splitting).controlSize(.small).tint(Color.mixPrimary)
                    Text("Splitting into stems…").font(.mixCaption).foregroundStyle(Color.mixTextSecondary)
                } else {
                    Button { split() } label: {
                        Label("Split into Stems", systemImage: "square.3.layers.3d").font(.mixLabel)
                    }
                    .buttonStyle(.plain).mixHandCursor()
                    .foregroundStyle(Color.mixPrimary)
                    .disabled(source == nil || busy)
                    .help("Vocals, drums, bass and the rest as their own tracks")
                    Text(splitError ?? "Made on this Mac. Takes a minute the first time.")
                        .font(.mixCaption)
                        .foregroundStyle(splitError == nil ? Color.mixTextSecondary : Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity, alignment: .center)
        .disabled(busy && splitting == nil)
    }

    func laneToggle(_ letter: String, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(letter)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(on ? Color.mixOnAccent : Color.mixTextSecondary)
                .frame(width: 20, height: 18)
                .background(RoundedRectangle(cornerRadius: 4).fill(on ? Color.mixPrimary : Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain).mixHandCursor()
        .help(help)
        .accessibilityLabel(help)
    }

    /// A lane's shape follows its level and the arrangement.
    func laneWave(_ lane: String?) -> some View {
        let shape: [Float]? = lane.map { name in
            stemPeaks?[name].map { p in p.map { $0 * Float(levels[name] ?? 1) } }
        } ?? peaks
        return GeometryReader { geo in
            WaveformView(peaks: shape.map { window(Waveform.arranged($0, length: preview.length, isWholeSong ? nil : sections)) },
                         progress: preview.duration > 0 ? min(max(visible(preview.position / preview.duration), 0), 1) : 0,
                         height: geo.size.height - 12,
                         onSeek: canSeek ? { seek(fraction: $0) } : nil)
                .padding(.vertical, 6)
        }
        .opacity(lane.map { (levels[$0] ?? 1) < 0.005 ? 0.35 : 1 } ?? 1)
    }

    // MARK: - Inspector

    var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                soundCard
                trimCard
                card("Parts", icon: "scissors",
                     caption: "Loop, reorder, copy or drop parts. On the timeline, drag one to move it or right-click it.",
                     trailing: arrangeButtons) { arrangeControls }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Name").font(.mixLabel).foregroundStyle(Color.mixTextSecondary)
                    TextField("Name", text: nameBinding)
                        .mixSheetField()
                        .focused($naming)
                    Text("Saved as a new song in Liked Songs. The original stays as it is.")
                        .font(.mixCaption).foregroundStyle(Color.mixTextSecondary)
                }
            }
            .padding(16)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: 340)
        .background(Color.primary.opacity(0.02))
    }

    // MARK: - Status

    var statusBar: some View {
        HStack(spacing: 10) {
            Text("Space plays   ← → skip   ⌘T cuts   ⌫ removes   ⌘Z undoes   Pinch or ⌘ scroll zooms")
                .font(.mixCaption)
                .foregroundStyle(Color.mixTextTertiary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let progress {
                ProgressView(value: progress).controlSize(.small).tint(Color.mixPrimary).frame(width: 120)
                Text("Saving \(Int(progress * 100))%").font(.mixCaption.monospacedDigit()).foregroundStyle(Color.mixTextSecondary)
            } else if let splitting {
                ProgressView(value: splitting).controlSize(.small).tint(Color.mixPrimary).frame(width: 120)
                Text("Splitting \(Int(splitting * 100))%").font(.mixCaption.monospacedDigit()).foregroundStyle(Color.mixTextSecondary)
            } else if let saveError {
                Text(saveError).font(.mixCaption).foregroundStyle(Color.red)
            } else if source == nil {
                ProgressView().controlSize(.small)
                Text("Getting the song…").font(.mixCaption).foregroundStyle(Color.mixTextSecondary)
            } else if let edit, !edit.isOriginal {
                Text(edit.label).font(.mixCaptionBold).foregroundStyle(Color.mixPrimary).lineLimit(1)
            }
            Rectangle().fill(Color.mixSeparator).frame(width: 1, height: 14)
            iconButton("minus.magnifyingglass", "Zoom out (⌘−)") { setZoom(zoom / 2) }
                .disabled(zoom <= 1)
            Slider(value: Binding(get: { log2(zoom) }, set: { setZoom(pow(2, $0)) }), in: 0...log2(Self.maxZoom))
                .controlSize(.mini)
                .frame(width: 90)
                .accessibilityLabel("Timeline zoom")
            iconButton("plus.magnifyingglass", "Zoom in (⌘+)") { setZoom(zoom * 2) }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(zoom >= Self.maxZoom)
        }
        .padding(.horizontal, 14)
        .frame(height: 28)
        .overlay(alignment: .top) { rowLine }
    }

    // MARK: - Saved

    func savedCard(_ saved: Track) -> some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(Color.mixPrimary)
                Text("Saved to Liked Songs").font(.mixTitle).foregroundStyle(Color.mixTextPrimary)
                Text(saved.title).font(.mixBody).foregroundStyle(Color.mixTextSecondary).lineLimit(2)
                    .multilineTextAlignment(.center)
                HStack(spacing: 18) {
                    if saved.edit != nil {
                        Button { posting = saved } label: {
                            Label("Post to Community", systemImage: "paperplane").font(.mixLabel)
                        }
                    }
                    if let shareURL {
                        ShareLink(item: shareURL) {
                            Label("Share or Export", systemImage: "square.and.arrow.up").font(.mixLabel)
                        }
                    }
                }
                .buttonStyle(.plain).mixHandCursor()
                .foregroundStyle(Color.mixPrimary)
                HStack(spacing: 10) {
                    Button("Keep Editing") {
                        if let shareURL { try? FileManager.default.removeItem(at: shareURL.deletingLastPathComponent()) }
                        shareURL = nil
                        self.saved = nil
                    }
                    Button("Done") { close() }
                        .keyboardShortcut(.defaultAction)
                }
                .controlSize(.large)
                .padding(.top, 4)
            }
            .padding(28)
            .frame(width: 420)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.mixSurface))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.mixSeparator, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.3), radius: 30, y: 10)
        }
        .transition(.opacity)
    }
}

/// Trackpad and mouse wheel over the timeline: scroll sideways, pinch or ⌘-scroll to zoom.
/// A local monitor, since SwiftUI on macOS 14 has no scroll-wheel or pinch events for a plain view.
private struct TimelineScroll: NSViewRepresentable {
    /// How far to move, in widths of the visible timeline.
    var onScroll: (Double) -> Void
    /// How much to zoom by, and where, 0...1 across.
    var onZoom: (Double, Double) -> Void

    func makeNSView(context: Context) -> NSView {
        context.coordinator.start()
        return context.coordinator.view
    }

    func updateNSView(_ view: NSView, context: Context) { context.coordinator.parent = self }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.stop() }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator {
        var parent: TimelineScroll
        let view = NSView()
        private var monitor: Any?

        init(parent: TimelineScroll) { self.parent = parent }

        func start() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
                guard let self, let window = view.window, event.window === window else { return event }
                let at = view.convert(event.locationInWindow, from: nil)
                let width = view.bounds.width
                guard width > 0, view.bounds.contains(at) else { return event }
                if event.type == .magnify {
                    parent.onZoom(1 + event.magnification, at.x / width)
                } else if event.modifierFlags.contains(.command) {
                    parent.onZoom(1 + event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.1), at.x / width)
                } else {
                    // A mouse wheel only goes up and down, so that moves sideways too.
                    let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
                    parent.onScroll(-delta * (event.hasPreciseScrollingDeltas ? 1 : 12) / width)
                }
                return nil
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

private struct PlayheadCap: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            p.closeSubpath()
        }
    }
}
#endif

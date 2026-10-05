// The Mac editor covers the whole window, like a music app: transport and Save on top, the song as a
// timeline with its parts above one lane per stem, and the sound settings in a panel on the right.

#if os(macOS)
import SwiftUI
import AppKit

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
        .disabled(source == nil || busy)
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var rowLine: some View { Rectangle().fill(Color.mixSeparator).frame(height: 1) }

    /// 0...1 of the arrangement to its time, then play from there.
    func seek(fraction: Double) {
        naming = false
        preview.seek(to: fraction * preview.duration)
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
        return GeometryReader { geo in
            Canvas { ctx, size in
                guard total > 0 else { return }
                let step = [1.0, 2, 5, 10, 15, 30, 60, 120, 300].first { $0 / total * size.width >= 70 } ?? 600
                var t = 0.0
                while t <= total {
                    let x = t / total * size.width
                    ctx.fill(Path(CGRect(x: x, y: size.height - 8, width: 1, height: 8)),
                             with: .color(Color.mixTextTertiary))
                    ctx.draw(Text(clock(t)).font(.system(size: 10, weight: .medium).monospacedDigit())
                                .foregroundStyle(Color.mixTextSecondary),
                             at: CGPoint(x: x + 4, y: 4), anchor: .topLeading)
                    let half = x + step / 2 / total * size.width
                    if half < size.width {
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
            let x = preview.duration > 0 ? preview.position / preview.duration * geo.size.width : 0
            ZStack(alignment: .topLeading) {
                ForEach(partEdges, id: \.self) { edge in
                    Rectangle().fill(Color.mixPrimary.opacity(0.35)).frame(width: 1)
                        .offset(x: edge * geo.size.width)
                }
                Rectangle().fill(Color.mixPrimary).frame(width: 1.5).offset(x: x)
                PlayheadCap().fill(Color.mixPrimary).frame(width: 11, height: 7).offset(x: x - 5)
            }
        }
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
                iconButton("arrow.uturn.backward", "Back to the whole song") { sections = nil }
                    .disabled(busy)
            }
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    var partsStrip: some View {
        if let sections, preview.duration > 0 {
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    ForEach(Array(sections.enumerated()), id: \.offset) { i, part in
                        let start = arrangedStart(of: i)
                        partBlock(i, part, count: sections.count)
                            .frame(width: max(part.span / preview.duration * geo.size.width - 2, 4))
                            .offset(x: start / preview.duration * geo.size.width + 1)
                    }
                }
                .frame(maxHeight: .infinity)
                .padding(.vertical, 6)
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

    /// One part on the strip. Click jumps to it; the menu loops, moves, copies or drops it.
    func partBlock(_ i: Int, _ part: SongEdit.Section, count: Int) -> some View {
        let starts = arrangedStart(of: i)
        let playing = (starts..<starts + part.span).contains(preview.position)
        return RoundedRectangle(cornerRadius: 6)
            .fill(Color.mixPrimary.opacity(playing ? 0.32 : 0.16))
            .overlay {
                // A line where each loop starts again.
                GeometryReader { geo in
                    ForEach(1..<max(part.times, 1), id: \.self) { k in
                        Rectangle().fill(Color.mixPrimary.opacity(0.5)).frame(width: 1)
                            .offset(x: geo.size.width * Double(k) / Double(part.times))
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.mixPrimary.opacity(playing ? 0.9 : 0.45), lineWidth: 1))
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
            .help("Part \(i + 1). Click to play from here; right-click to loop, move, copy or remove it")
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
            WaveformView(peaks: shape.map { Waveform.arranged($0, length: preview.length, isWholeSong ? nil : sections) },
                         progress: preview.duration > 0 ? preview.position / preview.duration : 0,
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
                     caption: "Loop, reorder, copy or drop parts. Right-click one on the timeline too.",
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
            Text("Space plays   ← → skip 5s   ⌘T cuts   ⌘S saves   Esc leaves")
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

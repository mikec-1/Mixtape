// Quick editor: speed, pitch, bass, reverb and a trim on any song, saved as a new song beside the original.
// On Apple silicon Macs it can also split the song into stems and set each one's level,
// and on any Mac cut, loop and reorder parts of it.

import SwiftUI

struct SongEditorSheet: View {
    let track: Track
    /// Opens a post made from the saved edit, by its share code.
    var onOpenPost: ((String) -> Void)?

    @EnvironmentObject private var deps: AppDependencies
    @Environment(\.dismiss) private var dismiss
    @StateObject private var preview = EditPreview()

    @State private var original: Track?
    @State private var source: URL?
    /// A temporary copy of the original's audio, deleted on close.
    @State private var scratch: URL?
    @State private var loadError: String?
    @State private var speed = 0.85
    @State private var reverb = 0.35
    /// Nil follows the speed.
    @State private var pitch: Double?
    @State private var bass = 0.0
    @State private var name = ""
    @State private var nameTouched = false
    /// Set once the song is split; the preview then plays these.
    @State private var stemFiles: [String: URL]?
    @State private var levels: [String: Double] = [:]
    @State private var splitting: Double?
    @State private var splitTask: Task<Void, Never>?
    @State private var splitError: String?
    /// Parts in play order once arranging. Nil is the song as it is.
    @State private var sections: [SongEdit.Section]?
    /// Peaks of the whole original, about 20 slices a second.
    @State private var peaks: [Float]?
    /// Each stem's peaks once split, so the shape follows the levels.
    @State private var stemPeaks: [String: [Float]]?
    @State private var posting: Track?

    @State private var progress: Double?
    @State private var saveTask: Task<Void, Never>?
    @State private var saveError: String?
    @State private var saved: Track?
    /// The rendered file under a readable name, for sharing. Its folder is deleted on close.
    @State private var shareURL: URL?
    #if os(macOS)
    /// Grows the editor to the app window. Remembered on this Mac.
    @AppStorage("songEditor.fillsWindow") private var fillsWindow = false
    /// The app window's content size, which the editor fits itself to.
    @State private var room = CGSize(width: 1200, height: 860)
    private static let resized = NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)
    #endif

    private var edit: SongEdit? {
        guard let original else { return nil }
        return SongEdit(of: original.id,
                        sourceRef: original.sourceRef
                            ?? OnlineTrack.key(title: original.identityTitle, artistName: original.artistName),
                        speed: speed, reverb: reverb, pitch: pitch, bass: bass,
                        stems: stemFiles == nil ? nil : levels,
                        sections: isWholeSong ? nil : sections)
    }

    /// One part, start to end, once: nothing to save.
    private var isWholeSong: Bool {
        guard let sections else { return true }
        guard sections.count == 1, let only = sections.first else { return false }
        return only.times == 1 && only.start < 0.05 && only.end > preview.length - 0.05
    }

    private var peakCount: Int { min(max(Int(preview.length * 20), 200), 12_000) }

    private var busy: Bool { progress != nil || splitting != nil }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        MixSheet(title: "Edit Song",
                 subtitle: "Saved as a new song. The original stays as it is.",
                 size: sheetSize,
                 scroll: false,
                 dismissDisabled: busy,
                 closesOnOutsideClick: false) {
            // The waveform stays put while the controls scroll under it.
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    if let loadError {
                        MixSheetStatus(kind: .failure, title: loadError)
                    } else if let saved {
                        savedView(saved)
                    } else {
                        stage
                    }
                }
                .padding(.horizontal, MixSheetMetrics.margin)
                .padding(.vertical, MixSheetMetrics.contentVertical)
                if loadError == nil && saved == nil {
                    ScrollView {
                        controls
                            .padding(.horizontal, MixSheetMetrics.margin)
                            .padding(.bottom, MixSheetMetrics.contentVertical)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
            }
        } footer: {
            footer
        }
        #if os(macOS)
        .onAppear { room = Self.windowRoom() ?? room }
        .onReceive(Self.resized) { _ in room = Self.windowRoom() ?? room }
        #else
        .editorPageSizing()
        #endif
        .sheet(item: $posting) { track in
            PostSheet(track: track, onOpen: { code in dismiss(); onOpenPost?(code) })
                .environmentObject(deps)
        }
        .task { await load() }
        .onChange(of: speed) { changed() }
        .onChange(of: reverb) { changed() }
        .onChange(of: pitch) { changed() }
        .onChange(of: bass) { changed() }
        .onChange(of: levels) { changed() }
        .onChange(of: sections) {
            let wasPlaying = preview.isPlaying
            preview.arrange(sections)
            if wasPlaying { preview.play() }
            refreshName()
        }
        .onDisappear {
            saveTask?.cancel()
            splitTask?.cancel()
            preview.stop()
            if let scratch { try? FileManager.default.removeItem(at: scratch) }
            if let shareURL { try? FileManager.default.removeItem(at: shareURL.deletingLastPathComponent()) }
        }
    }

    // MARK: - Parts

    private var header: some View {
        HStack(spacing: 12) {
            ArtworkThumbnail(data: original?.artworkData,
                             artworkRef: .track(original?.id ?? track.id),
                             size: 52, cornerRadius: 6, placeholder: MixtapeIcons.track)
            VStack(alignment: .leading, spacing: 2) {
                Text(original?.displayTitle ?? track.displayTitle)
                    .font(.mixBody.weight(.semibold))
                    .foregroundStyle(Color.mixTextPrimary)
                Text(original?.artistName ?? track.artistName)
                    .font(.mixCaption)
                    .foregroundStyle(Color.mixTextSecondary)
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            if let edit, !edit.isOriginal, saved == nil {
                Text(edit.label)
                    .font(.mixCaptionBold)
                    .foregroundStyle(Color.mixPrimary)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Color.mixPrimary.opacity(0.15)))
                    .lineLimit(1)
            }
            #if os(macOS)
            Button { withAnimation(.snappy) { fillsWindow.toggle() } } label: {
                Label(fillsWindow ? "Smaller" : "Fill Window",
                      systemImage: fillsWindow ? "arrow.down.right.and.arrow.up.left"
                                               : "arrow.up.left.and.arrow.down.right")
                    .font(.mixLabel)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
            }
            .buttonStyle(.plain).mixHandCursor()
            .foregroundStyle(Color.mixTextSecondary)
            .help(fillsWindow ? "Make the editor smaller" : "Make the editor fill the window")
            #endif
        }
    }

    // MARK: - Size

    private var sheetSize: MixSheetSize {
        #if os(macOS)
        let width = fillsWindow ? room.width - 24 : min(940, room.width - 80)
        let height = fillsWindow ? room.height - 24 : min(780, room.height - 60)
        return .window(CGSize(width: max(width, 580), height: max(height, 480)))
        #else
        .large
        #endif
    }

    /// Two columns of cards once there's room for them.
    private var isWide: Bool {
        #if os(macOS)
        sheetSize.width >= 820
        #else
        false
        #endif
    }

    #if os(macOS)
    /// The app window under this sheet, past any sheet stacked on it.
    private static func windowRoom() -> CGSize? {
        var window = NSApp.keyWindow
        while let parent = window?.sheetParent { window = parent }
        return (window ?? NSApp.mainWindow)?.contentLayoutRect.size
    }
    #endif

    @ViewBuilder
    private func savedView(_ saved: Track) -> some View {
        MixSheetStatus(kind: .success, title: "Saved to Liked Songs", detail: saved.title)
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
    }

    private var controls: some View {
        let columns = isWide ? AnyLayout(HStackLayout(alignment: .top, spacing: 14))
                             : AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
        return VStack(alignment: .leading, spacing: 14) {
            columns {
                VStack(alignment: .leading, spacing: 14) {
                    soundCard
                    trimCard
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                VStack(alignment: .leading, spacing: 14) {
                    if StemSeparator.isAvailable {
                        card("Stems", icon: "square.3.layers.3d",
                             caption: "Turn the vocals, drums, bass or the rest up, down or off.") { stemControls }
                    }
                    #if os(macOS)
                    card("Arrange", icon: "scissors",
                         caption: "Cut the song into parts, then loop, reorder, copy or drop them.",
                         trailing: arrangeButtons) { arrangeControls }
                    #else
                    Label("Stems and arranging are in Mixtape for Mac.", systemImage: "desktopcomputer")
                        .font(.mixCaption)
                        .foregroundStyle(Color.mixTextSecondary)
                    #endif
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.mixLabel).foregroundStyle(Color.mixTextSecondary)
                TextField("Name", text: Binding(get: { name }, set: { name = $0; nameTouched = true }))
                    .mixSheetField()
            }

            if let progress {
                MixSheetStatus(kind: .busy, title: "Saving…", progress: progress)
            } else if let saveError {
                MixSheetStatus(kind: .failure, title: saveError)
            }
        }
    }

    private var soundCard: some View {
        card("Sound", icon: "dial.medium", caption: "Pick a preset, or set it up yourself.") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(SongEdit.presets) { preset in
                        presetChip(preset)
                    }
                }
            }
            slider("Speed", value: $speed, in: SongEdit.speedRange,
                   label: String(format: "%.2f×", speed))
            Toggle("Pitch follows speed", isOn: Binding(get: { pitch == nil }, set: { pitch = $0 ? nil : 0 }))
                .toggleStyle(.switch)
                .tint(Color.mixPrimary)
                .font(.mixLabel)
                .foregroundStyle(Color.mixTextSecondary)
                .disabled(busy)
            if let pitch {
                slider("Pitch", value: Binding(get: { pitch }, set: { self.pitch = $0 }), in: SongEdit.pitchRange,
                       step: 1, label: semitones(pitch))
            }
            slider("Reverb", value: $reverb, in: 0...1,
                   label: "\(Int((reverb * 100).rounded()))%")
            slider("Bass", value: $bass, in: 0...1,
                   label: bass < 0.005 ? "Off" : "+\(Int((bass * 100).rounded()))%")
        }
    }

    private func presetChip(_ preset: SongEdit.Preset) -> some View {
        chip(preset.name, selected: abs(speed - preset.speed) < 0.005 && abs(reverb - preset.reverb) < 0.005
                && pitch == nil && bass < 0.005) {
            speed = preset.speed
            reverb = preset.reverb
            pitch = nil
            bass = 0
        }
    }

    private func semitones(_ value: Double) -> String {
        let n = Int(value.rounded())
        return n == 0 ? "Original" : "\(n > 0 ? "+" : "")\(n) semitone\(abs(n) == 1 ? "" : "s")"
    }

    /// Start and end, while the song plays as one part once. More than that is the Arrange card's.
    @ViewBuilder
    private var trimCard: some View {
        if preview.length > 0, sections.map({ $0.count == 1 && $0[0].times == 1 }) ?? true {
            let part = sections?.first ?? SongEdit.Section(start: 0, end: preview.length)
            card("Trim", icon: "timeline.selection", caption: "Start the song later or end it sooner.") {
                slider("Start", value: Binding(get: { part.start }, set: { trim(start: $0, end: part.end) }),
                       in: 0...preview.length, step: nil, label: clock(part.start / speed))
                slider("End", value: Binding(get: { part.end }, set: { trim(start: part.start, end: $0) }),
                       in: 0...preview.length, step: nil, label: clock(part.end / speed))
            }
        }
    }

    /// Keeps at least a second. All of it is no trim.
    private func trim(start: Double, end: Double) {
        let start = min(start, preview.length - 1), end = max(end, start + 1)
        sections = start < 0.05 && end > preview.length - 0.05 ? nil : [SongEdit.Section(start: start, end: end)]
    }

    @ViewBuilder
    private var stemControls: some View {
        if let splitting {
            MixSheetStatus(kind: .busy, title: "Splitting into stems…", progress: splitting)
        } else if stemFiles == nil {
            VStack(alignment: .leading, spacing: 4) {
                Button { split() } label: {
                    Label("Split into Stems", systemImage: "square.3.layers.3d").font(.mixLabel)
                }
                .buttonStyle(.plain).mixHandCursor()
                .foregroundStyle(Color.mixPrimary)
                .disabled(source == nil || busy)
                Text(splitError ?? "Made on this Mac. Takes a minute the first time.")
                    .font(.mixCaption)
                    .foregroundStyle(splitError == nil ? Color.mixTextSecondary : Color.red)
            }
        } else {
            HStack(spacing: 6) {
                ForEach(SongEdit.stemPresets, id: \.name) { preset in
                    chip(preset.name, selected: SongEdit.stemNames.allSatisfy {
                        abs((preset.stems?[$0] ?? 1) - (levels[$0] ?? 1)) < 0.005
                    }) {
                        levels = Dictionary(uniqueKeysWithValues: SongEdit.stemNames.map { ($0, preset.stems?[$0] ?? 1) })
                    }
                }
            }
            ForEach(SongEdit.stemNames, id: \.self) { name in
                let level = levels[name] ?? 1
                slider(name.capitalized,
                       value: Binding(get: { levels[name] ?? 1 }, set: { levels[name] = $0 }),
                       in: 0...1, label: level < 0.005 ? "Muted" : "\(Int((level * 100).rounded()))%")
            }
        }
    }

    #if os(macOS)
    @ViewBuilder
    private var arrangeControls: some View {
        if let sections {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(sections.enumerated()), id: \.offset) { i, part in
                    sectionRow(i, part, count: sections.count)
                }
            }
            .disabled(busy)
        } else {
            Button { sections = [SongEdit.Section(start: 0, end: preview.length)] } label: {
                Label("Start Arranging", systemImage: "scissors").font(.mixLabel)
            }
            .buttonStyle(.plain).mixHandCursor()
            .foregroundStyle(Color.mixPrimary)
            .disabled(source == nil || busy)
        }
    }

    @ViewBuilder
    private var arrangeButtons: some View {
        if sections != nil {
            Button("Reset") { sections = nil }
                .font(.mixLabel)
                .buttonStyle(.plain).mixHandCursor()
                .foregroundStyle(Color.mixPrimary)
                .disabled(busy)
        }
    }

    /// One part: jump to it, loop it, move it, copy it, drop it.
    private func sectionRow(_ i: Int, _ part: SongEdit.Section, count: Int) -> some View {
        let starts = arrangedStart(of: i)
        let playing = (starts..<starts + part.span).contains(preview.position)
        return HStack(spacing: 10) {
            Button { preview.seek(to: starts) } label: {
                HStack(spacing: 8) {
                    Text("\(i + 1)").font(.mixCaption.monospacedDigit()).foregroundStyle(Color.mixTextSecondary)
                        .frame(width: 16, alignment: .trailing)
                    Text("\(clock(part.start)) – \(clock(part.end))")
                        .font(.mixLabel.monospacedDigit())
                        .foregroundStyle(playing ? Color.mixPrimary : Color.mixTextPrimary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).mixHandCursor()
            .accessibilityLabel("Part \(i + 1), \(clock(part.start)) to \(clock(part.end)). Jump to it")

            Stepper("×\(part.times)", value: Binding(get: { part.times }, set: { sections?[i].times = $0 }),
                    in: 1...SongEdit.maxLoops)
                .font(.mixLabel.monospacedDigit())
                .accessibilityLabel("Plays \(part.times) times")
            Group {
                iconButton("chevron.up", "Move up") { sections?.swapAt(i, i - 1) }.disabled(i == 0)
                iconButton("chevron.down", "Move down") { sections?.swapAt(i, i + 1) }.disabled(i == count - 1)
                iconButton("plus.square.on.square", "Duplicate") { sections?.insert(part, at: i + 1) }
                    .disabled(count >= SongEdit.maxSections)
                iconButton("trash", "Remove") { sections?.remove(at: i) }.disabled(count == 1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(playing ? 0.08 : 0.04)))
    }

    private func iconButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).frame(width: 22, height: 22)
        }
        .buttonStyle(.plain).mixHandCursor()
        .foregroundStyle(Color.mixTextSecondary)
        .help(label)
        .accessibilityLabel(label)
    }

    /// Cuts the part under the playhead in two. Both halves keep its loop count.
    private func splitAtPlayhead() {
        guard let sections, sections.count < SongEdit.maxSections else { return }
        let now = preview.now
        var at: TimeInterval = 0
        for (i, part) in sections.enumerated() {
            defer { at += part.span }
            guard now < at + part.span else { continue }
            let cut = part.start + (now - at).truncatingRemainder(dividingBy: part.length)
            guard cut - part.start > 0.1, part.end - cut > 0.1 else { return }
            self.sections?.replaceSubrange(i...i, with: [
                SongEdit.Section(start: part.start, end: cut, times: part.times),
                SongEdit.Section(start: cut, end: part.end, times: part.times),
            ])
            return
        }
    }
    #endif

    /// Where part `i` starts in the arrangement, before speed.
    private func arrangedStart(of i: Int) -> TimeInterval {
        (sections ?? []).prefix(i).reduce(0) { $0 + $1.span }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: MixFontScale.size(12), weight: .semibold))
                .foregroundStyle(selected ? Color.mixOnAccent : Color.mixTextSecondary)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(Capsule().fill(selected ? Color.mixPrimary : Color.primary.opacity(0.07)))
        }
        .buttonStyle(.plain).mixHandCursor()
        .disabled(busy)
    }

    /// A nil step slides freely.
    private func slider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>,
                        step: Double? = 0.05, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.mixLabel).foregroundStyle(Color.mixTextSecondary)
                Spacer()
                Text(label).font(.mixLabel.monospacedDigit()).foregroundStyle(Color.mixTextPrimary)
            }
            Group {
                if let step { Slider(value: value, in: range, step: step) } else { Slider(value: value, in: range) }
            }
                .tint(Color.mixPrimary)
                .accessibilityLabel(title)
                .accessibilityValue(label)
        }
        .disabled(busy)
    }

    private func card<Content: View>(_ title: String, icon: String, caption: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        card(title, icon: icon, caption: caption, trailing: EmptyView(), content: content)
    }

    /// A titled box for one kind of change.
    private func card<Trailing: View, Content: View>(_ title: String, icon: String, caption: String,
                                                     trailing: Trailing,
                                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Label(title, systemImage: icon)
                        .font(.mixBodyBold)
                        .foregroundStyle(Color.mixTextPrimary)
                    Text(caption).font(.mixCaption).foregroundStyle(Color.mixTextSecondary)
                }
                Spacer(minLength: 8)
                trailing
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.mixSeparator, lineWidth: 0.5))
    }

    /// The waveform as the scrubber, with the parts on it, and play. Times are in the edited
    /// song's clock, so a slowed song reads longer.
    private var stage: some View {
        let total = preview.duration
        let edges = (1..<max(sections?.count ?? 0, 1)).map { arrangedStart(of: $0) / max(total, 0.01) }
        return VStack(spacing: 10) {
            WaveformView(peaks: (stemPeaks.map { Waveform.mixed($0, levels: levels) } ?? peaks)
                            .map { Waveform.arranged($0, length: preview.length, isWholeSong ? nil : sections) },
                         progress: total > 0 ? preview.position / total : 0,
                         parts: isWholeSong ? [] : edges,
                         height: waveHeight,
                         onSeek: source == nil || busy ? nil : { preview.seek(to: $0 * total) })
            HStack(spacing: 12) {
                Button { preview.toggle() } label: {
                    Image(systemName: preview.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.mixOnAccent)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color.mixPrimary))
                }
                .buttonStyle(.plain).mixHandCursor()
                .accessibilityLabel(preview.isPlaying ? "Pause preview" : "Play preview")
                Text("\(clock(preview.position / speed)) / \(clock(total / speed))")
                    .font(.mixLabel.monospacedDigit()).foregroundStyle(Color.mixTextSecondary)
                Spacer(minLength: 0)
                #if os(macOS)
                if sections != nil {
                    Button { splitAtPlayhead() } label: {
                        Label("Split at Playhead", systemImage: "scissors").font(.mixLabel)
                    }
                    .buttonStyle(.plain).mixHandCursor()
                    .foregroundStyle(Color.mixPrimary)
                    .disabled((sections?.count ?? 0) >= SongEdit.maxSections)
                }
                #endif
            }
            .disabled(source == nil || busy)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
    }

    private var waveHeight: CGFloat {
        #if os(macOS)
        fillsWindow ? 180 : 120
        #else
        72
        #endif
    }

    @ViewBuilder
    private var footer: some View {
        if saved != nil || loadError != nil {
            MixSheetActions(primary: MixSheetAction("Done") { dismiss() }, showsCancel: false)
        } else {
            MixSheetActions(
                primary: MixSheetAction("Save",
                                        isEnabled: source != nil && splitting == nil
                                            && edit?.isOriginal == false && !trimmedName.isEmpty,
                                        isBusy: progress != nil,
                                        action: save),
                secondary: progress != nil ? MixSheetAction("Stop") { saveTask?.cancel() } : nil
            )
        }
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.isFinite ? seconds : 0)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: - Work

    private func load() async {
        deps.playbackEngine.pause()
        if let recipe = track.edit {
            speed = recipe.speed
            reverb = recipe.reverb
            pitch = recipe.pitch
            bass = recipe.bass
            if let stems = recipe.stems { levels = stems }
            sections = recipe.sections
        }
        // Editing an edit starts again from its original.
        guard let base = track.edit.map({ deps.libraryService.track(id: $0.of) }) ?? track else {
            loadError = "The original song isn't in your library anymore."
            return
        }
        original = base
        refreshName()
        do {
            let audio = try await deps.downloadManager.localAudio(for: base)
            guard !Task.isCancelled else {
                if let scratch = audio.scratch { try? FileManager.default.removeItem(at: scratch) }
                return
            }
            scratch = audio.scratch
            try preview.load([audio.url])
            changed()
            source = audio.url
            Task { peaks = await Waveform.peaks(of: audio.url, count: peakCount) }
        } catch {
            loadError = "Couldn't get this song's audio."
            return
        }
        // A studio edit opens split, at its levels.
        if track.edit?.stems != nil { split() }
    }

    private func changed() {
        guard let edit else { return }
        preview.apply(edit, levels: stemFiles == nil ? [1] : SongEdit.stemNames.map { levels[$0] ?? 1 })
        refreshName()
    }

    private func split() {
        guard let source, let original, splitting == nil else { return }
        splitError = nil
        splitting = 0
        splitTask = Task {
            defer { splitting = nil }
            do {
                let files = try await StemSeparator.stems(of: source, id: original.id) { p in
                    Task { @MainActor in if splitting != nil { splitting = p } }
                }
                try Task.checkCancellation()
                let wasPlaying = preview.isPlaying
                try preview.load(SongEdit.stemNames.compactMap { files[$0] })
                stemFiles = files
                changed()
                if wasPlaying { preview.play() }
                Task { stemPeaks = await Waveform.stems(files, count: peakCount) }
            } catch {
                if !(error is CancellationError) { splitError = "Couldn't split this song." }
            }
        }
    }

    private func refreshName() {
        guard !nameTouched, let original, let edit else { return }
        name = edit.isOriginal ? original.displayTitle : "\(original.displayTitle) (\(edit.label))"
    }

    private func save() {
        guard let source, let original, let edit, progress == nil else { return }
        preview.pause()
        let title = trimmedName
        let folder = FileManager.default.temporaryDirectory.appending(path: "Edit-\(UUID().uuidString)")
        let file = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let dest = folder.appending(path: "\(file).m4a")
        saveError = nil
        progress = 0
        saveTask = Task {
            defer { progress = nil }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                // Stems are cached by now, so this doesn't split again.
                let layers = try await EditRenderer.layers(for: edit, source: source)
                try await EditRenderer.render(layers, edit: edit,
                                              quality: deps.downloadManager.editQuality, to: dest) { p in
                    Task { @MainActor in if progress != nil { progress = p } }
                }
                try Task.checkCancellation()
                saved = try await deps.importService.saveEdit(rendered: dest, of: original, edit: edit, title: title)
                shareURL = dest
            } catch {
                try? FileManager.default.removeItem(at: folder)
                if !(error is CancellationError) { saveError = "Couldn't save the edit." }
            }
        }
    }
}

#if os(iOS)
private extension View {
    /// The bigger iPad sheet where there is one. iPhone already gets the full height.
    @ViewBuilder
    func editorPageSizing() -> some View {
        if #available(iOS 18, *) { presentationSizing(.page) } else { self }
    }
}
#endif

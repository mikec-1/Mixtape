// WidgetStyles.swift
// The other looks for the same song: cover art, the queue, a cassette, a
// record, big type, a click-wheel player and a till receipt. Each is its own
// entry in the widget gallery; all read the snapshot NowPlayingProvider loads.

import WidgetKit
import SwiftUI
import AppIntents

private func songWidget<V: View>(_ kind: String, _ name: String, _ about: String, _ families: [WidgetFamily],
                                 @ViewBuilder _ view: @escaping (NowPlayingEntry) -> V) -> some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: NowPlayingProvider(), content: view)
        .configurationDisplayName(name)
        .description(about)
        .supportedFamilies(families)
}

// MARK: - Cover Art

struct CoverArtWidget: Widget {
    var body: some WidgetConfiguration {
        songWidget("CoverArt", "Cover Art", "The cover, edge to edge.", [.systemSmall, .systemLarge]) {
            CoverArtView(song: $0.song)
        }
    }
}

private struct CoverArtView: View {
    let song: NowPlayingSnapshot
    @Environment(\.widgetFamily) private var family
    var body: some View {
        let large = family == .systemLarge
        VStack(alignment: .leading, spacing: 10) {
            // Small: the button sits up top so the title gets the full width.
            if !large { HStack { Spacer(); PlayButton(isPlaying: song.isPlaying, size: 34) } }
            Spacer(minLength: 0)
            HStack(alignment: .bottom, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title).font(large ? .title2.bold() : .headline).lineLimit(2)
                    Text(song.artist).font(.subheadline).lineLimit(1).opacity(0.8)
                }
                Spacer(minLength: 0)
                if large { PlayButton(isPlaying: song.isPlaying, size: 46) }
            }
            if large { TimedBar(song: song) }
        }
        .foregroundStyle(.white)
        .containerBackground(for: .widget) {
            ZStack {
                if let image = song.cover {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    LinearGradient(colors: [song.tintColor, .black], startPoint: .topLeading, endPoint: .bottomTrailing)
                }
                LinearGradient(colors: [.clear, .clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
            }
        }
    }
}

// MARK: - Up Next

struct UpNextWidget: Widget {
    var body: some WidgetConfiguration {
        songWidget("UpNext", "Up Next", "The song playing and what's coming after it.", [.systemMedium, .systemLarge]) {
            UpNextView(song: $0.song)
        }
    }
}

private struct UpNextView: View {
    let song: NowPlayingSnapshot
    @Environment(\.widgetFamily) private var family
    var body: some View {
        let large = family == .systemLarge
        VStack(alignment: .leading, spacing: large ? 10 : 7) {
            HStack(spacing: 10) {
                Cover(data: song.artwork, size: large ? 52 : 38)
                VStack(alignment: .leading, spacing: 1) {
                    Text("PLAYING FROM \((song.source ?? "Mixtape").uppercased())")
                        .font(.caption2.weight(.semibold)).lineLimit(1).opacity(0.6)
                    Text(song.title).font(.headline).lineLimit(1)
                    Text(song.artist).font(.caption).lineLimit(1).opacity(0.75)
                }
                Spacer(minLength: 0)
                PlayButton(isPlaying: song.isPlaying, size: large ? 38 : 32)
            }
            if large { TimedBar(song: song) }
            Rectangle().fill(.white.opacity(0.18)).frame(height: 1)
            if song.upNext.isEmpty {
                Text("Nothing queued after this one").font(.caption).opacity(0.6)
            }
            ForEach(Array(song.upNext.prefix(large ? 5 : 2).enumerated()), id: \.offset) { i, next in
                HStack(spacing: 10) {
                    Text("\(i + 1)").font(.caption.monospacedDigit().weight(.bold)).opacity(0.5).frame(width: 12)
                    Cover(data: next.artwork, size: large ? 34 : 26)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(next.title).font(.caption.weight(.semibold)).lineLimit(1)
                        Text(next.artist).font(.caption2).lineLimit(1).opacity(0.65)
                    }
                    Spacer(minLength: 0)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .containerBackground(for: .widget) { ArtWash(song: song) }
    }
}

// MARK: - Cassette

struct CassetteWidget: Widget {
    var body: some WidgetConfiguration {
        songWidget("Cassette", "Cassette", "The song on a tape that winds as it plays.", [.systemSmall, .systemMedium]) {
            CassetteView(entry: $0)
        }
    }
}

private struct CassetteView: View {
    let entry: NowPlayingEntry
    var body: some View {
        let song = entry.song, p = song.progress(at: entry.date)
        GeometryReader { g in
            let w = g.size.width, h = g.size.height, reel = min(h * 0.36, w * 0.2)  // square small: width binds
            ZStack {
                RoundedRectangle(cornerRadius: h * 0.08, style: .continuous)
                    .fill(LinearGradient(colors: [song.tintColor, song.tintColor.opacity(0.7)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: h * 0.08, style: .continuous)
                        .stroke(.black.opacity(0.25), lineWidth: 1))
                // Screws.
                ForEach(0..<4, id: \.self) { i in
                    Circle().fill(.black.opacity(0.3)).frame(width: 5, height: 5)
                        .position(x: i % 2 == 0 ? 7 : w - 7, y: i < 2 ? 7 : h - 7)
                }
                VStack(spacing: h * 0.04) {
                    // The label, written on by hand.
                    VStack(spacing: h * 0.03) {
                        HStack(spacing: 6) {
                            Text("A").font(.system(size: h * 0.1, weight: .black))
                                .foregroundStyle(.white)
                                .frame(width: h * 0.15, height: h * 0.15)
                                .background(song.tintColor, in: RoundedRectangle(cornerRadius: 3))
                            Text(song.title).font(.custom("MarkerFelt-Wide", size: h * 0.12)).lineLimit(2)
                                .minimumScaleFactor(0.6)
                            Spacer(minLength: 0)
                        }
                        // The window, and the tape moving from one reel to the other.
                        HStack {
                            Reel(wound: 1 - p, spin: p * 7200, size: reel)
                            Spacer(minLength: 0)
                            PlayButton(isPlaying: song.isPlaying, size: reel * 0.62, fill: .white.opacity(0.9))
                            Spacer(minLength: 0)
                            Reel(wound: p, spin: p * 7200, size: reel)
                        }
                        .padding(.horizontal, h * 0.05)
                        .padding(.vertical, h * 0.02)
                        .background(Color.black.opacity(0.8), in: Capsule())
                        .padding(.horizontal, w * 0.06)
                        Text(song.artist).font(.custom("MarkerFelt-Thin", size: h * 0.09)).lineLimit(1)
                    }
                    .foregroundStyle(Color(red: 0.13, green: 0.16, blue: 0.35))
                    .padding(h * 0.05)
                    .background(Color(red: 0.97, green: 0.93, blue: 0.82), in: RoundedRectangle(cornerRadius: 5))
                    // The head opening along the bottom edge.
                    HStack(spacing: w * 0.18) {
                        ForEach(0..<2, id: \.self) { _ in Circle().fill(.black.opacity(0.4)).frame(width: 6, height: 6) }
                    }
                    .frame(width: w * 0.6, height: h * 0.1)
                    .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 3))
                }
                .padding(.horizontal, w * 0.05)
                .padding(.top, h * 0.07)
            }
        }
        .containerBackground(for: .widget) {
            LinearGradient(colors: [Color(white: 0.16), Color(white: 0.06)], startPoint: .top, endPoint: .bottom)
        }
    }
}

private struct Reel: View {
    let wound: Double       // 0...1, how much of the tape is on this reel
    let spin: Double
    let size: CGFloat
    var body: some View {
        ZStack {
            Circle().fill(Color(red: 0.3, green: 0.2, blue: 0.14))
                .frame(width: size * (0.45 + 0.55 * wound), height: size * (0.45 + 0.55 * wound))
            Circle().fill(.white).frame(width: size * 0.42, height: size * 0.42)
            ForEach(0..<6, id: \.self) { i in
                Rectangle().fill(.black.opacity(0.65)).frame(width: size * 0.06, height: size * 0.1)
                    .offset(y: -size * 0.14)
                    .rotationEffect(.degrees(Double(i) * 60 + spin))
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Vinyl

struct VinylWidget: Widget {
    var body: some WidgetConfiguration {
        songWidget("Vinyl", "Vinyl", "The cover as a record label, with the needle down.", [.systemSmall, .systemMedium]) {
            VinylView(entry: $0)
        }
    }
}

private struct VinylView: View {
    let entry: NowPlayingEntry
    @Environment(\.widgetFamily) private var family
    var body: some View {
        let song = entry.song, p = song.progress(at: entry.date)
        GeometryReader { g in
            let h = g.size.height
            if family == .systemSmall {
                ZStack(alignment: .bottomTrailing) {
                    Record(song: song, spin: p * 3600, size: h * 0.92)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    // The arm swings in across the record as the song goes on.
                    Tonearm(length: h * 0.62)
                        .rotationEffect(.degrees(song.isPlaying || p > 0 ? 14 + p * 18 : 0), anchor: .top)
                        // position() places the centre; the pivot (its top) sits in the corner.
                        .position(x: g.size.width - h * 0.1, y: h * 0.08 + h * 0.31)
                    PlayButton(isPlaying: song.isPlaying, size: 30)
                }
            } else {
                HStack(spacing: 14) {
                    ZStack(alignment: .leading) {
                        Record(song: song, spin: p * 3600, size: h * 0.94).offset(x: h * 0.42)
                        Cover(data: song.artwork, size: h)
                            .shadow(color: .black.opacity(0.5), radius: 6, x: 3)
                    }
                    .frame(width: h * 1.4, alignment: .leading)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(song.isPlaying ? "NOW SPINNING" : "ON THE PLATTER")
                            .font(.caption2.weight(.heavy)).tracking(1.5).opacity(0.55)
                        Text(song.title).font(.headline).lineLimit(2)
                        Text(song.artist).font(.caption).lineLimit(1).opacity(0.75)
                        Spacer(minLength: 0)
                        HStack(spacing: 16) {
                            Button(intent: PreviousTrackIntent()) { Image(systemName: "backward.fill") }
                            PlayButton(isPlaying: song.isPlaying, size: 32)
                            Button(intent: NextTrackIntent()) { Image(systemName: "forward.fill") }
                        }
                        .buttonStyle(.plain)
                    }
                    .foregroundStyle(.white)
                }
            }
        }
        .containerBackground(for: .widget) {
            LinearGradient(colors: [Color(red: 0.2, green: 0.15, blue: 0.12), Color(red: 0.07, green: 0.05, blue: 0.04)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

private struct Record: View {
    let song: NowPlayingSnapshot
    let spin: Double
    let size: CGFloat
    var body: some View {
        ZStack {
            Circle().fill(Color(white: 0.05))
            ForEach(1..<9, id: \.self) { i in
                Circle().stroke(.white.opacity(0.07), lineWidth: 0.7).padding(size * (0.02 + CGFloat(i) * 0.033))
            }
            Circle().fill(AngularGradient(colors: [.clear, .white.opacity(0.16), .clear, .clear,
                                                   .white.opacity(0.1), .clear], center: .center))
            Group {
                if let image = song.cover {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    song.tintColor.overlay(Text("MIXTAPE").font(.system(size: size * 0.05, weight: .heavy)))
                }
            }
            .frame(width: size * 0.38, height: size * 0.38)
            .clipShape(Circle())
            .rotationEffect(.degrees(spin))
            Circle().fill(Color(white: 0.8)).frame(width: size * 0.035, height: size * 0.035)
        }
        .frame(width: size, height: size)
    }
}

private struct Tonearm: View {
    let length: CGFloat
    var body: some View {
        let metal = LinearGradient(colors: [Color(white: 0.92), Color(white: 0.6)], startPoint: .leading, endPoint: .trailing)
        ZStack(alignment: .top) {
            Capsule().fill(metal).frame(width: length * 0.05, height: length)
            RoundedRectangle(cornerRadius: 2).fill(Color(white: 0.25))
                .frame(width: length * 0.1, height: length * 0.16).offset(y: length * 0.88)
            Circle().fill(metal).frame(width: length * 0.2, height: length * 0.2).offset(y: -length * 0.1)
        }
        .frame(height: length, alignment: .top)
    }
}

// MARK: - Big Type

struct BigTypeWidget: Widget {
    var body: some WidgetConfiguration {
        songWidget("BigType", "Big Type", "The title, as loud as it goes, in the cover's colour.", [.systemSmall, .systemMedium]) {
            BigTypeView(song: $0.song)
        }
    }
}

private struct BigTypeView: View {
    let song: NowPlayingSnapshot
    @Environment(\.widgetFamily) private var family
    var body: some View {
        let ink = song.inkOnTint
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top) {
                Text(song.isPlaying ? "NOW PLAYING" : "PAUSED").font(.caption2.weight(.heavy)).tracking(2)
                Spacer(minLength: 0)
                if family == .systemMedium {
                    Cover(data: song.artwork, size: 40).rotationEffect(.degrees(6))
                        .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                }
            }
            Spacer(minLength: 0)
            Text(song.title)
                .font(.system(size: family == .systemSmall ? 28 : 34, weight: .black))
                .lineLimit(3).minimumScaleFactor(0.45)
            HStack(alignment: .lastTextBaseline) {
                Text(song.artist.uppercased()).font(.caption.weight(.bold)).tracking(1).lineLimit(1).opacity(0.7)
                Spacer(minLength: 4)
                PlayButton(isPlaying: song.isPlaying, size: 28, fill: ink, ink: song.tintColor)
            }
        }
        .foregroundStyle(ink)
        .containerBackground(for: .widget) {
            ZStack {
                song.tintColor
                Image(systemName: "music.note").font(.system(size: 220, weight: .black))
                    .foregroundStyle(ink.opacity(0.07)).rotationEffect(.degrees(-14)).offset(x: 70, y: -10)
            }
        }
    }
}

// MARK: - Click Wheel

struct ClickWheelWidget: Widget {
    var body: some WidgetConfiguration {
        songWidget("ClickWheel", "Click Wheel", "A pocket player from the 2000s. The wheel works.", [.systemSmall, .systemLarge]) {
            ClickWheelView(song: $0.song)
        }
    }
}

private struct ClickWheelView: View {
    let song: NowPlayingSnapshot
    @Environment(\.widgetFamily) private var family
    var body: some View {
        GeometryReader { g in
            let h = g.size.height, large = family == .systemLarge
            VStack(spacing: h * 0.04) {
                screen(large: large).frame(height: h * 0.46)
                Wheel(isPlaying: song.isPlaying, size: min(g.size.width, h * 0.5))
            }
            .frame(width: g.size.width, height: h)
        }
        .containerBackground(for: .widget) {
            LinearGradient(colors: [Color(white: 0.98), Color(white: 0.84)], startPoint: .top, endPoint: .bottom)
        }
    }

    private func screen(large: Bool) -> some View {
        let ink = Color(red: 0.12, green: 0.16, blue: 0.2)
        return VStack(alignment: .leading, spacing: large ? 8 : 3) {
            HStack(spacing: 3) {
                Image(systemName: song.isPlaying ? "play.fill" : "pause.fill")
                Spacer(minLength: 0)
                Text("Now Playing").fontWeight(.bold)
                Spacer(minLength: 0)
                Image(systemName: "battery.75percent")
            }
            .font(.system(size: large ? 11 : 7))
            .padding(.bottom, 1)
            .overlay(alignment: .bottom) { Rectangle().fill(ink.opacity(0.3)).frame(height: 0.5) }
            HStack(alignment: .top, spacing: large ? 10 : 5) {
                Cover(data: song.artwork, size: large ? 84 : 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(song.title).font(.system(size: large ? 15 : 8, weight: .bold)).lineLimit(2)
                    Text(song.artist).font(.system(size: large ? 13 : 7)).lineLimit(1)
                    if large, !song.album.isEmpty { Text(song.album).font(.system(size: 12)).lineLimit(1).opacity(0.7) }
                }
                Spacer(minLength: 0)
            }
            if large {
                Spacer(minLength: 0)
                TimedBar(song: song, ink: ink)
            }
        }
        .foregroundStyle(ink)
        .padding(large ? 10 : 5)
        .background(RoundedRectangle(cornerRadius: large ? 8 : 5)
            .fill(LinearGradient(colors: [Color(red: 0.86, green: 0.92, blue: 0.95), Color(red: 0.72, green: 0.8, blue: 0.85)],
                                 startPoint: .top, endPoint: .bottom)))
        .overlay(RoundedRectangle(cornerRadius: large ? 8 : 5).stroke(Color(white: 0.55), lineWidth: 1.5))
    }
}

private struct Wheel: View {
    let isPlaying: Bool
    let size: CGFloat
    var body: some View {
        let label = Font.system(size: size * 0.09, weight: .bold)
        ZStack {
            Circle().fill(Color(white: 0.93)).overlay(Circle().stroke(Color(white: 0.76), lineWidth: 1))
                .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
            Text("MENU").font(.system(size: size * 0.08, weight: .heavy)).offset(y: -size * 0.36)
            Button(intent: PreviousTrackIntent()) { target("backward.end.alt.fill", label) }.offset(x: -size * 0.36)
            Button(intent: NextTrackIntent()) { target("forward.end.alt.fill", label) }.offset(x: size * 0.36)
            Button(intent: TogglePlaybackIntent()) { target("playpause.fill", label) }.offset(y: size * 0.36)
            Button(intent: TogglePlaybackIntent()) {
                Circle().fill(LinearGradient(colors: [.white, Color(white: 0.9)], startPoint: .top, endPoint: .bottom))
                    .overlay(Circle().stroke(Color(white: 0.78), lineWidth: 1))
                    .frame(width: size * 0.38, height: size * 0.38)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color(white: 0.58))
        .frame(width: size, height: size)
    }

    private func target(_ symbol: String, _ font: Font) -> some View {
        Image(systemName: symbol).font(font)
            .frame(width: size * 0.26, height: size * 0.26).contentShape(Rectangle())
    }
}

// MARK: - Receipt

struct ReceiptWidget: Widget {
    var body: some WidgetConfiguration {
        songWidget("Receipt", "Receipt", "Proof of purchase for the song you're playing.", [.systemSmall, .systemLarge]) {
            ReceiptView(entry: $0)
        }
    }
}

private struct ReceiptView: View {
    let entry: NowPlayingEntry
    @Environment(\.widgetFamily) private var family
    var body: some View {
        let song = entry.song, large = family == .systemLarge
        let next = large ? Array(song.upNext.prefix(4)) : []
        VStack(spacing: large ? 5 : 2) {
            Text("MIXTAPE RECORDS").font(.system(size: large ? 16 : 10, weight: .black, design: .monospaced))
            if large { Text("★ EST. 2026 · OPEN ALL HOURS ★").font(.system(size: 8, design: .monospaced)) }
            Dashes()
            if large {
                HStack {
                    Text(entry.date, format: .dateTime.day().month(.abbreviated).year())
                    Spacer()
                    Text(entry.date, format: .dateTime.hour().minute())
                }
                Dashes()
            }
            HStack(alignment: .top, spacing: 4) {
                Text("1×")
                VStack(alignment: .leading, spacing: 0) {
                    Text(song.title.uppercased()).lineLimit(2)
                    if large { Text(song.artist).opacity(0.7).lineLimit(1) }
                }
                Spacer(minLength: 2)
                Text(clock(song.duration))
            }
            ForEach(Array(next.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 4) {
                    Text("1×")
                    Text(item.title.uppercased()).lineLimit(1)
                    Spacer(minLength: 2)
                    Text("NEXT")
                }
            }
            Dashes()
            HStack {
                Text("TOTAL").fontWeight(.black)
                Spacer()
                Text(clock(song.duration)).fontWeight(.black)
            }
            if large {
                HStack { Text("PAID IN"); Spacer(); Text("GOOD VIBES") }
                HStack { Text("CHANGE"); Spacer(); Text(song.isLiked ? "♥ LIKED" : "0:00") }
                Dashes()
            }
            Barcode(seed: song.title + song.artist).frame(height: large ? 26 : 14)
            Text(large ? "NO REFUNDS ON EARWORMS\nTHANK YOU FOR LISTENING" : "THANK YOU")
                .multilineTextAlignment(.center)
                .font(.system(size: large ? 8 : 6, weight: .bold, design: .monospaced))
        }
        .font(.system(size: large ? 10 : 7, design: .monospaced))
        .foregroundStyle(Color(white: 0.15))
        .padding(.horizontal, large ? 14 : 8)
        .padding(.top, large ? 12 : 6)
        .padding(.bottom, large ? 16 : 10)
        .background(ReceiptPaper().fill(Color(red: 0.99, green: 0.98, blue: 0.95)).shadow(color: .black.opacity(0.4), radius: 4, y: 2))
        .rotationEffect(.degrees(-2.5))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(for: .widget) {
            LinearGradient(colors: [Color(red: 0.22, green: 0.24, blue: 0.28), Color(red: 0.1, green: 0.11, blue: 0.13)],
                           startPoint: .top, endPoint: .bottom)
        }
    }
}

private struct Dashes: View {
    var body: some View {
        Line().stroke(style: StrokeStyle(lineWidth: 0.8, dash: [3, 2])).frame(height: 1).opacity(0.6)
    }
    private struct Line: Shape {
        func path(in r: CGRect) -> Path { Path { $0.move(to: CGPoint(x: r.minX, y: r.midY)); $0.addLine(to: CGPoint(x: r.maxX, y: r.midY)) } }
    }
}

/// A made-up barcode, the same for the same song.
private struct Barcode: View {
    let seed: String
    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(Array((seed + "MIXTAPE-RECORDS-0123456789").utf8.prefix(34).enumerated()), id: \.offset) { _, byte in
                Rectangle().frame(width: CGFloat(byte % 3) + 0.8)
            }
        }
    }
}

/// Paper with a torn, zigzag bottom edge.
private struct ReceiptPaper: Shape {
    func path(in r: CGRect) -> Path {
        let tooth: CGFloat = 5, n = max(2, Int(r.width / tooth)), step = r.width / CGFloat(n)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - tooth))
        for i in 1...n {
            p.addLine(to: CGPoint(x: r.maxX - CGFloat(i) * step, y: i % 2 == 1 ? r.maxY : r.maxY - tooth))
        }
        p.closeSubpath()
        return p
    }
}

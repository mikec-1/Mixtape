// The recap's share card, the slide that shows it, and the two ways into a
// recap: the Home card and the profile shelf.

import SwiftUI
import ImageIO
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Card

struct RecapCard: View {
    let r: RecapSnapshot
    let theme: RecapTheme
    let username: String
    let artists: [String: PlatformImage]
    let width: CGFloat
    var square = false
    var rounded = true

    static let themes: [(name: String, theme: RecapTheme)] = [
        ("Tangerine", RecapTheme("FF6B00", "140B05", "140B05")),
        ("Bubblegum", RecapTheme("FF8FC0", "2A0A18", "2A0A18")),
        ("Cobalt",    RecapTheme("2F45FF", "FFFFFF", "FFC93C")),
        ("Mint",      RecapTheme("8BE3C0", "06261B", "06261B")),
        ("Ink",       RecapTheme("141212", "F4EEE7", "FF6B00")),
    ]

    /// Sizes are a percentage of the card's width, as in the design.
    private func p(_ x: CGFloat) -> CGFloat { x * width / 100 }
    private var month: String { Calendar.current.monthSymbols[r.monthNumber - 1] }

    var body: some View {
        VStack(alignment: .leading, spacing: p(square ? 3.4 : 4.2)) {
            HStack {
                HStack(spacing: p(1.4)) {
                    Image(systemName: "recordingtape").font(.system(size: p(5.2) * 0.8, weight: .semibold))
                    Text("Mixtape").font(.system(size: p(4.4), weight: .heavy))
                }
                Spacer()
                Text("@\(username)").font(mono(3.3)).tracking(p(3.3) * 0.05)
            }
            title
            if !square { discs }
            HStack(spacing: p(2)) {
                stat(r.minutes, "minutes")
                stat(r.plays, "plays")
                stat(r.songs, "songs")
            }
            HStack(alignment: .top, spacing: p(4)) {
                column("Top songs", r.topSongs.map { ($0.title, $0.artist) })
                column("Top artists", r.topArtists.map { ($0.name, "\($0.minutes.formatted()) min") })
            }
            if !square {
                if !r.genres.isEmpty { genres }
                WordFlow(spacing: p(1.6), lineSpacing: p(1.6)) {
                    ForEach(chips, id: \.self) { chip in
                        Text(chip)
                            .font(.system(size: p(3), weight: .semibold))
                            .padding(.vertical, p(1.2)).padding(.horizontal, p(2.6))
                            .overlay(Capsule().strokeBorder(theme.fg, lineWidth: p(0.35)))
                    }
                }
            }
            Spacer(minLength: 0)
            HStack {
                Text("mixtaped.tech/@\(username)")
                Spacer()
                Text(String(format: "%02d · %d", r.monthNumber, r.year))
            }
            .font(mono(2.8))
            .opacity(0.75)
        }
        .lineLimit(1)
        .padding(.top, p(6.5)).padding(.horizontal, p(6.5)).padding(.bottom, p(5.5))
        .frame(width: width, height: square ? width : width * 16 / 9, alignment: .topLeading)
        .background(theme.bg)
        .foregroundStyle(theme.fg)
        .clipShape(RoundedRectangle(cornerRadius: rounded ? p(3.9) : 0))
        .accessibilityElement(children: .combine)
    }

    private func mono(_ size: CGFloat) -> Font { .system(size: p(size), weight: .medium, design: .monospaced) }

    @ViewBuilder private var title: some View {
        let font = Font.system(size: p(13.5), weight: .heavy).width(.condensed)
        Group {
            if square {
                Text("\(month) \(String(r.year))").minimumScaleFactor(0.4)
            } else {
                VStack(alignment: .leading, spacing: -p(13.5) * 0.16) {
                    Text(month).minimumScaleFactor(0.5)
                    Text(String(r.year))
                }
            }
        }
        .font(font)
        .tracking(-p(13.5) * 0.03)
        .foregroundStyle(theme.acc)
    }

    private var discs: some View {
        HStack(spacing: -p(4.5)) {
            ForEach(r.topArtists.prefix(3).map(\.name), id: \.self) { name in
                ArtistDisc(image: artists[name], name: name, size: p(21), font: p(4))
                    .background(Circle().fill(theme.bg).padding(-p(1)))
            }
        }
    }

    private func stat(_ n: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: p(0.4)) {
            Text(n.formatted()).font(.system(size: p(7), weight: .heavy)).monospacedDigit()
                .minimumScaleFactor(0.6)
            Text(label.uppercased()).font(mono(2.7)).tracking(p(2.7) * 0.06).opacity(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func column(_ header: String, _ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(header.uppercased()).font(mono(2.8)).tracking(p(2.8) * 0.07).opacity(0.7)
                .padding(.bottom, p(1.8))
            VStack(alignment: .leading, spacing: p(1.9)) {
                ForEach(Array(rows.prefix(square ? 3 : 5).enumerated()), id: \.offset) { i, row in
                    HStack(alignment: .firstTextBaseline, spacing: p(1.4)) {
                        Text("\(i + 1)").font(.system(size: p(3.5), weight: .heavy)).opacity(0.55)
                            .frame(width: p(3.6), alignment: .leading)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(row.0).font(.system(size: p(3.5), weight: .bold))
                                .lineLimit(2).minimumScaleFactor(0.8)
                            Text(row.1).font(.system(size: p(2.9))).opacity(0.7)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var genres: some View {
        let top = Array(r.genres.prefix(5))
        let rest = max(0, 1 - top.reduce(0) { $0 + $1.share })
        let shares = top.map(\.share) + (rest > 0.005 ? [rest] : [])
        let opacities = [1, 0.72, 0.52, 0.36, 0.24, 0.12]
        let gap = p(0.6)
        let room = width - p(13) - gap * CGFloat(shares.count - 1)
        let total = shares.reduce(0, +)
        return VStack(alignment: .leading, spacing: p(1.6)) {
            HStack(spacing: gap) {
                ForEach(shares.indices, id: \.self) { i in
                    Rectangle().fill(theme.fg).opacity(i < top.count ? opacities[i] : 0.12)
                        .frame(width: room * shares[i] / total)
                }
            }
            .frame(height: p(2.8))
            .clipShape(Capsule())
            Text(r.genres.prefix(3).map { "\($0.name) \(Int(($0.share * 100).rounded()))%" }.joined(separator: " · "))
                .font(.system(size: p(3))).opacity(0.8)
        }
    }

    private var chips: [String] {
        var c = [RecapMath.clockBlock(r.playsByHour).block.title, "\(r.loyalPct)% loyal"]
        if r.bestStreak > 1 { c.append("\(r.bestStreak)-day streak") }
        if let rep = r.onRepeat { c.append("On repeat: \(rep.song.title)") }
        return c
    }
}

// MARK: - Export

enum RecapExport {
    /// A 1080 wide PNG of the card, square or 9:16.
    static func png(_ r: RecapSnapshot, theme: RecapTheme, username: String,
                    artists: [String: PlatformImage], square: Bool) -> Data? {
        png(RecapCard(r: r, theme: theme, username: username, artists: artists,
                      width: 360, square: square, rounded: false))
    }

    /// Any view at 3x, like a story slide.
    static func png(_ view: some View) -> Data? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        guard let image = renderer.cgImage else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    static func name(_ r: RecapSnapshot, square: Bool) -> String {
        "\(Calendar.current.monthSymbols[r.monthNumber - 1]) \(r.year) recap\(square ? " (square)" : "").png"
    }

    /// The slide when there is one, the card, and the link to the whole recap. The link only opens
    /// for others once the recap is on the profile, so sending it from a private one puts it there.
    @MainActor
    static func choices(_ recap: RecapService.Recap, mine: Bool, username: String, theme: RecapTheme,
                        artists: [String: PlatformImage], slide: Data? = nil,
                        deps: AppDependencies) -> [ShareChoice] {
        let r = recap.payload
        let title = "\(Calendar.current.monthSymbols[r.monthNumber - 1]) \(r.year)"
        let live = deps.recap.recaps.first { $0.month == recap.month }
        let shareID = recap.shareID ?? live?.shareID
        let isPrivate = mine && !(live?.shared ?? recap.shared)
        var items: [(String, ShareItem)] = []
        if let slide { items.append(("This Slide", .recap(slide, title: title, username: username, shareID: shareID))) }
        if let card = png(r, theme: theme, username: username, artists: artists, square: false) {
            items.append(("Card", .recap(card, title: title, username: username, shareID: shareID)))
        }
        if let shareID {
            let square = png(r, theme: theme, username: username, artists: artists, square: true)
            items.append(("Link", ShareItem(url: MixtapeLink.recap(shareID: shareID), noun: "Recap", title: title,
                                            subtitle: "@\(username)", artwork: .stored(square, nil))))
        }
        return items.map { label, item in
            var item = item
            if isPrivate { item.beforeLink = { deps.recap.setShared(true, month: recap.month) } }
            return ShareChoice(label: label, item: item,
                               note: isPrivate ? "Sharing the link puts this recap on your profile." : nil)
        }
    }
}

// MARK: - Card slide

struct RecapCardSlide: View {
    let recap: RecapService.Recap
    let isOwner: Bool
    let username: String
    @ObservedObject var images: RecapImages
    let mac: Bool
    let onWatchAgain: () -> Void

    @Environment(AppDependencies.self) private var deps
    @State private var look = 0
    @State private var saved = false

    private var r: RecapSnapshot { recap.payload }
    private var theme: RecapTheme { RecapCard.themes[look].theme }
    private let fg = RecapTheme.ink.fg

    var body: some View {
        Group {
            if mac {
                HStack(spacing: 56) {
                    GeometryReader { g in
                        card(width: min(g.size.width, g.size.height * 9 / 16))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .aspectRatio(9 / 16, contentMode: .fit)
                    controls.frame(width: 280)
                }
                .padding(.top, 64).padding(.horizontal, 104).padding(.bottom, 36)
            } else {
                VStack(spacing: 14) {
                    GeometryReader { g in
                        card(width: min(g.size.width, g.size.height * 9 / 16))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    controls
                }
                .padding(.top, 50).padding(.horizontal, 16).padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func card(width: CGFloat) -> some View {
        RecapCard(r: r, theme: theme, username: username, artists: images.artists, width: width)
            .shadow(color: .black.opacity(0.45), radius: 20, y: 12)
            .animation(.easeInOut(duration: 0.3), value: look)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                ForEach(RecapCard.themes.indices, id: \.self) { i in
                    Button { look = i } label: {
                        Circle().fill(RecapCard.themes[i].theme.bg)
                            .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                            .frame(width: 26, height: 26)
                            .overlay(Circle().stroke(fg, lineWidth: 2).padding(-5).opacity(look == i ? 1 : 0))
                    }
                    .buttonStyle(.plain)
                    .mixHandCursor()
                    .accessibilityLabel(RecapCard.themes[i].name)
                    .accessibilityAddTraits(look == i ? .isSelected : [])
                }
            }
            .padding(.vertical, 5)

            HStack(spacing: 8) {
                Button {
                    ShareSheet.present(RecapExport.choices(recap, mine: isOwner, username: username, theme: theme,
                                                           artists: images.artists, deps: deps), deps: deps)
                } label: { tile("square.and.arrow.up", "Share") }
                    .buttonStyle(.plain)
                Button(action: save) { tile(saved ? "checkmark" : "arrow.down.to.line", saved ? "Saved" : "Save image") }
                    .buttonStyle(.plain)
                Button(action: onWatchAgain) { tile("arrow.counterclockwise", "Watch again") }
                    .buttonStyle(.plain)
            }
            .mixHandCursor()

            // A developer preview isn't stored, so there's nothing to share.
            if isOwner, deps.recap.recaps.contains(where: { $0.month == recap.month }) { visibility }
        }
        .foregroundStyle(fg)
    }

    private func tile(_ symbol: String, _ label: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 19)).frame(height: 22)
            Text(label).font(.system(size: 11.5, weight: .semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9).padding(.horizontal, 4)
        .background(fg.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    private var visibility: some View {
        let shared = deps.recap.recaps.first { $0.month == recap.month }?.shared ?? recap.shared
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Label("Show on profile", systemImage: shared ? "globe" : "lock.fill")
                    .font(.system(size: 13, weight: .semibold))
                Text(shared ? "Anyone who opens your profile can see it." : "Private. Only you can see this recap.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(fg.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Toggle("Show on profile", isOn: Binding(
                get: { shared },
                set: { deps.recap.setShared($0, month: recap.month) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Color(hex: "FF6B00"))
        }
        .padding(.vertical, 9).padding(.horizontal, 12)
        .background(fg.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
    }

    /// Story and square both, to Photos on iOS and a picked folder on the Mac.
    private func save() {
        let files = [false, true].compactMap { square in
            RecapExport.png(r, theme: theme, username: username, artists: images.artists, square: square)
                .map { (RecapExport.name(r, square: square), $0) }
        }
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save"
        panel.message = "Choose where to save your recap images"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        for (name, data) in files { try? data.write(to: folder.appendingPathComponent(name)) }
        #else
        for (_, data) in files {
            if let image = UIImage(data: data) { UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil) }
        }
        #endif
        Haptics.play(.success)
        saved = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            saved = false
        }
    }
}

// MARK: - Home card

/// Last month's recap until it's watched or put off, with the month's Tape under it.
struct RecapHomeCard: View {
    let recap: RecapService.Recap
    let tape: SmartPlaylist?
    let onTape: (SmartPlaylist) -> Void

    @Environment(AppDependencies.self) private var deps

    #if os(macOS)
    private let mac = true
    #else
    private let mac = false
    #endif

    private static let ink = Color(hex: "140B05")
    private var r: RecapSnapshot { recap.payload }
    private var month: String { Calendar.current.monthSymbols[r.monthNumber - 1] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: mac ? 10 : 8) {
                    Text("NEW · \(month.uppercased()) RECAP")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .tracking(0.8)
                        .opacity(0.75)
                    Text("Your \(month) is in")
                        .font(.system(size: mac ? 40 : 27, weight: .heavy))
                        .tracking(mac ? -1 : -0.6)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                    Text("\(RecapService.hours(r.minutes)), \(r.songs.formatted()) songs"
                         + (r.onRepeat == nil ? "." : " and one you couldn't stop playing."))
                        .font(.system(size: 13.5))
                        .frame(maxWidth: 13.5 * 17, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button { deps.recap.watch(recap) } label: {
                            Label("Watch", systemImage: "play.fill")
                                .font(.system(size: 13.5, weight: .bold))
                                .foregroundStyle(Color(hex: "FF6B00"))
                                .padding(.vertical, 9).padding(.horizontal, 16)
                                .background(Self.ink, in: Capsule())
                        }
                        Button { deps.recap.dismiss(recap) } label: {
                            Text("Later")
                                .font(.system(size: 13.5, weight: .semibold))
                                .padding(.vertical, 9).padding(.horizontal, 12)
                                .opacity(0.72)
                        }
                    }
                    .buttonStyle(.plain)
                    .mixHandCursor()
                    .padding(.top, 4)
                }
                Spacer(minLength: 0)
                covers
            }
            .padding(.vertical, mac ? 26 : 18).padding(.horizontal, mac ? 28 : 18)
            .foregroundStyle(Self.ink)
            .background(Color(hex: "FF6B00"), in: RoundedRectangle(cornerRadius: 18))

            if let tape { tapeRow(tape) }
        }
        .task(id: recap.month) { await RecapClips.warm(RecapClips.plan(r, mine: true, tape: tape != nil, deps: deps), deps: deps) }
    }

    private var covers: some View {
        let area = mac ? CGSize(width: 170, height: 150) : CGSize(width: 92, height: 118)
        let side = area.width * 0.62
        let ids = r.topSongs.prefix(3).map(\.trackID)
        let spots: [(x: CGFloat, y: CGFloat, tilt: Double)] = [
            (0, area.height * 0.04, -9),
            (area.width - side, 0, 7),
            (area.width * 0.18, area.height - side, -2),
        ]
        return ZStack(alignment: .topLeading) {
            ForEach(Array(ids.enumerated()), id: \.offset) { i, id in
                AsyncArtworkImage(source: .row(.track(id)), size: side) {
                    Rectangle().fill(Self.ink.opacity(0.2))
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .shadow(color: .black.opacity(0.35), radius: 10, y: 8)
                .rotationEffect(.degrees(spots[i].tilt))
                .offset(x: spots[i].x, y: spots[i].y)
            }
        }
        .frame(width: area.width, height: area.height, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    private func tapeRow(_ tape: SmartPlaylist) -> some View {
        let seconds = deps.smartTracks(tape).reduce(0) { $0 + $1.duration }
        let h = Int(seconds) / 3600, m = Int(seconds) % 3600 / 60
        return Button { onTape(tape) } label: {
            HStack(spacing: 12) {
                SmartPlaylistCover(playlist: tape, size: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(month) Tape").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                    Text("Your top 25 · " + (h > 0 ? "\(h) hr \(m) min" : "\(m) min"))
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color(hex: "9A9A9A"))
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(hex: "9A9A9A"))
            }
            .padding(10)
            .background(Color(hex: "1B1B1B"), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .mixHandCursor()
    }
}

// MARK: - Profile shelf

/// A recap on a profile: the card's colours with the month on it.
struct RecapShelfTile: View {
    let recap: RecapService.Recap
    let action: () -> Void

    private var r: RecapSnapshot { recap.payload }

    var body: some View {
        let theme = RecapCard.themes[(r.monthNumber - 1) % RecapCard.themes.count].theme
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 0) {
                    Image(systemName: "recordingtape").font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 0)
                    Text(Calendar.current.shortMonthSymbols[r.monthNumber - 1])
                        .font(.system(size: 30, weight: .heavy).width(.condensed))
                        .foregroundStyle(theme.acc)
                    Text("\(RecapService.hours(r.minutes))")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .opacity(0.75)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .aspectRatio(3 / 4, contentMode: .fit)
                .foregroundStyle(theme.fg)
                .background(theme.bg, in: RoundedRectangle(cornerRadius: 12))
                Text("\(Calendar.current.monthSymbols[r.monthNumber - 1]) \(String(r.year))")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.mixTextPrimary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .mixHandCursor()
        .accessibilityLabel("\(Calendar.current.monthSymbols[r.monthNumber - 1]) \(String(r.year)) recap")
    }
}

/// The Home card while last month's recap is unwatched.
struct RecapHomeSlot: View {
    var recap: RecapService
    @Environment(SmartPlaylistService.self) private var smartService
    let onTape: (SmartPlaylist) -> Void

    var body: some View {
        if let fresh = recap.fresh {
            let r = fresh.payload
            // Archived tapes are left out of the shelves, so search them all.
            let tape = smartService.tape(year: r.year, month: r.monthNumber)
            RecapHomeCard(recap: fresh, tape: tape, onTape: onTape)
                .transition(.opacity)
        }
    }
}

/// The Recaps section on a profile. Your own shows every month; anyone else's
/// only the ones they've shared.
struct RecapShelf: View {
    var recap: RecapService
    let profile: UserProfile
    let isMe: Bool
    /// Someone else's shared recaps.
    let others: [RecapService.Recap]

    var body: some View {
        let items = isMe ? recap.recaps : others
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Recaps")
                        .font(.mixTitle)
                        .foregroundStyle(Color.mixTextPrimary)
                    if isMe {
                        Text("Only the ones you choose to show are visible to others")
                            .font(.mixCaption)
                            .foregroundStyle(Color.mixTextTertiary)
                    }
                }
                #if os(macOS)
                let column = GridItem(.adaptive(minimum: 130, maximum: 160), spacing: 14, alignment: .top)
                #else
                let column = GridItem(.adaptive(minimum: 104), spacing: 14, alignment: .top)
                #endif
                LazyVGrid(columns: [column], alignment: .leading, spacing: 14) {
                    ForEach(items) { r in
                        RecapShelfTile(recap: r) {
                            recap.open(r, owner: isMe ? nil : profile, atCard: true)
                        }
                    }
                }
            }
        }
    }
}

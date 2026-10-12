// The Jam: a pill over the player bars, and a sheet to start, join or run one.
// Opened from the pill, the device picker, the command palette, Messages and Jam links.

import SwiftUI

extension Notification.Name {
    /// Focuses the search field; the Jam sheet's Add songs tile.
    static let mixFocusSearch = Notification.Name("mix.focusSearch")
}

/// Presents the Jam sheet from the root, so links and the picker share it.
struct JamSheetPresenter: View {
    @ObservedObject var jam: JamService
    @EnvironmentObject private var deps: AppDependencies

    var body: some View {
        Color.clear
            .sheet(isPresented: $jam.isSheetPresented) { JamSheet(jam: jam).environmentObject(deps) }
    }
}

/// One row per person, not per device. Host first.
@MainActor
private func people(_ jam: JamService) -> [JamService.Member] {
    var seen = Set<String>()
    return jam.members.sorted { $0.host && !$1.host }.filter { seen.insert($0.userID).inserted }
}

private var jamGradient: LinearGradient {
    LinearGradient(colors: [.mixAccentFill, .mixPrimaryDark], startPoint: .topLeading, endPoint: .bottomTrailing)
}

// MARK: - Player bar pill

/// Floats over the player bars while in a Jam. Tapping opens the Jam sheet.
struct JamStrip: View {
    @ObservedObject var jam: JamService
    var alignment: Alignment = .center
    var hPadding: CGFloat = 14

    var body: some View {
        if let session = jam.session {
            Button { jam.isSheetPresented = true } label: {
                HStack(spacing: 8) {
                    JamAvatarStack(names: people(jam).map(\.avatarSeed), size: 20, ring: .mixPrimaryDark)
                    Text(title(session))
                        .font(.mixCaptionBold)
                        .lineLimit(1)
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(Color.mixOnAccent)
                .padding(.leading, 3)
                .padding(.trailing, 12)
                .padding(.vertical, 3)
                .background(jamGradient, in: Capsule())
                .mixShadow(color: Color.mixPrimaryDark.opacity(0.35), radius: 6, y: 2)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain).mixHandCursor()
            .frame(maxWidth: .infinity, alignment: alignment)
            .padding(.horizontal, hPadding)
            .padding(.vertical, 6)
            .accessibilityLabel("\(title(session)). Open the Jam")
        }
    }

    private func title(_ s: JamService.Session) -> String {
        let name = s.isHost ? "Your Jam" : "\(s.hostName)\u{2019}s Jam"
        let n = people(jam).count
        return n > 1 ? "\(name) · \(n) listening" : name
    }
}

// MARK: - Profile banner

/// "Sam is in a Jam", on a friend's profile.
struct JamBanner: View {
    let name: String
    let code: String
    @EnvironmentObject private var deps: AppDependencies

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "person.2.wave.2.fill")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(Color.mixOnAccent.opacity(0.18), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("\(name) is in a Jam")
                    .font(.mixBodyBold)
                Text("Join to add songs and listen along.")
                    .font(.mixSubtext)
                    .opacity(0.85)
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            Button { Task { await deps.jam.join(code: code) } } label: {
                Text("Join")
                    .font(.mixButtonSmall)
                    .foregroundStyle(Color.mixAccentFill)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(Color.mixOnAccent, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain).mixHandCursor()
            .accessibilityLabel("Join \(name)\u{2019}s Jam")
        }
        .foregroundStyle(Color.mixOnAccent)
        .padding(14)
        .background(jamGradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Avatars

/// The person's blob. Pass `Member.avatarSeed`; nearby Jams only know the host's name.
struct JamAvatar: View {
    let name: String
    var size: CGFloat = 32

    var body: some View {
        BlobAvatar(seed: name)
            .frame(width: size, height: size)
            .clipShape(Circle())
    }
}

struct JamAvatarStack: View {
    let names: [String]
    var size: CGFloat = 32
    /// The colour behind the stack, so overlaps read as separate faces.
    var ring: Color = .mixBackground

    var body: some View {
        HStack(spacing: -size * 0.3) {
            ForEach(Array(names.prefix(4).enumerated()), id: \.offset) { _, name in
                JamAvatar(name: name, size: size)
                    .overlay(Circle().strokeBorder(ring, lineWidth: max(1.5, size * 0.07)))
            }
        }
    }
}

// MARK: - Sheet

struct JamSheet: View {
    @ObservedObject var jam: JamService

    var body: some View {
        if let session = jam.session {
            MixSheet(title: session.isHost ? "Your Jam" : "\(session.hostName)\u{2019}s Jam",
                     subtitle: session.isHost ? "Everyone adds to one queue. This device plays it."
                                              : "Songs you add go into \(session.hostName)\u{2019}s queue.",
                     size: .large, cancelTitle: "Done") {
                JamLiveView(jam: jam, session: session)
            }
        } else {
            MixSheet(title: "Jam", subtitle: "Listen together, in the same room or miles apart.",
                     size: .medium, cancelTitle: "Done") {
                JamStartView(jam: jam)
            }
        }
    }
}

// MARK: Not in a Jam

private struct JamStartView: View {
    @ObservedObject var jam: JamService
    @State private var code = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            hero
            NearbyJams(jam: jam)
            VStack(alignment: .leading, spacing: 10) {
                JamSectionTitle("Join with a code")
                JamCodeField(code: $code) { full in
                    Task {
                        await jam.join(code: full)
                        if jam.session == nil { code = "" }
                    }
                }
                Text("Ask the host for the code in their Jam, or scan their QR code with your camera.")
                    .font(.mixSubtext)
                    .foregroundStyle(Color.mixTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { jam.nearby.startBrowsing() }
        .onDisappear { jam.nearby.stopBrowsing() }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "person.2.wave.2.fill")
                .font(.system(size: 26, weight: .semibold))
            VStack(alignment: .leading, spacing: 4) {
                Text("Start a Jam")
                    .font(.mixTitle)
                Text("Friends add songs to your queue and can listen along on their own devices.")
                    .font(.mixSubtext)
                    .opacity(0.85)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button { Task { await jam.start() } } label: {
                ZStack {
                    Text("Start").opacity(jam.isBusy ? 0 : 1)
                    if jam.isBusy { ProgressView().controlSize(.small).tint(Color.mixAccentFill) }
                }
                .font(.mixButton)
                .foregroundStyle(Color.mixAccentFill)
                .padding(.horizontal, 28)
                .padding(.vertical, 10)
                .background(Color.mixOnAccent, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain).mixHandCursor()
            .disabled(jam.isBusy)
        }
        .foregroundStyle(Color.mixOnAccent)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(jamGradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// Six boxes over a hidden field. Calls `onComplete` once all six are in;
/// a pasted Jam link is cut down to its code.
struct JamCodeField: View {
    @Binding var code: String
    var onComplete: (String) -> Void
    @FocusState private var focused: Bool

    static let length = 6
    private static let alphabet = Set("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    static func clean(_ raw: String) -> String {
        let tail = raw.range(of: "code=", options: .caseInsensitive).map { String(raw[$0.upperBound...]) } ?? raw
        return String(tail.uppercased().filter(alphabet.contains).prefix(length))
    }

    var body: some View {
        ZStack {
            TextField("", text: $code)
                .focused($focused)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.characters)
                .keyboardType(.asciiCapable)
                #else
                .focusEffectDisabled()
                #endif
                .opacity(0.001)
                .accessibilityLabel("Jam code")
                .onChange(of: code) { _, new in
                    let clean = Self.clean(new)
                    guard clean == new else { code = clean; return }
                    if clean.count == Self.length { onComplete(clean) }
                }
            HStack(spacing: 8) {
                ForEach(0..<Self.length, id: \.self) { box($0) }
            }
            .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .onAppear { focused = true }
        .mixHandCursor()
    }

    private func box(_ i: Int) -> some View {
        let chars = Array(code)
        let active = focused && i == min(chars.count, Self.length - 1)
        return Text(i < chars.count ? String(chars[i]) : " ")
            .font(.system(size: 24, weight: .bold, design: .rounded))
            .foregroundStyle(Color.mixTextPrimary)
            .frame(maxWidth: 56)
            .frame(height: 58)
            .frame(maxWidth: .infinity)
            .background(Color.mixSurface2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(active ? Color.mixPrimary : Color.mixSeparator, lineWidth: active ? 2 : 1))
    }
}

/// Jams on the same network. The parent browses while it's on screen.
struct NearbyJams: View {
    @ObservedObject var jam: JamService
    /// Closes whatever this sits in before joining opens the Jam sheet.
    var onPick: (() -> Void)? = nil
    @ObservedObject private var nearby: JamNearby

    init(jam: JamService, onPick: (() -> Void)? = nil) {
        self.jam = jam
        self.onPick = onPick
        nearby = jam.nearby
    }

    var body: some View {
        let found = nearby.found.filter { $0.code != jam.session?.code }
        if !found.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                JamSectionTitle("Jams near you")
                ForEach(found) { f in
                    HStack(spacing: 12) {
                        JamAvatar(name: f.host, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(f.host)\u{2019}s Jam")
                                .font(.mixBodyBold)
                                .foregroundStyle(Color.mixTextPrimary)
                            Text("On your network")
                                .font(.mixSubtext)
                                .foregroundStyle(Color.mixTextSecondary)
                        }
                        Spacer(minLength: 8)
                        Button {
                            let pick = onPick
                            Task {
                                if let pick { pick(); try? await Task.sleep(for: .milliseconds(350)) }
                                await jam.join(code: f.code)
                            }
                        } label: {
                            JamPill(title: "Join", filled: true)
                        }
                        .buttonStyle(.plain).mixHandCursor()
                        .disabled(jam.isBusy)
                    }
                    .padding(10)
                    .background(Color.mixSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
    }
}

// MARK: In a Jam

private struct JamLiveView: View {
    @ObservedObject var jam: JamService
    let session: JamService.Session
    @EnvironmentObject private var deps: AppDependencies
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var showInvite = false
    @State private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header
            output
            upNext
            members
        }
        .sheet(isPresented: $showInvite) { JamInviteSheet(session: session).environmentObject(deps) }
        .sheet(isPresented: $showSettings) { JamSettingsSheet(jam: jam) }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                JamAvatarStack(names: people(jam).map(\.avatarSeed), size: 40, ring: .mixAccentFill)
                Button { showInvite = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .bold))
                        .frame(width: 40, height: 40)
                        .background(Color.mixOnAccent.opacity(0.18), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain).mixHandCursor()
                .accessibilityLabel("Invite people")
                Spacer(minLength: 8)
                if session.isHost {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 36, height: 36)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain).mixHandCursor()
                    .accessibilityLabel("Jam settings")
                }
                Button { jam.leave(); dismiss() } label: {
                    Text(session.isHost ? "End" : "Leave")
                        .font(.mixButtonSmall)
                        .foregroundStyle(Color.mixAccentFill)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(Color.mixOnAccent, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain).mixHandCursor()
                .accessibilityLabel(session.isHost ? "End the Jam" : "Leave the Jam")
            }
            Text(status)
                .font(.mixSubtext)
                .opacity(0.9)
        }
        .foregroundStyle(Color.mixOnAccent)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(jamGradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var status: String {
        if !session.isHost, !jam.hostPresent { return "Waiting for \(session.hostName) to connect\u{2026}" }
        let n = people(jam).count
        if n > 1 { return "\(n) listening" }
        return "Tap + to invite friends"
    }

    // MARK: Where it plays

    private static let deviceIcon: String = {
        #if os(macOS)
        return "laptopcomputer"
        #else
        return "iphone"
        #endif
    }()

    @ViewBuilder
    private var output: some View {
        if session.isHost {
            outputLabel(icon: Self.deviceIcon, title: "Playing on this device", chevron: false)
        } else {
            // Only where the audio comes out; the queue is the host's either way.
            Menu {
                Picker("Listen on", selection: Binding(get: { jam.playsHere }, set: { jam.setPlaysHere($0) })) {
                    Label("This device", systemImage: Self.deviceIcon).tag(true)
                    Label("\(session.hostName)\u{2019}s device", systemImage: "hifispeaker.fill").tag(false)
                }
                .pickerStyle(.inline)
            } label: {
                outputLabel(icon: jam.playsHere ? Self.deviceIcon : "hifispeaker.fill",
                            title: jam.playsHere ? "Playing on this device"
                                                 : "Playing on \(session.hostName)\u{2019}s device",
                            chevron: true)
            }
            .menuStyle(.button)
            .buttonStyle(.plain).mixHandCursor()
            .menuIndicator(.hidden)
        }
    }

    private func outputLabel(icon: String, title: String, chevron: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.mixPrimary)
                .frame(width: 36, height: 36)
                .background(Color.mixPrimary.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text("Listening on")
                    .font(.mixCaption)
                    .foregroundStyle(Color.mixTextSecondary)
                Text(title)
                    .font(.mixBodyBold)
                    .foregroundStyle(Color.mixTextPrimary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if chevron {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.mixTextSecondary)
            }
        }
        .padding(10)
        .background(Color.mixSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
    }

    // MARK: Up next

    private var upNext: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Up next")
                    .font(.mixTitle2)
                    .foregroundStyle(Color.mixTextPrimary)
                Spacer()
                if !jam.upNext.isEmpty {
                    Button { withAnimation(.snappy) { editing.toggle() } } label: {
                        JamPill(title: editing ? "Done" : "Edit", filled: editing)
                    }
                    .buttonStyle(.plain).mixHandCursor()
                }
            }

            HStack(spacing: 10) {
                JamTile(icon: "shuffle", title: "Shuffle", active: jam.shuffle) {
                    jam.setShuffle(!jam.shuffle)
                }
                JamTile(icon: jam.repeatMode == .one ? "repeat.1" : "repeat", title: "Repeat",
                        active: jam.repeatMode != .off) {
                    jam.cycleRepeat()
                }
                JamTile(icon: "plus", title: "Add songs", active: false) {
                    dismiss()
                    Task {
                        try? await Task.sleep(for: .milliseconds(350))
                        NotificationCenter.default.post(name: .mixFocusSearch, object: nil)
                    }
                }
            }

            if jam.shuffle {
                Button { jam.reshuffle() } label: {
                    JamPill(title: "Reshuffle", icon: "shuffle", filled: false)
                }
                .buttonStyle(.plain).mixHandCursor()
            }

            if jam.upNext.isEmpty {
                Text("Nothing queued yet. Tap Add songs, or use Add to Queue on any song.")
                    .font(.mixSubtext)
                    .foregroundStyle(Color.mixTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(jam.upNext.enumerated()), id: \.offset) { i, item in
                row(i, item)
            }
        }
    }

    private func row(_ i: Int, _ item: JamService.Item) -> some View {
        HStack(spacing: 12) {
            if editing {
                Button { jam.removeUpNext(at: [i]) } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 20))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.mixDestructive)
                }
                .buttonStyle(.plain).mixHandCursor()
                .accessibilityLabel("Remove \(item.title)")
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
            AsyncImage(url: item.coverURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.mixSurface2
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.mixBody)
                    .foregroundStyle(Color.mixTextPrimary)
                    .lineLimit(1)
                Text(item.addedBy.map { "\(item.artist) · Added by \($0)" } ?? item.artist)
                    .font(.mixSubtext)
                    .foregroundStyle(Color.mixTextSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if editing {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.mixTextTertiary)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .draggable(item.row?.uuidString ?? "")
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first,
                  let from = jam.upNext.firstIndex(where: { $0.row?.uuidString == id }), from != i
            else { return false }
            jam.moveUpNext(from: IndexSet(integer: from), to: i > from ? i + 1 : i)
            return true
        }
    }

    // MARK: People

    private var members: some View {
        VStack(alignment: .leading, spacing: 10) {
            JamSectionTitle("In this Jam")
            ForEach(people(jam)) { member in
                HStack(spacing: 12) {
                    JamAvatar(name: member.avatarSeed, size: 32)
                    Text(member.name)
                        .font(.mixBody)
                        .foregroundStyle(Color.mixTextPrimary)
                    if member.host {
                        Text("Host")
                            .font(.mixCaptionBold)
                            .foregroundStyle(Color.mixPrimary)
                    }
                    Spacer()
                    if session.isHost, !member.host {
                        Button("Remove") { jam.remove(member) }
                            .buttonStyle(.plain).mixHandCursor()
                            .font(.mixSubtext)
                            .foregroundStyle(Color.mixDestructive)
                    }
                }
            }
        }
    }
}

// MARK: - Settings (host)

private struct JamSettingsSheet: View {
    @ObservedObject var jam: JamService

    var body: some View {
        MixSheet(title: "Jam settings", size: .compact, cancelTitle: "Done") {
            VStack(alignment: .leading, spacing: 20) {
                toggle("Play, pause, and skip tracks",
                       note: "Let guests control playback. Only you can start it again once it stops.",
                       isOn: Binding(get: { jam.session?.guestsControl ?? true },
                                     set: { jam.setGuestsControl($0) }))
                toggle("Let people nearby find this Jam",
                       note: "Shows it to Mixtape users on the same Wi-Fi, so they can join without the code.",
                       isOn: Binding(get: { jam.isDiscoverable }, set: { jam.setDiscoverable($0) }))
            }
        }
    }

    private func toggle(_ title: String, note: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.mixBodyBold)
                    .foregroundStyle(Color.mixTextPrimary)
                Text(note)
                    .font(.mixSubtext)
                    .foregroundStyle(Color.mixTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .tint(Color.mixPrimary)
    }
}

// MARK: - Invite

private struct JamInviteSheet: View {
    let session: JamService.Session
    @EnvironmentObject private var deps: AppDependencies
    @State private var copied = false

    var body: some View {
        let link = JamService.link(for: session.code)
        MixSheet(title: "Invite to Jam", subtitle: "Friends scan the code or open the link to join.",
                 size: .medium, cancelTitle: "Done") {
            VStack(spacing: 18) {
                if let qr = InviteCollaboratorsSheet.qrImage(for: link.absoluteString) {
                    qr.interpolation(.none)
                        .resizable()
                        .frame(width: 180, height: 180)
                        .padding(12)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .accessibilityLabel("QR code to join this Jam")
                }
                Text(session.code.map(String.init).joined(separator: " "))
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.mixTextPrimary)
                    .textSelection(.enabled)
                    .accessibilityLabel("Code \(session.code)")

                HStack(spacing: 10) {
                    ShareLink(item: link, message: Text("Join my Jam on Mixtape")) {
                        JamPill(title: "Share link", icon: "square.and.arrow.up", filled: true)
                    }
                    .buttonStyle(.plain).mixHandCursor()
                    Button {
                        copyToClipboard(link.absoluteString)
                        copied = true
                    } label: {
                        JamPill(title: copied ? "Copied" : "Copy link", icon: copied ? "checkmark" : "link",
                                filled: false)
                    }
                    .buttonStyle(.plain).mixHandCursor()
                }
                Button {
                    ShareSheet.sendTo(ShareItem(url: link, noun: "Jam", title: "Join my Jam",
                                                subtitle: session.hostName), deps: deps)
                } label: {
                    JamPill(title: "Send to a friend", icon: "paperplane.fill", filled: false)
                }
                .buttonStyle(.plain).mixHandCursor()
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Bits

private struct JamSectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.mixCaptionBold)
            .foregroundStyle(Color.mixTextSecondary)
            .textCase(.uppercase)
    }
}

private struct JamPill: View {
    let title: String
    var icon: String? = nil
    let filled: Bool

    var body: some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon) }
            Text(title)
        }
        .font(.mixButtonSmall)
        .foregroundStyle(filled ? Color.mixOnAccent : Color.mixTextPrimary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(filled ? Color.mixAccentFill : Color.mixSurface2, in: Capsule())
        .contentShape(Capsule())
    }
}

/// A square button: icon over a label. Also the device picker's Jam and AirPlay tiles.
struct JamTile: View {
    let icon: String
    let title: String
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) { JamTileLabel(icon: icon, title: title, active: active) }
            .buttonStyle(.plain).mixHandCursor()
            .accessibilityAddTraits(active ? .isSelected : [])
    }
}

struct JamTileLabel: View {
    let icon: String
    let title: String
    var active = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
            Text(title)
                .font(.mixCaptionBold)
                .lineLimit(1)
        }
        .foregroundStyle(active ? Color.mixPrimary : Color.mixTextPrimary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(active ? Color.mixPrimary.opacity(0.14) : Color.mixSurface2,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

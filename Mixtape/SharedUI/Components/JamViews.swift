// The Jam sheet: start or join one; while in one, its code and QR, who's in,
// and what plays next. Opened from the device picker and by Jam links.

import SwiftUI

/// Presents the Jam sheet from the root, so links and the picker share it.
struct JamSheetPresenter: View {
    @ObservedObject var jam: JamService

    var body: some View {
        Color.clear
            .sheet(isPresented: $jam.isSheetPresented) { JamSheet(jam: jam) }
    }
}

struct JamSheet: View {
    @ObservedObject var jam: JamService
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""

    var body: some View {
        if let session = jam.session {
            MixSheet(title: session.isHost ? "Your Jam" : "\(session.hostName)\u{2019}s Jam",
                     subtitle: session.isHost ? "Friends add to the queue; this device plays."
                                              : "Songs you add go into \(session.hostName)\u{2019}s queue.",
                     size: .large,
                     primary: MixSheetAction(session.isHost ? "End Jam" : "Leave Jam",
                                             isDestructive: true) { jam.leave(); dismiss() },
                     cancelTitle: "Done") {
                live(session)
            }
        } else {
            MixSheet(title: "Start a Jam",
                     subtitle: "Listen together. Everyone adds to one queue and this device plays it.",
                     size: .compact,
                     primary: MixSheetAction("Start Jam", isBusy: jam.isBusy) {
                         Task { await jam.start() }
                     }) {
                joinField
            }
        }
    }

    // MARK: Not in a Jam

    private var joinField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Or join a friend\u{2019}s")
                .font(.mixCaptionBold)
                .foregroundStyle(Color.mixTextSecondary)
                .textCase(.uppercase)
            HStack(spacing: 8) {
                TextField("Jam code", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.characters)
                    #endif
                    .onSubmit(join)
                Button("Join", action: join)
                    .disabled(code.trimmingCharacters(in: .whitespaces).count < 4 || jam.isBusy)
            }
        }
    }

    private func join() {
        let code = code
        Task { await jam.join(code: code) }
    }

    // MARK: In a Jam

    @ViewBuilder
    private func live(_ session: JamService.Session) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            invite(session)

            if session.isHost {
                Toggle("Guests can control playback", isOn: Binding(
                    get: { session.guestsControl },
                    set: { jam.setGuestsControl($0) }))
                    .font(.mixBody)
                    .tint(Color.mixPrimary)
            } else if !jam.hostPresent {
                Text("Waiting for \(session.hostName) to connect\u{2026}")
                    .font(.mixSubtext)
                    .foregroundStyle(Color.mixTextSecondary)
            }

            section("In this Jam") {
                ForEach(people) { member in
                    HStack {
                        Text(member.name).font(.mixBody).foregroundStyle(Color.mixTextPrimary)
                        if member.host {
                            Text("Host").font(.mixCaption).foregroundStyle(Color.mixTextTertiary)
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

            section("Up next") {
                if jam.upNext.isEmpty {
                    Text("Nothing queued. Add songs from anywhere with Add to Queue.")
                        .font(.mixSubtext)
                        .foregroundStyle(Color.mixTextSecondary)
                }
                ForEach(Array(jam.upNext.enumerated()), id: \.offset) { _, item in
                    upNextRow(item)
                }
            }
        }
    }

    private func invite(_ session: JamService.Session) -> some View {
        let link = JamService.link(for: session.code)
        return HStack(alignment: .center, spacing: 16) {
            if let qr = InviteCollaboratorsSheet.qrImage(for: link.absoluteString) {
                qr.interpolation(.none)
                    .resizable()
                    .frame(width: 120, height: 120)
                    .padding(8)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityLabel("QR code to join this Jam")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Scan or enter")
                    .font(.mixSubtext)
                    .foregroundStyle(Color.mixTextSecondary)
                Text(session.code)
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.mixTextPrimary)
                    .textSelection(.enabled)
                ShareLink(item: link, message: Text("Join my Jam on Mixtape")) {
                    Label("Share invite", systemImage: "square.and.arrow.up")
                        .font(.mixSubtext)
                }
                .buttonStyle(.plain).mixHandCursor()
                .foregroundStyle(Color.mixPrimary)
            }
        }
    }

    private func upNextRow(_ item: JamService.Item) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: item.coverURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.mixSurface2
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.mixBody).foregroundStyle(Color.mixTextPrimary).lineLimit(1)
                Text(item.addedBy.map { "\(item.artist) · Added by \($0)" } ?? item.artist)
                    .font(.mixSubtext).foregroundStyle(Color.mixTextSecondary).lineLimit(1)
            }
        }
    }

    /// One row per person, not per device.
    private var people: [JamService.Member] {
        var seen = Set<String>()
        return jam.members.sorted { $0.host && !$1.host }.filter { seen.insert($0.userID).inserted }
    }

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.mixCaptionBold)
                .foregroundStyle(Color.mixTextSecondary)
                .textCase(.uppercase)
            content()
        }
    }
}

import SwiftUI

extension BlendService {
    /// Makes or reuses the open invite, then shares its link.
    func shareInvite(deps: AppDependencies) async {
        guard let url = await invite() else { return }
        ShareSheet.present(ShareItem(url: url, noun: "Blend", title: "Blend with me on Mixtape",
                                     subtitle: "One playlist from both of our listening"),
                           deps: deps)
    }
}

/// Your Blends, the invite you're waiting on, and a tile to start another.
/// A grid on the Mac, a carousel on the phone, like "Your mixes".
struct BlendShelf: View {

    var blends: BlendService
    let deps: AppDependencies
    var showsHeader = true
    var resolvingID: String? = nil
    let onOpen: (PersonalMix) -> Void
    let onPlay: (PersonalMix) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsHeader {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Blends")
                        .font(.system(size: MixFontScale.size(20), weight: .bold))
                        .foregroundStyle(Color.mixTextPrimary)
                        .mixTightened()
                    Text("One playlist from you and a friend, fresh every day")
                        .font(.system(size: MixFontScale.size(12.5)))
                        .foregroundStyle(Color.mixTextTertiary)
                }
            }
            #if os(macOS)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: MixMosaicCard.side,
                                                   maximum: MixMosaicCard.side),
                                         spacing: 18)],
                      alignment: .leading, spacing: 20) { cards }
            #else
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 18) { cards }.padding(.vertical, 2)
            }
            .scrollClipDisabled(true)
            #endif
        }
        .task { await blends.refresh() }
    }

    @ViewBuilder
    private var cards: some View {
        ForEach(blends.blends) { blend in
            Group {
                if let mix = blend.mix {
                    MixMosaicCard(mix: mix,
                                  isResolving: mix.tracks.first.map { resolvingID == $0.id } ?? false,
                                  onOpen: { onOpen(mix) },
                                  onPlay: { onPlay(mix) })
                } else if blend.isPending {
                    GenerateMixTile(icon: "hourglass", title: "Invite sent",
                                    subtitle: "Waiting for a friend to join. Tap to share again") { share() }
                } else {
                    GenerateMixTile(icon: "person.2", title: "You + \(blend.otherName ?? "")",
                                    subtitle: "Not enough listening yet to blend") {}
                }
            }
            .contextMenu {
                if blend.isPending {
                    Button("Share Invite", systemImage: "square.and.arrow.up") { share() }
                }
                Button(blend.isPending ? "Cancel Invite" : "Leave Blend",
                       systemImage: "xmark", role: .destructive) {
                    Task { await blends.leave(blend.id) }
                }
            }
        }
        if !blends.blends.contains(where: \.isPending) {
            GenerateMixTile(icon: "person.2.fill", title: "Create a Blend",
                            subtitle: "Invite a friend and mix your tastes") { share() }
        }
    }

    private func share() {
        Task { await blends.shareInvite(deps: deps) }
    }
}

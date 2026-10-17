// Text tabs with a sliding underline, for slices of one page. Not
// `Picker(.segmented)`, which reads as a form control rather than headings.
// One underline moved with `matchedGeometryEffect`, so it travels between tabs.

import SwiftUI

struct MixTabStrip<Tab: Hashable>: View {

    let tabs: [Tab]
    let title: (Tab) -> String
    @Binding var selection: Tab

    /// Trailing accessory (refresh button, count, "Show all") on the strip's baseline.
    var accessory: AnyView? = nil

    @Namespace private var underline
    @State private var hovered: Tab? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 24) {
                ForEach(tabs, id: \.self) { tab in
                    tabButton(tab)
                }

                Spacer(minLength: 12)

                if let accessory { accessory.padding(.bottom, 8) }
            }

            // Full-width hairline so the active underline sits on a rule.
            Rectangle()
                .fill(Color.mixSeparator)
                .frame(height: 1)
        }
    }

    private func tabButton(_ tab: Tab) -> some View {
        let isActive = tab == selection

        return Button {
            guard !isActive else { return }
            withMixAnimation(.mixSnappy) {
                selection = tab
            }
        } label: {
            VStack(spacing: 8) {
                Text(title(tab))
                    .font(.system(size: MixFontScale.size(17), weight: isActive ? .semibold : .medium))
                    .foregroundStyle(isActive ? Color.mixTextPrimary
                                     : hovered == tab ? Color.mixTextPrimary
                                                      : Color.mixTextSecondary)
                    .fixedSize()

                // Inactive tabs reserve the underline's height so nothing shifts.
                ZStack {
                    Color.clear.frame(height: 2)
                    if isActive {
                        Capsule()
                            .fill(Color.mixPrimary)
                            .frame(height: 2)
                            .matchedGeometryEffect(id: "tabUnderline", in: underline)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).mixHandCursor()
        .mixAnimation(.easeOut(duration: 0.12), value: hovered)
        .onHover { hovering in
            if hovering { hovered = tab } else if hovered == tab { hovered = nil }
            #if os(macOS)
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            #endif
        }
    }
}

// MixTabStrip.swift
// Mixtape — SharedUI/Components
//
// Text tabs with a sliding underline, for switching between slices of one page.
//
// Deliberately not a `Picker(.segmented)`. A segmented control is a *control* —
// a bordered capsule that reads as a form field, sized to its widest label and
// visually competing with whatever content sits under it. That is right for
// "sort ascending / descending" and wrong for the top-level structure of a
// page, where the tabs are the page's own headings and should read as type
// rather than as chrome. Underlined text is what Monochrome, Apple Music's web
// player and most editorial layouts use for exactly this reason.
//
// The underline is one shape moved between tabs with `matchedGeometryEffect`,
// not one per tab faded in and out, so switching reads as a single indicator
// travelling rather than two unrelated animations.

import SwiftUI

struct MixTabStrip<Tab: Hashable>: View {

    let tabs: [Tab]
    let title: (Tab) -> String
    @Binding var selection: Tab

    /// Trailing accessory — a refresh button, a count, a "Show all". Sits on the
    /// baseline of the strip so it reads as part of the same row.
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

            // A hairline the full width of the content, so the active tab's
            // underline reads as sitting *on* a rule rather than floating.
            Rectangle()
                .fill(Color.mixSeparator)
                .frame(height: 1)
        }
    }

    private func tabButton(_ tab: Tab) -> some View {
        let isActive = tab == selection

        return Button {
            guard !isActive else { return }
            withMixAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                selection = tab
            }
        } label: {
            VStack(spacing: 8) {
                Text(title(tab))
                    .font(.system(size: 17, weight: isActive ? .semibold : .medium))
                    .foregroundStyle(isActive ? Color.mixTextPrimary
                                     : hovered == tab ? Color.mixTextPrimary
                                                      : Color.mixTextSecondary)
                    .fixedSize()

                // The inactive tabs still reserve the underline's height, so
                // nothing shifts vertically when the selection moves.
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

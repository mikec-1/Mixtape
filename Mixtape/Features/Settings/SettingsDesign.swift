// The components every Settings page is built from.
// No `List`: it draws a Toggle as a checkbox on macOS and a switch on iOS, and its insets
// and separators differ between platforms. These cards look the same on both.
// Colour is information: accent means interactive or set, red means destructive,
// everything else is a monochrome glyph. Only category rows get coloured icons.

import SwiftUI

// MARK: - Metrics

enum SettingsMetrics {
    #if os(macOS)
    static let rowMinHeight: CGFloat = 34
    static let cardRadius:   CGFloat = 10
    static let rowPadH:      CGFloat = 14
    static let rowPadV:      CGFloat = 7
    /// Keeps a readable line length in a wide content pane.
    static let pageMaxWidth: CGFloat = 640
    #else
    static let rowMinHeight: CGFloat = 44
    static let cardRadius:   CGFloat = 12
    static let rowPadH:      CGFloat = 16
    static let rowPadV:      CGFloat = 9
    static let pageMaxWidth: CGFloat = 700
    #endif

    /// Fixed glyph width so every title in a card starts on the same x.
    static let iconColumn: CGFloat = 24
    static let groupSpacing: CGFloat = 22
}

// MARK: - Search highlight

/// The row id search asked for. Matching rows tint themselves until it's cleared.
private struct SettingsHighlightKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var settingsHighlight: String? {
        get { self[SettingsHighlightKey.self] }
        set { self[SettingsHighlightKey.self] = newValue }
    }
}

// MARK: - Page

/// A scrolling settings page: a title, then a stack of cards.
struct SettingsPage<Content: View>: View {

    let title: String
    /// One line of orientation under the title, when a page needs it.
    var subtitle: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsMetrics.groupSpacing) {
                #if os(macOS)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.mixTitle)
                        .foregroundStyle(Color.mixTextPrimary)
                        .accessibilityAddTraits(.isHeader)
                    if let subtitle {
                        Text(subtitle)
                            .font(.mixSubtext)
                            .foregroundStyle(Color.mixTextSecondary)
                    }
                }
                .padding(.bottom, 2)
                #else
                // iOS already shows the title in the navigation bar.
                if let subtitle {
                    Text(subtitle)
                        .font(.mixSubtext)
                        .foregroundStyle(Color.mixTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                #endif

                content
            }
            .frame(maxWidth: SettingsMetrics.pageMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 40)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

// MARK: - Group

/// A titled stack of rows drawn as one card.
struct SettingsGroup<Content: View>: View {

    var title: String? = nil
    /// A closing line of explanation, only where the rows can't say it.
    var footer: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title {
                Text(title.uppercased())
                    .font(.mixCaptionBold)
                    .tracking(0.6)
                    .foregroundStyle(Color.mixTextSecondary)
                    .padding(.leading, 4)
                    .accessibilityLabel(title)
                    .accessibilityAddTraits(.isHeader)
            }

            SettingsCard { content }

            if let footer {
                Text(footer)
                    .font(.mixCaption)
                    .foregroundStyle(Color.mixTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 4)
                    .padding(.top, 1)
            }
        }
    }
}

/// The card itself: rows separated by hairlines, with no trailing divider.
struct SettingsCard<Content: View>: View {

    @ViewBuilder var content: Content

    var body: some View {
        _VariadicView.Tree(DividedRows()) { content }
            .background(
                RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous)
                    .fill(Color.mixSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous)
                    .strokeBorder(Color.mixSeparator, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous))
    }

    /// A separator between children but not after the last. Needs the variadic tree
    /// to address children individually.
    private struct DividedRows: _VariadicView_UnaryViewRoot {
        @ViewBuilder
        func body(children: _VariadicView.Children) -> some View {
            // Indexed: inferring ForEach ids from `AnyHashable` collides with the `Subview` overloads.
            let rows  = Array(children)
            let count = rows.count
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, child in
                    child
                    if index < count - 1 {
                        Rectangle()
                            .fill(Color.mixSeparator)
                            .frame(height: 0.5)
                            .padding(.leading, SettingsMetrics.rowPadH)
                    }
                }
            }
        }
    }
}

// MARK: - Row

/// One row: optional leading glyph, title, optional second line, trailing content.
struct SettingsRow<Trailing: View>: View {

    /// Matches the search index. Rows without one can't be found by search.
    var id: String? = nil
    let title: String
    var subtitle: String? = nil
    var icon: String? = nil
    var titleColor: Color = .mixTextPrimary
    var iconColor: Color = .mixTextSecondary
    var showsChevron: Bool = false
    @ViewBuilder var trailing: () -> Trailing

    @Environment(\.settingsHighlight) private var highlight

    private var isHighlighted: Bool { id != nil && id == highlight }

    var body: some View {
        HStack(spacing: 11) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(iconColor)
                    .frame(width: SettingsMetrics.iconColumn, alignment: .leading)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.mixBody)
                    .foregroundStyle(titleColor)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle)
                        .font(.mixCaption)
                        .foregroundStyle(Color.mixTextTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 10)

            trailing()

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.mixTextTertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, SettingsMetrics.rowPadH)
        .padding(.vertical, SettingsMetrics.rowPadV)
        .frame(minHeight: SettingsMetrics.rowMinHeight)
        .background(isHighlighted ? Color.mixPrimary.opacity(0.14) : Color.clear)
        .mixAnimation(.easeOut(duration: 0.25), value: isHighlighted)
        .contentShape(Rectangle())
    }
}

extension SettingsRow where Trailing == EmptyView {
    init(id: String? = nil,
         title: String,
         subtitle: String? = nil,
         icon: String? = nil,
         titleColor: Color = .mixTextPrimary,
         iconColor: Color = .mixTextSecondary,
         showsChevron: Bool = false) {
        self.init(id: id, title: title, subtitle: subtitle, icon: icon,
                  titleColor: titleColor, iconColor: iconColor,
                  showsChevron: showsChevron) { EmptyView() }
    }
}

/// The standard trailing value: a right-aligned secondary string.
struct SettingsValue: View {
    let text: String
    var color: Color = .mixTextSecondary
    var body: some View {
        Text(text)
            .font(.mixSubtext)
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.middle)
            #if os(macOS)
            // Middle-truncated paths and emails need a way to read the whole thing.
            .help(text)
            #endif
    }
}

// MARK: - Controls

/// A switch row, on both platforms.
struct SettingsToggleRow: View {

    var id: String? = nil
    let title: String
    var subtitle: String? = nil
    var icon: String? = nil
    @Binding var isOn: Bool
    var isEnabled: Bool = true

    var body: some View {
        SettingsRow(id: id, title: title, subtitle: subtitle, icon: icon) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Color.mixPrimary)
                .disabled(!isEnabled)
                #if os(macOS)
                .controlSize(.small)
                #endif
        }
        .opacity(isEnabled ? 1 : 0.5)
    }
}

/// A pop-up value row, for a small closed set of choices.
struct SettingsPickerRow<Value: Hashable & Identifiable>: View {

    var id: String? = nil
    let title: String
    var subtitle: String? = nil
    var icon: String? = nil
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String

    var body: some View {
        SettingsRow(id: id, title: title, subtitle: subtitle, icon: icon) {
            Picker(title, selection: $selection) {
                ForEach(options) { option in
                    Text(label(option)).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(Color.mixPrimary)
            .fixedSize()
            #if os(macOS)
            .controlSize(.small)
            #endif
        }
    }
}

/// A tappable row. `role: .destructive` turns the title and glyph red.
struct SettingsButtonRow<Trailing: View>: View {

    var id: String? = nil
    let title: String
    var subtitle: String? = nil
    var icon: String? = nil
    /// `.accent` for actions, `.plain` for navigation, `.destructive` for anything that removes data.
    var role: SettingsActionRole = .accent
    var showsChevron: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        Button(action: action) {
            SettingsRow(id: id,
                        title: title,
                        subtitle: subtitle,
                        icon: icon,
                        titleColor: role.titleColor,
                        iconColor: role.iconColor,
                        showsChevron: showsChevron,
                        trailing: trailing)
        }
        .buttonStyle(.plain).mixHandCursor()
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
    }
}

extension SettingsButtonRow where Trailing == EmptyView {
    init(id: String? = nil,
         title: String,
         subtitle: String? = nil,
         icon: String? = nil,
         role: SettingsActionRole = .accent,
         showsChevron: Bool = false,
         isEnabled: Bool = true,
         action: @escaping () -> Void) {
        self.init(id: id, title: title, subtitle: subtitle, icon: icon,
                  role: role, showsChevron: showsChevron, isEnabled: isEnabled,
                  action: action) { EmptyView() }
    }
}

/// Opens a page on mixtaped.tech in the browser; the arrow says so.
struct SettingsLinkRow: View {

    var id: String? = nil
    let title: String
    var subtitle: String? = nil
    var icon: String? = nil
    var role: SettingsActionRole = .plain
    let url: URL

    @Environment(\.openURL) private var openURL

    var body: some View {
        SettingsButtonRow(id: id, title: title, subtitle: subtitle, icon: icon, role: role,
                          action: { openURL(url) }) {
            Image(systemName: "arrow.up.forward")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.mixTextTertiary)
                .accessibilityHidden(true)
        }
    }
}

enum SettingsActionRole {
    /// An action the user is meant to reach for.
    case accent
    /// Navigation, or an action whose weight comes from where it leads.
    case plain
    case destructive

    var titleColor: Color {
        switch self {
        case .accent:      return .mixPrimary
        case .plain:       return .mixTextPrimary
        case .destructive: return .mixDestructive
        }
    }

    var iconColor: Color {
        switch self {
        case .accent:      return .mixPrimary
        case .plain:       return .mixTextSecondary
        case .destructive: return .mixDestructive
        }
    }
}

/// A slider with its value above it. Two lines, since a trailing-edge slider is unusable.
struct SettingsSliderRow: View {

    var id: String? = nil
    let title: String
    var icon: String? = nil
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    let valueLabel: (Double) -> String

    @Environment(\.settingsHighlight) private var highlight

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 11) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 15))
                        .foregroundStyle(Color.mixTextSecondary)
                        .frame(width: SettingsMetrics.iconColumn, alignment: .leading)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.mixBody)
                    .foregroundStyle(Color.mixTextPrimary)
                Spacer(minLength: 10)
                Text(valueLabel(value))
                    .font(.mixSubtext)
                    .foregroundStyle(Color.mixTextSecondary)
                    .monospacedDigit()
            }
            Slider(value: $value, in: range, step: step)
                .tint(Color.mixPrimary)
                .accessibilityLabel(title)
                .accessibilityValue(valueLabel(value))
                #if os(macOS)
                .controlSize(.small)
                #endif
        }
        .padding(.horizontal, SettingsMetrics.rowPadH)
        .padding(.vertical, SettingsMetrics.rowPadV + 2)
        .background(id != nil && id == highlight ? Color.mixPrimary.opacity(0.14) : Color.clear)
        .mixAnimation(.easeOut(duration: 0.25), value: highlight)
    }
}

/// A small capsule button in a row's trailing edge, e.g. "Clear" next to a cache size.
struct SettingsInlineButton: View {

    let title: String
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.mixCaptionBold)
                .foregroundStyle(Color.mixPrimary)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(Color.mixPrimary.opacity(0.14))
                )
        }
        .buttonStyle(.plain).mixHandCursor()
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
    }
}

/// A row that's busy doing something.
struct SettingsBusyRow: View {
    let title: String
    var body: some View {
        SettingsRow(title: title, titleColor: .mixTextSecondary) {
            ProgressView()
                .controlSize(.small)
                .tint(Color.mixPrimary)
        }
    }
}

/// An inline failure message, shown under the row that produced it.
struct SettingsErrorRow: View {
    let message: String
    var body: some View {
        SettingsRow(title: message, icon: "exclamationmark.triangle.fill",
                    titleColor: .mixDestructive, iconColor: .mixDestructive)
    }
}

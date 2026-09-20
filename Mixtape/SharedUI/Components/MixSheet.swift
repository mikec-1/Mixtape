// MixSheet.swift
// Mixtape — SharedUI/Components
//
// One chrome for every modal in the app.
//
// The old sheets each built their own frame, and the shape they all reached for
// was an iOS one: `NavigationStack` → `.navigationTitle` → a toolbar "Done".
// That is a phone's navigation bar, and on the Mac it renders as a title strip
// with the dismiss button in the top-trailing corner — which is why the windows
// read as a port rather than as Mac UI. Apple's guidance puts every dismissing
// button (Done, OK, Cancel) at the *bottom*, in the trailing corner, and a sheet
// has no business owning a navigation stack when nothing inside it navigates.
//
// So the chrome lives here once, and the differences that actually are
// platform differences are the only ones expressed:
//
//   macOS  header is flat text; the actions sit bottom-trailing; Esc cancels
//          and Return commits; the sheet gets a real width instead of the
//          magic numbers each caller used to invent.
//   iOS    the header keeps a close control and the drag indicator, because
//          that is what a sheet means on a phone; the primary action is a
//          full-width capsule at the bottom where a thumb is.
//
// The visual tell that dates the old sheets is the static `Divider()` under the
// title: a hard line drawn whether or not there is anything to separate. Here
// the header and footer share the content's background and stay seamless until
// content actually passes beneath them, at which point a hairline fades in.
// Nothing is banded, nothing floats — the sheet is one surface.

import SwiftUI

// MARK: - Size

/// Named sizes, so callers stop hard-coding frames.
///
/// The old numbers (520×500, 460×?, 420×440, 440–460×560–640) were each picked
/// for one sheet's tallest state, which is why several of them open mostly
/// empty. These are picked for the *shape of the task* instead, and a sheet
/// that wants to grow says so with `.large` rather than a bigger literal.
enum MixSheetSize {
    /// One field, or one decision. A link to paste, a name to type.
    case compact
    /// A short form — a few fields, maybe a cover well beside them.
    case medium
    /// A list you scroll: search results, collaborators, a queue.
    case large

    #if os(macOS)
    var width: CGFloat {
        switch self {
        case .compact: return 460
        case .medium:  return 540
        case .large:   return 580
        }
    }

    /// Sheets size to content between these bounds, so a sheet that is short
    /// today doesn't reserve space for the state it might reach later.
    var minHeight: CGFloat {
        switch self {
        case .compact: return 240
        case .medium:  return 320
        case .large:   return 460
        }
    }

    var maxHeight: CGFloat {
        switch self {
        case .compact: return 420
        case .medium:  return 560
        case .large:   return 680
        }
    }
    #else
    var detents: Set<PresentationDetent> {
        switch self {
        case .compact: return [.height(380), .large]
        case .medium:  return [.medium, .large]
        case .large:   return [.large]
        }
    }
    #endif
}

// MARK: - Action

/// A button in the footer. Deliberately not a `View` — the footer decides how
/// an action is drawn, and that answer differs by platform.
struct MixSheetAction {
    var title: String
    var isEnabled: Bool = true
    var isBusy: Bool = false
    var isDestructive: Bool = false
    var action: () -> Void

    init(_ title: String,
         isEnabled: Bool = true,
         isBusy: Bool = false,
         isDestructive: Bool = false,
         action: @escaping () -> Void) {
        self.title = title
        self.isEnabled = isEnabled
        self.isBusy = isBusy
        self.isDestructive = isDestructive
        self.action = action
    }
}

// MARK: - Sheet

struct MixSheet<Content: View, Footer: View>: View {

    let title: String
    var subtitle: String? = nil
    var size: MixSheetSize = .medium
    /// Set false when the content scrolls itself (a `List`, or a page that
    /// already owns a `ScrollView`). The edge hairlines are then the caller's
    /// business, which is correct — only the caller knows where its edges are.
    var scroll: Bool = true
    /// Whether the footer bar is drawn at all. Distinct from `Footer` being
    /// `EmptyView`, because a footer can be empty for a reason the caller
    /// shouldn't have to encode in a type.
    var showsFooter: Bool = true

    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    @Environment(\.dismiss) private var dismiss
    @State private var edges = MixScrollEdges()

    private let scrollSpace = "mixSheetScroll"

    var body: some View {
        VStack(spacing: 0) {
            header
            body_
            footerBar
        }
        .background(Color.mixBackground)
        #if os(macOS)
        .frame(width: size.width)
        .frame(minHeight: size.minHeight, maxHeight: size.maxHeight)
        #else
        .presentationDetents(size.detents)
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.mixBackground)
        #endif
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: MixSheetMetrics.titleSize, weight: .semibold))
                        .foregroundStyle(Color.mixTextPrimary)
                        .mixTightened()
                        .fixedSize(horizontal: false, vertical: true)

                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Color.mixTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 8)

                #if os(iOS)
                // A phone has no Esc key and the footer may be a single primary
                // action, so the header keeps an explicit way out. The Mac
                // doesn't get one: Esc cancels, and the footer already holds
                // the dismissing button where the guidelines put it.
                // `xmark.circle.fill` rendered hierarchically, which is the
                // control Apple puts in this corner throughout the system —
                // one symbol carrying its own disc, rather than a bold glyph
                // stacked on a hand-drawn circle. The frame stays at 44pt so
                // the tap target meets the minimum even though the mark reads
                // smaller than the old one.
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color.mixTextSecondary)
                        .frame(width: 44, height: 44, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).mixHandCursor()
                .accessibilityLabel("Close")
                #endif
            }
            .padding(.horizontal, MixSheetMetrics.margin)
            .padding(.top, MixSheetMetrics.headerTop)
            .padding(.bottom, MixSheetMetrics.headerBottom)

            MixSheetHairline(visible: !edges.atTop)
        }
    }

    // MARK: Content

    // Named with a trailing underscore because `body` is taken by the protocol.
    @ViewBuilder
    private var body_: some View {
        if scroll {
            GeometryReader { outer in
                ScrollView {
                    content()
                        .padding(.horizontal, MixSheetMetrics.margin)
                        .padding(.vertical, MixSheetMetrics.contentVertical)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            GeometryReader { inner in
                                let f = inner.frame(in: .named(scrollSpace))
                                Color.clear.preference(
                                    key: MixScrollEdgeKey.self,
                                    value: MixScrollEdges(
                                        atTop:    f.minY >= -1,
                                        atBottom: f.maxY <= outer.size.height + 1
                                    )
                                )
                            }
                        )
                }
                .coordinateSpace(name: scrollSpace)
                .onPreferenceChange(MixScrollEdgeKey.self) { edges = $0 }
            }
            #if os(macOS)
            // The sheet is bounded, not fixed: it takes the height its content
            // needs and stops at `maxHeight`, where the scroll view takes over.
            .frame(maxHeight: .infinity)
            #endif
        } else {
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // MARK: Footer

    @ViewBuilder
    private var footerBar: some View {
        if showsFooter, Footer.self != EmptyView.self {
            VStack(spacing: 0) {
                MixSheetHairline(visible: !edges.atBottom)
                footer()
                    .padding(.horizontal, MixSheetMetrics.margin)
                    .padding(.top, MixSheetMetrics.footerTop)
                    .padding(.bottom, MixSheetMetrics.footerBottom)
            }
        }
    }
}

// MARK: - Convenience inits

extension MixSheet where Footer == MixSheetActions {

    /// The common shape: a confirming action, and a way out.
    ///
    /// `primary` is optional because plenty of these sheets don't commit
    /// anything — Find People and the collaborator list are browsing surfaces,
    /// and their footer is just the button that closes them.
    init(title: String,
         subtitle: String? = nil,
         size: MixSheetSize = .medium,
         scroll: Bool = true,
         primary: MixSheetAction? = nil,
         cancelTitle: String? = nil,
         showsCancel: Bool = true,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.size = size
        self.scroll = scroll
        self.content = content
        self.footer = {
            MixSheetActions(primary: primary,
                            cancelTitle: cancelTitle ?? (primary == nil ? "Done" : "Cancel"),
                            showsCancel: showsCancel)
        }
        #if os(iOS)
        // A browsing sheet with nothing to commit doesn't need a footer on a
        // phone. The header's ✕ and the drag-to-dismiss are both already the
        // way out, so a full-width "Done" would be the loudest control in a
        // window nobody opens in order to press Done. The Mac keeps it: the
        // guidelines want a dismissing button, and bottom-trailing is where
        // that button goes.
        self.showsFooter = primary != nil
        #endif
    }
}

extension MixSheet where Footer == EmptyView {

    /// No footer at all — for sheets that are pure presentation and dismiss by
    /// other means (Esc, a drag, a row tap that navigates away).
    init(title: String,
         subtitle: String? = nil,
         size: MixSheetSize = .medium,
         scroll: Bool = true,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.size = size
        self.scroll = scroll
        self.content = content
        self.footer = { EmptyView() }
    }
}

// MARK: - Footer actions

/// The default footer.
///
/// macOS follows the guidelines literally: dismissing buttons at the bottom in
/// the trailing corner, cancel to the left of the commit. iOS puts the primary
/// action across the full width where a thumb reaches it, and demotes cancel to
/// a plain text button underneath — on a phone the header's ✕ is the real way
/// out, so a second full-size Cancel would be noise.
struct MixSheetActions: View {

    var primary: MixSheetAction? = nil
    var cancelTitle: String = "Cancel"
    /// Set false when the header's close control is the only way out you want.
    var showsCancel: Bool = true

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if os(macOS)
        HStack(spacing: 12) {
            Spacer(minLength: 0)
            if showsCancel, primary == nil {
                // Nothing to commit means the dismissing button *is* the
                // action, so it's drawn as one — a grey word in the corner of
                // an otherwise finished sheet reads as disabled. iOS has always
                // promoted a lone Done this way; this is the Mac catching up.
                MixSheetPrimaryButton(
                    action: MixSheetAction(cancelTitle) { dismiss() },
                    fullWidth: false
                )
                .keyboardShortcut(.cancelAction)
            } else if showsCancel {
                Button(cancelTitle) { dismiss() }
                    .buttonStyle(.plain).mixHandCursor()
                    .foregroundStyle(Color.mixTextSecondary)
                    .keyboardShortcut(.cancelAction)
            }
            if let primary {
                MixSheetPrimaryButton(action: primary, fullWidth: false)
                    .keyboardShortcut(.defaultAction)
            }
        }
        #else
        VStack(spacing: 10) {
            if let primary {
                MixSheetPrimaryButton(action: primary, fullWidth: true)
            }
            if showsCancel, primary != nil {
                Button(cancelTitle) { dismiss() }
                    .buttonStyle(.plain).mixHandCursor()
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.mixTextSecondary)
            } else if showsCancel {
                MixSheetPrimaryButton(
                    action: MixSheetAction(cancelTitle) { dismiss() },
                    fullWidth: true
                )
            }
        }
        #endif
    }
}

/// The commit button. Capsule, filled, black label — the same shape the Play
/// button uses, so "the thing that happens" looks the same everywhere.
struct MixSheetPrimaryButton: View {

    let action: MixSheetAction
    var fullWidth: Bool

    private var fill: Color { action.isDestructive ? .mixDestructive : .mixPrimary }
    // `.black` was hard-coded here, which only ever read against the dark
    // appearance's bright orange. In light, `mixPrimary` is a deep burnt
    // orange and black on it lands around 2.6:1 — under the 4.5:1 floor the
    // rest of the palette is built to. `mixOnAccent` is the token that exists
    // for exactly this pairing and flips with the appearance.
    private var label: Color { action.isDestructive ? .white : .mixOnAccent }

    var body: some View {
        Button(action: action.action) {
            ZStack {
                // The title stays laid out while busy so the button keeps its
                // width — a spinner that shrinks the footer is worse than one
                // that doesn't.
                Text(action.title).opacity(action.isBusy ? 0 : 1)
                if action.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(label)
                }
            }
            .font(.system(size: fullWidth ? 16 : 13.5, weight: .semibold))
            .foregroundStyle(label)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.horizontal, fullWidth ? 0 : 18)
            .padding(.vertical, fullWidth ? 15 : 8)
            .background(fill, in: Capsule())
        }
        .buttonStyle(.plain).mixHandCursor()
        .disabled(!action.isEnabled || action.isBusy)
        .opacity(action.isEnabled && !action.isBusy ? 1 : 0.45)
        .mixAnimation(.easeOut(duration: 0.12), value: action.isBusy)
    }
}

// MARK: - Status

/// What just happened, inline.
///
/// Both import sheets used to answer this with a whole replacement page — a
/// 40pt glyph over a centred headline, with the field they'd been using thrown
/// away. That's a lot of motion to say "working on it", and it loses the thing
/// you typed. This is a row: it appears under the field, it goes away when
/// there's nothing to say, and the sheet never changes shape around it.
struct MixSheetStatus: View {

    enum Kind {
        case busy
        case success
        /// Succeeded, but nothing new happened — already imported, already saved.
        case noop
        case failure

        var icon: String? {
            switch self {
            case .busy:    return nil
            case .success: return "checkmark.circle.fill"
            case .noop:    return "checkmark.circle"
            case .failure: return "exclamationmark.circle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .busy:    return .mixTextSecondary
            case .success: return .mixSuccess
            case .noop:    return .mixTextSecondary
            // Was `.mixAccent` — a failure drawn in the brand colour reads
            // as an accent, not as a problem. Colour carries meaning here.
            case .failure: return .mixDestructive
            }
        }
    }

    let kind: Kind
    let title: String
    var detail: String? = nil
    /// 0…1 when the work actually knows how far along it is. Left nil for a
    /// wait of unknown length — a bar that sits at 40% for eight seconds is
    /// worse than no bar at all.
    var progress: Double? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if let icon = kind.icon {
                    Image(systemName: icon)
                        .font(.system(size: 14))
                        .foregroundStyle(kind.tint)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.mixTextPrimary)

                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.mixTextSecondary)
                        // Capped: unbounded, a `fixedSize` measured against a
                        // narrow column locks in a minimum height that can
                        // outgrow the window it sits in.
                        .lineLimit(6)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(Color.mixPrimary)
                        .padding(.top, 3)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.mixSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Option row

/// A route out of a chooser sheet.
///
/// The sheets that offer a handful of ways to do something — add music, create
/// something new — had been drawing them as a column of centred pill buttons
/// under a large glyph, which is a phone's onboarding screen. Stacked pills
/// also make every option look equally weighty and give none of them room to
/// say what they are. A row has a leading icon, a name, and a line of
/// explanation, and it scales to as many options as the sheet has.
struct MixSheetOptionRow: View {

    let icon: String
    let title: String
    var detail: String? = nil
    /// The one this sheet is really for. Tints the icon; nothing else changes,
    /// because a chooser with a shouting option isn't a chooser.
    var isPreferred: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(isPreferred ? Color.mixPrimary : Color.mixTextSecondary)
                    .frame(width: 26, height: 26)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Color.mixTextPrimary)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.mixTextSecondary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.mixTextTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered ? Color.mixSurface2 : Color.mixSurface)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).mixHandCursor()
        .mixHoverCursor { isHovered = $0 }
        .mixAnimation(.easeOut(duration: 0.12), value: isHovered)
    }
}

// MARK: - Hairline

/// A separator that only exists when it separates something.
struct MixSheetHairline: View {
    let visible: Bool

    var body: some View {
        Rectangle()
            .fill(Color.mixSeparator)
            .frame(height: 0.5)
            .opacity(visible ? 1 : 0)
            .mixAnimation(.easeOut(duration: 0.15), value: visible)
    }
}

// MARK: - Field style

/// The input treatment, in one place. Every sheet had been writing its own
/// `Color.mixSurface2` rounded rectangle at a slightly different radius and
/// padding, which is most of why no two of them looked related.
extension View {
    func mixSheetField() -> some View {
        self
            .font(.system(size: 13.5))
            .foregroundStyle(Color.mixTextPrimary)
            #if os(macOS)
            .textFieldStyle(.plain)
            #endif
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.mixSurface2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Metrics

enum MixSheetMetrics {
    #if os(macOS)
    /// 20pt, the Mac window margin.
    static let margin: CGFloat = 20
    static let titleSize: CGFloat = 17
    static let headerTop: CGFloat = 18
    static let headerBottom: CGFloat = 14
    static let contentVertical: CGFloat = 16
    static let footerTop: CGFloat = 14
    static let footerBottom: CGFloat = 16
    #else
    static let margin: CGFloat = 20
    static let titleSize: CGFloat = 20
    static let headerTop: CGFloat = 18
    static let headerBottom: CGFloat = 14
    static let contentVertical: CGFloat = 16
    static let footerTop: CGFloat = 14
    static let footerBottom: CGFloat = 28
    #endif
}

// MARK: - Scroll edges

struct MixScrollEdges: Equatable {
    var atTop = true
    var atBottom = true
}

private struct MixScrollEdgeKey: PreferenceKey {
    static let defaultValue = MixScrollEdges()
    static func reduce(value: inout MixScrollEdges, nextValue: () -> MixScrollEdges) {
        value = nextValue()
    }
}

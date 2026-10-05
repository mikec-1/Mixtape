// Shared chrome for every modal. The header always has a close button.
// macOS: flat text header, actions bottom-trailing, Esc cancels, Return commits.
// A click on the window behind closes the sheet.
// iOS: drag indicator; primary action is a full-width capsule at the bottom.
// Header and footer share the content background; a hairline fades in only
// when content scrolls under them.

import SwiftUI

#if os(macOS)
// MARK: - Corners

/// Tahoe gives sheets a 26pt corner that reads as an iOS card.
/// `presentationCornerRadius` is ignored on the Mac, so this calls NSWindow's
/// private `_setCornerRadius:`. If the selector goes away, sheets keep the system corner.
enum MixSheetCorners {
    static let radius: CGFloat = 8

    /// Installed once at launch; covers every sheet. A sheet becomes key before
    /// it's drawn, so there's no flash.
    static func install() {
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                               object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                guard window.isSheet else { return }
                let sel = Selector(("_setCornerRadius:"))
                guard let method = class_getInstanceMethod(object_getClass(window), sel) else { return }
                typealias Setter = @convention(c) (AnyObject, Selector, CGFloat) -> Void
                unsafeBitCast(method_getImplementation(method), to: Setter.self)(window, sel, radius)
                window.invalidateShadow()
            }
        }
    }
}

// MARK: - Outside click

/// Closes the sheet it sits in when the window behind it is clicked.
struct MixSheetOutsideClick: NSViewRepresentable {
    let dismiss: () -> Void

    func makeNSView(context: Context) -> Watcher { Watcher() }
    func updateNSView(_ view: Watcher, context: Context) { view.dismiss = dismiss }
    static func dismantleNSView(_ view: Watcher, coordinator: ()) { view.stop() }

    final class Watcher: NSView {
        var dismiss: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                // A sheet or alert on top of this one owns the click.
                guard let self, let sheet = self.window, sheet.isVisible, sheet.attachedSheet == nil,
                      let clicked = event.window, Self.window(clicked, isBehind: sheet)
                else { return event }
                self.dismiss?()
                return nil
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private static func window(_ window: NSWindow, isBehind sheet: NSWindow) -> Bool {
            var parent = sheet.sheetParent
            while let p = parent, p !== window { parent = p.sheetParent }
            return parent != nil
        }
    }
}
#endif

// MARK: - Size

/// Named sizes, picked for the shape of the task. Sheets that need to grow use `.large`.
enum MixSheetSize {
    /// One field, or one decision. A link to paste, a name to type.
    case compact
    /// A few fields, maybe a cover beside them.
    case medium
    /// A list you scroll: search results, collaborators, a queue.
    case large
    /// Exactly this size, worked out by the caller. The song editor fits it to the app window.
    case window(CGSize)

    #if os(macOS)
    var width: CGFloat {
        switch self {
        case .compact: return 460
        case .medium:  return 540
        case .large:   return 580
        case .window(let size): return size.width
        }
    }

    /// Sheets size to content between these bounds.
    var minHeight: CGFloat {
        switch self {
        case .compact: return 240
        case .medium:  return 320
        case .large:   return 460
        case .window(let size): return size.height
        }
    }

    var maxHeight: CGFloat {
        switch self {
        case .compact: return 420
        case .medium:  return 560
        case .large:   return 680
        case .window(let size): return size.height
        }
    }
    #else
    var detents: Set<PresentationDetent> {
        switch self {
        case .compact: return [.height(380), .large]
        case .medium:  return [.medium, .large]
        case .large, .window:  return [.large]
        }
    }
    #endif
}

// MARK: - Action

/// A footer button. Not a `View`: the footer draws it, differently per platform.
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
    /// False when the content scrolls itself (a `List`, or its own `ScrollView`);
    /// the caller then handles edge hairlines.
    var scroll: Bool = true
    /// Whether the footer bar is drawn at all.
    var showsFooter: Bool = true
    /// Blocks the close button, outside click and swipe while work can't be interrupted.
    var dismissDisabled: Bool = false
    /// False for a workspace, so a stray click beside it doesn't throw the work away.
    var closesOnOutsideClick: Bool = true
    /// False when the footer has no Esc button of its own, so the header X takes Esc.
    var footerCancels: Bool = true

    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    @Environment(\.dismiss) private var dismiss
    @State private var edges = MixScrollEdges()
    #if os(macOS)
    @State private var contentHeight: CGFloat = 0
    #endif

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
        .background {
            if !dismissDisabled && closesOnOutsideClick { MixSheetOutsideClick { dismiss() } }
        }
        #else
        .presentationDetents(size.detents)
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.mixBackground)
        .interactiveDismissDisabled(dismissDisabled)
        #endif
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    // Empty when the content draws its own heading.
                    if !title.isEmpty {
                        Text(title)
                            .font(.system(size: MixSheetMetrics.titleSize, weight: .semibold))
                            .foregroundStyle(Color.mixTextPrimary)
                            .mixTightened()
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: MixFontScale.size(12.5)))
                            .foregroundStyle(Color.mixTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 8)

                // Takes Esc when no footer button does.
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: MixSheetMetrics.closeSize))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color.mixTextSecondary)
                        .frame(width: MixSheetMetrics.closeFrame, height: MixSheetMetrics.closeFrame,
                               alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).mixHandCursor()
                .keyboardShortcut(footerDrawn && footerCancels ? nil : .cancelAction)
                .disabled(dismissDisabled)
                .accessibilityLabel("Close")
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
                        #if os(macOS)
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0 }
                        #endif
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
                .scrollBounceBehavior(.basedOnSize)
                .onPreferenceChange(MixScrollEdgeKey.self) { edges = $0 }
            }
            #if os(macOS)
            // Takes the height the content needs, up to `maxHeight`, then scrolls.
            // Without the ideal height every sheet opened at `minHeight`.
            .frame(minHeight: 0, idealHeight: contentHeight, maxHeight: .infinity)
            #endif
        } else {
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // MARK: Footer

    private var footerDrawn: Bool { showsFooter && Footer.self != EmptyView.self }

    @ViewBuilder
    private var footerBar: some View {
        if footerDrawn {
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

    /// A confirming action and a way out. `primary` is optional for browsing
    /// sheets (Find People, collaborators) whose footer only closes them.
    init(title: String,
         subtitle: String? = nil,
         size: MixSheetSize = .medium,
         scroll: Bool = true,
         primary: MixSheetAction? = nil,
         secondary: MixSheetAction? = nil,
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
                            secondary: secondary,
                            cancelTitle: cancelTitle ?? (primary == nil ? "Done" : "Cancel"),
                            showsCancel: showsCancel)
        }
        self.footerCancels = showsCancel && secondary == nil
        #if os(iOS)
        // On iOS a browsing sheet needs no footer: the close button and drag already
        // dismiss it. The Mac keeps a bottom-trailing dismiss button.
        self.showsFooter = primary != nil
        #endif
    }
}

extension MixSheet where Footer == EmptyView {

    /// No footer: sheets closed by the header button, Esc, an outside click, a drag or a navigating row tap.
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

/// Default footer. macOS: dismiss buttons bottom-trailing, cancel left of commit.
/// iOS: full-width primary, cancel as a plain text button below.
struct MixSheetActions: View {

    var primary: MixSheetAction? = nil
    /// Takes the cancel button's place, e.g. "Import Another" beside Done.
    var secondary: MixSheetAction? = nil
    var cancelTitle: String = "Cancel"
    /// Set false when the header's close control is the only way out you want.
    var showsCancel: Bool = true

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if os(macOS)
        HStack(spacing: 12) {
            Spacer(minLength: 0)
            if showsCancel, primary == nil, secondary == nil {
                // With nothing to commit, the dismiss button is the action, so draw it as one.
                MixSheetPrimaryButton(
                    action: MixSheetAction(cancelTitle) { dismiss() },
                    fullWidth: false
                )
                .keyboardShortcut(.cancelAction)
            } else if let slot = secondary ?? (showsCancel ? MixSheetAction(cancelTitle) { dismiss() } : nil) {
                Button(slot.title, action: slot.action)
                    .buttonStyle(.plain).mixHandCursor()
                    .foregroundStyle(Color.mixTextSecondary)
                    .keyboardShortcut(secondary == nil ? .cancelAction : nil)
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
            if let slot = secondary ?? (showsCancel && primary != nil ? MixSheetAction(cancelTitle) { dismiss() } : nil) {
                Button(slot.title, action: slot.action)
                    .buttonStyle(.plain).mixHandCursor()
                    .font(.system(size: MixFontScale.size(14), weight: .medium))
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

/// Commit button: filled capsule, same shape as Play.
struct MixSheetPrimaryButton: View {

    let action: MixSheetAction
    var fullWidth: Bool

    private var fill: Color { action.isDestructive ? .mixDestructive : .mixPrimary }
    // `mixOnAccent` flips with the appearance; black on light-mode `mixPrimary` fails contrast.
    private var label: Color { action.isDestructive ? .white : .mixOnAccent }

    var body: some View {
        Button(action: action.action) {
            ZStack {
                // Title stays laid out while busy so the button keeps its width.
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

/// Inline status row under a field. Appears and disappears without changing
/// the sheet's shape.
struct MixSheetStatus: View {

    enum Kind {
        case busy
        case success
        /// Succeeded, but nothing new (already imported, already saved).
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
            // Failures in the destructive colour, not the accent.
            case .failure: return .mixDestructive
            }
        }
    }

    let kind: Kind
    let title: String
    var detail: String? = nil
    /// 0-1 when the work knows its progress. Nil for an unknown wait.
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
                    .font(.system(size: MixFontScale.size(13), weight: .medium))
                    .foregroundStyle(Color.mixTextPrimary)

                if let detail {
                    Text(detail)
                        .font(.system(size: MixFontScale.size(12)))
                        .foregroundStyle(Color.mixTextSecondary)
                        // Capped: an unbounded `fixedSize` in a narrow column can outgrow the window.
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

/// One option in a chooser sheet: leading icon, name, a line of explanation.
struct MixSheetOptionRow: View {

    let icon: String
    let title: String
    var detail: String? = nil
    /// Tints the icon only.
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
                        .font(.system(size: MixFontScale.size(13.5), weight: .medium))
                        .foregroundStyle(Color.mixTextPrimary)
                    if let detail {
                        Text(detail)
                            .font(.system(size: MixFontScale.size(12)))
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

/// Shared input field background.
extension View {
    func mixSheetField() -> some View {
        self
            .font(.system(size: MixFontScale.size(13.5)))
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
    static let closeSize: CGFloat = 17
    static let closeFrame: CGFloat = 22
    #else
    static let margin: CGFloat = 20
    static let titleSize: CGFloat = 20
    static let headerTop: CGFloat = 18
    static let headerBottom: CGFloat = 14
    static let contentVertical: CGFloat = 16
    static let footerTop: CGFloat = 14
    static let footerBottom: CGFloat = 28
    static let closeSize: CGFloat = 22
    /// 44pt for the tap target.
    static let closeFrame: CGFloat = 44
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

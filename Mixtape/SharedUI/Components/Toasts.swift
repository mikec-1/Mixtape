// The message toast: what just happened, on a card in the theme's opposite colour, like Spotify's.
// The icon says the kind at a glance. On iOS the cards live in a window above the app's,
// so they show over sheets, Now Playing and the keyboard's page too.

import SwiftUI
import Combine
#if os(iOS)
import UIKit
#endif

// MARK: - Model

/// One message. A plain string is an info toast, so `toast("…")` still reads as before.
public nonisolated struct Toast: Identifiable, Equatable, ExpressibleByStringInterpolation {

    public enum Kind: Sendable { case info, done, failed }

    public let id = UUID()
    public let message: String
    public let kind: Kind
    /// The reason, under the message.
    public let detail: String?
    /// Drawn before an info message, e.g. a bell for a notification.
    public let symbol: String?
    /// One button on the trailing edge, like Undo or View.
    public private(set) var action: Action?

    public struct Action {
        let title: String
        let run: @MainActor () -> Void
    }

    public init(_ message: String, kind: Kind = .info, detail: String? = nil, symbol: String? = nil) {
        self.message = message
        self.kind = kind
        self.detail = detail
        self.symbol = symbol
    }

    public init(stringLiteral value: String) { self.init(value) }
    public init(stringInterpolation: DefaultStringInterpolation) { self.init(String(stringInterpolation: stringInterpolation)) }

    public static func done(_ message: String) -> Toast { Toast(message, kind: .done) }

    /// Same toast with a button. Tapping it dismisses the toast, then runs.
    public func action(_ title: String, _ run: @escaping @MainActor () -> Void) -> Toast {
        var copy = self
        copy.action = Action(title: title, run: run)
        return copy
    }

    public static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }

    /// Opens a library playlist from anywhere. MainTabView and MacRootView do the navigating.
    @MainActor
    static func openPlaylist(_ id: UUID) {
        NotificationCenter.default.post(name: .mixOpenPlaylist, object: id)
    }

    /// Something the person tried didn't happen. Passing the error adds the reason when it's one they can act on.
    public static func failed(_ message: String, _ error: Error? = nil) -> Toast {
        Toast(message, kind: .failed, detail: error.flatMap(reason))
    }

    /// Long enough to read twice. Failures, and anything with a button, stay longer.
    var duration: Double {
        let words = "\(message) \(detail ?? "")".split(separator: " ").count
        return min(max(2.5, 1.2 + Double(words) * 0.3), 7)
            + (kind == .failed ? 1.5 : 0) + (action == nil ? 0 : 2)
    }

    var spoken: String {
        [kind == .failed ? "Error" : nil, message, detail].compactMap { $0 }.joined(separator: ". ")
    }

    /// Only the connection problems. Anything else would be jargon.
    private static func reason(_ error: Error) -> String? {
        switch (error as? URLError)?.code {
        case .notConnectedToInternet?, .networkConnectionLost?, .dataNotAllowed?:
            "You\u{2019}re offline. Check your connection and try again."
        case .timedOut?, .cannotConnectToHost?, .cannotFindHost?:
            "The server didn\u{2019}t answer. Try again in a moment."
        default: nil
        }
    }
}

extension Notification.Name {
    /// Object is the playlist's id.
    static let mixOpenPlaylist = Notification.Name("mix.openPlaylist")
}

// MARK: - Presenter

/// Owns the current toast. Separate from `deps` so showing one doesn't redraw every view watching deps.
@MainActor
public final class ToastCenter: ObservableObject {

    @Published public private(set) var current: Toast?
    private var dismissal: Task<Void, Never>?

    /// Replaces whatever is showing.
    public func show(_ toast: Toast) {
        current = toast
        if toast.kind == .failed { Haptics.play(.error) }
        AccessibilityNotification.Announcement(toast.spoken).post()
        dismissal?.cancel()
        dismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(toast.duration))
            guard !Task.isCancelled else { return }
            self?.current = nil
        }
    }

    func dismiss() {
        dismissal?.cancel()
        current = nil
    }
}

// MARK: - The card

/// Bold message, optional reason, and an icon or cover on the leading edge. Shared by the saved pill.
struct ToastChrome<Leading: View>: View {

    let message: String
    var detail: String? = nil
    var action: Toast.Action? = nil
    @ViewBuilder let leading: Leading

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: Metrics.spacing) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                Text(message)
                    .font(.system(size: MixFontScale.size(Metrics.font), weight: .semibold))
                    .foregroundStyle(Color.mixTextPrimary)
                if let detail {
                    Text(detail)
                        .font(.system(size: MixFontScale.size(Metrics.font - 2)))
                        .foregroundStyle(Color.mixTextSecondary)
                }
            }
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            #if os(iOS)
            Spacer(minLength: 0)
            #else
            if action != nil { Spacer(minLength: 0) }
            #endif
            if let action {
                Button(action: action.run) {
                    Text(action.title)
                        .font(.system(size: MixFontScale.size(Metrics.font), weight: .bold))
                        .foregroundStyle(Color.mixPrimary)
                        // A wider target than the word.
                        .padding(.vertical, 8)
                        .padding(.leading, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
        }
        .padding(.horizontal, Metrics.padding)
        .padding(.vertical, Metrics.padding - 2)
        // The palette resolves for the card, not the page under it.
        .environment(\.colorScheme, scheme == .dark ? .light : .dark)
        .background(scheme == .dark ? Color.white : Color(white: 0.14),
                    in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
        .frame(maxWidth: Metrics.maxWidth)
        .accessibilityElement(children: .combine)
        .accessibilityActions { if let action { Button(action.title, action: action.run) } }
    }
}

private enum Metrics {
    #if os(iOS)
    static let font: CGFloat = 15, padding: CGFloat = 16, spacing: CGFloat = 12
    static let radius: CGFloat = 12, maxWidth: CGFloat = 560
    #else
    static let font: CGFloat = 13, padding: CGFloat = 12, spacing: CGFloat = 10
    static let radius: CGFloat = 8, maxWidth: CGFloat = 440
    #endif
}

/// Red for failed, green for done, a hint of the subject for info.
struct ToastCard: View {

    let toast: Toast
    var action: Toast.Action? = nil

    var body: some View {
        ToastChrome(message: toast.message, detail: toast.detail, action: action) {
            if let icon {
                Image(systemName: icon.name)
                    .font(.system(size: MixFontScale.size(ToastCard.iconSize), weight: .semibold))
                    .foregroundStyle(icon.color)
                    .accessibilityHidden(true)
            }
        }
    }

    private var icon: (name: String, color: Color)? {
        switch toast.kind {
        case .failed: ("exclamationmark.circle.fill", .mixDestructive)
        case .done:   ("checkmark.circle.fill", .mixSuccess)
        case .info:   toast.symbol.map { ($0, .mixTextPrimary) }
        }
    }

    #if os(iOS)
    static let iconSize: CGFloat = 22
    #else
    static let iconSize: CGFloat = 15
    #endif
}

// MARK: - Host

/// Draws the current toast. Tap it, or swipe it down, to dismiss.
struct ToastHost: View {

    @ObservedObject var center: ToastCenter
    @State private var drag: CGFloat = 0

    var body: some View {
        ZStack {
            if let toast = center.current {
                ToastCard(toast: toast, action: toast.action.map { a in
                    Toast.Action(title: a.title) { center.dismiss(); a.run() }
                })
                    .offset(y: max(0, drag))
                    .id(toast.id)
                    .transition(SavedToastHost.transition)
                    .onTapGesture { center.dismiss() }
                    .gesture(DragGesture(minimumDistance: 4)
                        .onChanged { drag = $0.translation.height }
                        .onEnded { value in
                            if value.predictedEndTranslation.height > 60 { center.dismiss() }
                            else { withMixAnimation(SavedToastHost.animation) { drag = 0 } }
                        })
                    .accessibilityAction(named: "Dismiss") { center.dismiss() }
            }
        }
        .mixAnimation(SavedToastHost.animation, value: center.current)
        .onChange(of: center.current?.id) { drag = 0 }
    }
}

// MARK: - iOS window

#if os(iOS)
/// A window above the app's, so toasts show over sheets, full-screen covers and alerts.
/// It takes touches only on the cards and never becomes key, so typing stays in the app.
@MainActor
enum ToastWindow {

    private static var window: UIWindow?

    /// ponytail: one window, on the first scene. iPad multi-window would need one per scene.
    static func install(_ deps: AppDependencies) {
        guard window == nil,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let main = scene.windows.first else { return }
        let overlay = PassthroughWindow(windowScene: scene)
        let host = ToastController(rootView: ToastLayer(deps: deps, toasts: deps.toasts, saved: deps.savedToasts,
                                                        main: main) { [weak overlay] in overlay?.claimed = $0 })
        host.main = main
        host.view.backgroundColor = .clear
        overlay.rootViewController = host
        overlay.windowLevel = .normal + 1
        overlay.isHidden = false
        window = overlay
    }
}

private final class PassthroughWindow: UIWindow {

    /// Where the cards are. Touches anywhere else go to the app underneath.
    var claimed: CGRect = .zero

    override var canBecomeKey: Bool { false }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        claimed.contains(point) ? super.hitTest(point, with: event) : nil
    }
}

/// Leaves the status bar and rotation to whatever the app is showing.
private final class ToastController<Content: View>: UIHostingController<Content> {

    weak var main: UIWindow?

    private var top: UIViewController? {
        var top = main?.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }

    override var childForStatusBarStyle: UIViewController? { top }
    override var childForStatusBarHidden: UIViewController? { top }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        top?.supportedInterfaceOrientations ?? .all
    }
}

/// Bottom of the screen: above the mini player on the tabs, above the keyboard while typing,
/// and just above the home indicator over a sheet or cover.
private struct ToastLayer: View {

    let deps: AppDependencies
    // Watched so the clearance is read again whenever a card appears.
    @ObservedObject var toasts: ToastCenter
    @ObservedObject var saved: SavedToastCenter
    weak var main: UIWindow?
    let claim: (CGRect) -> Void

    @ObservedObject private var keyboard = KeyboardVisibility.shared
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        VStack(spacing: 0) {
            VersionCheckHost(coordinator: deps.onlineCoordinator, queue: deps.playbackEngine.queue, bottomGap: 8)
            SavedToastHost(center: saved, bottomGap: 8)
            ToastHost(center: toasts)
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { claim($0) }
        // Same width as the mini player.
        .padding(.horizontal, 8)
        .padding(.bottom, clearance)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .environmentObject(deps)
        .environmentObject(deps.libraryService)
        .mixAppearance(density: theme.density, motion: theme.motion, chrome: theme.chrome)
        .tint(theme.accentColor)
        .preferredColorScheme(theme.preferredColorScheme)
    }

    private var clearance: CGFloat {
        let presented = main?.rootViewController?.presentedViewController
        guard !keyboard.isVisible, deps.isAuthenticated, presented == nil || presented?.isBeingDismissed == true
        else { return 8 }
        return deps.playbackEngine.state.isActive
            ? MiniPlayerMetrics.overlayBottomPadding + MiniPlayerMetrics.barHeight + 10
            : MiniPlayerMetrics.tabBarHeight + 12
    }
}
#endif

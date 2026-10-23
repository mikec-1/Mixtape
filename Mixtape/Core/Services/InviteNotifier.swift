// Local notifications: inbox rows, messages, Jams nearby and new releases.
// There's no push, so these fire when the app notices something itself: while
// running, on returning to the foreground, or during an iOS background refresh
// (opportunistic). Inbox and message banners only show while the app isn't
// frontmost, since those toast in the app. Also the notification centre's
// delegate, so a tap opens what the banner was about.

import Foundation
import Combine
import UserNotifications
import UniformTypeIdentifiers
#if os(iOS)
import BackgroundTasks
import UIKit
#else
import AppKit
import Observation
#endif

@Observable
@MainActor
public final class InviteNotifier: NSObject {

    public static let shared = InviteNotifier()

    /// Set at launch, for the release check and recap taps.
    @ObservationIgnored weak var deps: AppDependencies?

    private override init() {}

    /// Page-1 notices already announced. Persisted so a dismissed banner doesn't come back
    /// every launch. Missing means nothing has been checked yet on this account.
    private static let announcedKey = "inbox.notified.ids"

    private var announced: Set<String>? {
        get { UserDefaults.standard.stringArray(forKey: Self.announcedKey).map(Set.init) }
        set { UserDefaults.standard.set(newValue.map(Array.init), forKey: Self.announcedKey) }
    }

    /// Delegate and the DM reply action. Set before launch finishes so a tap that launched the app still arrives.
    func install(_ deps: AppDependencies) {
        self.deps = deps
        watchBadge()
        let centre = UNUserNotificationCenter.current()
        centre.delegate = self
        centre.setNotificationCategories([UNNotificationCategory(identifier: "dm", actions: [
            UNTextInputNotificationAction(identifier: "reply", title: "Reply", options: [],
                                          textInputButtonTitle: "Send", textInputPlaceholder: "Message"),
        ], intentIdentifiers: [])])
    }

    // MARK: On and off

    /// Per device. Off until turned on in Settings or the first-launch ask.
    nonisolated public static let enabledKey = "notifications.enabled"
    /// Set once the first-launch ask is answered.
    nonisolated public static let askedKey = "notifications.asked"

    public static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    #if os(macOS)
    public static let systemSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")")
    #else
    public static let systemSettingsURL = URL(string: UIApplication.openNotificationSettingsURLString)
    #endif

    /// Turns banners on, asking the system if it never has. False when the system has them blocked.
    @discardableResult
    public func enable() async -> Bool {
        let centre = UNUserNotificationCenter.current()
        if await centre.notificationSettings().authorizationStatus == .notDetermined {
            _ = try? await centre.requestAuthorization(options: [.alert, .sound, .badge])
        }
        let status = await centre.notificationSettings().authorizationStatus
        let allowed = status == .authorized || status == .provisional
        UserDefaults.standard.set(allowed, forKey: Self.enabledKey)
        // Turning them on in Settings answers the first-launch ask too.
        UserDefaults.standard.set(true, forKey: Self.askedKey)
        showBadge()
        return allowed
    }

    /// Also takes down anything showing or scheduled, like a recap due on the 1st.
    public func disable() {
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        showBadge()
        let centre = UNUserNotificationCenter.current()
        centre.removeAllPendingNotificationRequests()
        centre.removeAllDeliveredNotifications()
    }

    // MARK: App icon badge

    @ObservationIgnored private var badgeWatch: AnyCancellable?
    /// Also badges the Library tab on iOS, where the inbox lives.
    private(set) var unread = 0

    /// Unread inbox rows plus unread messages, the same counts as the tray and plane buttons.
    private func watchBadge() {
        badgeWatch = InboxService.shared.rowsPublisher
            .combineLatest(MessagesService.shared.threadsPublisher)
            .map { rows, threads in rows.count { $0.readAt == nil } + threads.reduce(0) { $0 + $1.unread } }
            .removeDuplicates()
            .sink { [weak self] in
                self?.unread = $0
                self?.showBadge()
            }
    }

    /// Follows the notifications switch, like the banners.
    private func showBadge() {
        let count = Self.isEnabled ? unread : 0
        #if os(macOS)
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        #else
        Task { try? await UNUserNotificationCenter.current().setBadgeCount(count) }
        #endif
    }

    // MARK: Posting

    /// Banners each new unread notice and returns them. The first check on an account only
    /// records what's there, so an existing inbox doesn't arrive as a pile of banners.
    @discardableResult
    public func announce(_ page: [InboxService.Notice], suppressBanner: Bool) async -> [InboxService.Notice] {
        let seen = announced
        // Only page 1 is ever compared, so older ids can go.
        announced = Set(page.map(\.id.uuidString))
        guard let seen else { return [] }
        let unseen = page.filter { $0.readAt == nil && !seen.contains($0.id.uuidString) }
        guard !suppressBanner else { return unseen }

        for notice in unseen {
            await post("inbox-\(notice.id.uuidString)",
                       title: Self.heading(notice),
                       body: notice.kind == .system ? (notice.body ?? "") : notice.sentence,
                       image: notice.artworkURL)
        }
        return unseen
    }

    /// Newest received message already announced. Missing means nothing checked yet on this account.
    private static let messagesKey = "inbox.notified.messagesAt"

    /// Banners threads with an unread message newer than the last check, same first-check rule as `announce`.
    @discardableResult
    public func announceMessages(_ threads: [MessagesService.Thread], suppressBanner: Bool) async -> [MessagesService.Thread] {
        let seen = UserDefaults.standard.object(forKey: Self.messagesKey) as? Date
        let received = threads.filter { $0.unread > 0 && !$0.lastFromMe }
        if let newest = received.map(\.lastAt).max(), newest > (seen ?? .distantPast) {
            UserDefaults.standard.set(newest, forKey: Self.messagesKey)
        } else if seen == nil {
            UserDefaults.standard.set(Date(), forKey: Self.messagesKey)
        }
        guard let seen else { return [] }
        let unseen = received.filter { $0.lastAt > seen }
        guard !suppressBanner else { return unseen }

        for thread in unseen {
            let person = thread.profile
            // One per person, so a newer message replaces the older banner.
            await post("dm-\(person.id.uuidString)", title: person.name, body: thread.lastBody,
                       info: ["dm": person.id.uuidString, "username": person.username,
                              "displayName": person.displayName ?? "",
                              "avatar": person.avatarURL?.absoluteString ?? ""],
                       category: "dm")
        }
        return unseen
    }

    /// Tapping it joins.
    func announceJam(code: String, host: String) async {
        await post("jam-\(code)", title: "\(host) started a Jam near you", body: "Tap to join", info: ["jam": code])
    }

    /// Release ids already announced, and when the catalogue was last asked.
    private static let releasesKey = "notified.releases"
    private static let releasesAtKey = "notified.releasesAt"

    /// At most daily: banners records by library artists that came out this week. The first
    /// check on a device only records what's already out.
    public func checkNewReleases() async {
        let defaults = UserDefaults.standard
        guard let deps,
              (defaults.object(forKey: Self.releasesAtKey) as? Date ?? .distantPast).timeIntervalSinceNow < -20 * 3600
        else { return }
        let artists = RecommendationEngine.radarSeeds(library: deps.libraryService)
        // The library hasn't loaded yet; the next refresh tries again.
        guard !artists.isEmpty else { return }
        defaults.set(Date(), forKey: Self.releasesAtKey)
        let albums = await RecommendationEngine.recentReleases(artists: artists, using: deps.itunesClient)
        guard !albums.isEmpty else { return }

        let seen = defaults.stringArray(forKey: Self.releasesKey)
        let fresh = albums.filter { !(seen ?? []).contains(String($0.id)) }
        defaults.set(Array(((seen ?? []) + fresh.map { String($0.id) }).suffix(200)), forKey: Self.releasesKey)
        guard seen != nil else { return }
        // ponytail: three a day, a single "N new releases" banner if people follow more
        for album in fresh.prefix(3) {
            await post("release-\(album.id)", title: "New from \(album.artistName)", body: album.title,
                       info: ["album": album.title, "artist": album.artistName], image: album.coverURL)
        }
    }

    /// `image` is for covers only: an expanded banner shows it full width, which suits art but not a face.
    private func post(_ id: String, title: String, body: String, info: [String: String] = [:],
                      image: URL? = nil, category: String = "") async {
        let centre = UNUserNotificationCenter.current()
        let status = await centre.notificationSettings().authorizationStatus
        guard Self.isEnabled, status == .authorized || status == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = info
        content.categoryIdentifier = category
        // Stacks by kind: messages together, releases together.
        content.threadIdentifier = String(id.prefix { $0 != "-" })
        if let picture = await Self.attachment(image) { content.attachments = [picture] }
        try? await centre.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    /// The picture as a local file, which is all an attachment takes. Nil on any failure, and the banner goes without.
    private static func attachment(_ url: URL?) async -> UNNotificationAttachment? {
        guard let url,
              let (data, response) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 5)),
              let type = response.mimeType.flatMap({ UTType(mimeType: $0) }), type.conforms(to: .image) else { return nil }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(type.preferredFilenameExtension ?? "jpg")
        guard (try? data.write(to: file)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: "picture", url: file)
    }

    private static func heading(_ notice: InboxService.Notice) -> String {
        switch notice.kind {
        case .invite: return "Playlist invite"
        case .joined: return "New collaborator"
        case .saved:  return "Playlist saved"
        case .dub:    return "You got a dub"
        case .postLike, .postRepost: return "Your post"
        case .postComment:  return "New comment"
        case .commentReply: return "New reply"
        case .follow:       return "New follower"
        case .system: return notice.title ?? "Mixtape"
        }
    }

    /// Removes the banner for an answered invite.
    public func clear(_ noticeID: UUID) {
        let id = "inbox-\(noticeID.uuidString)"
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }

    /// The next account's inbox isn't this one's.
    public func reset() {
        for key in [Self.announcedKey, Self.messagesKey, Self.releasesKey, Self.releasesAtKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: Background refresh

    /// Must match BGTaskSchedulerPermittedIdentifiers in Info.plist.
    nonisolated public static let backgroundTaskID = "com.mikey.Mixtape.invite-refresh"

    /// Asks for background time to check the inbox. iOS decides when, 15 min is the floor.
    public nonisolated func scheduleBackgroundRefresh() {
        #if os(iOS)
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        // Fails on simulators and extensions, nothing to do about it.
        try? BGTaskScheduler.shared.submit(request)
        #endif
    }

    /// Background task body. Re-arms first so an early return doesn't end the chain.
    public func runBackgroundRefresh() async {
        scheduleBackgroundRefresh()
        await InboxService.shared.refresh()
        await MessagesService.shared.refresh()
        await checkNewReleases()
    }

    // MARK: Taps

    /// What a tapped banner opens. The root views take it, so it survives a cold launch.
    public enum Tap {
        case messages(UserProfile)
        case jam(String)
        case album(title: String, artist: String)
    }

    @ObservationIgnored private var pendingTap: Tap?

    public func takePendingTap() -> Tap? {
        defer { pendingTap = nil }
        return pendingTap
    }

    /// A reply typed into a message banner. Replying reads the thread.
    private func send(_ text: String, _ info: [String: String]) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let other = info["dm"].flatMap(UUID.init(uuidString:)) else { return }
        do {
            try await MessagesService.shared.send(id: UUID(), to: other, body: text)
            await MessagesService.shared.markRead(other)
        } catch {
            await post("dm-failed-\(other.uuidString)", title: "Your reply didn't send",
                       body: "Tap to open the conversation and try again.", info: info)
        }
    }

    private func open(_ id: String, _ info: [String: String]) {
        if id.hasPrefix("recap-") {
            deps?.recap.open(month: String(id.dropFirst("recap-".count)))
            return
        }
        if let code = info["jam"] {
            pendingTap = .jam(code)
        } else if let title = info["album"], let artist = info["artist"] {
            pendingTap = .album(title: title, artist: artist)
        } else if let id = info["dm"].flatMap(UUID.init(uuidString:)), let username = info["username"] {
            pendingTap = .messages(UserProfile(id: id, username: username, displayName: info["displayName"],
                                               avatarURL: info["avatar"].flatMap(URL.init(string:))))
        } else {
            // Inbox rows: bringing the app forward is enough.
            return
        }
        NotificationCenter.default.post(name: .mixNotificationTap, object: nil)
    }
}

public extension Notification.Name {
    static let mixNotificationTap = Notification.Name("mix.notificationTap")
}

extension InviteNotifier: UNUserNotificationCenterDelegate {
    /// Jams and releases have no in-app toast, so they banner in the foreground too.
    nonisolated public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                                   willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let id = notification.request.identifier
        return id.hasPrefix("jam-") || id.hasPrefix("release-") ? [.banner, .list, .sound] : []
    }

    nonisolated public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                                   didReceive response: UNNotificationResponse) async {
        let id = response.notification.request.identifier
        // String values only: a push payload also carries "aps", which fails a whole-dictionary cast.
        var info: [String: String] = [:]
        for case let (key as String, value as String) in response.notification.request.content.userInfo { info[key] = value }
        if let reply = response as? UNTextInputNotificationResponse {
            await send(reply.userText, info)
        } else {
            await open(id, info)
        }
    }
}

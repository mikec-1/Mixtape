// InviteNotifier.swift
// Mixtape — Core/Services
//
// System notifications for collaborative-playlist invites.
//
// These are *local* notifications, and the distinction matters. Mixtape has no
// push infrastructure — no APNs key, no device-token table, no Edge Function to
// send from — so nothing can wake this device the instant somebody else presses
// Invite. What can happen is that the app notices on its own and then tells the
// user through the same banner a push would have used:
//
//   • whenever the app is running or returns to the foreground, and
//   • when iOS grants the app a background refresh (see MixtapeApp's
//     `.backgroundTask(.appRefresh:)`), which is opportunistic — minutes to
//     hours, and never at all if the user force-quit the app.
//
// So an invite is delivered reliably but not instantly. Real push is a separate
// piece of work that needs an APNs key from the developer account and a Supabase
// trigger to send from; the client half would then post the same banner text
// this file already builds.
//
// Banners are only raised while the app is *not* frontmost. RootView already
// shows an in-app toast for a new invite, and firing both means the same news
// twice on one screen.

import Foundation
import UserNotifications
#if os(iOS)
import BackgroundTasks
#endif

@MainActor
public final class InviteNotifier {

    public static let shared = InviteNotifier()

    private init() {}

    /// Invites already announced, by shared-playlist id.
    ///
    /// Persisted, unlike the toast's per-launch set: a banner is a thing the user
    /// has *seen and dismissed*, and re-posting it on every cold launch until they
    /// get round to answering would train them to ignore it.
    private static let announcedKey = "invite.notified.ids"

    private var announced: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.announcedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.announcedKey) }
    }

    // MARK: Authorisation

    /// Asks for permission the first time, and never again after an answer.
    ///
    /// Called on sign-in rather than at launch so the prompt lands when the user
    /// has an account that somebody could plausibly invite — a permission sheet
    /// on a cold first launch, before there is anyone to hear from, is the kind
    /// users decline reflexively and then never revisit.
    public func requestAuthorizationIfNeeded() async {
        let centre = UNUserNotificationCenter.current()
        let settings = await centre.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await centre.requestAuthorization(options: [.alert, .sound, .badge])
    }

    // MARK: Posting

    /// Raises a banner for each invite not previously announced.
    ///
    /// `suppressBanner` is passed by callers that are already showing the news
    /// in-app; the invite is still marked as announced so it doesn't reappear as
    /// a banner the moment the app goes to the background.
    public func announce(_ invites: [PlaylistSharingService.PendingInvite],
                         suppressBanner: Bool) async {
        let unseen = invites.filter { !announced.contains($0.id.uuidString) }
        guard !unseen.isEmpty else { return }

        announced.formUnion(unseen.map(\.id.uuidString))
        guard !suppressBanner else { return }

        let centre = UNUserNotificationCenter.current()
        let settings = await centre.notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
        else { return }

        for invite in unseen {
            let content = UNMutableNotificationContent()
            content.title = "Playlist invite"
            content.body  = Self.body(for: invite)
            content.sound = .default
            content.userInfo = ["sharedPlaylistID": invite.id.uuidString]

            // Identified by playlist so a re-announce replaces rather than stacks.
            let request = UNNotificationRequest(identifier: "invite-\(invite.id.uuidString)",
                                                content: content,
                                                trigger: nil)
            try? await centre.add(request)
        }
    }

    /// "@alex invited you to collaborate on “Late Night”."
    ///
    /// The inviter's username is resolved separately from the collaborator row, so
    /// it can legitimately be missing — a deleted profile, or a read that failed.
    /// "Someone" reads better there than an empty @.
    static func body(for invite: PlaylistSharingService.PendingInvite) -> String {
        let who = invite.inviterName ?? "Someone"
        return "\(who) invited you to collaborate on \u{201C}\(invite.record.name)\u{201D}."
    }

    /// Drops the banner for an invite that has just been answered, so a stale one
    /// sitting in Notification Centre can't be tapped into a playlist the user
    /// already declined.
    public func clear(_ inviteID: UUID) {
        let id = "invite-\(inviteID.uuidString)"
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }

    /// Forgets the announced set on sign-out — the next account's invites are not
    /// this account's, and their ids would otherwise be pre-suppressed.
    public func reset() {
        UserDefaults.standard.removeObject(forKey: Self.announcedKey)
    }

    // MARK: Background refresh

    /// Must match the entry in Info.plist's `BGTaskSchedulerPermittedIdentifiers`;
    /// `submit` throws at runtime if it doesn't.
    public static let backgroundTaskID = "com.mikey.Mixtape.invite-refresh"

    /// Asks iOS for a slice of background time to check the inbox.
    ///
    /// `earliestBeginDate` is a floor, not a promise — the system decides when (or
    /// whether) to run this based on how often the app is used, battery state and
    /// Low Power Mode. Fifteen minutes is the shortest floor worth asking for;
    /// anything shorter is silently treated the same.
    public nonisolated func scheduleBackgroundRefresh() {
        #if os(iOS)
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        // Throws when the identifier isn't declared, when the app is in an
        // extension, or on a simulator — none of which the user can act on.
        try? BGTaskScheduler.shared.submit(request)
        #endif
    }

    /// The body of the background task: re-read the inbox, banner anything new.
    ///
    /// Re-arms the next request first. A background task gets one shot, and an
    /// early return anywhere below — no session, empty inbox — would otherwise end
    /// the chain permanently, leaving invites undelivered until the next launch.
    public func runBackgroundRefresh() async {
        scheduleBackgroundRefresh()
        let sharing = PlaylistSharingService.shared
        await sharing.refreshPendingInvites()
        await announce(sharing.pendingInvites, suppressBanner: false)
    }
}

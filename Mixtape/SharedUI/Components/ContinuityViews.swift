// ContinuityViews.swift
// Mixtape — SharedUI/Components
//
// The device picker and "Playing on" line for continuity playback. Each view
// observes `ContinuityService` itself — `deps` doesn't rebroadcast it — so the
// bars hosting them redraw for a device change and nothing else does.

import SwiftUI

extension ContinuityService.Device {
    var symbol: String {
        switch platform {
        case "iOS": return "iphone"
        case "web": return "globe"
        default:    return "laptopcomputer"
        }
    }

    var kindName: String {
        switch platform {
        case "iOS": return "iPhone"
        case "web": return "Web Player"
        default:    return "Mac"
        }
    }
}

/// Hands its content the device playing right now, or nil when it's this one.
struct WithActiveRemote<Content: View>: View {
    @ObservedObject var continuity: ContinuityService
    @ViewBuilder let content: (ContinuityService.Device?) -> Content

    var body: some View { content(continuity.activeRemote) }
}

/// "Playing on Mike's iPhone", in the accent colour.
struct PlayingOnText: View {
    let device: ContinuityService.Device
    var font: Font = .mixCaptionBold
    var color: Color = .mixPrimary

    var body: some View {
        Label {
            Text("Playing on \(device.name)").lineLimit(1)
        } icon: {
            Image(systemName: "hifispeaker.fill")
        }
        .font(font)
        .foregroundStyle(color)
    }
}

/// The accent band the player bars wear while another device has the music —
/// Spotify's green strip. Full width, one line, always legible: the name used
/// to be a truncated caption competing with the artist line inside the bar.
struct RemoteDeviceStrip: View {
    let device: ContinuityService.Device
    var alignment: Alignment = .trailing
    var hPadding: CGFloat = 14
    /// Tapping the strip is the second way into the picker, so the name is a
    /// control and not just a label.
    var onTap: (() -> Void)? = nil

    var body: some View {
        let band = PlayingOnText(device: device, color: .mixOnAccent)
            .frame(maxWidth: .infinity, alignment: alignment)
            .padding(.horizontal, hPadding)
            .frame(height: 24)
            .background(Color.mixAccentFill)
            .contentShape(Rectangle())

        if let onTap {
            Button(action: onTap) { band }
                .buttonStyle(.plain).mixHandCursor()
                .accessibilityLabel("Playing on \(device.name). Choose a device")
        } else {
            band
        }
    }
}

// MARK: - Picker

/// Every open device, the one playing first. Picking one moves playback there.
///
/// Spotify Connect's shape, and its spacing: the device in charge is a card at
/// the top with what it is playing, everything else is a plain list underneath,
/// and the output route and audio quality get their own sections rather than
/// being crammed into a footnote. Rows are tall and sections are far apart on
/// purpose — the whole sheet is four decisions, not a dense table.
struct DevicePickerList: View {
    @ObservedObject var continuity: ContinuityService
    /// The Settings → Downloads quality, changeable from here. Observed
    /// directly: `deps` deliberately doesn't republish the download manager.
    @ObservedObject var downloads: DownloadManager
    var onPick: () -> Void = {}

    var body: some View {
        let current = continuity.activeRemote ?? continuity.me
        let others = ([continuity.me] + continuity.devices).filter { $0.id != current.id }

        VStack(alignment: .leading, spacing: 20) {
            CurrentDeviceCard(device: current,
                              kind: kind(current),
                              status: continuity.status(of: current))

            if others.isEmpty {
                Text("Open Mixtape on another device signed in to this account and it will show up here.")
                    .font(.mixSubtext)
                    .foregroundStyle(Color.mixTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
            } else {
                section("Select Another Device") {
                    ForEach(others) { device in
                        // No song line here: picking a device plays what is
                        // playing now, so what it *was* doing is noise.
                        DeviceRow(device: device, kind: kind(device)) {
                            continuity.play(on: device.id == continuity.me.id ? nil : device)
                            onPick()
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Divider().overlay(Color.mixSeparator).padding(.bottom, 4)
                #if os(iOS)
                RouteButton()
                #endif
                QualityRow(downloads: downloads)
            }

            Text("Only one device plays at a time.")
                .font(.mixCaption)
                .foregroundStyle(Color.mixTextTertiary)
                .padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The popover takes key the moment it opens and AppKit draws its focus
        // ring around whichever row got focus — the purple rectangle around the
        // current device. Same treatment as the Mac search results.
        .focusEffectDisabled()
    }

    /// The device's own name is in the row title, so this line carries what the
    /// title can't: what kind of machine it is, and what it plays at.
    private func kind(_ device: ContinuityService.Device) -> String {
        guard device.id != continuity.me.id else {
            return "This \(device.kindName) · \(downloads.downloadQuality.title)"
        }
        guard let quality = device.quality else { return device.kindName }
        return "\(device.kindName) · \(quality)"
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.mixCaptionBold)
                .foregroundStyle(Color.mixTextSecondary)
                .textCase(.uppercase)
                .padding(.horizontal, 8)
            content()
        }
    }
}

// MARK: - Rows

/// The device in charge: a tinted card, because "where is the music" is the one
/// question this picker exists to answer and a row in a list doesn't say it.
private struct CurrentDeviceCard: View {
    let device: ContinuityService.Device
    let kind: String
    let status: ContinuityService.DeviceStatus

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: device.symbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Color.mixOnAccent)
                .frame(width: 48, height: 48)
                .background(Color.mixAccentFill,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(device.name)
                    .font(.mixBodyBold)
                    .foregroundStyle(Color.mixPrimary)
                    .lineLimit(1)
                if let line = status.line {
                    Text(line)
                        .font(.mixSubtext)
                        .foregroundStyle(Color.mixTextSecondary)
                        .lineLimit(1)
                }
                Text(kind)
                    .font(.mixCaption)
                    .foregroundStyle(Color.mixTextTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            NowPlayingBars(isPlaying: status.isPlaying)
                .opacity(status.line == nil ? 0 : 1)
                .accessibilityHidden(true)
        }
        .padding(14)
        // Explicit, not inferred from the Spacer: as a content-sized card it
        // sat a few points in from the leading edge the rows use, which is the
        // lopsided gap around it.
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.mixPrimary.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.mixPrimary.opacity(0.25), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Current device: \(device.name), \(kind)")
    }
}

private struct DeviceRow: View {
    let device: ContinuityService.Device
    let kind: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: device.symbol)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.mixTextPrimary)
                    .frame(width: 40, height: 40)
                    .background(Color.mixSurface2,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .font(.mixBodyBold)
                        .foregroundStyle(Color.mixTextPrimary)
                        .lineLimit(1)
                    Text(kind)
                        .font(.mixSubtext)
                        .foregroundStyle(Color.mixTextSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Chevron()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(isHovered ? Color.primary.opacity(0.07) : .clear,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).mixHandCursor()
        .onHover { isHovered = $0 }
        .accessibilityLabel("\(device.name), \(kind). Play here")
    }
}

/// Audio quality, changeable in place. It used to be a read-only footnote —
/// but the one thing anyone wants after reading "Low" is to change it, and
/// Settings → Downloads is three taps away from here. Same shape as a Settings
/// picker row: a real `Picker`, not a `Menu` wrapping the row (macOS flattens a
/// custom menu label and the row lost its tile, subtitle and value).
private struct QualityRow: View {
    @ObservedObject var downloads: DownloadManager

    var body: some View {
        PickerTile(icon: "waveform",
                   title: "Audio quality",
                   subtitle: downloads.downloadQuality.detail) {
            Picker("", selection: Binding(get: { downloads.downloadQuality },
                                          set: { downloads.downloadQuality = $0 })) {
                ForEach(DownloadQuality.allCases) { quality in
                    Text(quality.title).tag(quality)
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

/// The shared look of the two non-device rows: same height and tile as a
/// `DeviceRow`, so the sheet reads as one list rather than three widgets.
private struct PickerTile<Trailing: View>: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.mixTextPrimary)
                .frame(width: 40, height: 40)
                .background(Color.mixSurface2,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.mixBodyBold)
                    .foregroundStyle(Color.mixTextPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.mixSubtext)
                        .foregroundStyle(Color.mixTextSecondary)
                        // Wraps rather than truncates: the quality lines are
                        // sentences, and "AAC 96 kbps — ab…" says nothing.
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 56)
        .contentShape(Rectangle())
    }
}

extension PickerTile where Trailing == Chevron {
    /// A row that is itself the control — a chevron, no value.
    init(icon: String, title: String, subtitle: String? = nil) {
        self.init(icon: icon, title: title, subtitle: subtitle) { Chevron() }
    }
}

struct Chevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.mixTextTertiary)
            .accessibilityHidden(true)
    }
}

// MARK: - iOS entry point

#if os(iOS)
import AVKit
import Combine

/// Bluetooth, AirPlay and wired output — the system's picker, wearing a row.
/// `AVRoutePickerView` is the only way to raise it, so it is laid invisibly
/// over the row rather than being driven by a tap handler.
private struct RouteButton: View {
    @State private var output = AVAudioSession.sharedInstance().currentRoute.outputs.first

    var body: some View {
        PickerTile(icon: "airplayaudio",
                   title: "Bluetooth & AirPlay",
                   subtitle: output?.portName)
            .overlay { RoutePicker(label: "Bluetooth and AirPlay") }
            .onReceive(NotificationCenter.default
                .publisher(for: AVAudioSession.routeChangeNotification)
                .receive(on: RunLoop.main)) { _ in
                output = AVAudioSession.sharedInstance().currentRoute.outputs.first
            }
    }
}

/// Zero-tint `AVRoutePickerView`, used as an invisible tap target.
struct RoutePicker: UIViewRepresentable {
    let label: String

    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .clear
        v.activeTintColor = .clear
        v.prioritizesVideoDevices = false
        return v
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.accessibilityLabel = label
    }
}

/// The devices control for iOS, and the player bars' output indicator.
///
/// Spotify's rule: with nothing but the built-in speaker the control is just
/// the devices glyph; the moment a remote device or an external output takes
/// the sound, the glyph is replaced by that thing's name in the accent colour.
/// Either way a tap opens the picker — the system route sheet is a row inside
/// it, not this button's job.
struct DevicesButton: View {
    @ObservedObject var continuity: ContinuityService
    @ObservedObject var downloads: DownloadManager
    var size: CGFloat = 18
    /// Off in the mini player, where the accent strip already names the remote
    /// device and there is no room for a second label.
    var showsName: Bool = false
    @State private var showPicker = false
    @State private var output = AVAudioSession.sharedInstance().currentRoute.outputs.first

    /// Built-in speaker/receiver isn't "an output" to anyone — it's just the phone.
    private var external: AVAudioSessionPortDescription? {
        guard let output, output.portType != .builtInSpeaker,
              output.portType != .builtInReceiver else { return nil }
        return output
    }

    private var name: String? {
        if let remote = continuity.activeRemote { return remote.name }
        return external?.portName
    }

    private var icon: String {
        if continuity.activeRemote != nil { return "hifispeaker.fill" }
        switch external?.portType {
        case .none:                             return "laptopcomputer.and.iphone"
        case .airPlay:                          return "airplayaudio"
        case .carAudio:                         return "car"
        case .some(.bluetoothA2DP), .some(.bluetoothHFP),
             .some(.bluetoothLE),   .some(.headphones):
                                                return "headphones"
        default:                                return "hifispeaker"
        }
    }

    var body: some View {
        Button { showPicker = true } label: {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: size, weight: .medium))
                if showsName, let name {
                    Text(name).font(.mixLabel).lineLimit(1)
                }
            }
            .foregroundStyle(name == nil ? Color.mixTextSecondary : Color.mixPrimary)
            .padding(.horizontal, showsName && name != nil ? 10 : 0)
            .frame(minWidth: 36, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name.map { "Devices, playing on \($0)" } ?? "Devices")
        .onReceive(NotificationCenter.default
            .publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: RunLoop.main)) { _ in
            output = AVAudioSession.sharedInstance().currentRoute.outputs.first
        }
        .sheet(isPresented: $showPicker) {
            // The app's own sheet chrome rather than a hand-rolled one: title,
            // drag indicator and close control where every other sheet keeps
            // them. `.medium` so the sections have room to breathe.
            MixSheet(title: "Devices",
                     subtitle: "Play on any device signed in to this account.",
                     size: .medium) {
                DevicePickerList(continuity: continuity, downloads: downloads) {
                    showPicker = false
                }
            }
        }
    }
}
#endif

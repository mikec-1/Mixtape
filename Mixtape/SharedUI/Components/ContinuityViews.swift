// Continuity device picker and "Playing on" line. Each observes
// `ContinuityService` itself since `deps` doesn't rebroadcast it.

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
    var continuity: ContinuityService
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

/// Accent strip on the player bars while another device is playing.
struct RemoteDeviceStrip: View {
    let device: ContinuityService.Device
    var alignment: Alignment = .trailing
    var hPadding: CGFloat = 14
    /// Tapping opens the picker.
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

/// Every open device, current one first; picking one moves playback there.
/// Spotify Connect layout: current device card, other devices, output, quality.
struct DevicePickerList: View {
    var continuity: ContinuityService
    /// Observed directly: `deps` doesn't republish the download manager.
    var downloads: DownloadManager
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
                        // No song line: picking a device plays what's playing now.
                        DeviceRow(device: device, kind: kind(device)) {
                            continuity.play(on: device.id == continuity.me.id ? nil : device)
                            onPick()
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Divider().overlay(Color.mixSeparator).padding(.bottom, 8)
                JamTiles(onPick: onPick)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                QualityRow(downloads: downloads)
            }

            Text("Only one device plays at a time.")
                .font(.mixCaption)
                .foregroundStyle(Color.mixTextTertiary)
                .padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Hides the focus ring AppKit draws when the popover takes key.
        .focusEffectDisabled()
    }

    /// Device type and quality; the name is in the title.
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

/// Tinted card for the device currently playing.
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
        // Explicit so it lines up with the rows' leading edge.
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

/// Start or open the Jam, the system output picker on iOS, and Jams nearby.
/// Reads `deps` so the picker's call sites stay as they are.
private struct JamTiles: View {
    @Environment(AppDependencies.self) private var deps
    let onPick: () -> Void

    var body: some View { Content(jam: deps.jam, onPick: onPick) }

    private struct Content: View {
        var jam: JamService
        let onPick: () -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    JamTile(icon: "person.2.wave.2", title: title, active: jam.session != nil) {
                        onPick()
                        jam.present()
                    }
                    #if os(iOS)
                    RouteButton()
                    #endif
                }
                NearbyJams(jam: jam, onPick: onPick)
            }
            .onAppear { jam.nearby.startBrowsing() }
            .onDisappear { jam.nearby.stopBrowsing() }
        }

        private var title: String {
            guard let s = jam.session else { return "Start a Jam" }
            return s.isHost ? "Your Jam" : "\(s.hostName)\u{2019}s Jam"
        }
    }
}

/// Editable quality. A real `Picker`, not a `Menu`, which macOS flattens.
private struct QualityRow: View {
    var downloads: DownloadManager

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

/// Same height and tile as `DeviceRow`.
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
                        // Wraps instead of truncating.
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
    /// Chevron, no value.
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

/// System output picker. `AVRoutePickerView` is laid invisibly over the row
/// since it's the only way to raise it.
private struct RouteButton: View {
    @State private var output = AVAudioSession.sharedInstance().currentRoute.outputs.first

    var body: some View {
        JamTileLabel(icon: "airplayaudio", title: output?.portName ?? "Bluetooth & AirPlay")
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

/// Devices button. Just the glyph on the built-in speaker, otherwise the active
/// output's name in accent. Tap opens the picker.
struct DevicesButton: View {
    var continuity: ContinuityService
    var downloads: DownloadManager
    var size: CGFloat = 18
    /// Off in the mini player, where the strip already names the device.
    var showsName: Bool = false
    @State private var showPicker = false
    @State private var output = AVAudioSession.sharedInstance().currentRoute.outputs.first

    /// The built-in speaker/receiver doesn't count.
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
            // Standard sheet chrome. `.medium` detent.
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

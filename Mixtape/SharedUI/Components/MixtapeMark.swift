import SwiftUI

/// The app's own mark: the launch screen's waveform at any size. Signs mixes,
/// the Mixtape profile and saved mixes without artwork. The symbol is a filled
/// circle with the waveform cut out, so don't draw a circle behind it.
public struct MixtapeMark: View {

    /// A missing symbol fails silently (an empty frame), so the name lives in one place.
    public static let symbolName = "waveform.circle.fill"

    private let size: CGFloat
    private let style: AnyShapeStyle

    /// Flat `mixPrimary`, same as the launch and sign-in screens.
    public init(size: CGFloat) {
        self.init(size: size, style: Color.mixPrimary)
    }

    /// Custom fill, e.g. white on a coloured background.
    public init(size: CGFloat, style: some ShapeStyle) {
        self.size  = size
        self.style = AnyShapeStyle(style)
    }

    public var body: some View {
        Image(systemName: Self.symbolName)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(style)
    }
}

import SwiftUI

/// The live aurora behind the whole window (Aurora.metal). Drawn at half resolution and scaled up,
/// at 30 fps, so it costs little GPU; with Reduce Motion on it holds one still frame.
struct AuroraBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    /// Drawn at 1/`downscale` of the window and scaled up: the sky is soft, so nothing is lost.
    var downscale: CGFloat = 2
    private static let start = Date()

    var body: some View {
        GeometryReader { geo in
            let size = CGSize(width: max(1, geo.size.width / downscale), height: max(1, geo.size.height / downscale))
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
                let t = Float(context.date.timeIntervalSince(Self.start)) + 40   // start mid-display, not at dark
                Rectangle()
                    .frame(width: size.width, height: size.height)
                    .colorEffect(ShaderLibrary.auroraMist(.float2(size), .float(Float(displayScale * downscale)), .float(t)))
                    .scaleEffect(downscale, anchor: .topLeading)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

#Preview { AuroraBackground().frame(width: 900, height: 600) }

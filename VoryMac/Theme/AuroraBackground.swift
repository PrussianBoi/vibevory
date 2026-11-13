import SwiftUI

/// The sky scenes the window can show. Each is one Metal `colorEffect` (Aurora.metal, Sunset.metal); a new scene
/// (space, galaxy…) is a new shader function and a new case here, nothing else.
enum SkyScene: String, CaseIterable, Identifiable {
    case sunset, aurora, mist
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sunset: "Sunset"
        case .aurora: "Aurora"
        case .mist: "Mist"
        }
    }

    func shader(size: CGSize, scale: CGFloat, t: Float) -> Shader {
        switch self {
        case .sunset: ShaderLibrary.sunsetSky(.float2(size), .float(Float(scale)), .float(t))
        case .aurora: ShaderLibrary.auroraSky(.float2(size), .float(Float(scale)), .float(t))
        case .mist: ShaderLibrary.auroraMist(.float2(size), .float(Float(scale)), .float(t))
        }
    }
}

/// The live sky behind the whole window (Metal), kept light: drawn at a third of the window's size
/// and scaled up (the sky is soft, so nothing is lost), at 20 fps, paused while the window is in the
/// background or Reduce Motion is on.
struct AuroraBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.displayScale) private var displayScale
    @AppStorage("vibe.skyScene") private var sceneName = SkyScene.aurora.rawValue
    @AppStorage("vibe.stillSky") private var still = false
    var downscale: CGFloat = 3
    /// The sky's own time: it runs only while the sky is not paused, so a pause (a scroll, the window in the
    /// background) holds the scene and it carries on from there, instead of jumping ahead by the time it was held.
    @MainActor private final class Clock {
        var elapsed: Double = 40   // start mid-display, not at dark
        var last: Date?
        func time(at date: Date, paused: Bool) -> Float {
            if !paused, let last { elapsed += min(max(0, date.timeIntervalSince(last)), 0.25) }
            last = paused ? nil : date
            return Float(elapsed)
        }
    }
    @MainActor private static let clock = Clock()

    var body: some View {
        let scene = SkyScene(rawValue: sceneName) ?? .aurora
        GeometryReader { geo in
            let size = CGSize(width: max(1, geo.size.width / downscale), height: max(1, geo.size.height / downscale))
            let paused = still || reduceMotion || activeState == .inactive || SkyHold.shared.scrolling
            TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: paused)) { context in
                let t = Self.clock.time(at: context.date, paused: paused)
                Rectangle()
                    .frame(width: size.width, height: size.height)
                    .colorEffect(scene.shader(size: size, scale: displayScale * downscale, t: t))
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

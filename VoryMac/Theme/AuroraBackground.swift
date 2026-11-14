import SwiftUI

/// The sky scenes the window can show. Each is one or more Metal `colorEffect` layers (Aurora.metal, Sunset.metal,
/// Space.metal); a new scene is a new shader function and a new case here, nothing else.
enum SkyScene: String, CaseIterable, Identifiable {
    case sunset, aurora, mist, milkyWay, nebula
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sunset: "Sunset"
        case .aurora: "Aurora"
        case .mist: "Mist"
        case .milkyWay: "Milky Way"
        case .nebula: "Nebula"
        }
    }

    /// The layers, bottom first. The nebula's soft clouds draw at an eighth of the size and 8 fps (they drift
    /// too slowly for more to show); only its sharp stars run at the usual third and 20 fps.
    var layers: [SkyLayer] {
        switch self {
        case .sunset: [SkyLayer { size, scale, _, t in ShaderLibrary.sunsetSky(.float2(size), .float(Float(scale)), .float(t)) }]
        case .aurora: [SkyLayer { size, scale, _, t in ShaderLibrary.auroraSky(.float2(size), .float(Float(scale)), .float(t)) }]
        case .mist: [SkyLayer { size, scale, _, t in ShaderLibrary.auroraMist(.float2(size), .float(Float(scale)), .float(t)) }]
        case .milkyWay: [SkyLayer { size, _, down, t in ShaderLibrary.milkyWaySky(.float2(size), .float(Float(down)), .float(t)) }]
        case .nebula: [
            SkyLayer(downscale: 8, fps: 8) { size, _, down, t in ShaderLibrary.nebulaClouds(.float2(size), .float(Float(down)), .float(t)) },
            SkyLayer(adds: true) { size, _, down, t in ShaderLibrary.spaceStars(.float2(size), .float(Float(down)), .float(t)) },
        ]
        }
    }
}

/// The colours that go with each sky (Dev's pick from the colour mockup, 2026-11-14): an accent taken from the
/// scene, and a glass, selection and field tint that sit in it instead of greying it out.
struct SkyPalette: Equatable {
    var accent: Color
    var onAccent: Color
    var glass: Color
    var selection: Color
    var field: Color

    static let plain = SkyPalette(accent: AppTheme.artha, onAccent: Color(red: 0.09, green: 0.07, blue: 0.23),
                                  glass: .white.opacity(0.03), selection: .white.opacity(0.08), field: .black.opacity(0.06))

    private static func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> Color {
        Color(red: r / 255, green: g / 255, blue: b / 255).opacity(a)
    }
    private static func make(_ accent: (Double, Double, Double), on: (Double, Double, Double),
                             glass: (Double, Double, Double, Double), field: (Double, Double, Double, Double)) -> SkyPalette {
        SkyPalette(accent: rgb(accent.0, accent.1, accent.2), onAccent: rgb(on.0, on.1, on.2),
                   glass: rgb(glass.0, glass.1, glass.2, glass.3), selection: rgb(accent.0, accent.1, accent.2, 0.16),
                   field: rgb(field.0, field.1, field.2, field.3))
    }

    static func of(_ scene: SkyScene) -> SkyPalette {
        switch scene {
        case .aurora: make((127, 240, 198), on: (6, 34, 26), glass: (12, 40, 48, 0.24), field: (8, 28, 34, 0.30))
        case .sunset: make((255, 180, 140), on: (42, 18, 8), glass: (60, 28, 30, 0.22), field: (40, 18, 20, 0.30))
        case .mist: make((169, 198, 236), on: (11, 22, 38), glass: (30, 44, 66, 0.22), field: (20, 30, 46, 0.30))
        case .milkyWay: make((235, 203, 157), on: (42, 29, 12), glass: (22, 22, 40, 0.26), field: (14, 14, 28, 0.32))
        case .nebula: make((240, 155, 234), on: (42, 10, 40), glass: (30, 14, 48, 0.30), field: (18, 8, 30, 0.36))
        }
    }
}

extension EnvironmentValues {
    @Entry var skyPalette: SkyPalette = .plain
}

/// Puts the chosen sky's colours on everything below: the tint (accent) and the palette the glass reads.
struct SkyThemed: ViewModifier {
    @AppStorage("vibe.skyScene") private var sceneName = SkyScene.aurora.rawValue
    func body(content: Content) -> some View {
        let palette = SkyPalette.of(SkyScene(rawValue: sceneName) ?? .aurora)
        content.tint(palette.accent).environment(\.skyPalette, palette)
    }
}

/// One drawn layer of a sky: its shader, how much smaller than the window it is drawn, its frame rate, and
/// whether it adds its light onto the layers below (stars on black) instead of covering them.
struct SkyLayer {
    var downscale: CGFloat = 3
    var fps: Double = 20
    var adds = false
    /// size of the drawn layer, pixels per layer point, window points per layer point, seconds
    var shader: (CGSize, CGFloat, CGFloat, Float) -> Shader

    init(downscale: CGFloat = 3, fps: Double = 20, adds: Bool = false,
         shader: @escaping (CGSize, CGFloat, CGFloat, Float) -> Shader) {
        self.downscale = downscale; self.fps = fps; self.adds = adds; self.shader = shader
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
        var now: Float { Float(elapsed) }
    }
    @MainActor private static let clock = Clock()

    var body: some View {
        let scene = SkyScene(rawValue: sceneName) ?? .aurora
        GeometryReader { geo in
            let paused = still || reduceMotion || activeState == .inactive || SkyHold.shared.scrolling
            // The fastest layer moves the sky's clock; slower layers only read it.
            let leadFPS = scene.layers.map(\.fps).max() ?? 20
            ZStack(alignment: .topLeading) {
                ForEach(Array(scene.layers.enumerated()), id: \.offset) { _, layer in
                    let size = CGSize(width: max(1, geo.size.width / layer.downscale),
                                      height: max(1, geo.size.height / layer.downscale))
                    let leads = layer.fps == leadFPS
                    TimelineView(.animation(minimumInterval: 1.0 / layer.fps, paused: paused)) { context in
                        let t = leads ? Self.clock.time(at: context.date, paused: paused) : Self.clock.now
                        Rectangle()
                            .frame(width: size.width, height: size.height)
                            .colorEffect(layer.shader(size, displayScale * layer.downscale, layer.downscale, t))
                            .scaleEffect(layer.downscale, anchor: .topLeading)
                            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                    }
                    .blendMode(layer.adds ? .plusLighter : .normal)
                }
            }
            .compositingGroup()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

#Preview { AuroraBackground().frame(width: 900, height: 600) }

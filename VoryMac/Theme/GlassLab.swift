#if DEBUG
import SwiftUI

/// CI only (`-vibe-glass-lab`): the glass recipes side by side over the aurora, each over the same
/// busy strip of text and colour, so frosting and see-through can be compared on a real Mac.
struct GlassLab: View {
    struct Recipe: Identifiable { let id: String; let note: String; let apply: (AnyView) -> AnyView }

    static let recipes: [Recipe] = [
        Recipe(id: "A", note: "regular glass") { AnyView($0.glassEffect(.regular, in: .rect(cornerRadius: 18))) },
        Recipe(id: "B", note: "clear glass") { AnyView($0.glassEffect(.clear, in: .rect(cornerRadius: 18))) },
        Recipe(id: "C", note: "clear + dark tint + rim") { AnyView($0.glassEffect(.clear.tint(.black.opacity(0.22)), in: .rect(cornerRadius: 18)).overlay(rim)) },
        Recipe(id: "D", note: "regular + white tint + rim") { AnyView($0.glassEffect(.regular.tint(.white.opacity(0.06)), in: .rect(cornerRadius: 18)).overlay(rim)) },
        Recipe(id: "E", note: "ultra-thin frost + rim") { AnyView($0.background(.ultraThinMaterial, in: .rect(cornerRadius: 18)).overlay(rim)) },
        Recipe(id: "F", note: "frost + clear glass edge") { AnyView($0.background(.ultraThinMaterial.opacity(0.7), in: .rect(cornerRadius: 18)).glassEffect(.clear, in: .rect(cornerRadius: 18))) },
        Recipe(id: "G", note: "thin frost, white wash + rim") { AnyView($0.background(.thinMaterial.opacity(0.85), in: .rect(cornerRadius: 18)).background(.white.opacity(0.05), in: .rect(cornerRadius: 18)).overlay(rim)) },
        Recipe(id: "H", note: "clear glass, frost underneath") { AnyView($0.glassEffect(.clear.tint(.white.opacity(0.03)), in: .rect(cornerRadius: 18)).background(.ultraThinMaterial.opacity(0.5), in: .rect(cornerRadius: 18)).overlay(rim)) },
    ]

    static var rim: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.16), lineWidth: 0.5)
    }

    var body: some View {
        let cols = [GridItem(.flexible(), spacing: 18), GridItem(.flexible(), spacing: 18), GridItem(.flexible(), spacing: 18), GridItem(.flexible(), spacing: 18)]
        LazyVGrid(columns: cols, spacing: 18) {
            ForEach(Self.recipes) { r in
                ZStack {
                    busy
                    r.apply(AnyView(card(r)))
                        .padding(.horizontal, 14).padding(.vertical, 22)
                }
                .frame(height: 190)
            }
        }
        .padding(.horizontal, 28).padding(.top, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// What sits behind each card: text and colour, so blur and see-through show.
    private var busy: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(0..<7) { i in
                HStack(spacing: 6) {
                    Capsule().fill([Color.teal, .purple, .pink, .blue, .mint, .orange, .cyan][i]).frame(width: 30, height: 8)
                    Text("The quick brown fox jumps over the lazy dog").font(.system(size: 11)).foregroundStyle(.white.opacity(0.8))
                }
            }
        }
    }

    private func card(_ r: Recipe) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(r.id).font(.system(size: 20, weight: .light)).foregroundStyle(.white)
            Text(r.note).font(.system(size: 11)).foregroundStyle(.white.opacity(0.75))
            Spacer(minLength: 0)
            Text("Search sessions…").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.5))
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
#endif

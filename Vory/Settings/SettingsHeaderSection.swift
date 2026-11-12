import SwiftUI

/// The header card at the top of every Settings sub-page, like iOS's own: the icon on a large
/// tile, the page's name and one line on what lives here. Scrolls with the list.
struct SettingsHeaderSection: View {
    var title: String
    var symbol: String
    var color: Color
    var description: String
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                // At the accessibility text sizes the tile is left out (#644): the title and the description grow
                // with the text and the tile doesn't, and the three stacked pushed the page's first rows off the
                // screen. The tile is decoration; the title says what the page is.
                if !typeSize.isAccessibilitySize {
                    #if os(macOS)
                    // Artha: a line glyph on a glass tile, no colour.
                    Image(systemName: symbol).font(.system(size: 24, weight: .light)).symbolVariant(.none).foregroundStyle(.white.opacity(0.92))
                        .frame(width: 52, height: 52)
                        .background(.white.opacity(0.1), in: .rect(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                        .accessibilityHidden(true)
                    #else
                    Image(systemName: symbol).font(.system(size: 30, weight: .medium)).foregroundStyle(.white)
                        .frame(width: 60, height: 60).background(color.gradient, in: .rect(cornerRadius: 14))
                        // The title under it says what the page is; the icon read its own name (#409).
                        .accessibilityHidden(true)
                    #endif
                }
                Text(title).font(.title.weight(.bold))
                Text(description).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
        }
        #if os(macOS)
        // Straight on the sky: the title is the page's heading, not a box.
        .listRowBackground(Color.clear)
        #else
        .listRowBackground(Color(.secondarySystemGroupedBackground))
        #endif
    }
}

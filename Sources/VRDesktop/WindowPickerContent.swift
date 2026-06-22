import SwiftUI

/// The window-picker grid: 5×3 thumbnails with truncated names, one cell highlighted. Used both for
/// the in-AR overlay rasterisation and the macOS panel fallback.
struct WindowPickerContent: View {
    let pageItems: [WinItem]      // the ≤15 items on the current page
    let selectedInPage: Int       // 0…14, highlighted cell
    let targetName: String?       // the screen currently looked at (move destination)
    let page: Int
    let pageCount: Int
    let loading: Bool

    private let columns = 5
    private let thumbWidth: CGFloat = 150
    private let thumbHeight: CGFloat = 94   // ~16:10

    var body: some View {
        VStack(spacing: 16) {
            Text("Move a window to the screen you're looking at")
                .font(.headline)

            if loading && pageItems.isEmpty {
                ProgressView().controlSize(.large).padding(40)
            } else if pageItems.isEmpty {
                Text("No movable windows").foregroundStyle(.secondary).padding(40)
            } else {
                grid
            }

            footer
        }
        .padding(24)
        .frame(width: 900, alignment: .center)
        .background(Color.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.15)))
        .foregroundStyle(.white)
    }

    private var grid: some View {
        let rows = Array(stride(from: 0, to: pageItems.count, by: columns))
        return VStack(spacing: 14) {
            ForEach(rows, id: \.self) { start in
                HStack(spacing: 14) {
                    ForEach(start..<min(start + columns, pageItems.count), id: \.self) { i in
                        cell(pageItems[i], selected: i == selectedInPage)
                    }
                    // pad the last row so cells stay left-aligned and sized
                    if start + columns > pageItems.count {
                        ForEach(0..<(start + columns - pageItems.count), id: \.self) { _ in
                            Color.clear.frame(width: thumbWidth, height: thumbHeight + 22)
                        }
                    }
                }
            }
        }
    }

    private func cell(_ item: WinItem, selected: Bool) -> some View {
        VStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.08))
                if let cg = item.image {
                    Image(decorative: cg, scale: 1)
                        .resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Image(systemName: "macwindow").font(.system(size: 28)).foregroundStyle(.secondary)
                }
            }
            .frame(width: thumbWidth, height: thumbHeight)
            Text(item.displayName)
                .font(.caption).lineLimit(1).truncationMode(.tail)
                .frame(width: thumbWidth)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(selected ? Color.accentColor.opacity(0.30) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2.5))
        .scaleEffect(selected ? 1.03 : 1.0)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Text(targetName.map { "→ Target: \($0)" } ?? "→ Look at a screen, then press ↵")
                .foregroundStyle(targetName == nil ? .orange : .secondary)
            Spacer()
            if pageCount > 1 { Text("Page \(page + 1)/\(pageCount)").foregroundStyle(.secondary) }
            Text("↵ move   ◀▲▶▼ select   esc ✕").foregroundStyle(.secondary)
        }
        .font(.caption)
        .frame(width: 852)
    }
}

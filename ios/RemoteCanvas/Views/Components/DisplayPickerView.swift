import SwiftUI

struct DisplayPickerView: View {
    let displays: [RemoteDisplay]
    let selectedId: UInt32?
    var onSelect: (UInt32) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose a display")
                .font(.headline)
            if displays.isEmpty {
                ContentUnavailableView("No displays", systemImage: "display")
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                GeometryReader { geometry in
                    let layout = DisplayLayout(displays: displays, in: geometry.size)
                    ZStack(alignment: .topLeading) {
                        ForEach(displays) { display in
                            let frame = layout.frame(for: display)
                            Button {
                                onSelect(display.id)
                            } label: {
                                displayCard(display, selected: display.id == selectedId)
                            }
                            .buttonStyle(.plain)
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                        }
                    }
                }
                .frame(minHeight: 220)
            }
        }
        .padding(20)
    }

    private func displayCard(_ display: RemoteDisplay, selected: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.28) : Color.white.opacity(0.08))
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(selected ? Color.accentColor : Color.white.opacity(0.28), lineWidth: selected ? 3 : 1)
            VStack(spacing: 6) {
                Image(systemName: "display")
                    .font(.title2)
                Text(display.name)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("\(display.width)×\(display.height)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                if display.isPrimary {
                    Text("Primary")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.white.opacity(0.12), in: Capsule())
                }
            }
            .padding(8)
            .foregroundStyle(.white)
        }
    }
}

private struct DisplayLayout {
    let scale: CGFloat
    let offset: CGPoint

    init(displays: [RemoteDisplay], in size: CGSize) {
        let minX = CGFloat(displays.map(\.x).min() ?? 0)
        let minY = CGFloat(displays.map(\.y).min() ?? 0)
        let maxX = CGFloat(displays.map { $0.x + Int($0.width) }.max() ?? 1)
        let maxY = CGFloat(displays.map { $0.y + Int($0.height) }.max() ?? 1)
        let world = CGSize(width: max(maxX - minX, 1), height: max(maxY - minY, 1))
        let padding: CGFloat = 12
        let available = CGSize(width: max(size.width - padding * 2, 1), height: max(size.height - padding * 2, 1))
        let scale = min(available.width / world.width, available.height / world.height)
        let used = CGSize(width: world.width * scale, height: world.height * scale)
        self.scale = scale
        self.offset = CGPoint(
            x: (size.width - used.width) / 2 - minX * scale,
            y: (size.height - used.height) / 2 - minY * scale
        )
    }

    func frame(for display: RemoteDisplay) -> CGRect {
        CGRect(
            x: CGFloat(display.x) * scale + offset.x,
            y: CGFloat(display.y) * scale + offset.y,
            width: max(CGFloat(display.width) * scale, 88),
            height: max(CGFloat(display.height) * scale, 56)
        )
    }
}

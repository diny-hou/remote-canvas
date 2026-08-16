import SwiftUI
import UIKit

struct RemoteWorkspaceView: View {
    let frameData: Data?
    let pointer: CGPoint
    let onPointerEvent: (PointerEvent) -> Void

    var body: some View {
        RemoteScreenView(frameData: frameData, pointer: pointer, onPointerEvent: onPointerEvent)
            .background(Color.black)
    }
}

private struct RemoteScreenView: UIViewRepresentable {
    let frameData: Data?
    let pointer: CGPoint
    let onPointerEvent: (PointerEvent) -> Void

    func makeUIView(context: Context) -> RemoteScreenUIView {
        let view = RemoteScreenUIView()
        view.onPointerEvent = onPointerEvent
        return view
    }

    func updateUIView(_ view: RemoteScreenUIView, context: Context) {
        view.onPointerEvent = onPointerEvent
        view.update(frameData: frameData, pointer: pointer)
    }
}

final class RemoteScreenUIView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    var onPointerEvent: ((PointerEvent) -> Void)?

    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let pointerView = UIImageView()
    private var lastBounds = CGSize.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 6
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .black
        scrollView.panGestureRecognizer.minimumNumberOfTouches = 2
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .black
        imageView.isUserInteractionEnabled = true
        pointerView.image = UIImage(systemName: "cursorarrow")?.withConfiguration(
            UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        )
        pointerView.tintColor = .white
        pointerView.isUserInteractionEnabled = false
        addSubview(scrollView)
        scrollView.addSubview(imageView)
        addSubview(pointerView)

        let move = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        move.maximumNumberOfTouches = 1
        move.delegate = self
        addGestureRecognizer(move)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { nil }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func update(frameData: Data?, pointer: CGPoint) {
        if let frameData, let image = UIImage(data: frameData) {
            imageView.image = image
        }
        layoutPointer(pointer)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        if lastBounds != bounds.size {
            lastBounds = bounds.size
            scrollView.zoomScale = 1
            imageView.frame = CGRect(origin: .zero, size: bounds.size)
            scrollView.contentSize = bounds.size
        }
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        other === scrollView.pinchGestureRecognizer
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let location = normalizedPoint(at: gesture.location(in: self))
        onPointerEvent?(PointerEvent(normalizedLocation: location, action: .move))
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let location = normalizedPoint(at: gesture.location(in: self))
        onPointerEvent?(PointerEvent(normalizedLocation: location, action: .move))
        onPointerEvent?(PointerEvent(normalizedLocation: location, action: .primaryClick))
    }

    private func layoutPointer(_ pointer: CGPoint) {
        let point = viewPoint(for: pointer)
        pointerView.center = point
        pointerView.isHidden = imageView.image == nil
    }

    private func normalizedPoint(at viewPoint: CGPoint) -> CGPoint {
        let pointInImage = imageView.convert(viewPoint, from: self)
        let fitted = aspectFitRect(imageSize: imageView.image?.size ?? imageView.bounds.size, in: imageView.bounds.size)
        return CGPoint(
            x: min(1, max(0, (pointInImage.x - fitted.minX) / max(fitted.width, 1))),
            y: min(1, max(0, (pointInImage.y - fitted.minY) / max(fitted.height, 1)))
        )
    }

    private func viewPoint(for normalized: CGPoint) -> CGPoint {
        let fitted = aspectFitRect(imageSize: imageView.image?.size ?? .zero, in: imageView.bounds.size)
        let pointInImage = CGPoint(
            x: fitted.minX + normalized.x * fitted.width,
            y: fitted.minY + normalized.y * fitted.height
        )
        return imageView.convert(pointInImage, to: self)
    }

    private func aspectFitRect(imageSize: CGSize, in box: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, box.width > 0, box.height > 0 else {
            return CGRect(origin: .zero, size: box)
        }
        let scale = min(box.width / imageSize.width, box.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (box.width - size.width) / 2,
            y: (box.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }
}

#Preview("Remote workspace") {
    RemoteWorkspaceView(frameData: nil, pointer: CGPoint(x: 0.6, y: 0.4)) { _ in }
        .frame(width: 390, height: 650)
        .preferredColorScheme(.dark)
}

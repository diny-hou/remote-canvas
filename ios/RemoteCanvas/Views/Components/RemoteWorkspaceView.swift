import SwiftUI
import UIKit

struct RemoteWorkspaceView: View {
    let frameData: Data?
    var protectFromCapture = false
    var onLocalTouch: ((CGPoint) -> Void)?
    let onPointerEvent: (PointerEvent) -> Void

    var body: some View {
        RemoteScreenView(
            frameData: frameData,
            protectFromCapture: protectFromCapture,
            onLocalTouch: onLocalTouch,
            onPointerEvent: onPointerEvent
        )
        .background(Color.black)
    }
}

private struct RemoteScreenView: UIViewRepresentable {
    let frameData: Data?
    let protectFromCapture: Bool
    let onLocalTouch: ((CGPoint) -> Void)?
    let onPointerEvent: (PointerEvent) -> Void

    func makeUIView(context: Context) -> RemoteScreenUIView {
        let view = RemoteScreenUIView()
        view.onPointerEvent = onPointerEvent
        view.onLocalTouch = onLocalTouch
        return view
    }

    func updateUIView(_ view: RemoteScreenUIView, context: Context) {
        view.onPointerEvent = onPointerEvent
        view.onLocalTouch = onLocalTouch
        view.update(frameData: frameData, protectFromCapture: protectFromCapture)
    }
}

final class RemoteScreenUIView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    var onPointerEvent: ((PointerEvent) -> Void)?
    var onLocalTouch: ((CGPoint) -> Void)?

    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let touchLayer = UIView()
    private let pointerView = UIImageView()
    private var captureField: UITextField?
    private var lastBounds = CGSize.zero
    private var lastPointer = CGPoint(x: 0.5, y: 0.5)
    private var pinchStart: CGFloat = 1
    private var protectFromCapture = false
    private var decodeGeneration = 0
    private var twoFingerScroll: UIPanGestureRecognizer!

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .black

        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 6
        scrollView.bounces = false
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .black
        scrollView.isUserInteractionEnabled = false

        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .black
        imageView.isUserInteractionEnabled = false

        touchLayer.backgroundColor = .clear
        touchLayer.isMultipleTouchEnabled = true

        pointerView.image = Self.cursorImage
        pointerView.contentMode = .scaleAspectFit
        pointerView.frame = CGRect(x: 0, y: 0, width: 26, height: 34)
        pointerView.isHidden = true
        pointerView.isUserInteractionEnabled = false
        pointerView.layer.shadowColor = UIColor.black.cgColor
        pointerView.layer.shadowOpacity = 0.55
        pointerView.layer.shadowRadius = 1.5
        pointerView.layer.shadowOffset = CGSize(width: 0, height: 1)

        addSubview(scrollView)
        scrollView.addSubview(imageView)
        addSubview(touchLayer)
        addSubview(pointerView)
        installGestures()
    }

    required init?(coder: NSCoder) { nil }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard bounds.contains(point), !isHidden, isUserInteractionEnabled, alpha > 0.01 else {
            return nil
        }
        return touchLayer
    }

    func update(frameData: Data?, protectFromCapture: Bool) {
        if self.protectFromCapture != protectFromCapture {
            self.protectFromCapture = protectFromCapture
            syncCaptureProtection()
        }
        if let frameData {
            decodeGeneration += 1
            let generation = decodeGeneration
            DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                let image = UIImage(data: frameData)
                DispatchQueue.main.async {
                    guard let self, generation == self.decodeGeneration else { return }
                    self.imageView.image = image
                    self.pointerView.isHidden = image == nil
                    self.layoutPointer(self.lastPointer)
                }
            }
        } else {
            decodeGeneration += 1
            imageView.image = nil
            pointerView.isHidden = true
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutCaptureViews()
        touchLayer.frame = bounds
        let size = scrollView.bounds.size
        guard size != lastBounds, size.width > 0, size.height > 0 else { return }
        let zoom = min(max(scrollView.zoomScale, 1), 6)
        lastBounds = size
        scrollView.zoomScale = 1
        imageView.frame = CGRect(origin: .zero, size: size)
        scrollView.contentSize = size
        scrollView.zoomScale = zoom
        layoutPointer(lastPointer)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        false
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === twoFingerScroll {
            return scrollView.pinchGestureRecognizer?.state != .changed
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    private func installGestures() {
        let move = UIPanGestureRecognizer(target: self, action: #selector(handleMove(_:)))
        move.maximumNumberOfTouches = 1
        move.cancelsTouchesInView = false
        move.delegate = self
        touchLayer.addGestureRecognizer(move)

        twoFingerScroll = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerScroll(_:)))
        twoFingerScroll.minimumNumberOfTouches = 2
        twoFingerScroll.maximumNumberOfTouches = 2
        twoFingerScroll.cancelsTouchesInView = false
        twoFingerScroll.delegate = self
        touchLayer.addGestureRecognizer(twoFingerScroll)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.cancelsTouchesInView = false
        pinch.delegate = self
        touchLayer.addGestureRecognizer(pinch)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = self
        touchLayer.addGestureRecognizer(doubleTap)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.require(toFail: doubleTap)
        tap.delegate = self
        touchLayer.addGestureRecognizer(tap)

        let press = UILongPressGestureRecognizer(target: self, action: #selector(handlePress(_:)))
        press.minimumPressDuration = 0.45
        press.allowableMovement = 16
        press.delegate = self
        touchLayer.addGestureRecognizer(press)
    }

    @objc private func handleMove(_ gesture: UIPanGestureRecognizer) {
        sendPointer(at: gesture.location(in: self), action: .move)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        sendPointer(at: point, action: .move)
        sendPointer(at: point, action: .primaryClick)
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        sendPointer(at: point, action: .move)
        sendPointer(at: point, action: .doubleClick)
    }

    @objc private func handlePress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        let point = gesture.location(in: self)
        sendPointer(at: point, action: .move)
        sendPointer(at: point, action: .secondaryClick)
    }

    @objc private func handleTwoFingerScroll(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self)
        gesture.setTranslation(.zero, in: self)
        if scrollView.zoomScale > 1.02 {
            var offset = scrollView.contentOffset
            offset.x -= translation.x
            offset.y -= translation.y
            let maxOffset = CGPoint(
                x: max(0, scrollView.contentSize.width - scrollView.bounds.width),
                y: max(0, scrollView.contentSize.height - scrollView.bounds.height)
            )
            offset.x = min(max(offset.x, 0), maxOffset.x)
            offset.y = min(max(offset.y, 0), maxOffset.y)
            scrollView.contentOffset = offset
            layoutPointer(lastPointer)
            return
        }
        if gesture.state == .began {
            sendPointer(at: gesture.location(in: self), action: .move)
        }
        guard gesture.state == .began || gesture.state == .changed else { return }
        let horizontal = abs(translation.x) > abs(translation.y)
        let distance = horizontal ? translation.x : translation.y
        let ticks = (-distance / 14).rounded()
        guard abs(ticks) >= 1 else { return }
        let action: PointerEvent.Action = horizontal ? .scrollHorizontal(ticks) : .scroll(ticks)
        sendPointer(at: gesture.location(in: self), action: action)
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        if gesture.state == .began {
            pinchStart = scrollView.zoomScale
        }
        guard gesture.state == .began || gesture.state == .changed || gesture.state == .ended else { return }
        let scale = min(max(pinchStart * gesture.scale, 1), 6)
        scrollView.setZoomScale(scale, animated: false)
        layoutPointer(lastPointer)
    }

    private func sendPointer(at viewPoint: CGPoint, action: PointerEvent.Action) {
        onLocalTouch?(viewPoint)
        let location = normalizedPoint(at: viewPoint)
        lastPointer = location
        layoutPointer(location)
        onPointerEvent?(PointerEvent(normalizedLocation: location, action: action))
    }

    private func layoutPointer(_ pointer: CGPoint) {
        let point = viewPoint(for: pointer)
        pointerView.frame.origin = CGPoint(x: point.x - 2, y: point.y - 2)
        pointerView.isHidden = imageView.image == nil
        bringSubviewToFront(pointerView)
    }

    private func syncCaptureProtection() {
        if protectFromCapture {
            if captureField == nil {
                let field = UITextField()
                field.isSecureTextEntry = true
                field.isUserInteractionEnabled = false
                field.backgroundColor = .black
                insertSubview(field, at: 0)
                captureField = field
            }
            layoutCaptureViews()
        } else if let field = captureField {
            if scrollView.superview !== self {
                scrollView.removeFromSuperview()
                insertSubview(scrollView, at: 0)
            }
            field.removeFromSuperview()
            captureField = nil
            scrollView.frame = bounds
        }
        bringSubviewToFront(touchLayer)
        bringSubviewToFront(pointerView)
    }

    private func layoutCaptureViews() {
        touchLayer.frame = bounds
        guard protectFromCapture, let field = captureField else {
            if captureField == nil {
                scrollView.frame = bounds
            }
            bringSubviewToFront(touchLayer)
            bringSubviewToFront(pointerView)
            return
        }
        field.frame = bounds
        if let container = field.subviews.first {
            container.frame = field.bounds
            if scrollView.superview !== container {
                scrollView.removeFromSuperview()
                container.addSubview(scrollView)
            }
            scrollView.frame = container.bounds
        } else {
            scrollView.frame = bounds
        }
        bringSubviewToFront(touchLayer)
        bringSubviewToFront(pointerView)
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

    private static let cursorImage: UIImage = {
        let size = CGSize(width: 26, height: 34)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            let path = UIBezierPath()
            path.move(to: CGPoint(x: 2.5, y: 1.5))
            path.addLine(to: CGPoint(x: 2.5, y: 25))
            path.addLine(to: CGPoint(x: 8.2, y: 19.2))
            path.addLine(to: CGPoint(x: 13.4, y: 31.2))
            path.addLine(to: CGPoint(x: 16.6, y: 29.8))
            path.addLine(to: CGPoint(x: 11.2, y: 17.6))
            path.addLine(to: CGPoint(x: 20.5, y: 17.6))
            path.close()
            UIColor.white.setStroke()
            UIColor.black.setFill()
            path.lineWidth = 1.6
            path.lineJoinStyle = .round
            path.fill()
            path.stroke()
        }
    }()
}

#Preview("Remote workspace") {
    RemoteWorkspaceView(frameData: nil) { _ in }
        .frame(width: 390, height: 650)
        .preferredColorScheme(.dark)
}

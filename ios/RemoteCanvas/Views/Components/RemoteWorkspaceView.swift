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
    private let touchLayer = TouchSurfaceView()
    private let pointerView = UIImageView()
    private var captureField: UITextField?
    private var lastBounds = CGSize.zero
    private var lastPointer = CGPoint(x: 0.5, y: 0.5)
    private var pinchStart: CGFloat = 1
    private var pinchAnchorInImage = CGPoint.zero
    private var twoFingerActive = false
    private var twoFingerIntent: TwoFingerIntent = .undecided
    private var twoFingerStartMid = CGPoint.zero
    private var twoFingerLastMid = CGPoint.zero
    private var twoFingerStartDistance: CGFloat = 1
    private var fingerStarts: [CGPoint] = []
    private var fingerLasts: [CGPoint] = []
    private var scrollAnchor = CGPoint.zero
    private var protectFromCapture = false
    private var decodeGeneration = 0
    private var isDragging = false
    private var suppressDragUntilLift = false
    private var didSecondaryClick = false
    private var scrollRemainder = CGPoint.zero
    private var oneFingerDrag: UIPanGestureRecognizer!
    private var twoFingerPan: UIPanGestureRecognizer!
    private var threeFingerPan: UIPanGestureRecognizer!
    private var pinch: UIPinchGestureRecognizer!

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .black

        scrollView.delegate = self
        scrollView.minimumZoomScale = Self.minZoom
        scrollView.maximumZoomScale = Self.maxZoom
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
        touchLayer.onTouchesBegan = { [weak self] in
            self?.didSecondaryClick = false
        }
        touchLayer.onSecondFinger = { [weak self] in
            self?.cancelOneFingerDragForScroll()
        }

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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(endDragIfNeeded),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
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
        let oldSize = lastBounds
        let oldZoom = max(scrollView.zoomScale, 0.001)
        let zoom = min(max(scrollView.zoomScale, Self.minZoom), Self.maxZoom)
        let focus = oldSize.width > 0
            ? CGPoint(
                x: (scrollView.contentOffset.x + oldSize.width / 2) / oldZoom,
                y: (scrollView.contentOffset.y + oldSize.height / 2) / oldZoom
            )
            : CGPoint(x: size.width / 2, y: size.height / 2)
        lastBounds = size
        scrollView.zoomScale = 1
        imageView.frame = CGRect(origin: .zero, size: size)
        scrollView.contentSize = size
        scrollView.zoomScale = zoom
        if zoom > 1.01, oldSize.width > 0 {
            scrollView.contentOffset = clampedOffset(
                CGPoint(
                    x: focus.x * zoom - size.width / 2,
                    y: focus.y * zoom - size.height / 2
                )
            )
        }
        layoutPointer(lastPointer)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        let pair = [gestureRecognizer, other]
        return pair.contains(where: { $0 === pinch }) && pair.contains(where: { $0 === twoFingerPan })
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === threeFingerPan {
            return scrollView.zoomScale > 1.02
        }
        if gestureRecognizer === oneFingerDrag {
            return !suppressDragUntilLift && !twoFingerActive
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    private func installGestures() {
        oneFingerDrag = UIPanGestureRecognizer(target: self, action: #selector(handleDrag(_:)))
        oneFingerDrag.maximumNumberOfTouches = 1
        oneFingerDrag.cancelsTouchesInView = false
        oneFingerDrag.delegate = self
        touchLayer.addGestureRecognizer(oneFingerDrag)

        twoFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFinger(_:)))
        twoFingerPan.minimumNumberOfTouches = 2
        twoFingerPan.maximumNumberOfTouches = 2
        twoFingerPan.cancelsTouchesInView = false
        twoFingerPan.delegate = self
        touchLayer.addGestureRecognizer(twoFingerPan)

        threeFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleThreeFingerPan(_:)))
        threeFingerPan.minimumNumberOfTouches = 3
        threeFingerPan.maximumNumberOfTouches = 3
        threeFingerPan.cancelsTouchesInView = false
        threeFingerPan.delegate = self
        touchLayer.addGestureRecognizer(threeFingerPan)

        pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.cancelsTouchesInView = false
        pinch.delegate = self
        touchLayer.addGestureRecognizer(pinch)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = self
        touchLayer.addGestureRecognizer(doubleTap)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.require(toFail: doubleTap)
        tap.require(toFail: oneFingerDrag)
        tap.delegate = self
        touchLayer.addGestureRecognizer(tap)

        let press = UILongPressGestureRecognizer(target: self, action: #selector(handlePress(_:)))
        press.minimumPressDuration = 0.45
        press.allowableMovement = 8
        press.delegate = self
        touchLayer.addGestureRecognizer(press)
    }

    @objc private func handleDrag(_ gesture: UIPanGestureRecognizer) {
        if suppressDragUntilLift {
            if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
                suppressDragUntilLift = false
            }
            return
        }

        let point = gesture.location(in: self)
        switch gesture.state {
        case .began:
            isDragging = true
            sendPointer(at: point, action: .primaryDown)
        case .changed:
            guard isDragging else { return }
            sendPointer(at: point, action: .move)
        case .ended, .cancelled, .failed:
            endDrag(at: point)
        default:
            break
        }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard !didSecondaryClick else { return }
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
        if gesture.state == .began {
            suppressDragUntilLift = true
            didSecondaryClick = true
            if isDragging {
                endDrag(at: gesture.location(in: self))
            }
            let point = gesture.location(in: self)
            sendPointer(at: point, action: .move)
            sendPointer(at: point, action: .secondaryClick)
        } else if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
            suppressDragUntilLift = false
        }
    }

    @objc private func handleTwoFinger(_ gesture: UIPanGestureRecognizer) {
        handleTwoFingerGesture(gesture, desiredZoom: desiredZoom(from: gesture))
    }

    @objc private func handleThreeFingerPan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self)
        gesture.setTranslation(.zero, in: self)
        guard gesture.state == .began || gesture.state == .changed else { return }
        panZoomedView(by: translation)
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        handleTwoFingerGesture(gesture, desiredZoom: desiredZoom(from: gesture))
    }

    private func handleTwoFingerGesture(_ gesture: UIGestureRecognizer, desiredZoom: CGFloat) {
        let mid = touchMidpoint(gesture)
        let fingers = touchPoints(gesture)
        switch gesture.state {
        case .began:
            beginTwoFinger(at: mid, distance: touchDistance(gesture))
            updateTwoFinger(desiredZoom: desiredZoom, mid: mid, fingers: fingers)
        case .changed:
            updateTwoFinger(desiredZoom: desiredZoom, mid: mid, fingers: fingers)
        case .ended, .cancelled, .failed:
            finishTwoFinger(desiredZoom: desiredZoom, mid: mid)
        default:
            break
        }
    }

    private func beginTwoFinger(at mid: CGPoint, distance: CGFloat) {
        guard !twoFingerActive else { return }
        cancelOneFingerDragForScroll()
        twoFingerActive = true
        twoFingerIntent = .undecided
        pinchStart = scrollView.zoomScale
        pinchAnchorInImage = contentPoint(under: mid)
        twoFingerStartMid = mid
        twoFingerLastMid = mid
        twoFingerStartDistance = max(distance, 1)
        fingerStarts = []
        fingerLasts = []
        scrollAnchor = mid
        scrollRemainder = .zero
    }

    private func updateTwoFinger(desiredZoom: CGFloat, mid: CGPoint, fingers: [CGPoint] = []) {
        guard twoFingerActive else {
            beginTwoFinger(at: mid, distance: twoFingerStartDistance)
            return
        }
        let tracked = trackedFingers(from: fingers)
        resolveTwoFingerIntent(desiredZoom: desiredZoom, mid: mid, fingers: tracked)
        switch twoFingerIntent {
        case .undecided:
            twoFingerLastMid = mid
            fingerLasts = tracked
        case .zoom:
            applyPinch(scale: desiredZoom, fingerInView: mid, settle: false)
            twoFingerLastMid = mid
            fingerLasts = tracked
        case .scroll:
            let delta = scrollDelta(mid: mid, fingers: tracked)
            twoFingerLastMid = mid
            fingerLasts = tracked
            applyRemoteScroll(delta)
        }
    }

    private func finishTwoFinger(desiredZoom: CGFloat, mid: CGPoint) {
        let pinchGoing = pinch.state == .began || pinch.state == .changed
        let panGoing = twoFingerPan.state == .began || twoFingerPan.state == .changed
        guard !pinchGoing, !panGoing else { return }
        if twoFingerIntent == .zoom {
            applyPinch(scale: desiredZoom, fingerInView: mid, settle: true)
        }
        twoFingerActive = false
        twoFingerIntent = .undecided
        fingerStarts = []
        fingerLasts = []
        scrollRemainder = .zero
    }

    private func resolveTwoFingerIntent(desiredZoom: CGFloat, mid: CGPoint, fingers: [CGPoint]) {
        guard twoFingerIntent == .undecided else { return }
        let factor = desiredZoom / max(pinchStart, 0.001)
        let zoomAmount = abs(factor - 1)
        let analysis = fingerMotion(fingers)

        if zoomAmount >= 0.05, analysis.radialPinch || (analysis.bothMoving && !analysis.sameDirection) {
            twoFingerIntent = .zoom
            return
        }
        if analysis.sameDirection, zoomAmount < 0.08 {
            lockScroll()
            return
        }
        if analysis.oneHeld, analysis.tangentialScroll, zoomAmount < 0.12 {
            lockScroll()
        }
    }

    private func lockScroll() {
        guard twoFingerIntent != .scroll else { return }
        twoFingerIntent = .scroll
        sendPointer(at: scrollAnchor, action: .move)
        twoFingerLastMid = twoFingerStartMid
        if fingerLasts.count == fingerStarts.count {
            fingerLasts = fingerStarts
        }
    }

    private func scrollDelta(mid: CGPoint, fingers: [CGPoint]) -> CGPoint {
        if fingers.count == 2, fingerLasts.count == 2 {
            let move0 = hypot(fingers[0].x - fingerStarts[0].x, fingers[0].y - fingerStarts[0].y)
            let move1 = hypot(fingers[1].x - fingerStarts[1].x, fingers[1].y - fingerStarts[1].y)
            if move0 >= 14, move1 < 16 {
                return CGPoint(x: fingers[0].x - fingerLasts[0].x, y: fingers[0].y - fingerLasts[0].y)
            }
            if move1 >= 14, move0 < 16 {
                return CGPoint(x: fingers[1].x - fingerLasts[1].x, y: fingers[1].y - fingerLasts[1].y)
            }
            if move0 >= 12, move1 >= 12 {
                return CGPoint(
                    x: ((fingers[0].x - fingerLasts[0].x) + (fingers[1].x - fingerLasts[1].x)) / 2,
                    y: ((fingers[0].y - fingerLasts[0].y) + (fingers[1].y - fingerLasts[1].y)) / 2
                )
            }
        }
        return CGPoint(x: mid.x - twoFingerLastMid.x, y: mid.y - twoFingerLastMid.y)
    }

    private func trackedFingers(from current: [CGPoint]) -> [CGPoint] {
        guard current.count == 2 else { return current }
        if fingerStarts.isEmpty {
            fingerStarts = current
            fingerLasts = current
            return current
        }
        let reference = fingerLasts.count == 2 ? fingerLasts : fingerStarts
        let direct = hypot(current[0].x - reference[0].x, current[0].y - reference[0].y)
            + hypot(current[1].x - reference[1].x, current[1].y - reference[1].y)
        let swapped = hypot(current[0].x - reference[1].x, current[0].y - reference[1].y)
            + hypot(current[1].x - reference[0].x, current[1].y - reference[0].y)
        return swapped < direct ? [current[1], current[0]] : current
    }

    private func fingerMotion(_ fingers: [CGPoint]) -> (
        oneHeld: Bool,
        bothMoving: Bool,
        sameDirection: Bool,
        radialPinch: Bool,
        tangentialScroll: Bool
    ) {
        guard fingers.count == 2, fingerStarts.count == 2 else {
            return (false, false, false, false, false)
        }
        let move0 = CGPoint(x: fingers[0].x - fingerStarts[0].x, y: fingers[0].y - fingerStarts[0].y)
        let move1 = CGPoint(x: fingers[1].x - fingerStarts[1].x, y: fingers[1].y - fingerStarts[1].y)
        let dist0 = hypot(move0.x, move0.y)
        let dist1 = hypot(move1.x, move1.y)
        let oneHeld = (dist0 < 10 && dist1 >= 16) || (dist1 < 10 && dist0 >= 16)
        let bothMoving = dist0 >= 10 && dist1 >= 10
        let lengths = dist0 * dist1
        let sameDirection = bothMoving && lengths > 0 && ((move0.x * move1.x + move0.y * move1.y) / lengths) > 0.45

        let axis = CGPoint(x: fingerStarts[1].x - fingerStarts[0].x, y: fingerStarts[1].y - fingerStarts[0].y)
        let axisLength = hypot(axis.x, axis.y)
        let primary = dist0 >= dist1 ? move0 : move1
        var radial: CGFloat = 0
        var tangential: CGFloat = 0
        if axisLength > 1 {
            let nx = axis.x / axisLength
            let ny = axis.y / axisLength
            radial = abs(primary.x * nx + primary.y * ny)
            tangential = abs(primary.x * -ny + primary.y * nx)
        }
        let radialPinch = radial >= 10 && radial >= tangential
        let tangentialScroll = oneHeld && tangential >= 12 && tangential > radial * 1.15
        return (oneHeld, bothMoving, sameDirection, radialPinch, tangentialScroll)
    }

    private func cancelOneFingerDragForScroll() {
        if isDragging {
            endDrag(at: viewPoint(for: lastPointer))
        }
    }

    private func desiredZoom(from gesture: UIGestureRecognizer) -> CGFloat {
        let distance = touchDistance(gesture)
        if twoFingerActive, twoFingerStartDistance > 1, distance > 1 {
            return pinchStart * (distance / twoFingerStartDistance)
        }
        if pinch.state == .began || pinch.state == .changed {
            return (twoFingerActive ? pinchStart : scrollView.zoomScale) * pinch.scale
        }
        return scrollView.zoomScale
    }

    private func applyRemoteScroll(_ delta: CGPoint) {
        scrollRemainder.x += delta.x
        scrollRemainder.y += delta.y
        let unit: CGFloat = 6
        let horizontalTicks = (-scrollRemainder.x / unit).rounded(.towardZero)
        let verticalTicks = (-scrollRemainder.y / unit).rounded(.towardZero)
        if abs(horizontalTicks) >= 1 {
            scrollRemainder.x += horizontalTicks * unit
            sendPointer(at: scrollAnchor, action: .scrollHorizontal(horizontalTicks))
        }
        if abs(verticalTicks) >= 1 {
            scrollRemainder.y += verticalTicks * unit
            sendPointer(at: scrollAnchor, action: .scroll(verticalTicks))
        }
    }

    private func touchPoints(_ gesture: UIGestureRecognizer) -> [CGPoint] {
        guard gesture.numberOfTouches >= 2 else { return [] }
        return [
            gesture.location(ofTouch: 0, in: self),
            gesture.location(ofTouch: 1, in: self)
        ]
    }

    private func touchDistance(_ gesture: UIGestureRecognizer) -> CGFloat {
        let points = touchPoints(gesture)
        guard points.count == 2 else { return 0 }
        return hypot(points[0].x - points[1].x, points[0].y - points[1].y)
    }

    private func touchMidpoint(_ gesture: UIGestureRecognizer) -> CGPoint {
        let points = touchPoints(gesture)
        guard points.count == 2 else { return gesture.location(in: self) }
        return CGPoint(x: (points[0].x + points[1].x) / 2, y: (points[0].y + points[1].y) / 2)
    }

    @objc private func endDragIfNeeded() {
        endDrag(at: viewPoint(for: lastPointer))
    }

    private func endDrag(at point: CGPoint) {
        guard isDragging else { return }
        isDragging = false
        sendPointer(at: point, action: .primaryUp)
    }

    private func panZoomedView(by translation: CGPoint) {
        var offset = scrollView.contentOffset
        offset.x -= translation.x
        offset.y -= translation.y
        scrollView.contentOffset = clampedOffset(offset)
        layoutPointer(lastPointer)
    }

    private func contentPoint(under viewPoint: CGPoint) -> CGPoint {
        let zoom = max(scrollView.zoomScale, 0.001)
        return CGPoint(
            x: (scrollView.contentOffset.x + viewPoint.x) / zoom,
            y: (scrollView.contentOffset.y + viewPoint.y) / zoom
        )
    }

    private func applyPinch(scale: CGFloat, fingerInView: CGPoint, settle: Bool) {
        let newScale = min(max(scale, Self.minZoom), Self.maxZoom)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scrollView.zoomScale = newScale
        if newScale <= 1.001 {
            scrollView.contentOffset = .zero
        } else {
            let offset = CGPoint(
                x: pinchAnchorInImage.x * newScale - fingerInView.x,
                y: pinchAnchorInImage.y * newScale - fingerInView.y
            )
            scrollView.contentOffset = settle ? clampedOffset(offset) : offset
        }
        CATransaction.commit()
        layoutPointer(lastPointer)
    }

    private func clampedOffset(_ offset: CGPoint) -> CGPoint {
        let maxOffset = CGPoint(
            x: max(0, scrollView.contentSize.width - scrollView.bounds.width),
            y: max(0, scrollView.contentSize.height - scrollView.bounds.height)
        )
        return CGPoint(
            x: min(max(offset.x, 0), maxOffset.x),
            y: min(max(offset.y, 0), maxOffset.y)
        )
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

    private static let minZoom: CGFloat = 1
    private static let maxZoom: CGFloat = 8

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

private enum TwoFingerIntent {
    case undecided
    case zoom
    case scroll
}

private final class TouchSurfaceView: UIView {
    var onTouchesBegan: (() -> Void)?
    var onSecondFinger: (() -> Void)?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        onTouchesBegan?()
        let count = event?.allTouches?.count ?? touches.count
        if count >= 2 {
            onSecondFinger?()
        }
        super.touchesBegan(touches, with: event)
    }
}

#Preview("Remote workspace") {
    RemoteWorkspaceView(frameData: nil) { _ in }
        .frame(width: 390, height: 650)
        .preferredColorScheme(.dark)
}

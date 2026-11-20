import AVFoundation
import CoreImage
import UIKit
import WralyCore

/// Owns the AVCaptureSession: picks the best back camera (or the front one for
/// selfies), streams upright frames for analysis, applies Wraly's capture plan
/// and takes photos.
final class CameraService: NSObject, @unchecked Sendable {
    enum CameraError: Error { case noCamera, cannotAddInput, cannotAddOutput }

    let session = AVCaptureSession()
    private(set) var device: AVCaptureDevice?

    /// Called on `videoQueue` for every frame.
    var onFrame: (@Sendable (CMSampleBuffer) -> Void)?

    let sessionQueue = DispatchQueue(label: "wraly.camera.session")
    let videoQueue = DispatchQueue(label: "wraly.camera.video", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private var processors: [Int64: PhotoCaptureProcessor] = [:]
    private let processorsLock = NSLock()

    /// Device zoom factor that corresponds to the main 1× camera.
    private(set) var wideZoomFactor: CGFloat = 1
    /// How frames and photos are currently rotated. Read and written on `videoQueue`.
    private(set) var orientation: FrameOrientation = .portrait
    private var lastApplied: CapturePlan?
    private var lastAppliedAt: CFTimeInterval = 0

    // MARK: Setup

    /// Which camera is live. Written on `sessionQueue`.
    private(set) var position: AVCaptureDevice.Position = .back
    private var input: AVCaptureDeviceInput?
    /// Play the shutter sound (once per photo, never for the extra burst frames).
    var shutterSound = false
    /// Save front-camera photos the way you saw yourself on screen.
    var mirrorSelfies = true {
        didSet { sessionQueue.async { self.applyConnections() } }
    }

    func configure() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo

        try attach(.back)

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(videoOutput) else { throw CameraError.cannotAddOutput }
        session.addOutput(videoOutput)

        guard session.canAddOutput(photoOutput) else { throw CameraError.cannotAddOutput }
        session.addOutput(photoOutput)
        photoOutput.maxPhotoQualityPrioritization = .quality

        applyConnections()
        try prepareDevice()
    }

    /// Switch between the back cameras and the front (selfie) camera.
    func switchCamera(to pos: AVCaptureDevice.Position, completion: @escaping @Sendable (Bool) -> Void) {
        sessionQueue.async { [self] in
            guard pos != position else { completion(true); return }
            session.beginConfiguration()
            var ok = true
            do {
                try attach(pos)
                applyConnections()
                try prepareDevice()
            } catch { ok = false }
            session.commitConfiguration()
            lastApplied = nil
            completion(ok)
        }
    }

    private static func findDevice(_ pos: AVCaptureDevice.Position) -> AVCaptureDevice? {
        // Prefer virtual multi-camera devices so zoom can switch lenses seamlessly.
        let types: [AVCaptureDevice.DeviceType] = pos == .front
            ? [.builtInTrueDepthCamera, .builtInWideAngleCamera]
            : [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: pos).devices.first
    }

    /// Swap the session's camera input. Call inside a configuration block.
    private func attach(_ pos: AVCaptureDevice.Position) throws {
        guard let device = Self.findDevice(pos) else { throw CameraError.noCamera }
        let newInput = try AVCaptureDeviceInput(device: device)
        let old = input
        if let old { session.removeInput(old) }
        guard session.canAddInput(newInput) else {
            if let old { session.addInput(old) }
            throw CameraError.cannotAddInput
        }
        session.addInput(newInput)
        input = newInput
        self.device = device
        position = pos
        // The ultra-wide is zoom 1.0 on virtual devices; the main camera starts at the first switch-over.
        wideZoomFactor = 1
        if device.constituentDevices.first?.deviceType == .builtInUltraWideCamera,
           let first = device.virtualDeviceSwitchOverVideoZoomFactors.first {
            wideZoomFactor = CGFloat(truncating: first)
        }
    }

    /// Rotation and mirroring for the current camera. Analysis frames are never mirrored
    /// (so geometry stays true); selfie photos are, if you like them that way.
    private func applyConnections() {
        let angle = Self.rotationAngle(orientation, position: position)
        for output in [videoOutput, photoOutput] as [AVCaptureOutput] {
            if let c = output.connection(with: .video), c.isVideoRotationAngleSupported(angle) {
                c.videoRotationAngle = angle
            }
        }
        if let c = videoOutput.connection(with: .video) {
            if c.isVideoStabilizationSupported { c.preferredVideoStabilizationMode = .off } // keep analysis frames geometrically true
            if c.isVideoMirroringSupported { c.automaticallyAdjustsVideoMirroring = false; c.isVideoMirrored = false }
        }
        if let c = photoOutput.connection(with: .video), c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = position == .front && mirrorSelfies
        }
    }

    private func prepareDevice() throws {
        guard let device else { throw CameraError.noCamera }
        if let maxDims = device.activeFormat.supportedMaxPhotoDimensions.last {
            photoOutput.maxPhotoDimensions = maxDims
        }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        // Back: Wraly drives focus/exposure to the eye itself.
        // Front: the face fills the frame, so the camera's own face priority is the right call.
        let front = position == .front
        device.automaticallyAdjustsFaceDrivenAutoFocusEnabled = front
        device.automaticallyAdjustsFaceDrivenAutoExposureEnabled = front
        if !front {
            device.isFaceDrivenAutoFocusEnabled = false
            device.isFaceDrivenAutoExposureEnabled = false
        }
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        if device.isSmoothAutoFocusSupported { device.isSmoothAutoFocusEnabled = false }
        device.isSubjectAreaChangeMonitoringEnabled = true
        if device.isLowLightBoostSupported { device.automaticallyEnablesLowLightBoostWhenAvailable = true }
        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        device.setExposureTargetBias(0, completionHandler: nil)
        // Start on the main 1× lens — never default a portrait to the ultra-wide.
        device.videoZoomFactor = wideZoomFactor
    }

    /// Rotate analysis frames and photos so they come out upright for the way the phone is held.
    /// Call on `videoQueue`.
    func setOrientation(_ o: FrameOrientation) {
        guard o != orientation else { return }
        orientation = o
        sessionQueue.async { self.applyConnections() }
    }

    /// The back sensor's natural orientation is landscape with the phone's top on the left.
    /// The front sensor faces the other way, so its sideways angles are swapped.
    static func rotationAngle(_ o: FrameOrientation, position: AVCaptureDevice.Position = .back) -> CGFloat {
        switch o {
        case .portrait: return 90
        case .landscapeCounterClockwise: return position == .front ? 180 : 0
        case .landscapeClockwise: return position == .front ? 0 : 180
        }
    }

    /// The orientation of an analysis frame, or nil while a rotation change is still in flight.
    func orientation(of buffer: CMSampleBuffer) -> FrameOrientation? {
        guard let pb = CMSampleBufferGetImageBuffer(buffer) else { return nil }
        let wide = CVPixelBufferGetWidth(pb) > CVPixelBufferGetHeight(pb)
        return wide == orientation.isLandscape ? orientation : nil
    }

    func start() { sessionQueue.async { if !self.session.isRunning { self.session.startRunning() } } }
    func stop() { sessionQueue.async { if self.session.isRunning { self.session.stopRunning() } } }

    // MARK: Lens info for the coach

    /// Current optics expressed in WralyCore terms, for an upright frame held the given way.
    func cameraInfo(orientation o: FrameOrientation = .portrait) -> CameraInfo {
        var info = portraitCameraInfo()
        info.orientation = o
        if o.isLandscape {
            info.aspect = 1 / info.aspect
            swap(&info.verticalFOV, &info.horizontalFOV)
        }
        return info
    }

    private func portraitCameraInfo() -> CameraInfo {
        guard let device else {
            return CameraInfo(equivalentFocalLength: 26, verticalFOV: 69, horizontalFOV: 54)
        }
        let zoom = Double(device.videoZoomFactor)
        // videoFieldOfView is the landscape horizontal FOV at zoom 1 → portrait vertical FOV.
        let baseHalf = Double(device.activeFormat.videoFieldOfView) * .pi / 360
        let tanV = tan(baseHalf) / zoom
        let dims = device.activeFormat.formatDescription.dimensions
        let aspect = dims.width > 0 ? Double(min(dims.width, dims.height)) / Double(max(dims.width, dims.height)) : 0.75
        let vfov = 2 * atan(tanV) * 180 / .pi
        let hfov = 2 * atan(tanV * aspect) * 180 / .pi
        // 36 mm-wide full frame ↔ landscape horizontal FOV.
        let eq = 18 / tanV

        let wide = Double(wideZoomFactor)
        let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors.map { Double(truncating: $0) }
        var stops = ([1.0] + switchOvers).map { $0 / wide }
        // 48 MP main sensors offer an optical-quality 2× crop.
        if !stops.contains(where: { abs($0 - 2) < 0.2 }), device.activeFormat.supportedMaxPhotoDimensions.contains(where: { $0.width >= 8000 }) {
            stops.append(2)
        }
        return CameraInfo(equivalentFocalLength: eq, verticalFOV: vfov, horizontalFOV: hfov, aspect: aspect,
                          zoomFactor: zoom / wide, opticalZoomStops: stops.sorted(), hasFlash: device.hasFlash)
    }

    func setZoom(userFacing z: Double, animated: Bool = true) {
        sessionQueue.async { [self] in
            guard let device, (try? device.lockForConfiguration()) != nil else { return }
            let target = min(max(CGFloat(z) * wideZoomFactor, device.minAvailableVideoZoomFactor),
                             min(device.maxAvailableVideoZoomFactor, 15 * wideZoomFactor))
            if animated { device.ramp(toVideoZoomFactor: target, withRate: 8) } else { device.videoZoomFactor = target }
            device.unlockForConfiguration()
        }
    }

    // MARK: Applying the plan

    /// Applies focus, metering, exposure and white balance. Throttled so AE/AF aren't constantly restarted.
    func apply(_ plan: CapturePlan, orientation o: FrameOrientation) {
        let now = CACurrentMediaTime()
        if let last = lastApplied, now - lastAppliedAt < 0.5, !Self.differsMeaningfully(last, plan) { return }
        lastApplied = plan; lastAppliedAt = now

        sessionQueue.async { [self] in
            guard let device, (try? device.lockForConfiguration()) != nil else { return }
            defer { device.unlockForConfiguration() }

            // The front camera keeps its own face-priority focus and exposure.
            let front = position == .front
            if !front, let p = plan.focusPoint, device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = Self.devicePoint(p, o)
                if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            }
            if !front, let p = plan.meteringPoint, device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = Self.devicePoint(p, o)
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            // Cap the shutter: auto-exposure raises ISO instead of going slower.
            let fmt = device.activeFormat
            let wanted = CMTime(seconds: plan.maxExposureSeconds, preferredTimescale: 1_000_000)
            device.activeMaxExposureDuration = CMTimeClampToRange(wanted, range: CMTimeRange(start: fmt.minExposureDuration, end: fmt.maxExposureDuration))

            let bias = Float(plan.exposureBias).clamped(device.minExposureTargetBias, device.maxExposureTargetBias)
            if abs(device.exposureTargetBias - bias) > 0.05 { device.setExposureTargetBias(bias, completionHandler: nil) }

            switch plan.whiteBalance {
            case .auto:
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance), device.whiteBalanceMode != .continuousAutoWhiteBalance {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                }
            case let .locked(kelvin, tint):
                guard device.isLockingWhiteBalanceWithCustomDeviceGainsSupported else { break }
                var gains = device.deviceWhiteBalanceGains(for: .init(temperature: Float(kelvin), tint: Float(tint)))
                let maxGain = device.maxWhiteBalanceGain
                gains.redGain = gains.redGain.clamped(1, maxGain)
                gains.greenGain = gains.greenGain.clamped(1, maxGain)
                gains.blueGain = gains.blueGain.clamped(1, maxGain)
                device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
            }
        }
    }

    static func differsMeaningfully(_ a: CapturePlan, _ b: CapturePlan) -> Bool {
        func far(_ p: Point2?, _ q: Point2?) -> Bool {
            switch (p, q) {
            case let (p?, q?): return p.distance(to: q) > 0.04
            case (nil, nil): return false
            default: return true
            }
        }
        return far(a.focusPoint, b.focusPoint) || abs(a.exposureBias - b.exposureBias) > 0.2
            || a.whiteBalance != b.whiteBalance || a.maxExposureSeconds != b.maxExposureSeconds
    }

    /// Upright, top-left-origin frame point → sensor point of interest.
    static func devicePoint(_ p: Point2, _ o: FrameOrientation) -> CGPoint {
        let s = o.toSensor(p)
        return CGPoint(x: s.x, y: s.y)
    }

    // MARK: Capture

    /// Captures `count` frames back-to-back; the processor keeps the best one.
    /// `straighten`: the phone's roll in degrees at the shot, to level the saved photo.
    func capture(plan: CapturePlan, count: Int, straighten: Double? = nil,
                 completion: @escaping (Result<CapturedPhoto, Error>) -> Void) {
        sessionQueue.async { [self] in
            let processor = PhotoCaptureProcessor(expected: max(1, count), straighten: straighten) { [weak self] id, result in
                self?.processorsLock.withLock { self?.processors[id] = nil }
                completion(result)
            }
            for i in 0..<max(1, count) {
                let settings = makeSettings(plan: plan, first: i == 0)
                if i == 0 { processor.id = settings.uniqueID }
                processorsLock.withLock { processors[processor.id] = processor }
                photoOutput.capturePhoto(with: settings, delegate: processor)
            }
        }
    }

    private func makeSettings(plan: CapturePlan, first: Bool) -> AVCapturePhotoSettings {
        let settings: AVCapturePhotoSettings
        if photoOutput.availablePhotoCodecTypes.contains(.hevc) {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        } else {
            settings = AVCapturePhotoSettings()
        }
        settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        // One click at most: the burst frames after the first are always silent.
        if #available(iOS 18.0, *), photoOutput.isShutterSoundSuppressionSupported {
            settings.isShutterSoundSuppressionEnabled = !(first && shutterSound)
        }
        settings.photoQualityPrioritization = .quality
        // Flash only on the first frame of a burst (it can't recycle fast enough).
        if plan.flash == .fill, first, photoOutput.supportedFlashModes.contains(.on) {
            settings.flashMode = .on
        } else {
            settings.flashMode = .off
        }
        return settings
    }
}

extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        onFrame?(sampleBuffer)
    }
}

extension Comparable {
    func clamped(_ lo: Self, _ hi: Self) -> Self { min(max(self, lo), hi) }
}

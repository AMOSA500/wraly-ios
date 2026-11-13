import AVFoundation
import CoreImage
import UIKit
import WralyCore

/// Owns the AVCaptureSession: picks the best back camera, streams portrait
/// frames for analysis, applies Wraly's capture plan and takes photos.
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

    func configure() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo

        // Prefer virtual multi-camera devices so zoom can switch lenses seamlessly.
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera],
            mediaType: .video, position: .back)
        guard let device = discovery.devices.first else { throw CameraError.noCamera }
        self.device = device

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CameraError.cannotAddInput }
        session.addInput(input)

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(videoOutput) else { throw CameraError.cannotAddOutput }
        session.addOutput(videoOutput)

        guard session.canAddOutput(photoOutput) else { throw CameraError.cannotAddOutput }
        session.addOutput(photoOutput)
        photoOutput.maxPhotoQualityPrioritization = .quality
        if let maxDims = device.activeFormat.supportedMaxPhotoDimensions.last {
            photoOutput.maxPhotoDimensions = maxDims
        }

        // Deliver frames and photos upright in portrait so Vision needs no orientation juggling.
        for output in [videoOutput, photoOutput] as [AVCaptureOutput] {
            if let c = output.connection(with: .video), c.isVideoRotationAngleSupported(90) {
                c.videoRotationAngle = 90
            }
        }
        if let c = videoOutput.connection(with: .video), c.isVideoStabilizationSupported {
            c.preferredVideoStabilizationMode = .off // keep analysis frames geometrically true
        }

        // The ultra-wide is zoom 1.0 on virtual devices; the main camera starts at the first switch-over.
        if device.constituentDevices.first?.deviceType == .builtInUltraWideCamera,
           let first = device.virtualDeviceSwitchOverVideoZoomFactors.first {
            wideZoomFactor = CGFloat(truncating: first)
        }

        try device.lockForConfiguration()
        // Wraly drives focus/exposure to the eye itself.
        device.automaticallyAdjustsFaceDrivenAutoFocusEnabled = false
        device.isFaceDrivenAutoFocusEnabled = false
        device.automaticallyAdjustsFaceDrivenAutoExposureEnabled = false
        device.isFaceDrivenAutoExposureEnabled = false
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        if device.isSmoothAutoFocusSupported { device.isSmoothAutoFocusEnabled = false }
        device.isSubjectAreaChangeMonitoringEnabled = true
        if device.isLowLightBoostSupported { device.automaticallyEnablesLowLightBoostWhenAvailable = true }
        // Start on the main 1× lens — never default a portrait to the ultra-wide.
        device.videoZoomFactor = wideZoomFactor
        device.unlockForConfiguration()
    }

    /// Rotate analysis frames and photos so they come out upright for the way the phone is held.
    /// Call on `videoQueue`.
    func setOrientation(_ o: FrameOrientation) {
        guard o != orientation else { return }
        orientation = o
        let angle = Self.rotationAngle(o)
        let outputs: [AVCaptureOutput] = [videoOutput, photoOutput]
        sessionQueue.async {
            for output in outputs {
                if let c = output.connection(with: .video), c.isVideoRotationAngleSupported(angle) {
                    c.videoRotationAngle = angle
                }
            }
        }
    }

    /// The sensor's natural orientation is landscape with the phone's top on the left.
    static func rotationAngle(_ o: FrameOrientation) -> CGFloat {
        switch o {
        case .portrait: return 90
        case .landscapeCounterClockwise: return 0
        case .landscapeClockwise: return 180
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

            if let p = plan.focusPoint, device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = Self.devicePoint(p, o)
                if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            }
            if let p = plan.meteringPoint, device.isExposurePointOfInterestSupported {
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
    func capture(plan: CapturePlan, count: Int, completion: @escaping (Result<CapturedPhoto, Error>) -> Void) {
        sessionQueue.async { [self] in
            let processor = PhotoCaptureProcessor(expected: max(1, count)) { [weak self] id, result in
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

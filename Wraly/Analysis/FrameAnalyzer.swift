import AVFoundation
import Vision
import WralyCore

/// Turns camera frames into `FrameSnapshot`s: who's in frame, where their
/// joints and face are, how the light falls, what the background is doing
/// and whether the lens is clean.
///
/// Runs on the camera's video queue. Heavy requests run on a cadence:
/// pose + face every analysed frame, segmentation every 2nd, face quality
/// every 3rd, scene classification every ~3 s.
final class FrameAnalyzer {
    /// Vision's face pitch sign differs from Wraly's "positive = chin up" convention.
    /// Verify on device: ask someone to lift their chin and check `pose.chinUp` fires.
    static let facePitchSign: Double = -1

    private var frameIndex = 0
    private var lastMask: [Bool]?
    private var lastQuality: Double?
    private var sceneLabels: [String] = []
    private var smudge = LensSmudgeEstimator()

    private let poseRequest = VNDetectHumanBodyPoseRequest()
    private let faceRequest = VNDetectFaceLandmarksRequest()
    private let qualityRequest = VNDetectFaceCaptureQualityRequest()
    private let segmentationRequest: VNGeneratePersonSegmentationRequest = {
        let r = VNGeneratePersonSegmentationRequest()
        r.qualityLevel = .fast
        r.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return r
    }()
    private let classifyRequest = VNClassifyImageRequest()

    func resetLensEstimate() { smudge.reset() }

    struct Output {
        var snapshot: FrameSnapshot
        /// For drawing: every joint of the main subject.
        var joints: [WralyCore.Joint: Point2]
        var faceBox: Rect2?
    }

    func analyze(_ sampleBuffer: CMSampleBuffer, device: AVCaptureDevice?, camera: CameraInfo,
                 attitude: DeviceAttitude?, sun: SunPosition?) -> Output? {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        frameIndex += 1
        let ts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let width = Double(CVPixelBufferGetWidth(pb)), height = Double(CVPixelBufferGetHeight(pb))
        // Frames arrive upright for the way the phone is held, so sideways frames are wide.
        let (gridW, gridH) = width > height ? (96, 72) : (72, 96)

        var requests: [VNRequest] = [poseRequest, faceRequest]
        let runSegmentation = frameIndex % 2 == 0
        let runScene = frameIndex % 30 == 1
        if runSegmentation { requests.append(segmentationRequest) }
        if runScene { requests.append(classifyRequest) }

        let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up, options: [:])
        try? handler.perform(requests)

        // ---- Faces & bodies ----
        let faces = faceRequest.results ?? []
        let bodies = poseRequest.results ?? []
        let mainFace = faces.max { $0.boundingBox.width < $1.boundingBox.width }
        let faceBox = mainFace.map { Self.rect($0.boundingBox) }
        let body = Self.matchBody(bodies, to: faceBox)
        let joints = body.map(Self.joints) ?? [:]

        if let mainFace, frameIndex % 3 == 0 {
            qualityRequest.inputFaceObservations = [mainFace]
            try? handler.perform([qualityRequest])
            lastQuality = qualityRequest.results?.first?.faceCaptureQuality.map { Double($0) }
        }

        if runSegmentation, let mask = segmentationRequest.results?.first?.pixelBuffer {
            lastMask = LumaGrid.mask(from: mask, width: gridW, height: gridH)
        }
        if runScene, let results = classifyRequest.results {
            sceneLabels = results.filter { $0.confidence > 0.3 }.prefix(6).map(\.identifier)
        }

        // ---- Pixels ----
        let grid = LumaGrid(pixelBuffer: pb, width: gridW, height: gridH)
        let stats = grid?.stats()
        // A mask from before the phone was turned has the wrong shape.
        if lastMask?.count != gridW * gridH { lastMask = nil }
        let regions = grid?.regions(person: lastMask, face: faceBox)

        var face: FaceReading?
        if let mainFace, let faceBox {
            var f = FaceReading(box: faceBox)
            f.rollDegrees = mainFace.roll.map { $0.doubleValue * 180 / .pi }
            f.yawDegrees = mainFace.yaw.map { $0.doubleValue * 180 / .pi }
            f.pitchDegrees = mainFace.pitch.map { $0.doubleValue * 180 / .pi * Self.facePitchSign }
            let size = CGSize(width: width, height: height)
            if let lm = mainFace.landmarks {
                f.leftPupil = lm.leftPupil?.pointsInImage(imageSize: size).first.map { Self.norm($0, size) }
                f.rightPupil = lm.rightPupil?.pointsInImage(imageSize: size).first.map { Self.norm($0, size) }
                f.leftEyeAspect = lm.leftEye.map { Self.eyeAspect($0.pointsInImage(imageSize: size)) }
                f.rightEyeAspect = lm.rightEye.map { Self.eyeAspect($0.pointsInImage(imageSize: size)) }
            }
            f.captureQuality = lastQuality
            if let fl = grid?.faceLight(faceBox) {
                f.leftHalfLuma = fl.left; f.rightHalfLuma = fl.right; f.clippedFraction = fl.clipped
            }
            face = f
        }

        // ---- Exposure / light ----
        var light: LightReading?
        if let device, let stats {
            let seconds = device.exposureDuration.seconds
            let ev = LightReading.ev100(aperture: Double(device.lensAperture), seconds: seconds, iso: Double(device.iso))
            // EV100 describes the camera settings. When auto-exposure is maxed out the frame
            // goes dark at the same settings, so correct by how far the (gamma-encoded) mean
            // sits from mid-grey (~0.45 encoded ≈ 18% linear).
            let offset = 2.2 * log2(max(stats.mean, 0.02) / 0.45)
            let sceneEV = ev + max(-4, min(3, offset))
            var l = LightReading(ev100: sceneEV, iso: Double(device.iso), exposureSeconds: seconds,
                                 aperture: Double(device.lensAperture), meanLuma: stats.mean,
                                 clippedHighlights: stats.clipped, crushedShadows: stats.crushed)
            l.subjectLuma = regions?.subjectLuma
            l.backgroundLuma = regions?.backgroundLuma
            l.colorTemperatureK = Double(device.temperatureAndTintValues(for: device.deviceWhiteBalanceGains).temperature)
            light = l
        }

        // ---- Lens ----
        var lens: LensReading?
        if let stats {
            let settled = !(device?.isAdjustingFocus ?? true)
            smudge.add(.init(edgeEnergy: stats.edgeEnergy, contrast: stats.contrast, haloLift: stats.haloLift,
                             blackLevel: stats.blackLevel, clipped: stats.clipped), focusSettled: settled)
            lens = LensReading(smudgeScore: smudge.isConfident ? smudge.score : 0, focusSettled: settled)
        }

        let background = regions.map {
            BackgroundReading(clutter: $0.clutter, mergerBehindHead: $0.merger, brightEdgeDistraction: $0.brightEdge,
                              backgroundSharpnessRatio: $0.backgroundSharpnessRatio, sceneLabels: sceneLabels)
        }

        let snapshot = FrameSnapshot(
            timestamp: ts,
            personCount: max(faces.count, bodies.count),
            pose: body == nil ? nil : BodyPose(joints: joints),
            face: face, light: light, background: background, lens: lens,
            attitude: attitude, camera: camera, depthDistance: nil, sun: sun)
        var snap = snapshot
        snap.faces = faces.map { Self.rect($0.boundingBox) }
        if let grid {
            snap.scene = SceneLayout.analyze(luma: grid.values, width: grid.width, height: grid.height, aspect: camera.aspect)
        }
        return Output(snapshot: snap, joints: joints, faceBox: faceBox)
    }

    // MARK: helpers

    /// Vision (bottom-left origin) → Wraly (top-left origin).
    static func rect(_ r: CGRect) -> Rect2 {
        Rect2(x: Double(r.minX), y: 1 - Double(r.maxY), width: Double(r.width), height: Double(r.height))
    }

    static func norm(_ p: CGPoint, _ size: CGSize) -> Point2 {
        Point2(Double(p.x / size.width), 1 - Double(p.y / size.height))
    }

    static func eyeAspect(_ pts: [CGPoint]) -> Double {
        guard let minX = pts.map(\.x).min(), let maxX = pts.map(\.x).max(),
              let minY = pts.map(\.y).min(), let maxY = pts.map(\.y).max(), maxX - minX > 0.5 else { return 0.3 }
        return Double((maxY - minY) / (maxX - minX))
    }

    static let jointMap: [VNHumanBodyPoseObservation.JointName: WralyCore.Joint] = [
        .nose: .nose, .leftEye: .leftEye, .rightEye: .rightEye, .leftEar: .leftEar, .rightEar: .rightEar,
        .neck: .neck, .leftShoulder: .leftShoulder, .rightShoulder: .rightShoulder,
        .leftElbow: .leftElbow, .rightElbow: .rightElbow, .leftWrist: .leftWrist, .rightWrist: .rightWrist,
        .root: .root, .leftHip: .leftHip, .rightHip: .rightHip,
        .leftKnee: .leftKnee, .rightKnee: .rightKnee, .leftAnkle: .leftAnkle, .rightAnkle: .rightAnkle,
    ]

    static func joints(_ obs: VNHumanBodyPoseObservation) -> [WralyCore.Joint: Point2] {
        guard let points = try? obs.recognizedPoints(.all) else { return [:] }
        var out: [WralyCore.Joint: Point2] = [:]
        for (name, p) in points where p.confidence > 0.3 {
            if let j = jointMap[name] { out[j] = Point2(Double(p.location.x), 1 - Double(p.location.y)) }
        }
        return out
    }

    /// The body whose head keypoints fall inside the main face; else the largest body.
    static func matchBody(_ bodies: [VNHumanBodyPoseObservation], to face: Rect2?) -> VNHumanBodyPoseObservation? {
        guard !bodies.isEmpty else { return nil }
        if let face {
            let grown = Rect2(x: face.minX - face.width * 0.3, y: face.minY - face.height * 0.3,
                              width: face.width * 1.6, height: face.height * 1.6)
            if let hit = bodies.first(where: { b in
                guard let nose = joints(b)[.nose] else { return false }
                return nose.x >= grown.minX && nose.x <= grown.maxX && nose.y >= grown.minY && nose.y <= grown.maxY
            }) { return hit }
        }
        return bodies.max { span($0) < span($1) }
    }

    private static func span(_ b: VNHumanBodyPoseObservation) -> Double {
        let ys = joints(b).values.map(\.y)
        guard let lo = ys.min(), let hi = ys.max() else { return 0 }
        return hi - lo
    }
}

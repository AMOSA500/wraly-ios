import Foundation

// MARK: - Geometry

/// A point in normalised frame coordinates.
/// Origin is the TOP-LEFT of the portrait frame, x grows right, y grows down,
/// both in 0...1. (Vision uses bottom-left; the app converts before calling in.)
public struct Point2: Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }

    public static func midpoint(_ a: Point2, _ b: Point2) -> Point2 {
        Point2((a.x + b.x) / 2, (a.y + b.y) / 2)
    }

    public func distance(to other: Point2) -> Double {
        hypot(other.x - x, other.y - y)
    }
}

/// A rectangle in normalised, top-left-origin frame coordinates.
public struct Rect2: Equatable, Sendable {
    public var minX: Double, minY: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        minX = x; minY = y; self.width = width; self.height = height
    }
    public var maxX: Double { minX + width }
    public var maxY: Double { minY + height }
    public var midX: Double { minX + width / 2 }
    public var midY: Double { minY + height / 2 }
    public var center: Point2 { Point2(midX, midY) }
}

// MARK: - Body pose

public enum Joint: String, CaseIterable, Sendable {
    case nose, leftEye, rightEye, leftEar, rightEar
    case neck, leftShoulder, rightShoulder
    case leftElbow, rightElbow, leftWrist, rightWrist
    case root, leftHip, rightHip
    case leftKnee, rightKnee, leftAnkle, rightAnkle
}

/// Body keypoints for one person. Only confidently detected joints are present.
public struct BodyPose: Equatable, Sendable {
    public var joints: [Joint: Point2]
    public init(joints: [Joint: Point2]) { self.joints = joints }

    public subscript(_ joint: Joint) -> Point2? { joints[joint] }

    public func has(_ js: Joint...) -> Bool { js.allSatisfy { joints[$0] != nil } }

    public var shoulderMid: Point2? {
        guard let l = joints[.leftShoulder], let r = joints[.rightShoulder] else { return joints[.neck] }
        return .midpoint(l, r)
    }
    public var hipMid: Point2? {
        guard let l = joints[.leftHip], let r = joints[.rightHip] else { return joints[.root] }
        return .midpoint(l, r)
    }
    public var ankleMid: Point2? {
        switch (joints[.leftAnkle], joints[.rightAnkle]) {
        case let (l?, r?): return .midpoint(l, r)
        case let (l?, nil): return l
        case let (nil, r?): return r
        default: return nil
        }
    }
    public var kneeMid: Point2? {
        switch (joints[.leftKnee], joints[.rightKnee]) {
        case let (l?, r?): return .midpoint(l, r)
        case let (l?, nil): return l
        case let (nil, r?): return r
        default: return nil
        }
    }
}

// MARK: - Face

public struct FaceReading: Equatable, Sendable {
    /// Face bounding box (normalised, top-left origin).
    public var box: Rect2
    /// Head roll in degrees (positive = head tilted toward the frame's right).
    public var rollDegrees: Double?
    /// Head yaw in degrees (0 = looking at camera; sign as reported by Vision).
    public var yawDegrees: Double?
    /// Head pitch in degrees (positive = chin up).
    public var pitchDegrees: Double?
    public var leftPupil: Point2?
    public var rightPupil: Point2?
    /// Eye aspect ratio (height / width) of each eye contour. ~0.25–0.35 open, < 0.15 closed.
    public var leftEyeAspect: Double?
    public var rightEyeAspect: Double?
    /// Vision's face capture quality, 0...1 (sharpness, expression, occlusion).
    public var captureQuality: Double?
    /// Mean luma of the left and right halves of the face (0...1). Used for shadow ratio.
    public var leftHalfLuma: Double?
    public var rightHalfLuma: Double?
    /// Fraction of face pixels that are clipped (blown) highlights.
    public var clippedFraction: Double?

    public init(box: Rect2) { self.box = box }

    public var eyesOpen: Bool? {
        guard let l = leftEyeAspect, let r = rightEyeAspect else { return nil }
        return min(l, r) > 0.17
    }

    public var eyeLine: Double {
        if let l = leftPupil, let r = rightPupil { return (l.y + r.y) / 2 }
        // Eyes sit roughly 40% down a face box.
        return box.minY + box.height * 0.40
    }

    /// Estimated crown (top of the skull incl. hair). Face boxes stop at the hairline.
    public var crownY: Double { box.minY - box.height * 0.22 }

    /// Estimated chin.
    public var chinY: Double { box.maxY }
}

// MARK: - Light

public struct LightReading: Equatable, Sendable {
    /// Scene brightness as EV100, derived from aperture, shutter and ISO.
    public var ev100: Double
    public var iso: Double
    public var exposureSeconds: Double
    public var aperture: Double
    /// Mean luma across the frame, 0...1.
    public var meanLuma: Double
    /// Fraction of pixels at or above 98% luma.
    public var clippedHighlights: Double
    /// Fraction of pixels at or below 2% luma.
    public var crushedShadows: Double
    /// Mean luma of person pixels (from segmentation), 0...1.
    public var subjectLuma: Double?
    /// Mean luma of non-person pixels, 0...1.
    public var backgroundLuma: Double?
    /// Correlated colour temperature from the white-balance gains, Kelvin.
    public var colorTemperatureK: Double?

    public init(ev100: Double, iso: Double, exposureSeconds: Double, aperture: Double,
                meanLuma: Double, clippedHighlights: Double, crushedShadows: Double) {
        self.ev100 = ev100; self.iso = iso; self.exposureSeconds = exposureSeconds
        self.aperture = aperture; self.meanLuma = meanLuma
        self.clippedHighlights = clippedHighlights; self.crushedShadows = crushedShadows
    }

    /// EV100 = log2(N² / t) − log2(ISO / 100)
    public static func ev100(aperture: Double, seconds: Double, iso: Double) -> Double {
        guard aperture > 0, seconds > 0, iso > 0 else { return 0 }
        return log2(aperture * aperture / seconds) - log2(iso / 100)
    }

    /// Stops of difference between background and subject (positive = background brighter).
    public var backlightStops: Double? {
        guard let s = subjectLuma, let b = backgroundLuma, s > 0.005 else { return nil }
        return log2(max(b, 0.005) / s)
    }
}

// MARK: - Background, lens, device

public struct BackgroundReading: Equatable, Sendable {
    /// Edge density in non-person areas, 0 (seamless) ... 1 (very busy).
    public var clutter: Double
    /// Strong vertical structure directly behind/above the head (pole, tree, door frame).
    public var mergerBehindHead: Bool
    /// A bright patch near the frame edge that pulls the eye away from the subject.
    public var brightEdgeDistraction: Bool
    /// Relative sharpness of the background vs the subject, 0...1 (1 = equally sharp, no separation).
    public var backgroundSharpnessRatio: Double?
    /// Top scene classification labels, e.g. ["outdoor", "beach"].
    public var sceneLabels: [String]

    public init(clutter: Double, mergerBehindHead: Bool = false, brightEdgeDistraction: Bool = false,
                backgroundSharpnessRatio: Double? = nil, sceneLabels: [String] = []) {
        self.clutter = clutter; self.mergerBehindHead = mergerBehindHead
        self.brightEdgeDistraction = brightEdgeDistraction
        self.backgroundSharpnessRatio = backgroundSharpnessRatio; self.sceneLabels = sceneLabels
    }
}

public struct LensReading: Equatable, Sendable {
    /// 0 = clean, 1 = certainly smudged. Already temporally smoothed by the caller.
    public var smudgeScore: Double
    /// Whether autofocus currently reports a settled focus. Smudge is only judged when true.
    public var focusSettled: Bool
    public init(smudgeScore: Double, focusSettled: Bool) {
        self.smudgeScore = smudgeScore; self.focusSettled = focusSettled
    }
}

public struct DeviceAttitude: Equatable, Sendable {
    /// 0 = phone perfectly upright. Positive = lens pointing UP (phone top tilted away).
    public var pitchDegrees: Double
    /// 0 = level. Positive = phone rotated clockwise as seen by the photographer.
    public var rollDegrees: Double
    /// How much the phone is moving (rotation rate magnitude, rad/s).
    public var shake: Double
    /// Compass heading of the lens direction in degrees (0 = north), if available.
    public var headingDegrees: Double?
    public init(pitchDegrees: Double, rollDegrees: Double, shake: Double = 0, headingDegrees: Double? = nil) {
        self.pitchDegrees = pitchDegrees; self.rollDegrees = rollDegrees
        self.shake = shake; self.headingDegrees = headingDegrees
    }
}

public struct CameraInfo: Equatable, Sendable {
    /// Full-frame-equivalent focal length of the current view, mm.
    public var equivalentFocalLength: Double
    /// Vertical field of view of the portrait frame, degrees.
    public var verticalFOV: Double
    /// Horizontal field of view of the portrait frame, degrees.
    public var horizontalFOV: Double
    /// Portrait frame aspect (width / height), e.g. 0.75 for 3:4.
    public var aspect: Double
    /// Current zoom in user-facing units: 1 = main wide camera, 0.5 = ultra-wide.
    public var zoomFactor: Double
    /// User-facing zoom factors this device reaches optically (e.g. [0.5, 1, 2, 5]).
    public var opticalZoomStops: [Double]
    public var hasFlash: Bool
    public init(equivalentFocalLength: Double, verticalFOV: Double, horizontalFOV: Double,
                aspect: Double = 0.75, zoomFactor: Double = 1, opticalZoomStops: [Double] = [1],
                hasFlash: Bool = true) {
        self.equivalentFocalLength = equivalentFocalLength; self.verticalFOV = verticalFOV
        self.horizontalFOV = horizontalFOV; self.aspect = aspect; self.zoomFactor = zoomFactor
        self.opticalZoomStops = opticalZoomStops; self.hasFlash = hasFlash
    }
}

// MARK: - Snapshot

/// Everything Wraly knows about one analysed frame.
public struct FrameSnapshot: Sendable {
    public var timestamp: TimeInterval
    public var personCount: Int
    public var pose: BodyPose?
    public var face: FaceReading?
    public var light: LightReading?
    public var background: BackgroundReading?
    public var lens: LensReading?
    public var attitude: DeviceAttitude?
    public var camera: CameraInfo
    /// Subject distance from LiDAR / depth, metres, when the device provides it.
    public var depthDistance: Double?
    /// Sun position relative to the scene, when location + heading are available.
    public var sun: SunPosition?

    public init(timestamp: TimeInterval, personCount: Int, pose: BodyPose? = nil, face: FaceReading? = nil,
                light: LightReading? = nil, background: BackgroundReading? = nil, lens: LensReading? = nil,
                attitude: DeviceAttitude? = nil, camera: CameraInfo, depthDistance: Double? = nil,
                sun: SunPosition? = nil) {
        self.timestamp = timestamp; self.personCount = personCount; self.pose = pose; self.face = face
        self.light = light; self.background = background; self.lens = lens; self.attitude = attitude
        self.camera = camera; self.depthDistance = depthDistance; self.sun = sun
    }
}

// MARK: - Shots

public enum ShotType: String, CaseIterable, Sendable, Identifiable {
    case headshot          // top of head to just below the collarbone
    case headAndShoulders  // to mid-chest
    case halfBody          // to the waist / just above
    case threeQuarter      // to mid-thigh ("American shot")
    case fullBody          // head to feet with floor space

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .headshot: return "Headshot"
        case .headAndShoulders: return "Head & Shoulders"
        case .halfBody: return "Half Body"
        case .threeQuarter: return "Three-Quarter"
        case .fullBody: return "Full Body"
        }
    }

    /// The flattering full-frame-equivalent focal length range. Short lenses
    /// close to a face exaggerate the nose and shrink the ears.
    public var idealFocalRange: ClosedRange<Double> {
        switch self {
        case .headshot: return 70...135
        case .headAndShoulders: return 60...105
        case .halfBody: return 48...85
        case .threeQuarter: return 35...85
        case .fullBody: return 24...70
        }
    }
}

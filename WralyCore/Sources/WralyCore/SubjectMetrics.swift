import Foundation

/// Measurements a photographer judges by eye: how far away the subject is,
/// how tall they are, how much of the body is in frame, and where the camera
/// sits relative to their body.
public struct SubjectMetrics: Equatable, Sendable {
    public var ladder: BodyLadder
    /// Shot type the current framing corresponds to.
    public var currentShot: ShotType
    /// Camera-to-subject distance in metres (depth sensor if available, else from eye spacing).
    public var distance: Double?
    /// Estimated standing height in metres (only when head and feet are visible).
    public var heightMeters: Double?
    /// Where the lens is relative to the subject's body (e.g. .chest).
    public var cameraHeightLevel: BodyLadder.Level?
    /// Camera height in head-heights below the crown (continuous version of the above).
    public var cameraHeightHeads: Double?
    /// Fraction of the frame width between the subject's centre line and the frame centre (−0.5...0.5).
    public var horizontalOffset: Double

    /// Average adult interpupillary distance. Varies ±10% between people, which is
    /// fine for coaching ("step back one pace") but not for measuring.
    public static let averageIPD = 0.063
    /// Average adult head height, crown to chin.
    public static let averageHeadHeight = 0.23

    public init?(snapshot s: FrameSnapshot) {
        guard let ladder = BodyLadder(face: s.face, pose: s.pose) else { return nil }
        self.ladder = ladder
        self.currentShot = SubjectMetrics.classify(ladder)

        // --- Distance -------------------------------------------------------
        let tanHalfH = tan(s.camera.horizontalFOV * .pi / 360)
        let tanHalfV = tan(s.camera.verticalFOV * .pi / 360)
        if let d = s.depthDistance, d > 0.2 {
            distance = d
        } else if let face = s.face, let l = face.leftPupil, let r = face.rightPupil {
            // Pupil spacing in frame-width units, corrected for head turn.
            let yawCorrection = max(cos((face.yawDegrees ?? 0) * .pi / 180), 0.5)
            let ipd = hypot(r.x - l.x, (r.y - l.y) / max(s.camera.aspect, 0.1)) / yawCorrection
            // Angle subtended: ipd * 2 * tan(hfov/2) (pinhole model, normalised by width).
            let angular = ipd * 2 * tanHalfH
            distance = angular > 1e-4 ? SubjectMetrics.averageIPD / angular : nil
        } else if ladder.headHeight > 0 {
            let angular = ladder.headHeight * 2 * tanHalfV
            distance = angular > 1e-4 ? SubjectMetrics.averageHeadHeight / angular : nil
        } else {
            distance = nil
        }

        // --- Height ---------------------------------------------------------
        if let d = distance, ladder.measured.contains(.ankles), s.face != nil {
            let span = ladder.figureHeight // crown → soles in frame-height units
            heightMeters = span * 2 * tanHalfV * d
        } else {
            heightMeters = nil
        }

        // --- Camera height relative to the body ---------------------------------
        // When the phone is upright, objects at lens height sit on the frame's
        // horizontal centre line. Tilting the lens up by θ moves that line down by
        // tan(θ) / (2·tan(vfov/2)) of the frame height.
        if let att = s.attitude {
            let horizonY = 0.5 + tan(att.pitchDegrees * .pi / 180) / (2 * tanHalfV)
            cameraHeightHeads = ladder.headsBelowCrown(horizonY)
            cameraHeightLevel = ladder.level(at: horizonY).level
        } else {
            cameraHeightHeads = nil
            cameraHeightLevel = nil
        }

        // --- Horizontal placement -------------------------------------------
        let centreX: Double
        if let p = s.pose, let sm = p.shoulderMid, let hm = p.hipMid {
            centreX = (sm.x + hm.x) / 2
        } else if let f = s.face {
            centreX = f.box.midX
        } else if let sm = s.pose?.shoulderMid {
            centreX = sm.x
        } else {
            centreX = 0.5
        }
        horizontalOffset = centreX - 0.5
    }

    /// Classify by where the bottom frame edge cuts the body.
    public static func classify(_ ladder: BodyLadder) -> ShotType {
        let cut = ladder.headsBelowCrown(1.0)
        switch cut {
        case ..<1.9: return .headshot
        case ..<2.6: return .headAndShoulders
        case ..<4.2: return .halfBody
        case ..<7.6: return .threeQuarter
        default: return .fullBody
        }
    }

    /// Converts a head-height offset into centimetres using the real distance.
    public func centimetres(heads: Double) -> Double {
        heads * SubjectMetrics.averageHeadHeight * 100
    }
}

import Foundation

/// Vertical body landmarks for the subject, in frame coordinates.
///
/// Real keypoints are used when Vision sees them; anything outside the frame is
/// extrapolated from the head height using classic figure-drawing proportions
/// (an adult is ~7.5–8 heads tall). This lets Wraly say "you're cropping at the
/// knee" even when the knee is just off the bottom of the frame.
public struct BodyLadder: Equatable, Sendable {
    public enum Level: Int, CaseIterable, Comparable, Sendable {
        case crown, eyes, chin, shoulders, chest, waist, hips, midThigh, knees, midCalf, ankles, soles

        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

        /// Distance from the crown in head heights for a typical standing adult.
        var headsFromCrown: Double {
            switch self {
            case .crown: return 0
            case .eyes: return 0.5
            case .chin: return 1.0
            case .shoulders: return 1.4
            case .chest: return 2.0
            case .waist: return 3.0
            case .hips: return 3.9
            case .midThigh: return 4.9
            case .knees: return 5.8
            case .midCalf: return 6.7
            case .ankles: return 7.5
            case .soles: return 7.75
            }
        }

        public var spoken: String {
            switch self {
            case .crown: return "the top of their head"
            case .eyes: return "eye level"
            case .chin: return "chin level"
            case .shoulders: return "shoulder level"
            case .chest: return "chest level"
            case .waist: return "waist level"
            case .hips: return "hip level"
            case .midThigh: return "mid-thigh"
            case .knees: return "knee level"
            case .midCalf: return "mid-calf"
            case .ankles: return "ankle level"
            case .soles: return "their feet"
            }
        }
    }

    public private(set) var y: [Level: Double]
    /// Which levels came from real keypoints rather than extrapolation.
    public private(set) var measured: Set<Level>
    /// Head height (crown to chin) in normalised frame units.
    public let headHeight: Double

    public init?(face: FaceReading?, pose: BodyPose?) {
        var values: [Level: Double] = [:]
        var measured: Set<Level> = []

        func set(_ l: Level, _ v: Double?) {
            guard let v else { return }
            values[l] = v; measured.insert(l)
        }

        if let face {
            set(.crown, face.crownY)
            set(.eyes, face.eyeLine)
            set(.chin, face.chinY)
        }
        if let pose {
            set(.shoulders, pose.shoulderMid?.y)
            set(.hips, pose.hipMid?.y)
            set(.knees, pose.kneeMid?.y)
            set(.ankles, pose.ankleMid?.y)
            if values[.eyes] == nil, let l = pose[.leftEye], let r = pose[.rightEye] {
                set(.eyes, (l.y + r.y) / 2)
            }
        }

        // Establish a head height: from the face if we have it, else from eyes→shoulders.
        let head: Double
        if let c = values[.crown], let ch = values[.chin], ch > c {
            head = ch - c
        } else if let e = values[.eyes], let s = values[.shoulders], s > e {
            head = (s - e) / (Level.shoulders.headsFromCrown - Level.eyes.headsFromCrown)
        } else if let s = values[.shoulders], let h = values[.hips], h > s {
            head = (h - s) / (Level.hips.headsFromCrown - Level.shoulders.headsFromCrown)
        } else {
            return nil
        }
        guard head > 0.005 else { return nil }
        self.headHeight = head

        // Fill gaps by extrapolating from the nearest measured level.
        let anchors = measured.sorted()
        for level in Level.allCases where values[level] == nil {
            guard let anchor = anchors.min(by: {
                abs($0.headsFromCrown - level.headsFromCrown) < abs($1.headsFromCrown - level.headsFromCrown)
            }), let ay = values[anchor] else { continue }
            values[level] = ay + (level.headsFromCrown - anchor.headsFromCrown) * head
        }
        self.y = values
        self.measured = measured
    }

    public subscript(_ level: Level) -> Double { y[level] ?? 0 }

    /// The body level nearest to a frame y coordinate, plus a 0...1 position toward the next level.
    public func level(at frameY: Double) -> (level: Level, fraction: Double) {
        let levels = Level.allCases
        if frameY <= self[.crown] { return (.crown, 0) }
        for (a, b) in zip(levels, levels.dropFirst()) where frameY <= self[b] {
            let span = max(self[b] - self[a], 1e-6)
            return ((frameY - self[a]) / span < 0.5 ? a : b, (frameY - self[a]) / span)
        }
        return (.soles, 0)
    }

    /// Height in head-heights below the crown for a frame y coordinate.
    public func headsBelowCrown(_ frameY: Double) -> Double {
        (frameY - self[.crown]) / headHeight
    }

    /// The full figure height (crown to soles) in frame units.
    public var figureHeight: Double { self[.soles] - self[.crown] }
}

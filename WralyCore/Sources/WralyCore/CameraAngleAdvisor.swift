import Foundation

/// Camera height, tilt and level.
///
/// Where the lens sits relative to the body changes the person's proportions:
/// whatever is closest to the lens looks biggest. Shoot a full-body from your
/// own eye level and you get a big head and short legs; shoot a face from below
/// and you get nostrils and a double chin.
public struct CameraAngleAdvisor: Sendable {
    public init() {}

    /// Acceptable lens heights in head-heights below the crown, per shot.
    /// (0 = top of head, 0.5 = eyes, 2 = chest, 3 = waist, 3.9 = hips.)
    public static func idealHeight(for shot: ShotType) -> (range: ClosedRange<Double>, label: String) {
        switch shot {
        case .headshot:         return (0.2...0.7, "eye level or slightly above")
        case .headAndShoulders: return (0.3...1.1, "eye to chin level")
        case .halfBody:         return (0.6...2.1, "chin to chest level")
        case .threeQuarter:     return (1.6...3.2, "chest to waist level")
        case .fullBody:         return (2.6...4.6, "waist to hip level")
        }
    }

    public func evaluate(_ s: FrameSnapshot, metrics m: SubjectMetrics?, target shot: ShotType) -> [Guidance] {
        guard let att = s.attitude else { return [] }
        var out: [Guidance] = []

        // Shake first: no setting fixes motion blur from the photographer.
        if att.shake > 0.6 {
            out.append(Guidance("angle.shake", .cameraAngle, .fix, .photographer,
                                "Hold steady — tuck your elbows in",
                                reason: "Brace elbows against your body and exhale as you shoot. Wraly waits for the phone to settle before auto-capturing.",
                                cue: .wait))
        }

        // Level. Even 2° of roll reads as a crooked horizon on walls and doors.
        if abs(att.rollDegrees) > 2.5 {
            out.append(Guidance("angle.level", .cameraAngle, abs(att.rollDegrees) > 6 ? .fix : .tip, .photographer,
                                "Level the phone",
                                reason: "A tilted horizon makes the whole picture feel off unless it's an obvious creative choice (>15°).",
                                cue: att.rollDegrees > 0 ? .rotateCounterClockwise : .rotateClockwise))
        }

        // Pitch: tilting converges verticals and distorts the body, worst in full-body.
        let pitchLimit: Double = shot == .fullBody || shot == .threeQuarter ? 7 : 15
        if abs(att.pitchDegrees) > pitchLimit {
            let up = att.pitchDegrees > 0
            out.append(Guidance("angle.pitch", .cameraAngle, .fix, .photographer,
                                up ? "Don't tilt up — keep the phone upright" : "Don't tilt down — keep the phone upright",
                                reason: up
                                    ? "Tilting up makes legs look huge and the head tiny. Lower the phone instead and keep it vertical."
                                    : "Tilting down shortens the legs and makes the head look big. Lower the phone to the right height and keep it vertical.",
                                cue: up ? .tiltDown : .tiltUp))
        }

        // Height relative to the body.
        if let m, let heads = m.cameraHeightHeads {
            let ideal = Self.idealHeight(for: shot)
            let cmPerHead = SubjectMetrics.averageHeadHeight * 100
            if heads < ideal.range.lowerBound - 0.15 {
                let cm = Int(((ideal.range.lowerBound - heads) * cmPerHead / 5).rounded() * 5)
                out.append(Guidance("angle.tooHigh", .cameraAngle, .fix, .photographer,
                                    cm >= 10 ? "Lower the phone ~\(cm) cm" : "Lower the phone slightly",
                                    reason: Self.highReason(shot, ideal.label),
                                    cue: .lowerPhone))
            } else if heads > ideal.range.upperBound + 0.15 {
                let cm = Int(((heads - ideal.range.upperBound) * cmPerHead / 5).rounded() * 5)
                out.append(Guidance("angle.tooLow", .cameraAngle, .fix, .photographer,
                                    cm >= 10 ? "Raise the phone ~\(cm) cm" : "Raise the phone slightly",
                                    reason: Self.lowReason(shot, ideal.label),
                                    cue: .raisePhone))
            } else if shot == .fullBody, heads < 3.3 {
                out.append(Guidance("angle.legsTip", .cameraAngle, .tip, .photographer,
                                    "Tip: go a little lower for longer legs",
                                    reason: "Dropping the lens to hip height, phone still vertical, makes the legs look longer without distorting the face.",
                                    cue: .lowerPhone))
            }
        }
        return out
    }

    static func highReason(_ shot: ShotType, _ label: String) -> String {
        switch shot {
        case .fullBody, .threeQuarter:
            return "Shooting down from your eye level gives a big head and short legs. Put the lens at \(label)."
        default:
            return "Too high an angle makes the subject look small and the forehead big. Put the lens at \(label)."
        }
    }

    static func lowReason(_ shot: ShotType, _ label: String) -> String {
        switch shot {
        case .headshot, .headAndShoulders:
            return "From below you see up the nostrils and under the chin. Put the lens at \(label)."
        default:
            return "The lens is too low for this framing — the subject will loom over the viewer. Put it at \(label)."
        }
    }
}

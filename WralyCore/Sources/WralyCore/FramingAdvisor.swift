import Foundation

/// Composition rules: headroom, eye line, size in frame, look room and,
/// most importantly, never cropping a limb at a joint.
public struct FramingAdvisor: Sendable {
    public init() {}

    struct Target {
        var headroom: ClosedRange<Double>      // crown → top edge, frame fraction
        var eyeLine: ClosedRange<Double>?      // eye y position
        var footroom: ClosedRange<Double>?     // soles → bottom edge (full body only)
        var cutHeads: ClosedRange<Double>      // where the bottom edge may cut, in heads below crown
    }

    /// Where the top of the head should sit (frame fraction from the top) for a shot.
    public static func headroomRange(for shot: ShotType) -> ClosedRange<Double> {
        target(for: shot).headroom
    }

    static func target(for shot: ShotType) -> Target {
        switch shot {
        case .headshot:
            // Tight headshots may trim the top of the hair, never the chin.
            return Target(headroom: -0.04...0.07, eyeLine: 0.28...0.42, footroom: nil, cutHeads: 1.45...1.9)
        case .headAndShoulders:
            return Target(headroom: 0.03...0.10, eyeLine: 0.26...0.38, footroom: nil, cutHeads: 2.1...2.6)
        case .halfBody:
            return Target(headroom: 0.04...0.12, eyeLine: 0.22...0.36, footroom: nil, cutHeads: 3.25...3.7)
        case .threeQuarter:
            // The "American shot" — cut at mid-thigh, never at the knee.
            return Target(headroom: 0.03...0.10, eyeLine: 0.12...0.30, footroom: nil, cutHeads: 4.6...5.3)
        case .fullBody:
            return Target(headroom: 0.03...0.10, eyeLine: nil, footroom: 0.03...0.10, cutHeads: 7.8...9.5)
        }
    }

    public func evaluate(_ s: FrameSnapshot, metrics m: SubjectMetrics, target shot: ShotType) -> [Guidance] {
        var out: [Guidance] = []
        let L = m.ladder
        let t = Self.target(for: shot)
        let cutHeads = L.headsBelowCrown(1.0)

        // 1. Shot size: are we too close / too far for the chosen shot?
        if cutHeads < t.cutHeads.lowerBound - 0.15 {
            out.append(Guidance("frame.tooTight", .framing, .fix, .photographer,
                                shot == .fullBody ? "Step back — include their feet" : "Step back a little",
                                reason: "For a \(shot.title.lowercased()) the bottom of the frame should fall \(Self.describeCut(shot)).",
                                cue: .moveBack))
        } else if cutHeads > t.cutHeads.upperBound + 0.3 {
            out.append(Guidance("frame.tooLoose", .framing, .fix, .photographer,
                                "Move closer or zoom in",
                                reason: "The subject is small in the frame. Filling the frame gives more detail on the face and less distracting background.",
                                cue: .moveCloser))
        }

        // 2. Never crop at a joint. A cut through a joint looks like an amputation;
        //    a cut between joints looks intentional.
        if let joint = Self.jointNearBottomEdge(L), shot != .fullBody {
            out.append(Guidance("frame.jointCrop.\(joint)", .framing, .fix, .photographer,
                                "Don't crop at the \(Self.jointName(joint))",
                                reason: "Cropping exactly at a joint (\(Self.jointName(joint))) looks like an amputation. Crop between joints: mid-thigh, mid-calf, or include the whole limb.",
                                cue: Self.isBelowKnee(joint) ? .moveBack : .moveCloser))
        }
        if let pose = s.pose {
            for j in [Joint.leftWrist, .rightWrist, .leftElbow, .rightElbow] {
                guard let p = pose[j] else { continue }
                if p.x < 0.025 || p.x > 0.975 {
                    out.append(Guidance("frame.sideCrop", .framing, .fix, .photographer,
                                        p.x < 0.5 ? "Hand cut off — aim a bit left" : "Hand cut off — aim a bit right",
                                        reason: "A hand or elbow touching the frame edge pulls the eye out of the picture. Leave a small gap or crop clearly through the forearm.",
                                        cue: p.x < 0.5 ? .moveLeft : .moveRight))
                    break
                }
            }
        }

        // 3. Headroom — the most common phone-photo mistake is too much sky over the head.
        let headroom = L[.crown]
        if headroom > t.headroom.upperBound + 0.03,
           let fix = Self.headroomFix(s, m, shot: shot, target: t, cutHeads: cutHeads) {
            out.append(fix)
        } else if headroom < t.headroom.lowerBound - 0.02 {
            out.append(Guidance("frame.headroom.cropped", .framing, shot == .headshot ? .tip : .fix, .photographer,
                                "Head is cut off — tilt up slightly",
                                reason: "Only tight headshots should trim the top of the hair. For this framing, keep the whole head in.",
                                cue: .tiltUp))
        }

        // 4. Eye line on the upper third.
        if let range = t.eyeLine, s.face != nil {
            let eye = L[.eyes]
            if eye > range.upperBound + 0.04 {
                out.append(Guidance("frame.eyeline.low", .framing, .tip, .photographer,
                                    "Put their eyes on the top third line",
                                    reason: "Eyes on the upper-third line is where viewers look first; centred eyes leave dead space above.",
                                    cue: .tiltDown))
            }
        }

        // 5. Feet: never cut toes, leave a little floor.
        if shot == .fullBody, let foot = t.footroom {
            let room = 1 - L[.soles]
            if room < 0 {
                out.append(Guidance("frame.feetCut", .framing, .critical, .photographer,
                                    "Feet are cut off — step back",
                                    reason: "A full-body shot with cropped feet looks like a mistake. Show the feet and a little floor.",
                                    cue: .moveBack))
            } else if room < foot.lowerBound {
                out.append(Guidance("frame.footroom", .framing, .tip, .photographer,
                                    "Leave a little floor under their feet",
                                    reason: "Feet touching the frame edge feel cramped. 3–10% floor grounds the subject.",
                                    cue: .moveBack))
            } else if room > 0.18 {
                out.append(Guidance("frame.footroom.tooMuch", .framing, .tip, .photographer,
                                    "Too much floor — step closer",
                                    reason: "A tall strip of ground wastes the frame; fill it with the person instead.",
                                    cue: .moveCloser))
            }
        }

        // 6. Horizontal placement and look room.
        let off = m.horizontalOffset
        let look = Self.lookDirection(s)
        if abs(off) > 0.22 {
            out.append(Guidance("frame.offCentre", .framing, .fix, .photographer,
                                off < 0 ? "Aim a little left" : "Aim a little right",
                                reason: "The subject is drifting out of frame. Keep them centred or on a third line.",
                                cue: off < 0 ? .moveLeft : .moveRight))
        } else if let look, abs(look) > 0.3, off * look > 0.06 {
            // Subject is placed on the same side they're looking toward → no look room.
            out.append(Guidance("frame.lookRoom", .framing, .tip, .photographer,
                                look < 0 ? "Give them room to look into — aim left" : "Give them room to look into — aim right",
                                reason: "When someone looks off to one side, leave more space in front of their face than behind it (look room).",
                                cue: look < 0 ? .moveLeft : .moveRight))
        }

        return out
    }

    // MARK: helpers

    /// Picks the one fix for too much space above the head that won't cause a new problem.
    static func headroomFix(_ s: FrameSnapshot, _ m: SubjectMetrics, shot: ShotType,
                            target t: Target, cutHeads: Double) -> Guidance? {
        let base = "Empty space above the head makes the subject look like they're sinking. Keep \(percent(t.headroom)) of the frame above the crown."
        func g(_ msg: String, _ why: String, _ cue: Cue) -> Guidance {
            Guidance("frame.headroom.tooMuch", .framing, .fix, .photographer, msg, reason: base + " " + why, cue: cue)
        }
        // 1. Subject small in the frame: "Move closer or zoom in" already covers it.
        if cutHeads > t.cutHeads.upperBound + 0.3 { return nil }

        // 2. Lens above the ideal height: lower it, phone upright, and the head rises in
        //    the frame without distorting the body. (Full body: only if there's floor to spare.)
        let ideal = CameraAngleAdvisor.idealHeight(for: shot)
        let floorToSpare = shot != .fullBody || 1 - m.ladder[.soles] > 0.08
        if let heads = m.cameraHeightHeads, heads < ideal.range.lowerBound + 0.1, floorToSpare {
            return g("Too much space above — lower the phone",
                     "Your lens is higher than \(ideal.label). Crouch or bend your knees and keep the phone upright — don't point it down.",
                     .lowerPhone)
        }

        // 3. Close shots: a small downward tilt is harmless.
        let closeShot = shot == .headshot || shot == .headAndShoulders || shot == .halfBody
        if closeShot, (s.attitude?.pitchDegrees ?? 0) > -10 {
            return g("Too much space above — tilt down slightly",
                     "For close framing a small tilt is fine — put their eyes on the top grid line.",
                     .tiltDown)
        }

        // 4. Longer shots: tilting down shortens the legs, so fill the frame instead.
        return g("Too much space above — step closer",
                 "Tilting down would shorten the legs and enlarge the head. Step closer or zoom so they fill the frame.",
                 .moveCloser)
    }

    /// Joint whose y is within ±3% (frame) of the bottom edge.
    static func jointNearBottomEdge(_ L: BodyLadder) -> BodyLadder.Level? {
        let joints: [BodyLadder.Level] = [.chin, .waist, .knees, .ankles]
        let tolerance = max(0.03, L.headHeight * 0.18)
        return joints.first { abs(L[$0] - 1.0) < tolerance }
    }

    static func jointName(_ l: BodyLadder.Level) -> String {
        switch l {
        case .chin: return "chin"
        case .waist: return "waist"
        case .knees: return "knees"
        case .ankles: return "ankles"
        default: return l.spoken
        }
    }

    static func isBelowKnee(_ l: BodyLadder.Level) -> Bool { l >= .knees }

    static func describeCut(_ shot: ShotType) -> String {
        switch shot {
        case .headshot: return "just below the collarbone"
        case .headAndShoulders: return "around mid-chest"
        case .halfBody: return "just above the waist"
        case .threeQuarter: return "at mid-thigh"
        case .fullBody: return "below the feet"
        }
    }

    static func percent(_ r: ClosedRange<Double>) -> String {
        "\(Int(max(r.lowerBound, 0) * 100))–\(Int(r.upperBound * 100))%"
    }

    /// −1 = looking toward frame left, +1 = toward frame right, nil = unknown.
    static func lookDirection(_ s: FrameSnapshot) -> Double? {
        if let face = s.face, let nose = s.pose?[.nose] {
            let half = max(face.box.width / 2, 1e-3)
            return max(-1, min(1, (nose.x - face.box.midX) / half * 2.5))
        }
        if let yaw = s.face?.yawDegrees { return max(-1, min(1, yaw / 45)) }
        return nil
    }
}

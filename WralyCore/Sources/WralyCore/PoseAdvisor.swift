import Foundation

/// Head, shoulder, arm and leg coaching. Messages are addressed to the subject
/// (Wraly can speak them aloud) and use no left/right, which people confuse
/// when mirrored.
public struct PoseAdvisor: Sendable {
    public init() {}

    public func evaluate(_ s: FrameSnapshot, metrics m: SubjectMetrics?, target shot: ShotType) -> [Guidance] {
        var out: [Guidance] = []
        let aspect = max(s.camera.aspect, 0.1)
        func dist(_ a: Point2, _ b: Point2) -> Double { hypot(a.x - b.x, (a.y - b.y) / aspect) } // width units

        // ---------------- Head ----------------
        if let face = s.face {
            if let roll = face.rollDegrees, abs(roll) > 16 {
                out.append(Guidance("pose.headTiltTooMuch", .pose, .fix, .subject,
                                    "Straighten your head a little",
                                    reason: "A slight tilt (5–10°) looks relaxed; much more looks quizzical.",
                                    cue: nil))
            }
            if let pitch = face.pitchDegrees {
                if pitch > 12 {
                    out.append(Guidance("pose.chinUp", .pose, .fix, .subject,
                                        "Bring your chin down slightly",
                                        reason: "Chin up shows the nostrils and the underside of the jaw.",
                                        cue: nil))
                } else if pitch < -16 {
                    out.append(Guidance("pose.chinDown", .pose, .fix, .subject,
                                        "Lift your chin a little",
                                        reason: "Chin tucked too far creates a double chin and hides the eyes.",
                                        cue: nil))
                }
            }
            if let yaw = face.yawDegrees, (28...55).contains(abs(yaw)) {
                out.append(Guidance("pose.noseBreaksCheek", .pose, .tip, .subject,
                                    "Turn your face back toward me a little",
                                    reason: "In this half-turn the nose crosses the cheek line and looks bigger. Either come back to a gentle three-quarter (~20°) or go fully to profile.",
                                    cue: nil))
            }
        }

        // ---------------- Shoulders & torso ----------------
        if let p = s.pose, let ls = p[.leftShoulder], let rs = p[.rightShoulder] {
            let shoulderWidth = dist(ls, rs)

            // Squared-to-camera: shoulders look widest when the body faces the lens.
            if let face = s.face, face.box.width > 0.02 {
                let ratio = shoulderWidth / face.box.width
                let facingCamera = abs(face.yawDegrees ?? 0) < 15
                if ratio > 2.35, facingCamera, shot != .headshot {
                    out.append(Guidance("pose.squareShoulders", .pose, shot == .headAndShoulders ? .tip : .fix, .subject,
                                        "Turn your body slightly, face back to me",
                                        reason: "Shoulders square to the lens look broad and stiff. Angle the body 30–45° away and turn just the face back — the classic portrait pose.",
                                        cue: nil))
                }
            }

            // Shoulder line badly uneven (but a slight drop of the front shoulder is good).
            let tilt = atan2((rs.y - ls.y) / aspect, rs.x - ls.x) * 180 / .pi
            let shoulderTilt = abs(tilt) > 90 ? 180 - abs(tilt) : abs(tilt)
            if shoulderTilt > 13 {
                out.append(Guidance("pose.shouldersUneven", .pose, .tip, .subject,
                                    "Relax your shoulders level",
                                    reason: "A small drop of the shoulder nearest the camera is flattering; a big slope looks like leaning.",
                                    cue: nil))
            }

            // Hunched / tense shoulders: little visible neck between chin and shoulder line.
            if let face = s.face, let m {
                let neckGap = (p.shoulderMid?.y ?? 0) - face.chinY
                if neckGap < m.ladder.headHeight * 0.16 {
                    out.append(Guidance("pose.tense", .pose, .tip, .subject,
                                        "Drop your shoulders and breathe out",
                                        reason: "Raised shoulders shorten the neck and read as tension. A slow exhale drops them naturally.",
                                        cue: nil))
                }
            }

            // Slouch / lean.
            if let sm = p.shoulderMid, let hm = p.hipMid {
                let torso = dist(sm, hm)
                if torso > 0.05, abs(sm.x - hm.x) / torso > 0.28 {
                    out.append(Guidance("pose.lean", .pose, .tip, .subject,
                                        "Stand tall — weight over your hips",
                                        reason: "The upper body is leaning sideways. Standing tall with a slight forward lean from the waist toward the camera is more flattering.",
                                        cue: nil))
                }
            }

            // ---------------- Arms ----------------
            if shot != .headshot, shot != .headAndShoulders {
                let pressed = [(Joint.leftElbow, Joint.leftHip), (.rightElbow, .rightHip)].contains { pair in
                    guard let ep = p[pair.0], let hp = p[pair.1] else { return false }
                    return abs(ep.x - hp.x) < shoulderWidth * 0.12
                }
                if pressed {
                    out.append(Guidance("pose.armsPressed", .pose, .tip, .subject,
                                        "Leave a small gap between arms and waist",
                                        reason: "Arms pressed against the body flatten and widen both. A hand on the hip or a slight bend of the elbow creates a gap and defines the waist.",
                                        cue: nil))
                }
            }

            // ---------------- Legs ----------------
            if shot == .fullBody,
               let lh = p[.leftHip], let lk = p[.leftKnee], let la = p[.leftAnkle],
               let rh = p[.rightHip], let rk = p[.rightKnee], let ra = p[.rightAnkle] {
                let lAngle = Self.angle(lh, lk, la, aspect: aspect)
                let rAngle = Self.angle(rh, rk, ra, aspect: aspect)
                let stance = dist(la, ra)
                if lAngle > 172, rAngle > 172, abs(la.y - ra.y) < 0.015 {
                    out.append(Guidance("pose.lockedLegs", .pose, .tip, .subject,
                                        "Shift weight to your back leg, soften the front knee",
                                        reason: "Both legs straight and evenly weighted looks like standing to attention. Weight on the back foot with the front knee bent creates an S-curve.",
                                        cue: nil))
                }
                if stance > shoulderWidth * 1.5 {
                    out.append(Guidance("pose.wideStance", .pose, .tip, .subject,
                                        "Bring your feet a little closer",
                                        reason: "A wide stance reads as a power pose; for most portraits feet about hip-width, one slightly forward, is more relaxed.",
                                        cue: nil))
                }
            }
        }

        // Headshot polish once nothing else is wrong.
        if out.isEmpty, shot == .headshot || shot == .headAndShoulders, let face = s.face {
            if let roll = face.rollDegrees, abs(roll) < 2.5 {
                out.append(Guidance("pose.jawline", .pose, .tip, .subject,
                                    "Push your forehead toward me, then chin down a touch",
                                    reason: "The \"turtle\" trick: extending the face forward stretches the skin under the jaw and defines the jawline on camera.",
                                    cue: nil))
            }
        }
        return out
    }

    /// Interior angle at b in degrees.
    static func angle(_ a: Point2, _ b: Point2, _ c: Point2, aspect: Double) -> Double {
        let v1 = (a.x - b.x, (a.y - b.y) / aspect)
        let v2 = (c.x - b.x, (c.y - b.y) / aspect)
        let dot = v1.0 * v2.0 + v1.1 * v2.1
        let mag = hypot(v1.0, v1.1) * hypot(v2.0, v2.1)
        guard mag > 1e-9 else { return 180 }
        return acos(max(-1, min(1, dot / mag))) * 180 / .pi
    }
}

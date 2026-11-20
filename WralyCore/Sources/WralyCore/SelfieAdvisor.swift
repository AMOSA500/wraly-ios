import Foundation

/// Coaching for selfies on the front camera. You're the photographer and the
/// subject, so every instruction is spoken to you, and directions are given
/// the way you see yourself on the mirrored screen.
///
/// Frames are analysed un-mirrored (as the camera sees them); `screenX` converts.
public struct SelfieAdvisor: Sendable {
    public init() {}

    /// Rules from the portrait advisors that still make sense when you hold the phone yourself.
    public static let keptPoseRules: Set<String> = [
        "pose.headTiltTooMuch", "pose.chinUp", "pose.chinDown", "pose.tense",
    ]

    /// Where an analysed point appears on the mirrored selfie screen.
    public static func screenX(_ x: Double) -> Double { 1 - x }

    public func evaluate(_ s: FrameSnapshot, metrics m: SubjectMetrics?) -> [Guidance] {
        var out: [Guidance] = []
        let faces = s.faces.isEmpty ? (s.face.map { [$0.box] } ?? []) : s.faces

        guard let face = s.face, !faces.isEmpty else {
            out.append(Guidance("selfie.none", .subject, .critical, .photographer,
                                "Bring your face into the frame",
                                reason: "Wraly needs to see your face to set focus, exposure and the moment to shoot.",
                                cue: .wait))
            return out
        }

        // ---- Angle: just above eye level, never from below ----------------------
        // Positive pitch = back lens up, so the front lens looks up when pitch is negative.
        if let att = s.attitude {
            if att.pitchDegrees < -12 {
                out.append(Guidance("selfie.lowAngle", .cameraAngle, .fix, .photographer,
                                    "Raise the phone to just above eye level",
                                    reason: "From below, the lens looks up your nose and adds a double chin. Slightly above eye level, angled down a touch, slims the jaw and opens up the eyes.",
                                    cue: .raisePhone))
            } else if att.pitchDegrees > 35 {
                out.append(Guidance("selfie.highAngle", .cameraAngle, .tip, .photographer,
                                    "A little lower — that angle is very steep",
                                    reason: "A gentle downward angle flatters; a steep one shrinks your body and makes your head look oversized.",
                                    cue: .lowerPhone))
            }
            if att.shake > 0.6 {
                out.append(Guidance("angle.shake", .cameraAngle, .fix, .photographer,
                                    "Hold steady — tuck your elbow in",
                                    reason: "The front camera has no stabilisation. Bracing your elbow against your body keeps the shot sharp.",
                                    cue: .wait))
            }
        }

        // ---- Distance: arm's length, not nose-to-lens -----------------------------
        let tooClose = (m?.distance).map { $0 < 0.3 } ?? (faces.count == 1 && face.box.width > 0.55)
        if tooClose {
            out.append(Guidance("selfie.tooClose", .lensChoice, .fix, .photographer,
                                "Hold the phone further away",
                                reason: "Closer than about 30 cm, the wide front lens stretches your nose and shrinks your ears. Full arm's length gives natural proportions.",
                                cue: .moveBack))
        } else if faces.count == 1, face.box.width < 0.14 {
            out.append(Guidance("selfie.tooFar", .framing, .tip, .photographer,
                                "Bring the phone a little closer",
                                reason: "Your face is small in the frame. Closer, the photo is about you rather than the background.",
                                cue: .moveCloser))
        }

        // ---- Framing ---------------------------------------------------------------
        if face.crownY < -0.02, !tooClose {
            out.append(Guidance("selfie.headCut", .framing, .fix, .photographer,
                                "Top of your head is cut off — raise the phone a little",
                                reason: "Cropping through the forehead looks like a mistake. Raise the phone (keep it angled down) so your whole head fits.",
                                cue: .raisePhone))
        } else if face.chinY > 0.9 {
            out.append(Guidance("selfie.tooLow", .framing, .tip, .photographer,
                                "Lower the phone a little — you're at the bottom",
                                reason: "Your eyes look best about a third of the way down the frame.",
                                cue: .lowerPhone))
        }
        if faces.count == 1 {
            let x = Self.screenX(face.box.midX)
            if abs(x - 0.5) > 0.2 {
                // Moving the phone to your right moves you left on the mirrored screen.
                let right = x > 0.5
                out.append(Guidance("selfie.centre", .framing, .tip, .photographer,
                                    right ? "Move the phone a little to your right" : "Move the phone a little to your left",
                                    reason: "Centred works well for a selfie; off to one side only works when the background is the point.",
                                    cue: right ? .moveRight : .moveLeft))
            }
        }

        // ---- Group selfies ---------------------------------------------------------
        if faces.count >= 2 {
            if faces.contains(where: { $0.minX < 0.015 || $0.maxX > 0.985 }) {
                out.append(Guidance("selfie.groupCut", .framing, .fix, .photographer,
                                    "Someone's cut off — hold the phone further out",
                                    reason: "A face sliced by the edge spoils a group selfie. Stretch your arm out or squeeze in closer.",
                                    cue: .moveBack))
            } else if let lo = faces.map(\.minX).min(), let hi = faces.map(\.maxX).max(), hi - lo > 0.8 {
                out.append(Guidance("selfie.squeeze", .framing, .tip, .photographer,
                                    "Squeeze in closer together",
                                    reason: "Heads close together fill the frame and look like you belong in the same photo.",
                                    cue: .moveCloser))
            }
            if faces.count >= 3, !s.camera.orientation.isLandscape {
                out.append(Guidance("selfie.sideways", .framing, .tip, .photographer,
                                    "\(faces.count) of you — turn the phone sideways",
                                    reason: "A sideways frame fits a row of faces without everyone shrinking.",
                                    cue: .turnSideways))
            }
        }

        // ---- Light -----------------------------------------------------------------
        if let l = s.light {
            if l.ev100 < 1 {
                out.append(Guidance("selfie.dark", .light, .critical, .photographer,
                                    "Too dark for a sharp selfie — find more light",
                                    reason: "The front camera is small and has no stabilisation: in this light it will be noisy and blurred.",
                                    cue: .turnAround))
            } else if let stops = l.backlightStops, stops > 2 {
                out.append(Guidance("selfie.backlit", .light, .fix, .photographer,
                                    "Bright light behind you — turn to face it",
                                    reason: "With a window or the sun behind you, your face goes dark or the background blows out. Facing the light gives clear skin and bright eyes.",
                                    cue: .turnAround))
            } else if l.ev100 < 4 {
                out.append(Guidance("selfie.dim", .light, .tip, .photographer,
                                    "Face a window or lamp for brighter skin",
                                    reason: "Soft light on your face — a window beside or in front of you — is the easiest way to a better selfie.",
                                    cue: .turnAround))
            }
        }

        // ---- Eyes ------------------------------------------------------------------
        if face.eyesOpen != false {
            out.append(Guidance("selfie.lookAtLens", .expression, .tip, .photographer,
                                "Look at the lens, not the screen",
                                reason: "Eyes on the screen look slightly down in the photo. A glance at the lens, just above the screen, gives eye contact.",
                                cue: .lookAtLens))
        }
        return out
    }
}

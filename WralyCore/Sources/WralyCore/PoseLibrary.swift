import Foundation

// MARK: - Checks the camera can confirm

/// Result of checking one pose step against a frame.
public enum CheckResult: Equatable, Sendable {
    case met
    case notMet
    /// The joints or face needed to judge this aren't visible.
    case unknown
}

/// A body position the camera can confirm from 2D keypoints and the face reading.
///
/// Thresholds are first guesses and need calibrating on a device (see README).
/// Shoulder turn is judged from shoulder width relative to face width: about
/// 2.3 face-widths when squared to the lens, ~1.6 at a 45° turn, < 1.3 side-on.
public enum PoseCheck: String, Sendable, CaseIterable {
    case bodyTurned        // shoulders angled roughly 30–60° away from the lens
    case bodySquare        // shoulders facing the lens
    case bodyProfile       // turned well away, nearly side-on
    case faceToCamera      // face pointing at the lens
    case faceAway          // face turned off to the side
    case chinLevel         // not tipped up or tucked down
    case headTilt          // a gentle sideways tilt
    case shouldersRelaxed  // visible neck, shoulders down
    case handOnHip         // a wrist at the hip with the elbow out
    case armsCrossed       // both wrists across the body at chest/waist height
    case handNearChin      // a hand up by the chin
    case weightShifted     // hips tilted or one knee bent
    case footForward       // one foot clearly ahead of the other
    case seated            // thighs foreshortened / horizontal

    public static let squareRatio = 2.1
    public static let turnedRange = 1.15...1.95
    public static let profileRatio = 1.3

    public func evaluate(_ s: FrameSnapshot, metrics m: SubjectMetrics?) -> CheckResult {
        let aspect = max(s.camera.aspect, 0.1)
        // Distances in frame-width units (y scaled so both axes match).
        func dist(_ a: Point2, _ b: Point2) -> Double { hypot(a.x - b.x, (a.y - b.y) / aspect) }
        let p = s.pose
        let face = s.face
        // Head height, in frame-height units and frame-width units.
        let headY: Double? = m?.ladder.headHeight ?? face.map { $0.box.height * 1.22 }
        let headW = headY.map { $0 / aspect }

        switch self {
        case .bodyTurned, .bodySquare, .bodyProfile:
            guard let face, face.box.width > 0.02 else { return .unknown }
            let ls = p?[.leftShoulder], rs = p?[.rightShoulder]
            guard let ls, let rs else {
                // One shoulder hidden behind the body: they're turned well away.
                if ls != nil || rs != nil { return self == .bodySquare ? .notMet : .met }
                return .unknown
            }
            let ratio = dist(ls, rs) / face.box.width
            switch self {
            case .bodySquare: return ratio >= Self.squareRatio ? .met : .notMet
            case .bodyTurned: return ratio <= Self.turnedRange.upperBound ? .met : .notMet
            default: return ratio < Self.profileRatio ? .met : .notMet
            }

        case .faceToCamera:
            guard let yaw = face?.yawDegrees else { return .unknown }
            return abs(yaw) <= 15 ? .met : .notMet

        case .faceAway:
            guard let yaw = face?.yawDegrees else { return .unknown }
            return abs(yaw) >= 25 ? .met : .notMet

        case .chinLevel:
            guard let pitch = face?.pitchDegrees else { return .unknown }
            return (-14...10).contains(pitch) ? .met : .notMet

        case .headTilt:
            guard let roll = face?.rollDegrees else { return .unknown }
            return (4...15).contains(abs(roll)) ? .met : .notMet

        case .shouldersRelaxed:
            guard let face, let headY, let sm = p?.shoulderMid else { return .unknown }
            return sm.y - face.chinY >= headY * 0.18 ? .met : .notMet

        case .handOnHip:
            guard let p, let headW, let cx = p.shoulderMid?.x else { return .unknown }
            var sawArm = false
            for (w, e, h, sh) in [(Joint.leftWrist, Joint.leftElbow, Joint.leftHip, Joint.leftShoulder),
                                  (.rightWrist, .rightElbow, .rightHip, .rightShoulder)] {
                guard let wp = p[w], let ep = p[e], let hp = p[h], let sp = p[sh] else { continue }
                sawArm = true
                let wristAtHip = dist(wp, hp) < headW * 0.75
                let elbowOut = abs(ep.x - cx) > abs(sp.x - cx) + headW * 0.1
                if wristAtHip && elbowOut { return .met }
            }
            return sawArm ? .notMet : .unknown

        case .armsCrossed:
            guard let p, let headY, let lw = p[.leftWrist], let rw = p[.rightWrist],
                  let ls = p[.leftShoulder], let rs = p[.rightShoulder] else { return .unknown }
            let cx = (ls.x + rs.x) / 2
            let top = (ls.y + rs.y) / 2 + headY * 0.3
            let bottom = p.hipMid?.y ?? top + headY * 2.6
            let inBand = [lw, rw].allSatisfy { $0.y > top && $0.y < bottom }
            // Each wrist has crossed the centre line to the opposite side.
            let crossed = (lw.x - cx) * (ls.x - cx) <= 0 && (rw.x - cx) * (rs.x - cx) <= 0
            return inBand && crossed ? .met : .notMet

        case .handNearChin:
            guard let face, let headW else { return .unknown }
            let wrists = [p?[.leftWrist], p?[.rightWrist]].compactMap { $0 }
            guard !wrists.isEmpty else { return .unknown }
            let chin = Point2(face.box.midX, face.chinY)
            return wrists.contains { dist($0, chin) < headW * 1.1 && $0.y > face.box.minY } ? .met : .notMet

        case .weightShifted:
            guard let p, let lh = p[.leftHip], let rh = p[.rightHip] else { return .unknown }
            let hipTilt = abs(atan2((rh.y - lh.y) / aspect, rh.x - lh.x) * 180 / .pi)
            let tilt = hipTilt > 90 ? 180 - hipTilt : hipTilt
            if tilt > 4 { return .met }
            if let lk = p[.leftKnee], let la = p[.leftAnkle], let rk = p[.rightKnee], let ra = p[.rightAnkle] {
                let l = PoseAdvisor.angle(lh, lk, la, aspect: aspect)
                let r = PoseAdvisor.angle(rh, rk, ra, aspect: aspect)
                if min(l, r) < 165 && max(l, r) > 168 { return .met }
            }
            return .notMet

        case .footForward:
            guard let p, let headY, let la = p[.leftAnkle], let ra = p[.rightAnkle] else { return .unknown }
            return abs(la.y - ra.y) > headY * 0.12 ? .met : .notMet

        case .seated:
            guard let p, let headY, let hip = p.hipMid, let knee = p.kneeMid else { return .unknown }
            // Standing, knees sit ~1.9 head-heights below the hips.
            return knee.y - hip.y < headY * 0.9 ? .met : .notMet
        }
    }
}

// MARK: - Poses

/// One instruction in a pose, and how the camera confirms the subject did it.
public struct PoseStep: Identifiable, Equatable, Sendable {
    public let id: String
    /// What the photographer tells the subject (spoken if voice is on).
    public let say: String
    /// Two or three words for the on-screen checklist.
    public let label: String
    public let check: PoseCheck

    public init(_ id: String, _ label: String, _ say: String, _ check: PoseCheck) {
        self.id = id; self.label = label; self.say = say; self.check = check
    }
}

public struct PoseRecipe: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    /// What the pose is for — shown in the picker.
    public let summary: String
    /// SF Symbol name.
    public let symbol: String
    public let shots: Set<ShotType>
    public let steps: [PoseStep]
}

public enum PoseLibrary {
    public static let all: [PoseRecipe] = [
        PoseRecipe(id: "classic", name: "Classic Portrait",
                   summary: "Body angled away, face back to the lens. Slims the shoulders and works for almost everyone.",
                   symbol: "person.crop.rectangle",
                   shots: [.headshot, .headAndShoulders, .halfBody, .threeQuarter],
                   steps: [
                    PoseStep("classic.turn", "Body turned", "Turn your body a little to the side", .bodyTurned),
                    PoseStep("classic.face", "Face to me", "Now turn just your face back to me", .faceToCamera),
                    PoseStep("classic.chin", "Chin level", "Keep your chin level", .chinLevel),
                    PoseStep("classic.relax", "Shoulders down", "Drop your shoulders and breathe out", .shouldersRelaxed),
                   ]),
        PoseRecipe(id: "confident", name: "Open & Confident",
                   summary: "Square to the camera, direct eye contact. Strong and approachable — good for profiles and business.",
                   symbol: "person.fill",
                   shots: [.headAndShoulders, .halfBody, .threeQuarter, .fullBody],
                   steps: [
                    PoseStep("confident.square", "Facing me", "Face me straight on", .bodySquare),
                    PoseStep("confident.face", "Eyes to lens", "Look right into the lens", .faceToCamera),
                    PoseStep("confident.relax", "Shoulders down", "Let your shoulders drop", .shouldersRelaxed),
                    PoseStep("confident.tilt", "Slight tilt", "Tilt your head just slightly", .headTilt),
                   ]),
        PoseRecipe(id: "hip", name: "Hand on Hip",
                   summary: "Creates a gap between arm and waist and adds shape. Great for half and full-length shots.",
                   symbol: "figure.stand",
                   shots: [.halfBody, .threeQuarter, .fullBody],
                   steps: [
                    PoseStep("hip.turn", "Body turned", "Turn slightly to the side", .bodyTurned),
                    PoseStep("hip.hand", "Hand on hip", "Put one hand on your hip, elbow out", .handOnHip),
                    PoseStep("hip.face", "Face to me", "Turn your face back to me", .faceToCamera),
                   ]),
        PoseRecipe(id: "crossed", name: "Arms Crossed",
                   summary: "Relaxed authority. Keep the arms loose so it reads confident, not closed.",
                   symbol: "person.crop.square",
                   shots: [.halfBody, .threeQuarter],
                   steps: [
                    PoseStep("crossed.turn", "Body turned", "Turn a little to the side", .bodyTurned),
                    PoseStep("crossed.arms", "Arms crossed", "Cross your arms loosely", .armsCrossed),
                    PoseStep("crossed.face", "Face to me", "Face back toward me", .faceToCamera),
                    PoseStep("crossed.relax", "Shoulders down", "Relax your shoulders", .shouldersRelaxed),
                   ]),
        PoseRecipe(id: "thoughtful", name: "Thoughtful",
                   summary: "Hand lightly at the chin with a gentle tilt. Soft and personal for close shots.",
                   symbol: "hand.raised",
                   shots: [.headAndShoulders, .halfBody],
                   steps: [
                    PoseStep("thoughtful.hand", "Hand to chin", "Rest your chin lightly on your hand", .handNearChin),
                    PoseStep("thoughtful.tilt", "Slight tilt", "Tilt your head slightly", .headTilt),
                    PoseStep("thoughtful.face", "Eyes to me", "Bring your eyes back to me", .faceToCamera),
                   ]),
        PoseRecipe(id: "stance", name: "Relaxed Stance",
                   summary: "Weight on the back leg, front knee soft. Creates a natural S-curve instead of standing to attention.",
                   symbol: "figure.walk",
                   shots: [.threeQuarter, .fullBody],
                   steps: [
                    PoseStep("stance.turn", "Body turned", "Turn a little to the side", .bodyTurned),
                    PoseStep("stance.weight", "Weight back", "Put your weight on your back leg", .weightShifted),
                    PoseStep("stance.foot", "Front foot out", "Slide your front foot forward, knee soft", .footForward),
                    PoseStep("stance.face", "Face to me", "Turn your face to me", .faceToCamera),
                   ]),
        PoseRecipe(id: "candid", name: "Candid Look-Away",
                   summary: "Looking off camera feels natural and unposed. Great between the posed frames.",
                   symbol: "eye",
                   shots: Set(ShotType.allCases),
                   steps: [
                    PoseStep("candid.turn", "Body turned", "Turn a little to the side", .bodyTurned),
                    PoseStep("candid.away", "Look away", "Look at something off to the side, past me", .faceAway),
                    PoseStep("candid.chin", "Chin level", "Keep your chin level", .chinLevel),
                   ]),
        PoseRecipe(id: "shoulder", name: "Over the Shoulder",
                   summary: "Body turned away, looking back. Elegant and a little dramatic.",
                   symbol: "arrow.uturn.backward.circle",
                   shots: [.headAndShoulders, .halfBody, .threeQuarter],
                   steps: [
                    PoseStep("shoulder.profile", "Side-on", "Turn almost side-on to me", .bodyProfile),
                    PoseStep("shoulder.look", "Look back", "Look back at me over your shoulder", .faceToCamera),
                    PoseStep("shoulder.chin", "Chin level", "Keep your chin level, not lifted", .chinLevel),
                   ]),
        PoseRecipe(id: "seated", name: "Seated",
                   summary: "Sitting angled away from the camera relaxes people and slims the body.",
                   symbol: "chair",
                   shots: [.halfBody, .threeQuarter, .fullBody],
                   steps: [
                    PoseStep("seated.sit", "Seated", "Take a seat", .seated),
                    PoseStep("seated.turn", "Knees angled", "Angle your knees and body away from me", .bodyTurned),
                    PoseStep("seated.face", "Face to me", "Turn your face back to me", .faceToCamera),
                   ]),
    ]

    public static func recipe(id: String) -> PoseRecipe? { all.first { $0.id == id } }

    /// Poses that suit this shot, best first.
    public static func recommended(for shot: ShotType) -> [PoseRecipe] {
        all.filter { $0.shots.contains(shot) }
    }

    /// The pose after `current` for this shot, wrapping around.
    public static func next(after current: PoseRecipe?, for shot: ShotType, step: Int = 1) -> PoseRecipe? {
        let list = recommended(for: shot)
        guard !list.isEmpty else { return nil }
        guard let current, let i = list.firstIndex(of: current) else { return list.first }
        return list[((i + step) % list.count + list.count) % list.count]
    }
}

// MARK: - Live matching

public struct PoseStepStatus: Identifiable, Equatable, Sendable {
    public let step: PoseStep
    /// Stabilised: true only after the step has held briefly.
    public let met: Bool
    /// The camera can't currently see what it needs to judge this step.
    public let unknown: Bool
    public var id: String { step.id }
}

public struct PoseProgress: Equatable, Sendable {
    public let recipe: PoseRecipe
    public let steps: [PoseStepStatus]
    /// Every step confirmed.
    public var matched: Bool { steps.allSatisfy(\.met) }
    public var metCount: Int { steps.filter(\.met).count }
    /// The step to ask for next.
    public var nextStep: PoseStepStatus? { steps.first { !$0.met } }
}

/// Tracks a chosen pose across frames. A step counts once it has held for a
/// moment, and doesn't un-tick on a single noisy frame.
public final class PoseMatcher {
    public var hold: TimeInterval = 0.3
    public var release: TimeInterval = 0.6

    public var recipe: PoseRecipe? { didSet { if recipe != oldValue { reset() } } }

    private var runStart: [String: TimeInterval] = [:]
    private var lastMet: [String: TimeInterval] = [:]
    private var stable: Set<String> = []

    public init(recipe: PoseRecipe? = nil) { self.recipe = recipe }

    public func reset() { runStart.removeAll(); lastMet.removeAll(); stable.removeAll() }

    public func update(_ s: FrameSnapshot, metrics: SubjectMetrics?) -> PoseProgress? {
        guard let recipe else { return nil }
        let now = s.timestamp
        let statuses = recipe.steps.map { step -> PoseStepStatus in
            let raw = s.personCount > 0 ? step.check.evaluate(s, metrics: metrics) : .unknown
            if raw == .met {
                if runStart[step.id] == nil { runStart[step.id] = now }
                lastMet[step.id] = now
                if now - runStart[step.id]! >= hold { stable.insert(step.id) }
            } else {
                runStart[step.id] = nil
                if now - (lastMet[step.id] ?? -.infinity) > release { stable.remove(step.id) }
            }
            return PoseStepStatus(step: step, met: stable.contains(step.id), unknown: raw == .unknown)
        }
        return PoseProgress(recipe: recipe, steps: statuses)
    }
}

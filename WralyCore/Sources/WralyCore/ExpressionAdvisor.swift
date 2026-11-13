import Foundation

/// Subject presence, eyes and the moment.
public struct ExpressionAdvisor: Sendable {
    public init() {}

    public func evaluate(_ s: FrameSnapshot, metrics m: SubjectMetrics?) -> [Guidance] {
        var out: [Guidance] = []
        if s.personCount == 0 {
            out.append(Guidance("subject.none", .subject, .critical, .photographer,
                                "Point the camera at your subject",
                                reason: "Wraly coaches once it can see a person.", cue: nil))
            return out
        }
        if s.personCount > 1 {
            out.append(Guidance("subject.group", .subject, .tip, .photographer,
                                "\(s.personCount) people — coaching the closest",
                                reason: "For groups, keep everyone's faces at a similar distance from the lens so all are sharp, and stagger heads at different heights.",
                                cue: nil))
        }
        if s.face == nil, s.pose != nil {
            out.append(Guidance("subject.faceHidden", .expression, .fix, .subject,
                                "Turn your face toward the camera",
                                reason: "Wraly can't see the face. Most portraits need at least one eye visible.",
                                cue: nil))
        }
        if let face = s.face {
            if face.eyesOpen == false {
                out.append(Guidance("expr.eyesClosed", .expression, .fix, .subject,
                                    "Eyes closed — waiting",
                                    reason: "Wraly won't fire on a blink. Tip: ask them to close their eyes and open on \"three\" for a fresh, wide-eyed look.",
                                    cue: .wait))
            }
            if let q = face.captureQuality, q < 0.25 {
                out.append(Guidance("expr.lowQuality", .expression, .tip, .subject,
                                    "Relax — let's get a natural expression",
                                    reason: "Ask a question or tell a quick joke and shoot on the reaction. Real smiles reach the eyes; held smiles fade after a few seconds.",
                                    cue: nil))
            }
        }
        return out
    }
}

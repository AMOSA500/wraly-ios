import Foundation

/// The background is half the picture. Pros check it before the subject.
public struct BackgroundAdvisor: Sendable {
    public init() {}

    public func evaluate(_ s: FrameSnapshot, metrics m: SubjectMetrics?) -> [Guidance] {
        guard let bg = s.background, s.personCount > 0 else { return [] }
        var out: [Guidance] = []

        if bg.mergerBehindHead {
            out.append(Guidance("bg.merger", .background, .fix, .photographer,
                                "Something's growing out of their head — step sideways",
                                reason: "A pole, tree or door frame lined up behind the head looks like it's sprouting from it. One step left or right fixes it.",
                                cue: .moveLeft))
        }
        if bg.clutter > 0.55 {
            let tele = (m?.currentShot ?? .halfBody) != .fullBody
            out.append(Guidance("bg.busy", .background, .tip, .photographer,
                                tele ? "Busy background — zoom in and step back" : "Busy background — find a plainer spot",
                                reason: "A longer lens shows less background and blurs it more. Otherwise look for a plain wall, foliage or open sky behind them.",
                                cue: tele ? .zoomIn : nil))
        }
        if let ratio = bg.backgroundSharpnessRatio, ratio > 0.8, (m?.distance ?? 9) < 3 {
            out.append(Guidance("bg.tooClose", .background, .tip, .subject,
                                "Step a few paces away from the background",
                                reason: "Background blur depends on the subject-to-background distance. Two or three metres gap gives creamy separation and avoids shadows on the wall behind.",
                                cue: nil))
        }
        if bg.brightEdgeDistraction {
            out.append(Guidance("bg.brightEdge", .background, .tip, .photographer,
                                "Bright spot at the edge — reframe",
                                reason: "The eye goes to the brightest part of a picture first. Keep bright patches away from the frame edges so attention stays on the face.",
                                cue: nil))
        }
        return out
    }
}

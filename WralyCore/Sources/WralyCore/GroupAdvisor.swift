import Foundation

/// Which way to hold the phone: sideways for groups and views, upright for one person.
public struct OrientationAdvisor: Sendable {
    public init() {}

    /// Three or more people is a group that usually wants a landscape frame.
    public static let groupSize = 3

    public func evaluate(_ s: FrameSnapshot, mode: CaptureMode, shot: ShotType) -> [Guidance] {
        let sideways = s.camera.orientation.isLandscape
        let people = max(s.personCount, s.faces.count)

        switch mode {
        case .scenery:
            guard !sideways else { return [] }
            return [Guidance("scene.sideways", .framing, .tip, .photographer,
                             "Turn the phone sideways for the view",
                             reason: "Wide views — coastlines, skylines, mountains, rooms — fill a landscape frame. Keep it upright only for tall subjects like towers, trees and waterfalls.",
                             cue: .turnSideways)]

        case .portrait, .environmental:
            if people >= Self.groupSize, !sideways {
                return [Guidance("group.sideways", .framing, .tip, .photographer,
                                 "\(people) people — turn the phone sideways",
                                 reason: "A group is wider than it is tall. Sideways, everyone fits without making the faces tiny.",
                                 cue: .turnSideways)]
            }
            if mode == .portrait, people == 1, sideways {
                return [Guidance("frame.upright", .framing, .tip, .photographer,
                                 "One person — turn the phone upright",
                                 reason: "An upright frame fits one person and avoids empty space either side. If the place matters, keep it sideways and switch to Person + Place.",
                                 cue: .turnUpright)]
            }
            return []
        }
    }
}

/// Framing for two or more people: nobody cut off at the edges, the group
/// centred, everyone at a similar distance from the lens.
public struct GroupAdvisor: Sendable {
    public init() {}

    public func evaluate(_ s: FrameSnapshot) -> [Guidance] {
        let faces = s.faces
        guard faces.count >= 2 else { return [] }
        var out: [Guidance] = []

        let left = faces.map(\.minX).min()!, right = faces.map(\.maxX).max()!
        let top = faces.map(\.minY).min()!
        let cutLeft = left < 0.02, cutRight = right > 0.98

        if cutLeft && cutRight {
            out.append(Guidance("group.cutBoth", .framing, .fix, .photographer,
                                "People cut off both sides — step back",
                                reason: "Every face in a group photo should be fully in frame. Step back, or go wider with 0.5×.",
                                cue: .moveBack))
        } else if cutLeft || cutRight {
            let side = cutLeft ? "left" : "right"
            out.append(Guidance("group.cutSide", .framing, .fix, .photographer,
                                "Someone's cut off on the \(side) — aim a little \(side)",
                                reason: "Every face in a group photo should be fully in frame, with a little space beyond the last person.",
                                cue: cutLeft ? .moveLeft : .moveRight))
        } else {
            let centre = (left + right) / 2
            if abs(centre - 0.5) > 0.15 {
                let side = centre < 0.5 ? "left" : "right"
                out.append(Guidance("group.offCentre", .framing, .tip, .photographer,
                                    "Aim a little \(side) to centre the group",
                                    reason: "A group usually looks best centred, with even space either side.",
                                    cue: centre < 0.5 ? .moveLeft : .moveRight))
            }
        }
        if top < 0.01 {
            out.append(Guidance("group.headCut", .framing, .fix, .photographer,
                                "A head is cut off at the top — tilt up or step back",
                                reason: "Keep a little space above the tallest person.",
                                cue: .moveBack))
        }

        // Faces at very different sizes = people at very different distances.
        let widths = faces.map(\.width)
        if let big = widths.max(), let small = widths.min(), small > 0, big / small > 1.7 {
            out.append(Guidance("group.depth", .pose, .tip, .subject,
                                "Everyone line up at the same distance",
                                reason: "People closer to the lens look bigger and can be sharp while the back row blurs. Step into one line, or two close rows, and stagger heads at different heights.",
                                cue: nil))
        }
        return out
    }

    /// Single-subject rules that don't make sense for a group.
    static let singleSubjectRules: Set<String> = ["frame.offCentre", "frame.lookRoom", "env.thirds"]
}

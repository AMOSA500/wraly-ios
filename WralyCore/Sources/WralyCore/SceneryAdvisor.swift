import Foundation

/// What the photographer is shooting.
public enum CaptureMode: String, CaseIterable, Identifiable, Sendable {
    /// Wraly works out what's in front of the camera and picks one of the others.
    case auto
    /// A person is the picture (headshot … full body).
    case portrait
    /// You, on the front camera: Wraly coaches you directly.
    case selfie
    /// A person small in a place — the setting matters as much as they do.
    case environmental
    /// Nature views: horizon, sky, land and water.
    case landscape
    /// Built and indoor views: cities, buildings, streets, rooms.
    case scenery
    /// A thing: food, a pet, a flower, a product, a document.
    case object

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .auto: return "Auto"
        case .portrait: return "Portrait"
        case .selfie: return "Selfie"
        case .environmental: return "Person + Place"
        case .landscape: return "Landscape"
        case .scenery: return "Scenery"
        case .object: return "Object"
        }
    }

    public var symbol: String {
        switch self {
        case .auto: return "sparkles"
        case .portrait: return "person.crop.rectangle"
        case .selfie: return "person.crop.circle"
        case .environmental: return "figure.walk"
        case .landscape: return "mountain.2"
        case .scenery: return "building.2"
        case .object: return "cube"
        }
    }

    public var needsPerson: Bool { self == .portrait || self == .environmental || self == .selfie }
    /// Shot on the front camera.
    public var usesFrontCamera: Bool { self == .selfie }
    /// Someone else is being photographed (so there's a subject to direct).
    public var directsSubject: Bool { self == .portrait || self == .environmental }
    /// A view with no person: landscape or scenery.
    public var isView: Bool { self == .landscape || self == .scenery }
}

/// Composition and handling for views: level horizon, straight verticals,
/// a steady phone, the widest lens when it helps.
public struct SceneryAdvisor: Sendable {
    public init() {}

    /// `strictVerticals`: buildings and rooms, where leaning walls are the first thing you notice.
    public func evaluate(_ s: FrameSnapshot, strictVerticals: Bool = false) -> [Guidance] {
        var out: [Guidance] = []

        if let att = s.attitude {
            // A crooked horizon is the most visible flaw in a landscape — stricter than portraits.
            if abs(att.rollDegrees) > 1.5 {
                out.append(Guidance("scene.level", .cameraAngle, abs(att.rollDegrees) > 3 ? .fix : .tip, .photographer,
                                    att.rollDegrees > 0 ? "Level the horizon — turn it slightly left" : "Level the horizon — turn it slightly right",
                                    reason: "Even a 2° tilt makes the sea look like it's draining away. Line the horizon up with the level line.",
                                    cue: att.rollDegrees > 0 ? .rotateCounterClockwise : .rotateClockwise))
            }
            // Pointing up at buildings makes them lean backwards.
            if abs(att.pitchDegrees) > (strictVerticals ? 5 : 10) {
                out.append(Guidance("scene.verticals", .cameraAngle, .tip, .photographer,
                                    att.pitchDegrees > 0 ? "Hold the phone upright — buildings will lean back" : "Hold the phone upright — verticals will lean",
                                    reason: "Tilting the phone makes vertical lines converge. Keep it upright and step back or go wider to fit the top in.",
                                    cue: att.pitchDegrees > 0 ? .tiltDown : .tiltUp))
            }
        }

        if let light = s.light {
            if light.ev100 < 3 {
                out.append(Guidance("scene.dark", .light, .tip, .photographer,
                                    "Low light — brace the phone on something",
                                    reason: "Rest the phone on a wall or railing and hold your breath. Wraly takes several frames and keeps the sharpest.",
                                    cue: .wait))
            }
            if light.clippedHighlights > 0.08 {
                out.append(Guidance("scene.brightSky", .light, .tip, .photographer,
                                    "Bright sky — exposing to keep the clouds",
                                    reason: "Wraly is darkening the exposure so the sky keeps its detail. Shadows can be lifted later; blown white sky can't.",
                                    cue: nil))
            }
        }

        if s.personCount > 0 {
            out.append(Guidance("scene.person", .subject, .tip, .photographer,
                                "Someone's in the view — wait, or try Person + Place",
                                reason: "For a clean view, wait for people to move out of frame. If they belong in the picture, switch to Person + Place.",
                                cue: .wait))
        }

        let c = s.camera
        if abs(c.zoomFactor - 1) < 0.05, c.opticalZoomStops.contains(where: { $0 < 0.9 }) {
            out.append(Guidance("scene.goWide", .lensChoice, .tip, .photographer,
                                "Try 0.5× for a wider view",
                                reason: "The ultra-wide lens fits big views and small rooms. Include something close in the foreground for depth, and put the horizon on the top or bottom grid line.",
                                cue: .zoomOut))
        }
        return out
    }
}

/// Framing for a person shown in their surroundings: small enough to show the
/// place, placed on a third line, feet included.
public struct EnvironmentalFramingAdvisor: Sendable {
    public init() {}

    public func evaluate(_ s: FrameSnapshot, metrics m: SubjectMetrics) -> [Guidance] {
        var out: [Guidance] = []
        let L = m.ladder
        let figure = L.figureHeight

        if figure > 0.7 {
            out.append(Guidance("env.tooBig", .framing, .fix, .photographer,
                                "Step back to show more of the place",
                                reason: "In an environmental portrait the setting tells the story. Let the person fill about a quarter to two-thirds of the frame height.",
                                cue: .moveBack))
        } else if figure < 0.12 {
            out.append(Guidance("env.tooSmall", .framing, .tip, .photographer,
                                "They're very small — step a little closer",
                                reason: "Below about a tenth of the frame the person gets lost and their face can't be read.",
                                cue: .moveCloser))
        }

        if L[.soles] > 1.0, figure <= 0.7 {
            out.append(Guidance("env.feetCut", .framing, .fix, .photographer,
                                "Show their feet — step back a little",
                                reason: "With this much space around them, cut-off feet look like a mistake.",
                                cue: .moveBack))
        }
        if L[.crown] < 0.02 {
            out.append(Guidance("env.headCut", .framing, .fix, .photographer,
                                "Head is cut off — step back",
                                reason: "Keep the whole person in frame when you're showing the place around them.",
                                cue: .moveBack))
        }

        // Place them on a vertical third line, with room in front of where they look.
        let off = m.horizontalOffset          // −0.5 … 0.5 from centre
        let third = 1.0 / 6                    // a third line is 1/6 of the width from centre
        let look = FramingAdvisor.lookDirection(s) ?? 0
        let target = look > 0.3 ? -third : look < -0.3 ? third : (off >= 0 ? third : -third)
        if abs(off - target) > 0.1 {
            // Aiming right moves the scene (and them) left in the frame.
            let aimRight = off > target
            let side = target < 0 ? "left" : "right"
            out.append(Guidance("env.thirds", .framing, abs(off) > 0.38 ? .fix : .tip, .photographer,
                                aimRight ? "Aim a little right — put them on the \(side) third" : "Aim a little left — put them on the \(side) third",
                                reason: "Off-centre on a grid line feels natural and leaves room for the scene. Leave the open side in front of where they're looking.",
                                cue: aimRight ? .moveRight : .moveLeft))
        }
        return out
    }
}

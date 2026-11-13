import Foundation

/// Who has to act on an instruction.
public enum Audience: String, Sendable {
    /// The person holding the phone.
    case photographer
    /// The person being photographed (the photographer relays it, or Wraly speaks it aloud).
    case subject
}

/// Broad groups, listed in the order a working photographer fixes them:
/// you can't pose someone well in a frame you will throw away, and you can't
/// frame well through a greasy lens.
public enum GuidanceCategory: Int, Comparable, Sendable {
    case lens = 0        // dirty lens — ruins every shot, fix first
    case subject         // no person / too many people
    case light           // backlight, harsh sun, low light
    case lensChoice      // focal length / distortion
    case cameraAngle     // height, tilt, level
    case framing         // headroom, thirds, cropping at joints, size
    case background      // mergers, clutter, distractions
    case pose            // head, shoulders, arms, legs
    case expression      // eyes, gaze, timing

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public enum Severity: Int, Comparable, Sendable {
    /// Nice to have — won't block auto capture.
    case tip = 0
    /// Noticeably weaker photo — blocks auto capture.
    case fix = 1
    /// The photo will fail — blocks auto capture and is shown first.
    case critical = 2

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// A direction cue drawn on screen next to the instruction.
public enum Cue: String, Sendable {
    case moveLeft, moveRight, moveCloser, moveBack
    case raisePhone, lowerPhone, tiltUp, tiltDown
    case rotateClockwise, rotateCounterClockwise
    case zoomIn, zoomOut
    case wipeLens, wait, turnAround
}

public struct Guidance: Identifiable, Equatable, Sendable {
    /// Stable identifier for the rule that produced it (used for debouncing).
    public let id: String
    public let category: GuidanceCategory
    public let severity: Severity
    public let audience: Audience
    /// Short on-screen text (aim for < 40 characters).
    public let message: String
    /// The "why" a photographer would give — shown on tap, never spoken.
    public let reason: String
    public let cue: Cue?

    public init(_ id: String, _ category: GuidanceCategory, _ severity: Severity, _ audience: Audience,
                _ message: String, reason: String, cue: Cue? = nil) {
        self.id = id; self.category = category; self.severity = severity
        self.audience = audience; self.message = message; self.reason = reason; self.cue = cue
    }

    /// What a pro would fix first.
    public static func priority(_ a: Guidance, _ b: Guidance) -> Bool {
        if a.severity != b.severity { return a.severity > b.severity }
        return a.category < b.category
    }
}

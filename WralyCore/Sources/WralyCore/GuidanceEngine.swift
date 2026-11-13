import Foundation

/// The coach's output for one frame.
public struct CoachState: Equatable, Sendable {
    /// The single instruction to show/speak now (a photographer gives one at a time).
    public var primary: Guidance?
    /// Everything currently wrong, in priority order (for the detail sheet).
    public var all: [Guidance]
    /// 0...1 — how close the frame is to "take it".
    public var readiness: Double
    /// True when nothing blocking has been seen for the hold period.
    public var readyToCapture: Bool
    public var metrics: SubjectMetrics?
    public var plan: CapturePlan
    public var shot: ShotType

    public static let empty = CoachState(primary: nil, all: [], readiness: 0, readyToCapture: false,
                                         metrics: nil, plan: .neutral, shot: .halfBody)
}

/// Runs every advisor and turns their raw, per-frame output into calm,
/// one-at-a-time coaching: issues must persist before they're shown, the
/// shown instruction sticks for a moment, and tips don't nag.
public final class GuidanceEngine {
    public struct Tuning: Sendable {
        /// An issue must be present this long before it is shown.
        public var onset: TimeInterval = 0.35
        /// A shown instruction stays at least this long (unless it's fixed).
        public var minimumDisplay: TimeInterval = 1.6
        /// A fixed issue must stay fixed this long before it's cleared.
        public var release: TimeInterval = 0.4
        /// Nothing blocking for this long → ready to capture.
        public var captureHold: TimeInterval = 0.7
        /// A tip shown once is suppressed for this long.
        public var tipCooldown: TimeInterval = 25
        public var tipDisplay: TimeInterval = 3.5
        public init() {}
    }

    public var tuning = Tuning()
    /// nil = automatic: coach whatever shot the photographer is already framing.
    public var targetShot: ShotType?

    private let framing = FramingAdvisor()
    private let angle = CameraAngleAdvisor()
    private let lens = LensAdvisor()
    private let lighting = LightingAdvisor()
    private let background = BackgroundAdvisor()
    private let pose = PoseAdvisor()
    private let expression = ExpressionAdvisor()
    private let planner = CapturePlanner()

    private var firstSeen: [String: TimeInterval] = [:]
    private var lastSeen: [String: TimeInterval] = [:]
    private var tipShownAt: [String: TimeInterval] = [:]
    private var current: (g: Guidance, since: TimeInterval)?
    private var lastBlockingAt: TimeInterval = -.infinity
    private var autoShot: ShotType = .halfBody
    private var pendingShot: ShotType?
    private var pendingShotFrames = 0

    public init(targetShot: ShotType? = nil) { self.targetShot = targetShot }

    public func reset() {
        firstSeen.removeAll(); lastSeen.removeAll(); current = nil
        lastBlockingAt = -.infinity
    }

    /// Raw, unstabilised evaluation — useful for tests and debugging.
    public func evaluate(_ s: FrameSnapshot) -> (issues: [Guidance], metrics: SubjectMetrics?, shot: ShotType) {
        let metrics = SubjectMetrics(snapshot: s)
        let shot = targetShot ?? stickyAutoShot(metrics?.currentShot)
        var issues = expression.evaluate(s, metrics: metrics)
        issues += lens.evaluate(s, metrics: metrics, target: shot)
        issues += lighting.evaluate(s, metrics: metrics)
        issues += angle.evaluate(s, metrics: metrics, target: shot)
        if let metrics {
            issues += framing.evaluate(s, metrics: metrics, target: shot)
        }
        issues += background.evaluate(s, metrics: metrics)
        issues += pose.evaluate(s, metrics: metrics, target: shot)

        // De-duplicate by id, keep priority order.
        var seen = Set<String>()
        issues = issues.filter { seen.insert($0.id).inserted }.sorted(by: Guidance.priority)
        return (issues, metrics, shot)
    }

    public func update(_ s: FrameSnapshot) -> CoachState {
        let now = s.timestamp
        let (issues, metrics, shot) = evaluate(s)

        // Track persistence.
        let ids = Set(issues.map(\.id))
        for g in issues {
            if firstSeen[g.id] == nil { firstSeen[g.id] = now }
            lastSeen[g.id] = now
        }
        for (id, t) in lastSeen where !ids.contains(id) && now - t > tuning.release {
            firstSeen[id] = nil; lastSeen[id] = nil
        }
        let established = issues.filter { g in
            g.severity == .critical || now - (firstSeen[g.id] ?? now) >= tuning.onset
        }

        // Readiness / capture gate.
        let blocking = established.filter { $0.severity >= .fix }
        if !blocking.isEmpty || s.personCount == 0 { lastBlockingAt = now }
        let eyesOK = s.face?.eyesOpen ?? false
        let ready = blocking.isEmpty && s.personCount > 0 && eyesOK && now - lastBlockingAt >= tuning.captureHold
        let penalty = established.reduce(0.0) { acc, g in
            acc + (g.severity == .critical ? 0.6 : g.severity == .fix ? 0.18 : 0.03)
        }
        let readiness = s.personCount == 0 ? 0 : max(0, min(1, 1 - penalty))

        // Choose the single instruction to show.
        let primary = choosePrimary(established, now: now)

        let plan = planner.plan(for: s, metrics: metrics, target: shot)
        return CoachState(primary: primary, all: established, readiness: readiness,
                          readyToCapture: ready, metrics: metrics, plan: plan, shot: shot)
    }

    private func choosePrimary(_ issues: [Guidance], now: TimeInterval) -> Guidance? {
        let blocking = issues.filter { $0.severity >= .fix }
        let best = blocking.first

        if let cur = current {
            let stillPresent = issues.contains { $0.id == cur.g.id }
            let shownLongEnough = now - cur.since >= (cur.g.severity == .tip ? tuning.tipDisplay : tuning.minimumDisplay)
            let outranked = best.map { $0.severity > cur.g.severity } ?? false
            if stillPresent && !shownLongEnough && !outranked { return cur.g }
            if stillPresent && cur.g.severity >= .fix && best?.id == cur.g.id { return cur.g }
        }

        if let best {
            if current?.g.id != best.id { current = (best, now) }
            return best
        }

        // Nothing blocking: offer one tip that hasn't been shown recently.
        if let cur = current, cur.g.severity == .tip, now - cur.since < tuning.tipDisplay,
           issues.contains(where: { $0.id == cur.g.id }) {
            return cur.g
        }
        if let tip = issues.first(where: { now - (tipShownAt[$0.id] ?? -.infinity) > tuning.tipCooldown }) {
            tipShownAt[tip.id] = now
            current = (tip, now)
            return tip
        }
        current = nil
        return nil
    }

    /// In automatic mode, don't flip the shot type on every frame as the subject moves.
    private func stickyAutoShot(_ detected: ShotType?) -> ShotType {
        guard let detected, detected != autoShot else { pendingShotFrames = 0; return autoShot }
        if detected == pendingShot {
            pendingShotFrames += 1
        } else {
            pendingShot = detected; pendingShotFrames = 1
        }
        if pendingShotFrames >= 6 { autoShot = detected; pendingShotFrames = 0 }
        return autoShot
    }
}

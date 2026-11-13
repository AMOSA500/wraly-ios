import Foundation

/// Detects a fingerprint / greasy film on the lens.
///
/// A smudge acts like a weak diffusion filter. Three things give it away, and
/// none of them is "the picture is blurry" on its own (that's just bad focus):
///
/// 1. **Low micro-contrast while focus reports locked.** Edges exist, but every
///    one is soft relative to the scene's overall contrast.
/// 2. **Halation.** Bright areas bleed a wide glow into their surroundings.
/// 3. **Veiling glare.** Scattered light lifts the blacks — the darkest 1% of
///    the frame never gets truly dark when there's a bright source in view.
///
/// Because a single frame can fool any one cue (fog, a plain wall, a soft
/// scene), the score is a slow moving average over frames with enough detail.
public struct LensSmudgeEstimator: Sendable {
    public struct Features: Sendable {
        /// Mean absolute Laplacian of luma (0...1 luma units).
        public var edgeEnergy: Double
        /// Standard deviation of luma (0...1).
        public var contrast: Double
        /// Mean luma in a ring around clipped highlights minus the frame mean (0...1); nil if no highlights.
        public var haloLift: Double?
        /// 1st-percentile luma (0...1).
        public var blackLevel: Double
        /// Fraction of clipped pixels.
        public var clipped: Double

        public init(edgeEnergy: Double, contrast: Double, haloLift: Double?, blackLevel: Double, clipped: Double) {
            self.edgeEnergy = edgeEnergy; self.contrast = contrast; self.haloLift = haloLift
            self.blackLevel = blackLevel; self.clipped = clipped
        }
    }

    public private(set) var score: Double = 0
    private var samples = 0
    /// Smoothing factor per accepted frame (~3 s at 10 fps analysis).
    public var alpha = 0.035

    public init() {}

    /// Per-frame raw likelihood 0...1, or nil when the frame isn't informative.
    public static func frameLikelihood(_ f: Features) -> Double? {
        guard f.contrast > 0.07 else { return nil } // plain wall / dark room: can't judge

        // Sharp, clean phone frames have edgeEnergy/contrast around 0.25–0.6.
        let crispness = f.edgeEnergy / f.contrast
        let soft = clamp((0.22 - crispness) / 0.14)

        var haze = 0.0
        if let halo = f.haloLift, f.clipped > 0.002 {
            haze = clamp((halo - 0.12) / 0.25)
        }
        let veil = f.clipped > 0.002 ? clamp((f.blackLevel - 0.06) / 0.12) : 0

        // Softness alone is weak evidence; softness + glow is strong.
        return clamp(0.45 * soft + 0.35 * haze + 0.2 * veil + (soft > 0.5 && haze > 0.4 ? 0.15 : 0))
    }

    /// Feed one frame. Only frames with settled focus count.
    public mutating func add(_ f: Features, focusSettled: Bool) {
        guard focusSettled, let p = Self.frameLikelihood(f) else { return }
        samples += 1
        // Faster warm-up for the first few samples, then a slow average.
        let a = samples < 10 ? 1.0 / Double(samples) : alpha
        score += (p - score) * a
    }

    /// Call after the user confirms they wiped the lens.
    public mutating func reset() { score = 0; samples = 0 }

    /// Not enough evidence yet.
    public var isConfident: Bool { samples >= 15 }

    private static func clamp(_ v: Double) -> Double { max(0, min(1, v)) }
}

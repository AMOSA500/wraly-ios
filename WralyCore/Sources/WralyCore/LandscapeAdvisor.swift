import Foundation

/// Where the horizon is and how the frame divides into sky and land,
/// measured from a small luma image of the frame.
public struct SceneLayout: Equatable, Sendable {
    /// Horizon height, 0 (top) … 1 (bottom), at the frame centre.
    public var horizonY: Double
    /// The horizon's own slope in degrees. Positive = it drops toward the right.
    public var horizonTiltDegrees: Double?
    /// 0 … 1: how clear the sky/land step is. Above ~0.5 is a real horizon.
    public var confidence: Double
    /// Fine detail above vs below the horizon (> 1 = the sky is more interesting).
    public var skyDetailRatio: Double
    /// Fine detail in the bottom third vs the whole frame (< 0.6 = empty foreground).
    public var foregroundDetail: Double

    public init(horizonY: Double, horizonTiltDegrees: Double?, confidence: Double,
                skyDetailRatio: Double, foregroundDetail: Double) {
        self.horizonY = horizonY; self.horizonTiltDegrees = horizonTiltDegrees; self.confidence = confidence
        self.skyDetailRatio = skyDetailRatio; self.foregroundDetail = foregroundDetail
    }

    /// Finds the strongest bright-above/dark-below step (sky over land or sea).
    /// `luma` is row-major 0…1, top-left origin; `aspect` is width / height.
    public static func analyze(luma: [Float], width w: Int, height h: Int, aspect: Double) -> SceneLayout? {
        guard w >= 16, h >= 16, luma.count == w * h else { return nil }
        func rowMeans(_ x0: Int, _ x1: Int) -> [Double] {
            (0..<h).map { y in
                var s = 0.0
                for x in x0..<x1 { s += Double(luma[y * w + x]) }
                return s / Double(x1 - x0)
            }
        }
        let band = max(2, h / 24)
        /// Best step row (with sub-row refinement) and its strength, searching `range`.
        func step(_ m: [Double], in range: ClosedRange<Int>) -> (y: Double, strength: Double)? {
            var best: (Int, Double)?
            for y in range where y - band >= 0 && y + band < h {
                var above = 0.0, below = 0.0
                for k in 1...band { above += m[y - k]; below += m[y + k] }
                let d = (above - below) / Double(band)
                if d > (best?.1 ?? 0) { best = (y, d) }
            }
            guard let (y, d) = best else { return nil }
            // Parabola through the neighbouring step strengths for a sub-row estimate.
            func strength(_ yy: Int) -> Double {
                guard yy - band >= 0, yy + band < h else { return d }
                var a = 0.0, b = 0.0
                for k in 1...band { a += m[yy - k]; b += m[yy + k] }
                return (a - b) / Double(band)
            }
            let l = strength(y - 1), r = strength(y + 1), denom = l - 2 * d + r
            let offset = abs(denom) > 1e-9 ? max(-0.5, min(0.5, 0.5 * (l - r) / denom)) : 0
            return (Double(y) + 0.5 + offset, d)
        }

        guard let whole = step(rowMeans(0, w), in: (h / 10)...(h * 9 / 10)) else { return nil }
        let confidence = min(1, whole.strength / 0.25)

        // Slope: find the step in vertical strips near the overall horizon and fit a line.
        let strips = 8, sw = w / strips
        let window = max(3, h / 8)
        let centre = Int(whole.y)
        var pts: [(x: Double, y: Double)] = []
        for i in 0..<strips {
            let m = rowMeans(i * sw, (i + 1) * sw)
            let lo = max(band, centre - window), hi = min(h - band - 1, centre + window)
            if lo < hi, let s = step(m, in: lo...hi), s.strength > 0.05 {
                pts.append(((Double(i) + 0.5) / Double(strips), s.y / Double(h)))
            }
        }
        var tilt: Double?
        if pts.count >= 5 {
            let mx = pts.map(\.x).reduce(0, +) / Double(pts.count)
            let my = pts.map(\.y).reduce(0, +) / Double(pts.count)
            let sxy = pts.reduce(0) { $0 + ($1.x - mx) * ($1.y - my) }
            let sxx = pts.reduce(0) { $0 + ($1.x - mx) * ($1.x - mx) }
            let slope = sxy / sxx
            let residual = pts.reduce(0) { $0 + abs($1.y - (my + slope * ($1.x - mx))) } / Double(pts.count)
            // A ragged edge (trees, hills) isn't a horizon to level to.
            if residual < 0.012 { tilt = atan2(slope / max(aspect, 0.1), 1) * 180 / .pi }
        }

        // Fine detail (|Laplacian|) above vs below, and in the bottom third.
        var above = 0.0, nAbove = 0, below = 0.0, nBelow = 0, fg = 0.0, nFg = 0, all = 0.0, nAll = 0
        let hy = Int(whole.y)
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let c = abs(4 * luma[y * w + x] - luma[y * w + x - 1] - luma[y * w + x + 1] - luma[(y - 1) * w + x] - luma[(y + 1) * w + x])
                let v = Double(c)
                all += v; nAll += 1
                if y < hy - band { above += v; nAbove += 1 } else if y > hy + band { below += v; nBelow += 1 }
                if y >= h * 2 / 3 { fg += v; nFg += 1 }
            }
        }
        let meanAll = all / Double(max(nAll, 1))
        let skyRatio = (above / Double(max(nAbove, 1))) / max(below / Double(max(nBelow, 1)), 1e-4)
        return SceneLayout(horizonY: whole.y / Double(h), horizonTiltDegrees: tilt, confidence: confidence,
                           skyDetailRatio: skyRatio, foregroundDetail: (fg / Double(max(nFg, 1))) / max(meanAll, 1e-4))
    }
}

/// Composition and light the way a landscape photographer sees it:
/// a level horizon on a third line, something in the foreground, good light.
public struct LandscapeAdvisor: Sendable {
    public init() {}

    public func evaluate(_ s: FrameSnapshot) -> [Guidance] {
        var out: [Guidance] = []

        if let L = s.scene, L.confidence >= 0.5 {
            // The phone can be level while the horizon in the picture isn't (lens, slope of the view).
            let phoneLevel = s.attitude.map { abs($0.rollDegrees) <= 1.5 } ?? true
            if phoneLevel, let t = L.horizonTiltDegrees, abs(t) > 1.2 {
                // Drops to the right → turn the phone clockwise (right) to bring it level.
                out.append(Guidance("land.horizonTilt", .cameraAngle, abs(t) > 2.5 ? .fix : .tip, .photographer,
                                    t > 0 ? "Horizon is tilted — turn slightly right" : "Horizon is tilted — turn slightly left",
                                    reason: "The phone is level but the horizon in the picture isn't. Line the horizon up with a grid line.",
                                    cue: t > 0 ? .rotateClockwise : .rotateCounterClockwise))
            }

            if abs(L.horizonY - 0.5) < 0.07 {
                let skyWins = L.skyDetailRatio > 1.1
                out.append(Guidance("land.horizonThirds", .framing, .tip, .photographer,
                                    skyWins ? "Great sky — put the horizon on the lower line" : "Put the horizon on the upper line",
                                    reason: skyWins
                                        ? "A horizon through the middle splits the picture in two. With an interesting sky, give it two-thirds of the frame."
                                        : "A horizon through the middle splits the picture in two. When the sky is plain, give the land or water two-thirds.",
                                    cue: skyWins ? .tiltUp : .tiltDown))
            }

            if L.foregroundDetail < 0.55, s.camera.equivalentFocalLength < 35 {
                out.append(Guidance("land.foreground", .framing, .tip, .photographer,
                                    "Add something in the foreground",
                                    reason: "Rocks, flowers, a path or a fence in the bottom third give a wide view depth and lead the eye in. Get low and close to it.",
                                    cue: .lowerPhone))
            }
        }

        if let sun = s.sun {
            switch sun.phase {
            case .goldenHour:
                out.append(Guidance("land.golden", .light, .tip, .photographer,
                                    "Golden hour — the best landscape light",
                                    reason: "Low, warm sun brings out texture and long shadows. Side light shows the shape of the land best.", cue: nil))
            case .blueHour:
                out.append(Guidance("land.blue", .light, .tip, .photographer,
                                    "Blue hour — brace the phone and hold still",
                                    reason: "Deep blue sky and city lights balance for a few minutes after sunset. Rest the phone on something solid.", cue: .wait))
            case .midday:
                out.append(Guidance("land.midday", .light, .tip, .photographer,
                                    "Flat midday light — early or late is better",
                                    reason: "A high sun flattens hills and washes out colour. If you can, come back within an hour of sunrise or sunset. Look for water or strong shapes instead.", cue: nil))
            default: break
            }
            if let r = sun.relativeToCamera, abs(r) < 25, sun.elevation > 0, sun.elevation < 30 {
                out.append(Guidance("land.intoSun", .light, .tip, .photographer,
                                    "Shooting into the sun — hide it behind something",
                                    reason: "Put the sun just behind a tree, rock or building edge for a starburst without flare, or keep a finger's shade over the lens.", cue: nil))
            }
        }
        return out
    }

    /// Scene labels that mean "this is a view, not a person shot".
    public static let viewLabels: Set<String> = [
        "sky", "mountain", "landscape", "beach", "ocean", "sea", "lake", "river", "forest", "field",
        "sunset_sunrise", "hill", "shore", "waterfall", "desert", "snow", "cityscape", "skyline", "canyon", "coast",
    ]
}

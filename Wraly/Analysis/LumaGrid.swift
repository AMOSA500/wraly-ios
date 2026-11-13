import CoreVideo
import Foundation
import WralyCore

/// A small luma image (e.g. 72×96) sampled straight from the camera's Y plane.
/// Everything that needs pixels — exposure stats, lens haze, background clutter,
/// mergers — runs on this grid, so it costs well under a millisecond per frame.
struct LumaGrid {
    let width: Int
    let height: Int
    var values: [Float] // 0...1, row-major, top-left origin

    init?(pixelBuffer pb: CVPixelBuffer, width: Int = 72, height: Int = 96) {
        guard CVPixelBufferGetPlaneCount(pb) >= 1 else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return nil }
        let srcW = CVPixelBufferGetWidthOfPlane(pb, 0)
        let srcH = CVPixelBufferGetHeightOfPlane(pb, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        self.width = width; self.height = height
        var out = [Float](repeating: 0, count: width * height)
        // Box-average a 2×2 block per sample to suppress sensor noise.
        for gy in 0..<height {
            let sy = min(srcH - 2, gy * srcH / height)
            for gx in 0..<width {
                let sx = min(srcW - 2, gx * srcW / width)
                let i = sy * stride + sx
                let sum = Int(ptr[i]) + Int(ptr[i + 1]) + Int(ptr[i + stride]) + Int(ptr[i + stride + 1])
                out[gy * width + gx] = Float(sum) / (4 * 255)
            }
        }
        values = out
    }

    init(width: Int, height: Int, values: [Float]) {
        self.width = width; self.height = height; self.values = values
    }

    /// Samples a one-component 8-bit mask (e.g. person segmentation) onto the same grid.
    static func mask(from pb: CVPixelBuffer, width: Int, height: Int) -> [Bool]? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let stride = CVPixelBufferGetBytesPerRow(pb)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        var out = [Bool](repeating: false, count: width * height)
        for gy in 0..<height {
            let sy = min(h - 1, gy * h / height)
            for gx in 0..<width {
                let sx = min(w - 1, gx * w / width)
                out[gy * width + gx] = ptr[sy * stride + sx] > 127
            }
        }
        return out
    }

    @inline(__always) func at(_ x: Int, _ y: Int) -> Float { values[y * width + x] }

    // MARK: - Statistics

    struct Stats {
        var mean: Double
        var clipped: Double
        var crushed: Double
        var blackLevel: Double  // 1st percentile
        var contrast: Double    // std dev
        var edgeEnergy: Double  // mean |laplacian|
        var haloLift: Double?
    }

    func stats() -> Stats {
        let n = Double(values.count)
        var sum = 0.0, sumSq = 0.0, clipped = 0, crushed = 0
        var hist = [Int](repeating: 0, count: 64)
        for v in values {
            let d = Double(v)
            sum += d; sumSq += d * d
            if v >= 0.98 { clipped += 1 }
            if v <= 0.02 { crushed += 1 }
            hist[min(63, Int(v * 64))] += 1
        }
        let mean = sum / n
        let contrast = sqrt(max(0, sumSq / n - mean * mean))

        var acc = 0, black = 0.0
        for (i, c) in hist.enumerated() {
            acc += c
            if Double(acc) >= n * 0.01 { black = Double(i) / 64; break }
        }

        var lap = 0.0, lapN = 0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let c = at(x, y) * 4 - at(x - 1, y) - at(x + 1, y) - at(x, y - 1) - at(x, y + 1)
                lap += Double(abs(c)); lapN += 1
            }
        }

        return Stats(mean: mean, clipped: Double(clipped) / n, crushed: Double(crushed) / n,
                     blackLevel: black, contrast: contrast, edgeEnergy: lap / Double(max(lapN, 1)),
                     haloLift: haloLift(mean: mean))
    }

    /// Mean luma in a ring 2–4 cells around clipped highlights, minus the frame mean.
    /// A clean lens falls off fast around a light; a smudged one glows.
    private func haloLift(mean: Double) -> Double? {
        var clippedMask = [Bool](repeating: false, count: values.count)
        var any = false
        for i in values.indices where values[i] >= 0.98 { clippedMask[i] = true; any = true }
        guard any else { return nil }
        var ringSum = 0.0, ringN = 0
        for y in 0..<height {
            for x in 0..<width where !clippedMask[y * width + x] {
                var nearest = Int.max
                for dy in -4...4 {
                    let yy = y + dy
                    guard yy >= 0, yy < height else { continue }
                    for dx in -4...4 {
                        let xx = x + dx
                        guard xx >= 0, xx < width, clippedMask[yy * width + xx] else { continue }
                        nearest = min(nearest, max(abs(dx), abs(dy)))
                    }
                }
                if nearest >= 2 && nearest <= 4 { ringSum += Double(at(x, y)); ringN += 1 }
            }
        }
        guard ringN > 8 else { return nil }
        return ringSum / Double(ringN) - mean
    }

    // MARK: - Subject vs background

    struct Regions {
        var subjectLuma: Double?
        var backgroundLuma: Double?
        var clutter: Double
        var backgroundSharpnessRatio: Double?
        var merger: Bool
        var brightEdge: Bool
    }

    func regions(person mask: [Bool]?, face: Rect2?) -> Regions {
        var subj = 0.0, subjN = 0, bg = 0.0, bgN = 0
        var subjEdge = 0.0, bgEdge = 0.0, subjEdgeN = 0, bgEdgeN = 0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                let isPerson = mask?[i] ?? false
                let v = Double(values[i])
                let e = Double(abs(at(x, y) * 4 - at(x - 1, y) - at(x + 1, y) - at(x, y - 1) - at(x, y + 1)))
                if isPerson { subj += v; subjN += 1; subjEdge += e; subjEdgeN += 1 }
                else { bg += v; bgN += 1; bgEdge += e; bgEdgeN += 1 }
            }
        }
        let subjectLuma = mask != nil && subjN > 20 ? subj / Double(subjN) : nil
        let backgroundLuma = bgN > 20 ? bg / Double(bgN) : nil
        let bgE = bgEdgeN > 0 ? bgEdge / Double(bgEdgeN) : 0
        let sE = subjEdgeN > 0 ? subjEdge / Double(subjEdgeN) : 0
        // ~0.06 mean |laplacian| on this grid is a very busy scene (foliage, shelves, crowds).
        let clutter = min(1, bgE / 0.06)
        let sharpRatio = mask != nil && sE > 0.002 ? min(1.5, bgE / sE) : nil

        return Regions(subjectLuma: subjectLuma, backgroundLuma: backgroundLuma, clutter: clutter,
                       backgroundSharpnessRatio: sharpRatio,
                       merger: face.map { detectMerger(mask: mask, face: $0) } ?? false,
                       brightEdge: detectBrightEdge(mask: mask, subjectLuma: subjectLuma))
    }

    /// Looks for a strong vertical line (pole, tree trunk, door frame) in the
    /// background directly above and behind the head.
    private func detectMerger(mask: [Bool]?, face: Rect2) -> Bool {
        let x0 = max(1, Int((face.minX - face.width * 0.2) * Double(width)))
        let x1 = min(width - 2, Int((face.maxX + face.width * 0.2) * Double(width)))
        let y1 = min(height - 2, max(1, Int((face.minY - face.height * 0.1) * Double(height))))
        let y0 = max(1, Int((face.minY - face.height * 1.6) * Double(height)))
        guard x1 - x0 >= 3, y1 - y0 >= 3 else { return false }

        var columns: [Double] = []
        var horizontal = 0.0, count = 0
        for x in x0...x1 {
            var colSum = 0.0, colN = 0
            for y in y0...y1 {
                if mask?[y * width + x] == true { continue }
                colSum += Double(abs(at(x + 1, y) - at(x - 1, y)))
                horizontal += Double(abs(at(x, y + 1) - at(x, y - 1)))
                colN += 1; count += 1
            }
            columns.append(colN > 2 ? colSum / Double(colN) : 0)
        }
        guard count > 10, let peak = columns.max() else { return false }
        let sorted = columns.sorted()
        let median = sorted[sorted.count / 2]
        let meanH = horizontal / Double(count)
        // A consistent vertical edge: strong in one column, weak around it, and not just texture.
        return peak > 0.08 && peak > median * 3 && peak > meanH * 2
    }

    /// A background patch near the frame border that is much brighter than the subject.
    private func detectBrightEdge(mask: [Bool]?, subjectLuma: Double?) -> Bool {
        guard let s = subjectLuma else { return false }
        let border = max(2, width / 9)
        var bright = 0, total = 0
        for y in 0..<height {
            for x in 0..<width where x < border || x >= width - border || y < border || y >= height - border {
                let i = y * width + x
                if mask?[i] == true { continue }
                total += 1
                if Double(values[i]) > s + 0.35 && values[i] > 0.85 { bright += 1 }
            }
        }
        return total > 0 && Double(bright) / Double(total) > 0.06
    }

    /// Mean luma of the left and right halves of a face box, and clipped fraction.
    func faceLight(_ box: Rect2) -> (left: Double, right: Double, clipped: Double)? {
        let x0 = max(0, Int(box.minX * Double(width))), x1 = min(width - 1, Int(box.maxX * Double(width)))
        let y0 = max(0, Int((box.minY + box.height * 0.15) * Double(height)))
        let y1 = min(height - 1, Int((box.maxY - box.height * 0.1) * Double(height)))
        guard x1 - x0 >= 2, y1 - y0 >= 2 else { return nil }
        let mid = (x0 + x1) / 2
        var l = 0.0, ln = 0, r = 0.0, rn = 0, clipped = 0, n = 0
        for y in y0...y1 {
            for x in x0...x1 {
                let v = at(x, y)
                if x < mid { l += Double(v); ln += 1 } else { r += Double(v); rn += 1 }
                if v >= 0.97 { clipped += 1 }
                n += 1
            }
        }
        guard ln > 0, rn > 0 else { return nil }
        return (l / Double(ln), r / Double(rn), Double(clipped) / Double(n))
    }
}

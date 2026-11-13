import AVFoundation
import ImageIO
import Photos
import UIKit
import Vision

struct CapturedPhoto {
    let data: Data
    let preview: UIImage?
    /// How many frames were shot to get this one.
    let burstSize: Int
    /// Why this frame won (e.g. "eyes open, sharpest face").
    let note: String
}

/// Collects one or more photos from a burst and keeps the best: eyes open first,
/// then Vision's face capture quality (sharpness, expression, no motion blur).
final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate {
    var id: Int64 = 0
    private let expected: Int
    private var received: [Data] = []
    private var finished = 0
    private let completion: (Int64, Result<CapturedPhoto, Error>) -> Void
    private let lock = NSLock()

    init(expected: Int, completion: @escaping (Int64, Result<CapturedPhoto, Error>) -> Void) {
        self.expected = expected
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let data = photo.fileDataRepresentation(), error == nil {
            lock.withLock { received.append(data) }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        let done: Bool = lock.withLock { finished += 1; return finished == expected }
        guard done else { return }
        let frames = lock.withLock { received }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            guard !frames.isEmpty else {
                completion(id, .failure(error ?? CocoaError(.fileWriteUnknown)))
                return
            }
            let (best, note) = BestShotPicker.pick(frames)
            PhotoSaver.save(best) { result in
                switch result {
                case .success:
                    let image = UIImage(data: best)
                    let wide = (image?.size.width ?? 0) > (image?.size.height ?? 1)
                    let thumb = image?.preparingThumbnail(of: wide ? CGSize(width: 320, height: 240) : CGSize(width: 240, height: 320))
                    self.completion(self.id, .success(CapturedPhoto(data: best, preview: thumb,
                                                                    burstSize: frames.count, note: note)))
                case .failure(let e):
                    self.completion(self.id, .failure(e))
                }
            }
        }
    }
}

enum BestShotPicker {
    static func pick(_ frames: [Data]) -> (Data, String) {
        guard frames.count > 1 else { return (frames[0], "single frame") }
        let images = frames.map(thumbnail)
        var best: (data: Data, score: Double, eyes: Bool)?
        var sawFace = false
        for (data, image) in zip(frames, images) {
            guard let image else { continue }
            let handler = VNImageRequestHandler(cgImage: image, orientation: orientation(data))
            let landmarks = VNDetectFaceLandmarksRequest()
            let quality = VNDetectFaceCaptureQualityRequest()
            try? handler.perform([landmarks, quality])
            let face = (quality.results ?? []).max { ($0.faceCaptureQuality ?? 0) < ($1.faceCaptureQuality ?? 0) }
            if face != nil { sawFace = true }
            let q = Double(face?.faceCaptureQuality ?? 0)
            let eyes = (landmarks.results ?? []).first.map(eyesOpen) ?? true
            let score = q + (eyes ? 1 : 0)
            if best == nil || score > best!.score { best = (data, score, eyes) }
        }
        // No faces anywhere (scenery): keep the frame with the crispest detail.
        if !sawFace {
            let scored = zip(frames, images).compactMap { d, img in img.map { (d, sharpness($0)) } }
            if let sharpest = scored.max(by: { $0.1 < $1.1 }) {
                return (sharpest.0, "sharpest of \(frames.count)")
            }
        }
        guard let best else { return (frames[0], "first frame") }
        return (best.data, best.eyes ? "best of \(frames.count): eyes open, sharpest face" : "best of \(frames.count)")
    }

    /// Variance of the Laplacian on a small greyscale copy: higher = more fine detail,
    /// so less hand shake and better focus. Standard blur measure.
    static func sharpness(_ image: CGImage) -> Double {
        let scale = min(1, 640 / Double(max(image.width, image.height)))
        let w = max(3, Int(Double(image.width) * scale)), h = max(3, Int(Double(image.height) * scale))
        var px = [UInt8](repeating: 0, count: w * h)
        let ok: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return 0 }
        var sum = 0.0, sumSq = 0.0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                let lap = Double(px[i - 1]) + Double(px[i + 1]) + Double(px[i - w]) + Double(px[i + w]) - 4 * Double(px[i])
                sum += lap; sumSq += lap * lap
            }
        }
        let n = Double((w - 2) * (h - 2))
        let mean = sum / n
        return sumSq / n - mean * mean
    }

    static func eyesOpen(_ face: VNFaceObservation) -> Bool {
        guard let l = face.landmarks?.leftEye, let r = face.landmarks?.rightEye else { return true }
        return min(aspect(l.normalizedPoints), aspect(r.normalizedPoints)) > 0.17
    }

    static func aspect(_ pts: [CGPoint]) -> Double {
        guard let minX = pts.map(\.x).min(), let maxX = pts.map(\.x).max(),
              let minY = pts.map(\.y).min(), let maxY = pts.map(\.y).max(), maxX > minX else { return 0.3 }
        return Double((maxY - minY) / (maxX - minX))
    }

    static func thumbnail(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: 1280,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// Thumbnails are created with the EXIF transform applied, so they're already upright.
    static func orientation(_ data: Data) -> CGImagePropertyOrientation { .up }
}

enum PhotoSaver {
    static func save(_ data: Data, completion: @escaping (Result<Void, Error>) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                completion(.failure(CocoaError(.fileWriteNoPermission)))
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }) { ok, error in
                completion(ok ? .success(()) : .failure(error ?? CocoaError(.fileWriteUnknown)))
            }
        }
    }
}

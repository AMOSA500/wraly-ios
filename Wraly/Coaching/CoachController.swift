import AVFoundation
import Observation
import SwiftUI
import WralyCore

/// Glue between the camera, the analyzers, the rule engine and the UI.
@Observable
@MainActor
final class CoachController {
    enum Permission { case unknown, authorized, denied }

    // MARK: UI state
    var permission: Permission = .unknown
    var state: CoachState = .empty
    var joints: [WralyCore.Joint: Point2] = [:]
    var faceBox: Rect2?
    var attitude: DeviceAttitude?
    var camera = CameraInfo(equivalentFocalLength: 26, verticalFOV: 69, horizontalFOV: 54)
    var exposureReadout = ""
    var lastPhoto: CapturedPhoto?
    var isCapturing = false
    var countdown: Int?
    var errorMessage: String?

    // MARK: Settings
    /// nil = Auto (coach whatever shot you're framing).
    var targetShot: ShotType? {
        didSet { let t = targetShot; analysisQueue { $0.engine.targetShot = t; $0.engine.reset() } }
    }
    var autoCapture = true
    var voiceEnabled = true { didSet { voice.enabled = voiceEnabled } }
    var showSkeleton = true
    var showGrid = true

    // MARK: Engines (touched only on the camera's video queue)
    let cameraService = CameraService()
    private let worker = AnalysisWorker()
    private let sensors = SensorMonitor()
    private let voice = VoiceCoach()
    @ObservationIgnored private var lastCaptureAt = Date.distantPast
    @ObservationIgnored private var wasReady = false
    @ObservationIgnored private var started = false

    func start() async {
        guard !started else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { permission = .denied; return }
        default:
            permission = .denied; return
        }
        permission = .authorized
        started = true

        do {
            try cameraService.configure()
        } catch {
            errorMessage = "Camera unavailable: \(error.localizedDescription)"
            return
        }
        sensors.start()

        let service = cameraService
        let sensors = sensors
        let worker = worker
        cameraService.onFrame = { [weak self] buffer in
            // Analyse ~12 fps; drop frames while busy.
            guard worker.shouldAnalyse() else { return }
            let info = service.cameraInfo()
            guard let out = worker.analyzer.analyze(buffer, device: service.device, camera: info,
                                                    attitude: sensors.attitude, sun: sensors.sun) else {
                worker.done(); return
            }
            let coach = worker.engine.update(out.snapshot)
            service.apply(coach.plan)
            let readout = Self.readout(service.device, info)
            worker.done()
            Task { @MainActor [weak self] in
                self?.receive(coach, out: out, info: info, readout: readout)
            }
        }
        cameraService.start()
    }

    private func analysisQueue(_ body: @escaping (AnalysisWorker) -> Void) {
        let w = worker
        cameraService.videoQueue.async { body(w) }
    }

    private func receive(_ coach: CoachState, out: FrameAnalyzer.Output, info: CameraInfo, readout: String) {
        state = coach
        joints = out.joints
        faceBox = out.faceBox
        attitude = out.snapshot.attitude
        camera = info
        exposureReadout = readout
        voice.announce(coach.primary)

        if coach.readyToCapture && !wasReady { voice.ready() }
        wasReady = coach.readyToCapture

        if autoCapture, coach.readyToCapture, !isCapturing, countdown == nil,
           Date().timeIntervalSince(lastCaptureAt) > 4 {
            beginAutoCapture()
        }
    }

    // MARK: Capture

    private func beginAutoCapture() {
        countdown = 1
        voice.say("Hold it")
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            countdown = nil
            // Re-check: the moment may have passed (blink, step).
            if state.readyToCapture { capture() }
        }
    }

    func capture() {
        guard !isCapturing else { return }
        isCapturing = true
        lastCaptureAt = Date()
        let plan = state.plan
        cameraService.capture(plan: plan, count: plan.burstCount) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isCapturing = false
                switch result {
                case .success(let photo):
                    self.lastPhoto = photo
                    self.voice.say("Got it")
                case .failure(let error):
                    self.errorMessage = "Couldn't save photo: \(error.localizedDescription)"
                }
            }
        }
    }

    func setZoom(_ z: Double) { cameraService.setZoom(userFacing: z) }

    func lensWiped() {
        analysisQueue { $0.analyzer.resetLensEstimate() }
        voice.clear()
    }

    nonisolated static func readout(_ device: AVCaptureDevice?, _ info: CameraInfo) -> String {
        guard let d = device else { return "" }
        let s = d.exposureDuration.seconds
        let shutter = s >= 0.25 ? String(format: "%.1fs", s) : "1/\(Int((1 / max(s, 1e-4)).rounded()))"
        let bias = d.exposureTargetBias
        let ev = abs(bias) < 0.05 ? "" : String(format: " · %+.1f EV", bias)
        return "\(Int(info.equivalentFocalLength.rounded())) mm · \(shutter) · ISO \(Int(d.iso))\(ev)"
    }
}

/// Frame-rate limiter + the non-thread-safe analysis objects, used only on the video queue.
final class AnalysisWorker: @unchecked Sendable {
    let analyzer = FrameAnalyzer()
    let engine = GuidanceEngine()
    private var busy = false
    private var lastStart: CFTimeInterval = 0

    func shouldAnalyse() -> Bool {
        let now = CACurrentMediaTime()
        guard !busy, now - lastStart >= 1.0 / 12 else { return false }
        busy = true; lastStart = now
        return true
    }

    func done() { busy = false }
}

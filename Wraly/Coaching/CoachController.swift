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
    /// Detected horizon, for the Landscape overlay.
    var scene: SceneLayout?
    var attitude: DeviceAttitude?
    var camera = CameraInfo(equivalentFocalLength: 26, verticalFOV: 69, horizontalFOV: 54)
    var exposureReadout = ""
    var lastPhoto: CapturedPhoto?
    var isCapturing = false
    var countdown: Int?
    var errorMessage: String?
    /// The front camera is live (selfie mode).
    private(set) var usingFrontCamera = false
    /// True while the camera is being swapped, to blur the preview.
    private(set) var isSwitchingCamera = false
    /// Bumped whenever the camera input changes, so the preview re-applies its rotation.
    private(set) var cameraGeneration = 0
    /// Bumped on every shutter press and every saved photo, for flash and haptics.
    private(set) var shutterCount = 0
    private(set) var photoCount = 0

    // MARK: Settings
    /// nil = Auto (coach whatever shot you're framing).
    var targetShot: ShotType? {
        didSet { let t = targetShot; analysisQueue { $0.engine.targetShot = t; $0.engine.reset() } }
    }
    var autoCapture = true
    /// What's being shot. Selfie runs on the front camera; every other mode on the back.
    var mode: CaptureMode = .auto {
        didSet {
            guard mode != oldValue else { return }
            if !oldValue.usesFrontCamera { lastBackMode = oldValue }
            let m = mode
            analysisQueue { $0.engine.mode = m; $0.engine.reset() }
            voice.clear()
            // Taking your own photo: hear everything, since you can't watch the screen and the lens.
            voice.speakPhotographerCues = m == .selfie
            if m.usesFrontCamera != usingFrontCamera { switchCamera(front: m.usesFrontCamera) }
        }
    }
    /// The mode to return to when leaving selfie.
    @ObservationIgnored private var lastBackMode: CaptureMode = .auto

    /// Front ↔ back, like the Camera app's flip button.
    func flipCamera() {
        mode = mode.usesFrontCamera ? lastBackMode : .selfie
    }

    /// Next or previous mode (swipe on the viewfinder).
    func shiftMode(_ step: Int) {
        let all = CaptureMode.allCases
        guard let i = all.firstIndex(of: mode) else { return }
        mode = all[min(max(i + step, 0), all.count - 1)]
    }

    private func switchCamera(front: Bool) {
        guard started else { return }
        isSwitchingCamera = true
        usingFrontCamera = front
        cameraService.switchCamera(to: front ? .front : .back) { ok in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !ok {
                    self.usingFrontCamera.toggle()
                    self.errorMessage = front ? "The front camera isn't available." : "The back camera isn't available."
                }
                self.cameraGeneration += 1
                self.analysisQueue { $0.analyzer.resetLensEstimate(); $0.engine.reset() }
                try? await Task.sleep(for: .milliseconds(250))
                self.isSwitchingCamera = false
            }
        }
    }

    /// Save selfies the way you saw yourself on screen (like the Camera app's "Mirror Front Camera").
    var mirrorSelfies: Bool = UserDefaults.standard.object(forKey: "mirrorSelfies") as? Bool ?? true {
        didSet {
            cameraService.mirrorSelfies = mirrorSelfies
            UserDefaults.standard.set(mirrorSelfies, forKey: "mirrorSelfies")
        }
    }
    /// Recommend poses and confirm the subject is in them before shooting.
    /// Off by default so nothing extra stands between you and the photo.
    var poseGuide = false {
        didSet { poseRecipe = poseGuide ? PoseLibrary.recommended(for: state.shot).first : nil }
    }
    /// Move to the next recommended pose after each photo.
    var autoNextPose = true
    /// The pose being directed right now.
    var poseRecipe: PoseRecipe? {
        didSet {
            guard poseRecipe != oldValue else { return }
            let r = poseRecipe
            analysisQueue { $0.engine.poseRecipe = r }
            poseWasMatched = false
            voice.clear()
        }
    }
    var recommendedPoses: [PoseRecipe] { PoseLibrary.recommended(for: state.shot) }
    var voiceEnabled = true { didSet { voice.enabled = voiceEnabled } }
    /// nil = the iPhone's Spoken Content voice.
    var voiceIdentifier: String? = UserDefaults.standard.string(forKey: "voiceIdentifier") {
        didSet {
            voice.voiceIdentifier = voiceIdentifier
            UserDefaults.standard.set(voiceIdentifier, forKey: "voiceIdentifier")
        }
    }
    var voiceRate: Float = UserDefaults.standard.object(forKey: "voiceRate") as? Float ?? 1.05 {
        didSet {
            voice.rate = voiceRate
            UserDefaults.standard.set(voiceRate, forKey: "voiceRate")
        }
    }
    func previewVoice(_ id: String?) { voice.preview(voice: id, rate: voiceRate) }
    /// Switch to the lens Wraly recommends without asking.
    var autoLens = true
    /// Straighten slightly tilted photos after the shot.
    var autoStraighten = true
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
    @ObservationIgnored private var poseWasMatched = false
    @ObservationIgnored private var lastManualZoomAt = Date.distantPast
    @ObservationIgnored private var lastAutoZoomAt = Date.distantPast
    @ObservationIgnored private var zoomSuggestion: (zoom: Double, since: Date)?

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
        cameraService.mirrorSelfies = mirrorSelfies
        sensors.start()
        voice.voiceIdentifier = voiceIdentifier
        voice.rate = voiceRate
        let initialPose = poseRecipe
        analysisQueue { $0.engine.poseRecipe = initialPose }

        let service = cameraService
        let sensors = sensors
        let worker = worker
        cameraService.onFrame = { [weak self] buffer in
            // Analyse ~12 fps; drop frames while busy.
            guard worker.shouldAnalyse() else { return }
            // Follow the phone: sideways frames and photos when it's held sideways.
            let held = sensors.attitude?.orientation ?? .portrait
            service.setOrientation(held)
            guard let orientation = service.orientation(of: buffer) else { worker.done(); return }
            let info = service.cameraInfo(orientation: orientation)
            guard let out = worker.analyzer.analyze(buffer, device: service.device, camera: info,
                                                    attitude: sensors.attitude, sun: sensors.sun) else {
                worker.done(); return
            }
            let coach = worker.engine.update(out.snapshot)
            service.apply(coach.plan, orientation: orientation)
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
        scene = out.snapshot.scene
        attitude = out.snapshot.attitude
        camera = info
        exposureReadout = readout
        voice.announce(coach.primary)
        if !usingFrontCamera { autoSwitchLens(coach.plan.suggestedZoom) }

        // Keep the pose suited to the shot being framed.
        if poseGuide, coach.mode.directsSubject, let r = poseRecipe, !r.shots.contains(coach.shot) {
            poseRecipe = PoseLibrary.recommended(for: coach.shot).first
        }
        let matched = coach.pose?.matched ?? false
        if matched && !poseWasMatched {
            voice.ready()
            if !autoCapture { voice.say("That's the pose") }
        }
        poseWasMatched = matched

        if coach.readyToCapture && !wasReady && coach.pose == nil { voice.ready() }
        wasReady = coach.readyToCapture

        if autoCapture, coach.readyToCapture, !isCapturing, !isSwitchingCamera, countdown == nil,
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
        guard !isCapturing, !isSwitchingCamera else { return }
        isCapturing = true
        shutterCount += 1
        lastCaptureAt = Date()
        let plan = state.plan
        // Small accidental tilts are fixed in the photo; bigger ones are probably on purpose.
        let roll = attitude?.rollDegrees ?? 0
        // Selfie tilts are usually on purpose, so leave those alone.
        let straighten = autoStraighten && !usingFrontCamera && abs(roll) >= 0.4 && abs(roll) <= 8 ? roll : nil
        cameraService.capture(plan: plan, count: plan.burstCount, straighten: straighten) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isCapturing = false
                switch result {
                case .success(let photo):
                    withAnimation(.spring(duration: 0.35)) {
                        self.lastPhoto = photo
                        self.photoCount += 1
                    }
                    self.voice.say("Got it")
                    if self.poseGuide, self.autoNextPose, self.state.mode.directsSubject { self.advancePoseAfterShot() }
                case .failure(let error):
                    self.errorMessage = "Couldn't save photo: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: Poses

    func nextPose(_ step: Int = 1) {
        poseRecipe = PoseLibrary.next(after: poseRecipe, for: state.shot, step: step)
    }

    private func advancePoseAfterShot() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1200))
            guard poseGuide else { return }
            nextPose()
            if let name = poseRecipe?.name { voice.say("Next pose: \(name)") }
        }
    }

    /// A zoom the photographer chose — Wraly won't override it for a while.
    func setZoom(_ z: Double) {
        lastManualZoomAt = Date()
        cameraService.setZoom(userFacing: z)
    }

    /// Switch to the recommended lens once the advice has been steady for a moment.
    private func autoSwitchLens(_ suggested: Double?) {
        guard autoLens, let z = suggested, abs(z - camera.zoomFactor) > 0.05 else { zoomSuggestion = nil; return }
        let now = Date()
        if zoomSuggestion?.zoom != z { zoomSuggestion = (z, now); return }
        guard let since = zoomSuggestion?.since, now.timeIntervalSince(since) > 1.2,
              now.timeIntervalSince(lastManualZoomAt) > 10, now.timeIntervalSince(lastAutoZoomAt) > 6 else { return }
        lastAutoZoomAt = now
        zoomSuggestion = nil
        cameraService.setZoom(userFacing: z)
        voice.say(z < 1 ? "Going wide" : "Switching to \(z == z.rounded() ? String(Int(z)) : String(z)) times")
    }

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

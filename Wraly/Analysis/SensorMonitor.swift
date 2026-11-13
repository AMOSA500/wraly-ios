import CoreLocation
import CoreMotion
import Foundation
import WralyCore

/// Phone attitude (level, tilt, shake) from CoreMotion and, if the user allows
/// location, the sun's position relative to where the lens is pointing.
final class SensorMonitor: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    private let motion = CMMotionManager()
    private let location = CLLocationManager()
    private let lock = NSLock()
    private var _attitude: DeviceAttitude?
    private var _heading: Double?
    private var _coordinate: CLLocationCoordinate2D?
    private var _sun: SunPosition?
    private var sunComputedAt = Date.distantPast

    var attitude: DeviceAttitude? {
        lock.withLock {
            guard var a = _attitude else { return nil }
            a.headingDegrees = _heading
            return a
        }
    }

    /// Sun position with `relativeToCamera` filled in when a compass heading exists.
    var sun: SunPosition? {
        lock.withLock {
            guard let coord = _coordinate else { return nil }
            if Date().timeIntervalSince(sunComputedAt) > 60 || _sun == nil {
                _sun = SunPosition.compute(date: Date(), latitude: coord.latitude, longitude: coord.longitude)
                sunComputedAt = Date()
            }
            return _sun?.withCamera(heading: _heading)
        }
    }

    func start() {
        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 1.0 / 30
            motion.startDeviceMotionUpdates(to: OperationQueue()) { [weak self] m, _ in
                guard let self, let m else { return }
                let g = m.gravity
                // Back camera looks along −z. Upright phone: g ≈ (0, −1, 0).
                // Lens pitch (positive = pointing up) and roll (positive = clockwise).
                let pitch = atan2(g.z, -g.y) * 180 / .pi
                let roll = atan2(g.x, -g.y) * 180 / .pi
                let r = m.rotationRate
                let shake = sqrt(r.x * r.x + r.y * r.y + r.z * r.z)
                self.lock.withLock {
                    // Light smoothing so the level indicator doesn't jitter.
                    let prev = self._attitude
                    let k = 0.25
                    self._attitude = DeviceAttitude(
                        pitchDegrees: prev.map { $0.pitchDegrees + (pitch - $0.pitchDegrees) * k } ?? pitch,
                        rollDegrees: prev.map { $0.rollDegrees + (roll - $0.rollDegrees) * k } ?? roll,
                        shake: prev.map { $0.shake + (shake - $0.shake) * 0.3 } ?? shake)
                }
            }
        }

        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyKilometer
        location.headingOrientation = .portrait
        switch location.authorizationStatus {
        case .notDetermined: location.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse: beginLocation()
        default: break
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        location.stopUpdatingHeading()
        location.stopUpdatingLocation()
    }

    private func beginLocation() {
        location.startUpdatingLocation()
        if CLLocationManager.headingAvailable() { location.startUpdatingHeading() }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            beginLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let c = locations.last?.coordinate else { return }
        lock.withLock { _coordinate = c; _sun = nil }
        // Coarse position is enough for the sun; stop the GPS to save battery.
        manager.stopUpdatingLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let h = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        lock.withLock { _heading = h }
    }
}

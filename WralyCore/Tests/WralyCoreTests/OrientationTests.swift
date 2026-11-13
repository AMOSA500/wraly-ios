import XCTest
@testable import WralyCore

final class OrientationTests: XCTestCase {
    private var landscapeCamera: CameraInfo {
        var c = Fixture.camera
        c.aspect = 4.0 / 3; c.orientation = .landscapeClockwise
        return c
    }

    func testScreenAndSensorMappingsAgree() {
        // The screen and the sensor are both fixed to the phone, so any frame point must
        // land on the same sensor spot whether we go there directly or via the screen.
        for o in [FrameOrientation.portrait, .landscapeClockwise, .landscapeCounterClockwise] {
            for p in [Point2(0.1, 0.2), Point2(0.8, 0.3), Point2(0.5, 0.9)] {
                let direct = o.toSensor(p), viaScreen = FrameOrientation.portrait.toSensor(o.toScreen(p))
                XCTAssertEqual(direct.x, viaScreen.x, accuracy: 1e-9, "\(o)")
                XCTAssertEqual(direct.y, viaScreen.y, accuracy: 1e-9, "\(o)")
            }
        }
        // Phone turned clockwise: the top of the scene is on the screen's left edge.
        XCTAssertEqual(FrameOrientation.landscapeClockwise.toScreen(Point2(0.5, 0)), Point2(0, 0.5))
        XCTAssertEqual(FrameOrientation.landscapeCounterClockwise.toScreen(Point2(0.5, 0)), Point2(1, 0.5))
    }

    func testSceneryAsksForLandscapeOnlyWhenUpright() {
        let engine = GuidanceEngine()
        engine.mode = .scenery
        let upright = FrameSnapshot(timestamp: 0, personCount: 0, camera: Fixture.camera)
        XCTAssertTrue(engine.evaluate(upright).issues.contains { $0.id == "scene.sideways" })
        let sideways = FrameSnapshot(timestamp: 0, personCount: 0, camera: landscapeCamera)
        XCTAssertFalse(engine.evaluate(sideways).issues.contains { $0.id == "scene.sideways" })
    }

    private func groupSnap(_ boxes: [Rect2], camera: CameraInfo? = nil) -> FrameSnapshot {
        var s = Fixture.snapshot(Fixture.person(top: 0.3, head: 0.12))
        s.faces = boxes
        s.personCount = boxes.count
        if let camera { s.camera = camera }
        return s
    }

    private func face(_ x: Double, w: Double = 0.08) -> Rect2 { Rect2(x: x, y: 0.3, width: w, height: w * 1.3) }

    func testGroupOfThreeSuggestsLandscapeAndDropsSingleSubjectRules() {
        let engine = GuidanceEngine()
        let ids = engine.evaluate(groupSnap([face(0.2), face(0.45), face(0.7)])).issues.map(\.id)
        XCTAssertTrue(ids.contains("group.sideways"))
        XCTAssertFalse(ids.contains("frame.offCentre"))
        let sideways = engine.evaluate(groupSnap([face(0.2), face(0.45), face(0.7)], camera: landscapeCamera)).issues.map(\.id)
        XCTAssertFalse(sideways.contains("group.sideways"))
    }

    func testGroupEdgesCentringAndDepth() {
        let advisor = GroupAdvisor()
        let cut = advisor.evaluate(groupSnap([face(0.005), face(0.4)]))
        XCTAssertTrue(cut.contains { $0.message == "Someone's cut off on the left — aim a little left" })
        let both = advisor.evaluate(groupSnap([face(0.0), face(0.93)]))
        XCTAssertTrue(both.contains { $0.id == "group.cutBoth" })
        let offCentre = advisor.evaluate(groupSnap([face(0.6), face(0.8)]))
        XCTAssertTrue(offCentre.contains { $0.message == "Aim a little right to centre the group" })
        let depth = advisor.evaluate(groupSnap([face(0.3, w: 0.15), face(0.6, w: 0.07)]))
        XCTAssertTrue(depth.contains { $0.id == "group.depth" })
    }

    func testSinglePersonSidewaysSuggestsUpright() {
        let engine = GuidanceEngine()
        var s = Fixture.snapshot(Fixture.person(top: 0.08, head: 0.25))
        s.camera = landscapeCamera
        XCTAssertTrue(engine.evaluate(s).issues.contains { $0.id == "frame.upright" })
        engine.mode = .environmental
        XCTAssertFalse(engine.evaluate(s).issues.contains { $0.id == "frame.upright" })
    }
}

import XCTest
@testable import WralyCore

final class AutoModeTests: XCTestCase {
    private func thing(_ labels: [String], ev: Double = 10, t: Double = 0) -> FrameSnapshot {
        var s = FrameSnapshot(timestamp: t, personCount: 0,
                              light: LightReading(ev100: ev, iso: 100, exposureSeconds: 0.01, aperture: 1.8, meanLuma: 0.45,
                                                  clippedHighlights: 0, crushedShadows: 0),
                              background: BackgroundReading(clutter: 0.2, sceneLabels: labels),
                              attitude: DeviceAttitude(pitchDegrees: 0, rollDegrees: 0), camera: Fixture.camera)
        s.salientObject = Rect2(x: 0.3, y: 0.5, width: 0.2, height: 0.2)
        return s
    }

    private func settle(_ engine: GuidanceEngine, _ make: (Double) -> FrameSnapshot) -> CoachState {
        var state = CoachState.empty
        for i in 0..<15 { state = engine.update(make(Double(i) * 0.1)) }
        return state
    }

    func testRecognisesThings() {
        XCTAssertEqual(SubjectClassifier.classify(thing(["food", "dessert"])), .food)
        XCTAssertEqual(SubjectClassifier.classify(thing(["outdoor", "mountain", "sky"])), .landscape)
        XCTAssertEqual(SubjectClassifier.classify(thing(["structure", "building"])), .city)
        XCTAssertEqual(SubjectClassifier.classify(thing(["building"], ev: 1)), .night)
        XCTAssertEqual(SubjectClassifier.classify(thing(["document", "text"])), .document)
        XCTAssertEqual(SubjectClassifier.classify(thing([])), .product)
        var pet = thing(["indoor"]); pet.animals = [Rect2(x: 0.2, y: 0.2, width: 0.4, height: 0.4)]
        XCTAssertEqual(SubjectClassifier.classify(pet), .pet)
        XCTAssertEqual(SubjectClassifier.classify(Fixture.snapshot(Fixture.person(top: 0.1, head: 0.2))), .person)
    }

    func testAutoAppliesProSettingsForTheSubject() {
        let engine = GuidanceEngine(); engine.mode = .auto
        let food = settle(engine) { self.thing(["food"], t: $0) }
        XCTAssertEqual(food.mode, .object)
        XCTAssertEqual(food.subject, .food)
        XCTAssertEqual(food.plan.exposureBias, 0.3, accuracy: 0.01)
        XCTAssertEqual(food.plan.focusPoint, Point2(0.4, 0.6), "focus on the object, not the centre")
        XCTAssertTrue(food.readyToCapture, "no person needed")

        engine.reset()
        let pet = settle(engine) { t in
            var s = self.thing(["dog"], t: t); s.animals = [Rect2(x: 0.2, y: 0.2, width: 0.4, height: 0.4)]; return s
        }
        XCTAssertEqual(pet.subject, .pet)
        XCTAssertLessThanOrEqual(pet.plan.maxExposureSeconds, 1.0 / 250)
        XCTAssertEqual(pet.plan.burstCount, 5)

        let view = settle(engine) { self.thing(["sky", "mountain"], t: 2 + $0) }
        XCTAssertEqual(view.mode, .landscape)
        let person = settle(engine) { Fixture.snapshot(Fixture.person(top: 0.1, head: 0.2), t: 4 + $0) }
        XCTAssertEqual(person.mode, .portrait)
    }

    func testAdviceDoesNotHoldTheShutter() {
        // Shoulders square to camera is a "fix", but it's advice: the photo still goes.
        let engine = GuidanceEngine(targetShot: .halfBody)
        let square = Fixture.person(top: 0.08, head: 0.16, shoulderWidthInFaces: 2.4)
        let state = settle(engine) { Fixture.snapshot(square, t: $0) }
        XCTAssertTrue(state.all.contains { $0.severity == .fix }, "advice is still given")
        XCTAssertTrue(state.readyToCapture)
    }

    func testSceneryAndLandscapeDiffer() {
        let engine = GuidanceEngine()
        var s = thing(["building"])
        s.attitude = DeviceAttitude(pitchDegrees: 7, rollDegrees: 0)
        engine.mode = .scenery
        let scenery = engine.evaluate(s).issues.map(\.id)
        XCTAssertTrue(scenery.contains("scene.verticals"), "buildings: strict about leaning walls")
        XCTAssertFalse(scenery.contains("scene.sideways"), "buildings are often upright")
        engine.mode = .landscape
        let landscape = engine.evaluate(s).issues.map(\.id)
        XCTAssertFalse(landscape.contains("scene.verticals"))
        XCTAssertTrue(landscape.contains("scene.sideways"))
    }
}

final class SurroundingsTests: XCTestCase {
    private func person(labels: [String], ev: Double = 12, kelvin: Double = 5500) -> FrameSnapshot {
        var s = Fixture.snapshot(Fixture.person(top: 0.1, head: 0.2),
                                 light: LightReading(ev100: ev, iso: 100, exposureSeconds: 1.0 / 250, aperture: 1.8,
                                                     meanLuma: 0.45, clippedHighlights: 0, crushedShadows: 0))
        s.light?.colorTemperatureK = kelvin
        s.background = BackgroundReading(clutter: 0, mergerBehindHead: false, brightEdgeDistraction: false,
                                         backgroundSharpnessRatio: nil, sceneLabels: labels)
        return s
    }

    func testPersonOnTheBeachGetsBeachSettings() {
        let s = person(labels: ["beach", "sky"])
        XCTAssertEqual(SurroundingsReader.read(s).first, .beach)
        let plan = CapturePlanner().plan(for: s, metrics: SubjectMetrics(snapshot: s), target: .halfBody, kind: .person)
        XCTAssertEqual(plan.exposureBias, 0.7, accuracy: 0.01)
        XCTAssertEqual(plan.recipe, "Portrait at the beach")
    }

    func testConcertProtectsHighlightsAndFreezes() {
        let s = person(labels: ["concert"], ev: 5)
        let plan = CapturePlanner().plan(for: s, metrics: SubjectMetrics(snapshot: s), target: .halfBody, kind: .person)
        XCTAssertLessThan(plan.exposureBias, 0)
        XCTAssertLessThanOrEqual(plan.maxExposureSeconds, 1.0 / 125)
        XCTAssertEqual(plan.recipe, "Portrait under stage lights")
    }

    func testNightIsNamedAndBursts() {
        let s = person(labels: [], ev: 1.5)
        let state = GuidanceEngine().update(s)
        XCTAssertEqual(state.surroundings.first, .night)
        XCTAssertEqual(state.plan.recipe, "Night portrait")
        XCTAssertGreaterThanOrEqual(state.plan.burstCount, 3)
    }
}

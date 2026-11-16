import Foundation

/// What the camera is looking at, worked out from people, animals, scene labels and light.
public enum SubjectKind: String, CaseIterable, Sendable {
    case person, group, pet, food, flower, document, product, motion, night, landscape, city, interior

    public var title: String {
        switch self {
        case .person: return "Person"
        case .group: return "Group"
        case .pet: return "Pet"
        case .food: return "Food"
        case .flower: return "Flower"
        case .document: return "Document"
        case .product: return "Object"
        case .motion: return "Action"
        case .night: return "Night"
        case .landscape: return "Landscape"
        case .city: return "City"
        case .interior: return "Interior"
        }
    }

    public var symbol: String {
        switch self {
        case .person: return "person.fill"
        case .group: return "person.3.fill"
        case .pet: return "pawprint.fill"
        case .food: return "fork.knife"
        case .flower: return "camera.macro"
        case .document: return "doc.text"
        case .product: return "cube.fill"
        case .motion: return "figure.run"
        case .night: return "moon.stars.fill"
        case .landscape: return "mountain.2.fill"
        case .city: return "building.2.fill"
        case .interior: return "sofa.fill"
        }
    }

    /// The mode Auto coaches with for this subject.
    public var mode: CaptureMode {
        switch self {
        case .person, .group: return .portrait
        case .landscape: return .landscape
        case .city, .interior, .night: return .scenery
        case .pet, .food, .flower, .document, .product, .motion: return .object
        }
    }
}

public enum SubjectClassifier {
    // Keyword fragments matched against Vision's scene-classification labels.
    static let keywords: [(SubjectKind, [String])] = [
        (.pet, ["dog", "cat", "puppy", "kitten", "animal", "bird", "horse", "pet", "rabbit"]),
        (.food, ["food", "meal", "dish", "dessert", "fruit", "vegetable", "salad", "pizza", "cake", "bread",
                 "coffee", "drink", "burger", "sandwich", "pasta", "sushi", "baked", "breakfast", "plate"]),
        (.flower, ["flower", "blossom", "rose", "tulip", "sunflower", "daisy", "orchid", "petal", "houseplant", "leaf"]),
        (.document, ["document", "paper", "text", "receipt", "book", "letter", "menu", "whiteboard", "printed", "poster"]),
        (.motion, ["sport", "vehicle", "car", "bicycle", "motorcycle", "train", "running", "skate", "ball"]),
        (.city, ["city", "skyline", "building", "architecture", "street", "bridge", "tower", "skyscraper",
                 "structure", "road", "monument", "church", "castle"]),
        (.interior, ["interior", "room", "kitchen", "bedroom", "office", "restaurant", "hall", "lobby", "indoor"]),
        (.landscape, ["sky", "mountain", "landscape", "beach", "ocean", "sea", "lake", "river", "forest", "field",
                      "sunset", "sunrise", "hill", "shore", "waterfall", "desert", "snow", "canyon", "coast",
                      "valley", "meadow", "cliff", "cloud"]),
    ]

    /// Best guess for this frame. Labels earlier in the list count more.
    public static func classify(_ s: FrameSnapshot) -> SubjectKind {
        let people = max(s.personCount, s.faces.count)
        if people >= OrientationAdvisor.groupSize { return .group }
        // A clearly visible person wins over everything else.
        if people > 0, (s.face?.box.width ?? 0) > 0.035 || s.pose != nil { return .person }
        if !s.animals.isEmpty { return .pet }

        var score: [SubjectKind: Double] = [:]
        for (rank, label) in (s.background?.sceneLabels ?? []).enumerated() {
            let l = label.lowercased(), weight = 1 / Double(rank + 1)
            for (kind, words) in keywords where words.contains(where: { l.contains($0) }) {
                score[kind, default: 0] += weight
                break   // a label counts for its first (most specific) kind only
            }
        }
        if let best = score.max(by: { $0.value < $1.value }), best.value >= 0.3 {
            if best.key == .landscape || best.key == .city, (s.light?.ev100 ?? 10) < 3 { return .night }
            return best.key
        }
        if (s.light?.ev100 ?? 10) < 3 { return .night }
        // A clear horizon with no labels is still a view.
        if let L = s.scene, L.confidence > 0.7 { return .landscape }
        return .product
    }
}

/// Short, optional tips for things — none of them hold the shutter.
public struct ObjectAdvisor: Sendable {
    public init() {}

    public func evaluate(_ s: FrameSnapshot, kind: SubjectKind) -> [Guidance] {
        var out: [Guidance] = []
        let clutter = s.background?.clutter ?? 0
        switch kind {
        case .food:
            out.append(Guidance("obj.food", .cameraAngle, .tip, .photographer,
                                "Food: shoot from above, or low at 45°",
                                reason: "Flat dishes (pizza, bowls) look best straight down; tall food (burgers, drinks) at a low 45°. Use window light, never flash.",
                                cue: nil))
        case .pet:
            out.append(Guidance("obj.pet", .cameraAngle, .tip, .photographer,
                                "Get down to their eye level",
                                reason: "Pets look best from their own height. Wraly uses a fast shutter and a burst, and keeps the sharpest frame. A squeak or treat above the lens gets the look.",
                                cue: .lowerPhone))
        case .flower:
            out.append(Guidance("obj.flower", .framing, .tip, .photographer,
                                "Get close and fill the frame",
                                reason: "Go as close as the phone will focus. Shoot with the light behind the petals to make them glow, and keep the background far away.",
                                cue: .moveCloser))
        case .document:
            if let pitch = s.attitude?.pitchDegrees, pitch > -75 {
                out.append(Guidance("obj.docFlat", .cameraAngle, .tip, .photographer,
                                    "Hold the phone flat above the page",
                                    reason: "Straight down keeps the text square and evenly sharp. Avoid your own shadow — light from the side works best.",
                                    cue: .tiltDown))
            }
        case .product:
            if clutter > 0.5 {
                out.append(Guidance("obj.background", .background, .tip, .photographer,
                                    "A plain background makes it stand out",
                                    reason: "Put the object against a wall, a sheet of paper or the sky. Fewer things behind it means the eye goes straight to it.",
                                    cue: nil))
            }
        case .motion:
            out.append(Guidance("obj.motion", .cameraAngle, .tip, .photographer,
                                "Moving subject — follow it and hold the button",
                                reason: "Wraly switches to a fast shutter and a burst. Pan with the subject and leave space in front of where it's going.",
                                cue: nil))
        default:
            break
        }
        return out
    }
}

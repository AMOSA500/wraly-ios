import AVFoundation
import UIKit
import WralyCore

/// Speaks instructions and gives haptic cues. A good photographer talks
/// constantly but never says two things at once.
final class VoiceCoach {
    private let synth = AVSpeechSynthesizer()
    private var lastSpokenID: String?
    private var lastSpokenAt = Date.distantPast
    private let tick = UIImpactFeedbackGenerator(style: .light)
    private let success = UINotificationFeedbackGenerator()

    var enabled = true
    /// Speak instructions meant for the photographer too (otherwise only subject-facing ones).
    var speakPhotographerCues = false

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .voicePrompt, options: [.mixWithOthers, .duckOthers])
    }

    func announce(_ g: Guidance?) {
        guard let g, g.id != lastSpokenID else { return }
        let speakable = enabled && (g.audience == .subject || speakPhotographerCues || g.severity == .critical)
        // Too soon after the last line: try again on a later frame rather than dropping it.
        if speakable && Date().timeIntervalSince(lastSpokenAt) <= 2.2 { return }
        tick.impactOccurred(intensity: g.severity == .critical ? 1 : 0.5)
        lastSpokenID = g.id
        if speakable { say(g.message) }
    }

    func say(_ text: String) {
        guard enabled else { return }
        if synth.isSpeaking { synth.stopSpeaking(at: .word) }
        let u = AVSpeechUtterance(string: text.replacingOccurrences(of: "—", with: ","))
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        u.prefersAssistiveTechnologySettings = true
        synth.speak(u)
        lastSpokenAt = Date()
    }

    func ready() { success.notificationOccurred(.success) }

    func clear() { lastSpokenID = nil }
}

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
    /// A specific voice, or nil to follow the iPhone's Spoken Content voice.
    var voiceIdentifier: String?
    /// Multiplier on the default speaking rate.
    var rate: Float = 1.05

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
        speak(text, voice: voiceIdentifier, rate: rate)
        lastSpokenAt = Date()
    }

    /// Plays a sample in the given voice (works even when voice coaching is off).
    func preview(voice id: String?, rate: Float) {
        speak("Turn your body a little to the side, and look back at me. Perfect, hold it.", voice: id, rate: rate)
    }

    private func speak(_ text: String, voice id: String?, rate: Float) {
        if synth.isSpeaking { synth.stopSpeaking(at: .word) }
        let u = AVSpeechUtterance(string: text.replacingOccurrences(of: "—", with: ","))
        u.rate = min(AVSpeechUtteranceMaximumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * rate)
        if let id, let v = AVSpeechSynthesisVoice(identifier: id) {
            u.voice = v
            u.prefersAssistiveTechnologySettings = false
        } else {
            u.prefersAssistiveTechnologySettings = true
        }
        synth.speak(u)
    }

    func ready() { success.notificationOccurred(.success) }

    func clear() { lastSpokenID = nil }
}

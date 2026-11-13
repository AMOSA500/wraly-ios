import AVFoundation
import SwiftUI

/// Choose the coaching voice: every voice installed on the phone, best quality first,
/// with a tap-to-preview sample and a speaking speed slider.
struct VoicePickerView: View {
    @Environment(CoachController.self) private var coach
    @State private var allLanguages = false

    var body: some View {
        @Bindable var coach = coach
        List {
            Section {
                VStack(alignment: .leading) {
                    HStack {
                        Text("Speed")
                        Spacer()
                        Text(String(format: "%.2g×", coach.voiceRate)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Slider(value: $coach.voiceRate, in: 0.8...1.4, step: 0.05) { editing in
                        if !editing { coach.previewVoice(coach.voiceIdentifier) }
                    }
                }
            }

            Section {
                row(id: nil, title: "iPhone voice", subtitle: "Follows Settings › Accessibility › Spoken Content")
            }

            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.voices, id: \.identifier) { v in
                        row(id: v.identifier, title: v.name, subtitle: Self.languageName(v.language))
                    }
                }
            }

            Section {
                Toggle("Show all languages", isOn: $allLanguages)
            } footer: {
                Text("Want a more natural voice? Download an Enhanced or Premium voice in Settings › Accessibility › Spoken Content › Voices, then come back here.")
            }
        }
        .navigationTitle("Voice")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(id: String?, title: String, subtitle: String) -> some View {
        Button {
            coach.voiceIdentifier = id
            coach.previewVoice(id)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if coach.voiceIdentifier == id {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                } else {
                    Image(systemName: "play.circle").foregroundStyle(.secondary)
                }
            }
        }
        .tint(.primary)
        .accessibilityHint("Selects this voice and plays a sample")
    }

    // MARK: Voices

    private struct Group { let title: String; let voices: [AVSpeechSynthesisVoice] }

    private var groups: [Group] {
        let lang = String(Locale.preferredLanguages.first?.prefix(2) ?? "en")
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { v in
            !v.voiceTraits.contains(.isNoveltyVoice) && !v.voiceTraits.contains(.isPersonalVoice)
                && (allLanguages || v.language.hasPrefix(lang))
        }
        .sorted { ($0.language, $0.name) < ($1.language, $1.name) }
        return [(AVSpeechSynthesisVoiceQuality.premium, "Premium"), (.enhanced, "Enhanced"), (.default, "Standard")]
            .map { q, title in Group(title: title, voices: voices.filter { $0.quality == q }) }
            .filter { !$0.voices.isEmpty }
    }

    static func languageName(_ code: String) -> String {
        Locale.current.localizedString(forIdentifier: code) ?? code
    }

    static func name(for id: String?) -> String {
        guard let id, let v = AVSpeechSynthesisVoice(identifier: id) else { return "iPhone voice" }
        return v.name
    }
}

import AVFoundation
import SwiftUI
import WralyCore

/// Everything Wraly sees right now, with the reasoning a photographer would give.
struct DetailsSheet: View {
    @Environment(CoachController.self) private var coach

    var body: some View {
        @Bindable var coach = coach
        NavigationStack {
            List {
                Section("What Wraly sees") {
                    row("Shot", coach.state.plan.recipe)
                    if !coach.state.surroundings.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(coach.state.surroundings, id: \.self) { s in
                                Label(s.title, systemImage: s.symbol)
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Color.secondary.opacity(0.18), in: Capsule())
                            }
                        }
                    }
                    if coach.state.mode == .portrait {
                        Picker("Framing", selection: $coach.targetShot) {
                            Text("Auto").tag(ShotType?.none)
                            ForEach(ShotType.allCases) { Text($0.title).tag(ShotType?.some($0)) }
                        }
                    }
                }
                Section("Subject") {
                    row("Shot", coach.state.shot.title)
                    if let m = coach.state.metrics {
                        if let d = m.distance { row("Distance", String(format: "%.1f m", d)) }
                        if let h = m.heightMeters { row("Est. height", String(format: "%.2f m (±8%%)", h)) }
                        if let level = m.cameraHeightLevel { row("Lens is at", level.spoken) }
                        row("Ideal lens height", CameraAngleAdvisor.idealHeight(for: coach.state.shot).label)
                    } else {
                        Text("No subject detected").foregroundStyle(.secondary)
                    }
                }

                Section("Coaching") {
                    if coach.state.all.isEmpty {
                        Label("Nothing to fix — shoot!", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    }
                    ForEach(coach.state.all) { g in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(g.message).font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(g.audience == .subject ? "Subject" : "You")
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.2), in: Capsule())
                            }
                            Text(g.reason).font(.footnote).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }

                Section("Camera settings Wraly chose") {
                    row("Exposure", coach.exposureReadout)
                    ForEach(coach.state.plan.notes, id: \.self) { Text($0).font(.footnote) }
                    if coach.state.plan.flash == .fill { Label("Fill flash on", systemImage: "bolt.fill") }
                    if coach.state.plan.burstCount > 1 {
                        Label("Shooting \(coach.state.plan.burstCount) frames, keeping the sharpest with open eyes",
                              systemImage: "square.stack.3d.down.right")
                    }
                }

                if let photo = coach.lastPhoto {
                    Section("Last photo") {
                        Text(photo.note).font(.footnote)
                    }
                }
            }
            .navigationTitle("What Wraly sees")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k); Spacer(); Text(v).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
    }
}

struct SettingsSheet: View {
    @Environment(CoachController.self) private var coach

    var body: some View {
        @Bindable var coach = coach
        NavigationStack {
            Form {
                Section {
                    Toggle("Take the photo when it's ready", isOn: $coach.autoCapture)
                    Toggle("Switch lenses automatically", isOn: $coach.autoLens)
                    Toggle("Straighten tilted photos", isOn: $coach.autoStraighten)
                } header: { Text("Shooting") } footer: {
                    Text("Wraly only waits for things that would ruin the photo — closed eyes, shake, a dirty lens, someone cut off. Everything else is advice.")
                }
                Section {
                    Toggle("Shutter sound", isOn: $coach.shutterSound)
                } footer: {
                    Text("Off, the screen blinks and the phone taps instead. Burst frames are always silent. Some regions always play the sound.")
                }
                Section {
                    Toggle("Mirror selfies", isOn: $coach.mirrorSelfies)
                } header: { Text("Selfie") } footer: {
                    Text("Saves front-camera photos the way you see yourself on screen. Turn off to save them as others see you. Double-tap the viewfinder to flip cameras.")
                }
                Section {
                    Toggle("Voice coaching", isOn: $coach.voiceEnabled)
                    NavigationLink {
                        VoicePickerView()
                    } label: {
                        LabeledContent("Voice", value: VoicePickerView.name(for: coach.voiceIdentifier))
                    }
                } header: { Text("Voice") } footer: {
                    Text("Wraly speaks instructions meant for your subject so you can keep your eyes on the screen. In Selfie it speaks everything, so you can look at the lens.")
                }
                Section("Display") {
                    Toggle("Show skeleton", isOn: $coach.showSkeleton)
                    Toggle("Rule-of-thirds grid", isOn: $coach.showGrid)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct PermissionView: View {
    let denied: Bool

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "camera.aperture").font(.system(size: 64, weight: .thin))
            Text("Wraly").font(.largeTitle.weight(.bold))
            Text("Your pocket photographer. It reads the light, the scene and your subject — or you, in a selfie — tells you the one thing to fix, then takes the shot.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            if denied {
                Button("Allow camera in Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .buttonStyle(.borderedProminent)
            } else {
                ProgressView()
            }
        }
        .padding(32)
    }
}

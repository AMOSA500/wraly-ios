import SwiftUI
import WralyCore

struct CameraScreen: View {
    @Environment(CoachController.self) private var coach
    @State private var showDetails = false
    @State private var showSettings = false
    @State private var showPoses = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 10) {
                TopBar(showSettings: $showSettings)
                ZStack {
                    CameraPreview(session: coach.cameraService.session)
                    GuideOverlay()
                    if coach.countdown != nil {
                        RoundedRectangle(cornerRadius: 4).stroke(Color.green, lineWidth: 4)
                    }
                }
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(alignment: .bottom) {
                    InstructionBanner(guidance: coach.state.primary, ready: coach.state.readyToCapture)
                        .padding(10)
                        .onTapGesture { showDetails = true }
                }
                .overlay(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(coach.exposureReadout)
                            .font(.caption2.monospacedDigit())
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.black.opacity(0.5), in: Capsule())
                        PoseCard(showPicker: $showPoses)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                ZoomStops()
                BottomBar(showDetails: $showDetails)
            }
            .padding(.horizontal, 8)
        }
        .sheet(isPresented: $showDetails) { DetailsSheet().presentationDetents([.medium, .large]) }
        .sheet(isPresented: $showSettings) { SettingsSheet().presentationDetents([.medium, .large]) }
        .sheet(isPresented: $showPoses) { PosePickerSheet().presentationDetents([.medium, .large]) }
        .alert("Wraly", isPresented: Binding(get: { coach.errorMessage != nil }, set: { if !$0 { coach.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(coach.errorMessage ?? "") }
    }
}

// MARK: - Top bar: shot picker

private struct TopBar: View {
    @Environment(CoachController.self) private var coach
    @Binding var showSettings: Bool

    var body: some View {
        @Bindable var coach = coach
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 6) {
                Picker("Mode", selection: $coach.mode) {
                    ForEach(CaptureMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if coach.mode == .portrait {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            chip("Auto", selected: coach.targetShot == nil) { coach.targetShot = nil }
                            ForEach(ShotType.allCases) { shot in
                                chip(shot.title, selected: coach.targetShot == shot) { coach.targetShot = shot }
                            }
                        }
                    }
                }
            }
            Button { showSettings = true } label: {
                Image(systemName: "slider.horizontal.3").font(.title3)
            }
            .tint(.white)
            .accessibilityLabel("Settings")
        }
        .padding(.top, 4)
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.footnote.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(selected ? Color.yellow : Color.white.opacity(0.12), in: Capsule())
                .foregroundStyle(selected ? Color.black : Color.white)
        }
    }
}

// MARK: - Instruction banner

struct InstructionBanner: View {
    let guidance: Guidance?
    let ready: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                if let g = guidance, g.audience == .subject {
                    Text("TELL THEM").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                }
                Text(text).font(.callout.weight(.semibold)).lineLimit(2)
            }
            Spacer(minLength: 0)
            if guidance != nil {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .animation(.snappy, value: guidance?.id)
        .accessibilityElement(children: .combine)
    }

    private var text: String {
        if let g = guidance { return g.message }
        return ready ? "Perfect — hold it" : "Looking good"
    }

    private var tint: Color {
        guard let g = guidance else { return .green }
        switch g.severity {
        case .critical: return .red
        case .fix: return .yellow
        case .tip: return .cyan
        }
    }

    private var icon: String {
        guard let cue = guidance?.cue else { return guidance == nil ? "checkmark.circle.fill" : "lightbulb" }
        switch cue {
        case .moveLeft: return "arrow.left"
        case .moveRight: return "arrow.right"
        case .moveCloser: return "figure.walk.motion"
        case .moveBack: return "arrow.uturn.backward"
        case .raisePhone: return "arrow.up.to.line"
        case .lowerPhone: return "arrow.down.to.line"
        case .tiltUp: return "arrow.up.and.down.circle"
        case .tiltDown: return "arrow.up.and.down.circle"
        case .rotateClockwise: return "arrow.clockwise"
        case .rotateCounterClockwise: return "arrow.counterclockwise"
        case .zoomIn: return "plus.magnifyingglass"
        case .zoomOut: return "minus.magnifyingglass"
        case .wipeLens: return "sparkles"
        case .wait: return "hourglass"
        case .turnAround: return "arrow.triangle.2.circlepath"
        }
    }
}

// MARK: - Zoom

private struct ZoomStops: View {
    @Environment(CoachController.self) private var coach

    var body: some View {
        HStack(spacing: 10) {
            ForEach(coach.camera.opticalZoomStops, id: \.self) { z in
                let current = abs(coach.camera.zoomFactor - z) < 0.05
                let suggested = coach.state.plan.suggestedZoom.map { abs($0 - z) < 0.05 } ?? false
                Button { coach.setZoom(z) } label: {
                    Text(label(z))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .frame(width: 40, height: 40)
                        .background(current ? Color.white.opacity(0.25) : Color.white.opacity(0.08), in: Circle())
                        .overlay(Circle().stroke(suggested ? Color.yellow : .clear, lineWidth: 2))
                        .foregroundStyle(current ? Color.yellow : Color.white)
                }
                .accessibilityLabel("\(label(z)) zoom\(suggested ? ", suggested" : "")")
            }
        }
    }

    private func label(_ z: Double) -> String {
        z == z.rounded() ? "\(Int(z))×" : String(format: "%.1f×", z)
    }
}

// MARK: - Bottom bar: thumbnail, shutter with readiness ring, lens wipe

private struct BottomBar: View {
    @Environment(CoachController.self) private var coach
    @Binding var showDetails: Bool

    var body: some View {
        HStack {
            Group {
                if let img = coach.lastPhoto?.preview {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    Color.white.opacity(0.08)
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Spacer()

            Button { coach.capture() } label: {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.25), lineWidth: 5)
                    Circle()
                        .trim(from: 0, to: coach.state.readiness)
                        .stroke(coach.state.readyToCapture ? Color.green : Color.yellow,
                                style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.25), value: coach.state.readiness)
                    Circle().fill(coach.isCapturing ? Color.gray : Color.white).padding(9)
                }
                .frame(width: 78, height: 78)
            }
            .accessibilityLabel("Take photo")
            .accessibilityValue("\(Int(coach.state.readiness * 100)) percent ready")

            Spacer()

            Button {
                if coach.state.all.contains(where: { $0.category == .lens }) { coach.lensWiped() } else { showDetails = true }
            } label: {
                Image(systemName: coach.state.all.contains(where: { $0.category == .lens }) ? "checkmark.circle" : "list.bullet.rectangle")
                    .font(.title2)
                    .frame(width: 52, height: 52)
            }
            .tint(.white)
            .accessibilityLabel(coach.state.all.contains(where: { $0.category == .lens }) ? "I wiped the lens" : "All suggestions")
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}

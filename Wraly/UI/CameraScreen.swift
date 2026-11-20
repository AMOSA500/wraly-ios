import SwiftUI
import WralyCore

/// Layout, top to bottom:
/// - a slim status bar: voice, what Wraly sees, settings
/// - the viewfinder with the one instruction at the top (next to the front lens,
///   so in a selfie your eyes stay near the camera) and zoom at the bottom
/// - a swipeable mode strip, then the last photo, the shutter and the flip button,
///   all within thumb reach.
struct CameraScreen: View {
    @Environment(CoachController.self) private var coach
    @State private var showDetails = false
    @State private var showSettings = false
    @State private var showPoses = false
    @State private var flash = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                TopBar(showSettings: $showSettings)
                    .padding(.horizontal, 14)
                    .frame(height: 48)
                viewfinder
                    .padding(.horizontal, 6)
                Spacer(minLength: 6)
                ModeStrip()
                    .frame(height: 36)
                BottomBar()
                    .padding(.top, 4)
                    .padding(.bottom, 6)
            }
        }
        .sheet(isPresented: $showDetails) { DetailsSheet().presentationDetents([.medium, .large]) }
        .sheet(isPresented: $showSettings) { SettingsSheet().presentationDetents([.medium, .large]) }
        .sheet(isPresented: $showPoses) { PosePickerSheet().presentationDetents([.medium, .large]) }
        .sensoryFeedback(.selection, trigger: coach.mode)
        .sensoryFeedback(.impact(weight: .medium), trigger: coach.shutterCount)
        .alert("Wraly", isPresented: Binding(get: { coach.errorMessage != nil }, set: { if !$0 { coach.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(coach.errorMessage ?? "") }
    }

    private var viewfinder: some View {
        ZStack {
            CameraPreview(session: coach.cameraService.session, generation: coach.cameraGeneration)
            GuideOverlay()
            if coach.isSwitchingCamera {
                Rectangle().fill(.ultraThinMaterial).transition(.opacity)
            }
            if coach.countdown != nil {
                RoundedRectangle(cornerRadius: 14).stroke(Color.green, lineWidth: 4)
                Text("Hold it")
                    .font(.title3.weight(.bold))
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(.green.opacity(0.85), in: Capsule())
                    .foregroundStyle(.black)
                    .transition(.scale.combined(with: .opacity))
            }
            // Shutter blink.
            Color.black.opacity(flash ? 0.75 : 0).allowsHitTesting(false)
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .rotation3DEffect(.degrees(coach.usingFrontCamera ? 180 : 0), axis: (x: 0, y: 1, z: 0))
        // Undo the mirror of the 3D flip so the picture itself isn't reversed.
        .scaleEffect(x: coach.usingFrontCamera ? -1 : 1, y: 1)
        .animation(.easeInOut(duration: 0.35), value: coach.usingFrontCamera)
        .animation(.easeOut(duration: 0.2), value: coach.isSwitchingCamera)
        .animation(.snappy, value: coach.countdown)
        .overlay(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                InstructionBanner(guidance: coach.state.primary, ready: coach.state.readyToCapture,
                                  onWiped: { coach.lensWiped() })
                    .onTapGesture { showDetails = true }
                PoseCard(showPicker: $showPoses)
            }
            .padding(10)
        }
        .overlay(alignment: .bottom) {
            ZoomStops().padding(.bottom, 12)
        }
        .contentShape(Rectangle())
        // Swipe sideways to change mode; double-tap to flip the camera — as in the Camera app.
        .gesture(
            DragGesture(minimumDistance: 30).onEnded { v in
                guard abs(v.translation.width) > abs(v.translation.height) * 1.5 else { return }
                withAnimation(.snappy) { coach.shiftMode(v.translation.width < 0 ? 1 : -1) }
            }
        )
        .onTapGesture(count: 2) { coach.flipCamera() }
        .onChange(of: coach.shutterCount) {
            flash = true
            withAnimation(.easeOut(duration: 0.25)) { flash = false }
        }
        .accessibilityAction(named: "Flip camera") { coach.flipCamera() }
    }
}

// MARK: - Top bar: voice, what Wraly sees, settings

private struct TopBar: View {
    @Environment(CoachController.self) private var coach
    @Binding var showSettings: Bool

    var body: some View {
        @Bindable var coach = coach
        HStack(spacing: 12) {
            Button { coach.voiceEnabled.toggle() } label: {
                Image(systemName: coach.voiceEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.12), in: Circle())
            }
            .accessibilityLabel(coach.voiceEnabled ? "Mute voice coaching" : "Turn on voice coaching")

            Spacer(minLength: 0)
            SubjectBadge()
            Spacer(minLength: 0)

            Button { showSettings = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.12), in: Circle())
            }
            .accessibilityLabel("Settings")
        }
        .font(.subheadline.weight(.semibold))
        .tint(.white)
        .foregroundStyle(.white)
    }
}

/// What Wraly is coaching right now, e.g. "✦ Food" in Auto or "Portrait · Half body".
/// In portrait it doubles as the shot picker.
private struct SubjectBadge: View {
    @Environment(CoachController.self) private var coach

    var body: some View {
        let portrait = coach.state.mode == .portrait && (coach.mode == .portrait || coach.mode == .auto)
        VStack(spacing: 2) {
            if portrait {
                Menu {
                    Picker("Shot", selection: Binding(get: { coach.targetShot }, set: { coach.targetShot = $0 })) {
                        Text("Auto").tag(ShotType?.none)
                        ForEach(ShotType.allCases) { Text($0.title).tag(ShotType?.some($0)) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        badgeLabel
                        Text("· \(coach.targetShot?.title ?? coach.state.shot.title)").foregroundStyle(.yellow)
                        Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                    }
                    .modifier(BadgeStyle())
                }
                .accessibilityLabel("Shot type: \(coach.targetShot?.title ?? "automatic, \(coach.state.shot.title)")")
            } else {
                badgeLabel.modifier(BadgeStyle())
            }
            Text(coach.exposureReadout)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
        }
        .animation(.snappy, value: coach.state.subject)
        .animation(.snappy, value: coach.state.mode)
    }

    @ViewBuilder private var badgeLabel: some View {
        if coach.mode == .auto {
            Label {
                Text(coach.state.subject.title)
            } icon: {
                Image(systemName: coach.state.subject.symbol)
            }
            .overlay(alignment: .topLeading) {
                Image(systemName: "sparkle").font(.system(size: 8, weight: .bold)).foregroundStyle(.yellow).offset(x: -7, y: -5)
            }
            .accessibilityLabel("Auto: \(coach.state.subject.title)")
        } else {
            Label(coach.mode.title, systemImage: coach.mode.symbol)
        }
    }
}

private struct BadgeStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.white.opacity(0.12), in: Capsule())
            .foregroundStyle(.white)
    }
}

// MARK: - Mode strip

/// A horizontally scrolling list of modes with the current one centred, like the Camera app.
private struct ModeStrip: View {
    @Environment(CoachController.self) private var coach

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 22) {
                        ForEach(CaptureMode.allCases) { m in
                            let selected = coach.mode == m
                            Button { withAnimation(.snappy) { coach.mode = m } } label: {
                                Text(m.title.uppercased())
                                    .font(.footnote.weight(.semibold))
                                    .kerning(0.6)
                                    .foregroundStyle(selected ? Color.yellow : Color.white.opacity(0.7))
                                    .padding(.vertical, 8)
                                    .fixedSize()
                            }
                            .id(m)
                            .accessibilityLabel("\(m.title) mode")
                            .accessibilityAddTraits(selected ? .isSelected : [])
                        }
                    }
                    .padding(.horizontal, geo.size.width / 2 - 30)
                }
                .onAppear { proxy.scrollTo(coach.mode, anchor: .center) }
                .onChange(of: coach.mode) { _, m in withAnimation(.snappy) { proxy.scrollTo(m, anchor: .center) } }
            }
        }
        .mask(LinearGradient(colors: [.clear, .black, .black, .clear], startPoint: .leading, endPoint: .trailing))
    }
}

// MARK: - Instruction banner

struct InstructionBanner: View {
    let guidance: Guidance?
    let ready: Bool
    var onWiped: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 28)
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 2) {
                if let g = guidance, g.audience == .subject {
                    Text("TELL THEM").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                }
                Text(text).font(.callout.weight(.semibold)).lineLimit(2)
            }
            Spacer(minLength: 0)
            if guidance?.category == .lens {
                // The fix happens off-screen, so confirm it here.
                Button("Wiped", action: onWiped)
                    .font(.footnote.weight(.bold))
                    .buttonStyle(.borderedProminent)
                    .tint(.yellow)
                    .foregroundStyle(.black)
            } else {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(tint.opacity(0.5), lineWidth: 1))
        .animation(.snappy, value: guidance?.id)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows everything Wraly sees")
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
        case .turnSideways: return "rectangle.landscape.rotate"
        case .turnUpright: return "rectangle.portrait.rotate"
        case .lookAtLens: return "eye"
        }
    }
}

// MARK: - Zoom

private struct ZoomStops: View {
    @Environment(CoachController.self) private var coach

    var body: some View {
        // The front camera has one lens: nothing to pick.
        if coach.camera.opticalZoomStops.count > 1, !coach.usingFrontCamera {
            HStack(spacing: 6) {
                ForEach(coach.camera.opticalZoomStops, id: \.self) { z in
                    let current = abs(coach.camera.zoomFactor - z) < 0.05
                    let suggested = coach.state.plan.suggestedZoom.map { abs($0 - z) < 0.05 } ?? false
                    Button { coach.setZoom(z) } label: {
                        Text(current ? label(z) : short(z))
                            .font(.caption.weight(.bold).monospacedDigit())
                            .frame(width: current ? 38 : 30, height: current ? 38 : 30)
                            .background(Color.black.opacity(0.45), in: Circle())
                            .overlay(Circle().stroke(suggested ? Color.yellow : .clear, lineWidth: 2))
                            .foregroundStyle(current ? Color.yellow : Color.white)
                    }
                    .accessibilityLabel("\(label(z)) zoom\(suggested ? ", suggested" : "")")
                }
            }
            .padding(4)
            .background(Color.black.opacity(0.25), in: Capsule())
            .animation(.snappy, value: coach.camera.zoomFactor)
        }
    }

    private func label(_ z: Double) -> String { short(z) + "×" }
    private func short(_ z: Double) -> String {
        z == z.rounded() ? "\(Int(z))" : String(format: "%.1f", z).replacingOccurrences(of: "0.", with: ".")
    }
}

// MARK: - Bottom bar: last photo, shutter with readiness ring, flip camera

private struct BottomBar: View {
    @Environment(CoachController.self) private var coach
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack {
            // Opens the Photos app, where the newest photo is first in Recents.
            Button { openURL(URL(string: "photos-redirect://")!) } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08))
                    if let img = coach.lastPhoto?.preview {
                        Image(uiImage: img).resizable().scaledToFill()
                            .id(coach.photoCount)
                            .transition(.scale(scale: 0.4).combined(with: .opacity))
                    }
                }
                .frame(width: 54, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.25), lineWidth: 1))
            }
            .disabled(coach.lastPhoto == nil)
            .accessibilityLabel("Last photo")
            .accessibilityHint("Opens the Photos app")

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
                        .scaleEffect(coach.isCapturing ? 0.85 : 1)
                        .animation(.spring(duration: 0.2), value: coach.isCapturing)
                }
                .frame(width: 80, height: 80)
            }
            .accessibilityLabel("Take photo")
            .accessibilityValue("\(Int(coach.state.readiness * 100)) percent ready")

            Spacer()

            Button { coach.flipCamera() } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.title3.weight(.semibold))
                    .rotationEffect(.degrees(coach.usingFrontCamera ? 180 : 0))
                    .animation(.spring(duration: 0.4), value: coach.usingFrontCamera)
                    .frame(width: 54, height: 54)
                    .background(Color.white.opacity(0.12), in: Circle())
            }
            .tint(.white)
            .disabled(coach.isSwitchingCamera)
            .accessibilityLabel(coach.usingFrontCamera ? "Switch to back camera" : "Switch to selfie camera")
        }
        .padding(.horizontal, 24)
    }
}

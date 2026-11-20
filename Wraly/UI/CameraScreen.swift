import SwiftUI
import WralyCore

/// The camera, designed around one idea: Wraly is looking with you.
///
/// - The room behind the viewfinder glows with the light Wraly reads in the scene
///   (amber at golden hour, indigo at night, teal at the beach).
/// - The recipe card names the shot and the settings it has dialled in ("Golden-hour
///   portrait · 1/250 · +0.7 EV"), and a scan sweeps the frame whenever that changes.
/// - Things it recognises get brackets and tags; the one instruction floats next to
///   the subject's head instead of in a banner.
/// - The viewfinder's edge fills with light as the shot gets ready.
/// - The shutter is an aperture iris that opens as the frame gets ready, and the
///   modes sit on a dial you turn with your thumb.
struct CameraScreen: View {
    @Environment(CoachController.self) private var coach
    @State private var showDetails = false
    @State private var showSettings = false
    @State private var showPoses = false
    @State private var flash = false

    var body: some View {
        ZStack {
            AmbientBackground(palette: Palette.for(coach.state)).ignoresSafeArea()
            VStack(spacing: 0) {
                TopBar(showSettings: $showSettings, showDetails: $showDetails)
                    .padding(.horizontal, 14)
                    .padding(.top, 2)
                viewfinder
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                Spacer(minLength: 0)
                ModeDial()
                    .frame(height: 54)
                BottomBar()
                    .padding(.bottom, 8)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showDetails) { DetailsSheet().presentationDetents([.medium, .large]) }
        .sheet(isPresented: $showSettings) { SettingsSheet().presentationDetents([.medium, .large]) }
        .sheet(isPresented: $showPoses) { PosePickerSheet().presentationDetents([.medium, .large]) }
        .sensoryFeedback(.selection, trigger: coach.mode)
        .sensoryFeedback(.impact(weight: .medium), trigger: coach.shutterCount)
        .sensoryFeedback(.success, trigger: coach.state.readyToCapture) { _, ready in ready }
        .alert("Wraly", isPresented: Binding(get: { coach.errorMessage != nil }, set: { if !$0 { coach.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(coach.errorMessage ?? "") }
    }

    private var viewfinder: some View {
        ZStack {
            CameraPreview(session: coach.cameraService.session, generation: coach.cameraGeneration)
            GuideOverlay()
            SceneTags()
            ScanSweep(trigger: coach.state.plan.recipe)
            CoachBubble(onWiped: { coach.lensWiped() }, onTap: { showDetails = true })
            if coach.isSwitchingCamera {
                Rectangle().fill(.ultraThinMaterial).transition(.opacity)
            }
            Color.black.opacity(flash ? 0.8 : 0).allowsHitTesting(false)
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(ReadinessEdge(readiness: coach.state.readiness, ready: coach.state.readyToCapture,
                               holding: coach.countdown != nil))
        .overlay(alignment: .topLeading) {
            PoseCard(showPicker: $showPoses).padding(12).frame(maxWidth: 300, alignment: .leading)
        }
        .overlay(alignment: .bottom) { ZoomStops().padding(.bottom, 14) }
        .rotation3DEffect(.degrees(coach.usingFrontCamera ? 180 : 0), axis: (x: 0, y: 1, z: 0))
        // Undo the mirror of the 3D flip so the picture itself isn't reversed.
        .scaleEffect(x: coach.usingFrontCamera ? -1 : 1, y: 1)
        .animation(.easeInOut(duration: 0.4), value: coach.usingFrontCamera)
        .animation(.easeOut(duration: 0.2), value: coach.isSwitchingCamera)
        .contentShape(Rectangle())
        // Swipe sideways to turn the mode dial; double-tap to flip the camera.
        .gesture(
            DragGesture(minimumDistance: 30).onEnded { v in
                guard abs(v.translation.width) > abs(v.translation.height) * 1.5 else { return }
                withAnimation(.snappy) { coach.shiftMode(v.translation.width < 0 ? 1 : -1) }
            }
        )
        .onTapGesture(count: 2) { coach.flipCamera() }
        .onChange(of: coach.shutterCount) {
            flash = true
            withAnimation(.easeOut(duration: 0.3)) { flash = false }
        }
        .accessibilityAction(named: "Flip camera") { coach.flipCamera() }
    }
}

// MARK: - Ambient light

/// Colours for the light Wraly reads in the scene.
enum Palette {
    static func `for`(_ s: CoachState) -> [Color] {
        switch s.surroundings.first {
        case .sunset?: return [.orange, .pink, Color(red: 0.5, green: 0.1, blue: 0.3)]
        case .blueHour?: return [.blue, .indigo, .purple]
        case .night?: return [.indigo, Color(red: 0.1, green: 0.1, blue: 0.35), .purple]
        case .stage?: return [.pink, .purple, .blue]
        case .beach?: return [.teal, .cyan, Color(red: 0.9, green: 0.8, blue: 0.55)]
        case .snow?: return [.cyan, .white, .blue]
        case .greenery?: return [.green, .mint, .teal]
        case .water?: return [.blue, .teal, .cyan]
        case .city?: return [.gray, .blue, .indigo]
        case .indoor?: return [.orange, .brown, Color(red: 0.6, green: 0.4, blue: 0.2)]
        case .harshSun?: return [.yellow, .orange, .white]
        case .shade?: return [.teal, .blue, .gray]
        case .backlit?: return [.yellow, .orange, .pink]
        case nil:
            switch s.subject {
            case .food: return [.orange, .red, .yellow]
            case .flower: return [.pink, .purple, .green]
            case .pet: return [.orange, .brown, .yellow]
            case .landscape: return [.green, .blue, .teal]
            default: return [.teal, .indigo, .purple]
            }
        }
    }
}

/// Slowly drifting blurred light behind the viewfinder.
private struct AmbientBackground: View {
    let palette: [Color]
    @State private var drift = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                Color.black
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(palette[i % palette.count].opacity(0.38))
                        .frame(width: w * 0.95, height: w * 0.95)
                        .offset(x: (drift ? 1 : -1) * w * [0.28, -0.3, 0.12][i],
                                y: h * [-0.32, 0.05, 0.38][i] + (drift ? 1 : -1) * 30)
                }
            }
            .blur(radius: 70)
            .animation(.easeInOut(duration: 1.2), value: palette.description)
        }
        .onAppear { withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) { drift = true } }
    }
}

// MARK: - Top bar: voice, recipe card, settings

private struct TopBar: View {
    @Environment(CoachController.self) private var coach
    @Binding var showSettings: Bool
    @Binding var showDetails: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            GlassButton(symbol: coach.voiceEnabled ? "waveform" : "speaker.slash.fill",
                        label: coach.voiceEnabled ? "Mute voice coaching" : "Turn on voice coaching") {
                coach.voiceEnabled.toggle()
            }
            RecipeCard().onTapGesture { showDetails = true }
            GlassButton(symbol: "slider.horizontal.3", label: "Settings") { showSettings = true }
        }
    }
}

private struct GlassButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.15)))
        }
        .tint(.white)
        .accessibilityLabel(label)
    }
}

/// The shot Wraly has recognised and the settings it has dialled in for it.
private struct RecipeCard: View {
    @Environment(CoachController.self) private var coach

    var body: some View {
        let plan = coach.state.plan
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: coach.mode == .auto ? coach.state.subject.symbol : coach.mode.symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(.white.opacity(0.14)))
                if let s = coach.state.surroundings.first {
                    Image(systemName: s.symbol)
                        .font(.system(size: 9, weight: .bold))
                        .padding(3)
                        .background(Circle().fill(Palette.for(coach.state)[0]))
                        .offset(x: 4, y: 4)
                }
            }
            .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if coach.mode == .auto {
                        Image(systemName: "sparkles").font(.system(size: 9, weight: .bold)).foregroundStyle(.yellow)
                    }
                    Text(plan.recipe.isEmpty ? coach.mode.title : plan.recipe)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .contentTransition(.interpolate)
                }
                Text(settingsLine(plan))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 6).padding(.trailing, 12).padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.15)))
        .animation(.snappy, value: plan.recipe)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(plan.recipe). \(settingsLine(plan))")
        .accessibilityHint("Shows what Wraly sees and why")
        .accessibilityAddTraits(.isButton)
    }

    private func settingsLine(_ p: CapturePlan) -> String {
        var parts = [coach.exposureReadout.replacingOccurrences(of: " · ", with: " ")]
        if case let .locked(k, _) = p.whiteBalance { parts.append("\(Int(k))K") }
        if p.burstCount > 1 { parts.append("×\(p.burstCount)") }
        if p.flash == .fill { parts.append("⚡︎") }
        return parts.filter { !$0.isEmpty }.joined(separator: "  ")
    }
}

// MARK: - The instruction, beside the subject

/// The one thing to fix, floating next to the subject's head (or at the top of the
/// frame when there's no one), turned to read upright however the phone is held.
private struct CoachBubble: View {
    @Environment(CoachController.self) private var coach
    let onWiped: () -> Void
    let onTap: () -> Void

    var body: some View {
        GeometryReader { geo in
            let map = FrameMapper(orientation: coach.camera.orientation, mirrored: coach.usingFrontCamera, size: geo.size)
            let (anchor, below) = anchorPoint()
            let p = map.point(anchor)
            bubble(below: below)
                .frame(maxWidth: map.uprightWidth * 0.82)
                .fixedSize(horizontal: false, vertical: true)
                .rotationEffect(map.textRotation)
                .position(p)
                .animation(.interpolatingSpring(stiffness: 120, damping: 20), value: anchor)
        }
    }

    /// Above the head when there's room, otherwise below the chin; the top of the frame without a face.
    private func anchorPoint() -> (Point2, Bool) {
        let q = { (v: Double) in (v * 50).rounded() / 50 }   // calm the motion
        guard let face = coach.faceBox, coach.state.mode.needsPerson else { return (Point2(0.5, 0.1), false) }
        let x = min(max(q(face.midX), 0.4), 0.6)
        let crown = face.minY - face.height * 0.22
        if crown > 0.2 { return (Point2(x, q(crown - 0.075)), false) }
        if face.maxY < 0.72 { return (Point2(x, q(face.maxY + 0.085)), true) }
        return (Point2(0.5, 0.1), false)
    }

    private func bubble(below: Bool) -> some View {
        let g = coach.state.primary
        let ready = coach.state.readyToCapture
        let tint = Self.tint(g, ready: ready)
        return HStack(spacing: 9) {
            Image(systemName: Self.icon(g, ready: ready, holding: coach.countdown != nil))
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 1) {
                if let g, g.audience == .subject {
                    Text("TELL THEM").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white.opacity(0.6))
                }
                Text(coach.countdown != nil ? "Perfect — hold it" : g?.message ?? (ready ? "Perfect — hold it" : "Looking good"))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .lineLimit(2)
                    .contentTransition(.interpolate)
            }
            if g?.category == .lens {
                Button("Wiped", action: onWiped)
                    .font(.footnote.weight(.bold))
                    .buttonStyle(.borderedProminent)
                    .tint(.yellow)
                    .foregroundStyle(.black)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(tint.opacity(0.7), lineWidth: 1.2))
        .shadow(color: tint.opacity(0.35), radius: 10)
        .animation(.snappy, value: g?.id)
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows everything Wraly sees")
    }

    static func tint(_ g: Guidance?, ready: Bool) -> Color {
        guard let g else { return .green }
        switch g.severity {
        case .critical: return .red
        case .fix: return .yellow
        case .tip: return .cyan
        }
    }

    static func icon(_ g: Guidance?, ready: Bool, holding: Bool) -> String {
        if holding { return "camera.aperture" }
        guard let g else { return ready ? "checkmark.circle.fill" : "eye" }
        guard let cue = g.cue else { return "lightbulb.fill" }
        switch cue {
        case .moveLeft: return "arrow.left"
        case .moveRight: return "arrow.right"
        case .moveCloser: return "figure.walk.motion"
        case .moveBack: return "arrow.uturn.backward"
        case .raisePhone: return "arrow.up.to.line"
        case .lowerPhone: return "arrow.down.to.line"
        case .tiltUp, .tiltDown: return "arrow.up.and.down.circle"
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

// MARK: - Readiness edge

/// The viewfinder's rim fills with light as the frame gets ready, and glows green when it is.
private struct ReadinessEdge: View {
    let readiness: Double
    let ready: Bool
    let holding: Bool
    @State private var spin = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)
        ZStack {
            shape.stroke(.white.opacity(0.10), lineWidth: 1)
            shape
                .trim(from: 0, to: max(0.02, readiness))
                .stroke(AngularGradient(colors: ready ? [.green, .mint, .green] : [.yellow, .orange, .pink, .yellow],
                                        center: .center, angle: .degrees(spin ? 360 : 0)),
                        style: StrokeStyle(lineWidth: holding ? 5 : 3, lineCap: .round))
                .shadow(color: (ready ? Color.green : .orange).opacity(0.7), radius: holding ? 12 : 6)
        }
        .animation(.easeOut(duration: 0.35), value: readiness)
        .animation(.snappy, value: holding)
        .allowsHitTesting(false)
        .onAppear { withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) { spin = true } }
    }
}

// MARK: - Mode dial

/// The modes on a curved dial above the shutter, like the dial on a camera's top plate.
/// Turn it with your thumb or tap a mode.
private struct ModeDial: View {
    @Environment(CoachController.self) private var coach
    @GestureState private var drag: CGFloat = 0

    private let radius: CGFloat = 420
    private let step: Double = 9   // degrees between modes

    var body: some View {
        GeometryReader { geo in
            let modes = CaptureMode.allCases
            let selected = Double(modes.firstIndex(of: coach.mode) ?? 0)
            let turned = selected - Double(drag / (radius * step * .pi / 180))
            let cx = geo.size.width / 2, cy = radius + 14
            ZStack {
                // The selected notch.
                Capsule().fill(.yellow).frame(width: 4, height: 4).position(x: cx, y: 4)
                ForEach(Array(modes.enumerated()), id: \.element) { i, m in
                    let offset = Double(i) - turned
                    let a = (-90 + offset * step) * .pi / 180
                    let on = m == coach.mode && drag == 0
                    Text(m.title.uppercased())
                        .font(.system(size: on ? 13 : 11, weight: on ? .bold : .semibold, design: .rounded))
                        .kerning(1)
                        .foregroundStyle(on ? Color.yellow : .white.opacity(0.75))
                        .fixedSize()
                        .rotationEffect(.radians(a + .pi / 2))
                        .position(x: cx + radius * cos(a), y: cy + radius * sin(a))
                        .opacity(max(0, 1 - abs(offset) / 3.2))
                        .onTapGesture { withAnimation(.snappy) { coach.mode = m } }
                        .accessibilityLabel("\(m.title) mode")
                        .accessibilityAddTraits(m == coach.mode ? [.isButton, .isSelected] : .isButton)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 8)
                    .updating($drag) { v, s, _ in s = v.translation.width }
                    .onEnded { v in
                        let moved = Int((-v.translation.width / (radius * step * .pi / 180)).rounded())
                        withAnimation(.snappy) { coach.shiftMode(moved) }
                    }
            )
            .animation(.snappy, value: coach.mode)
        }
        .mask(LinearGradient(colors: [.clear, .black, .black, .clear], startPoint: .leading, endPoint: .trailing))
    }
}

// MARK: - Bottom bar: last photo, iris shutter, flip

private struct BottomBar: View {
    @Environment(CoachController.self) private var coach
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack {
            // Opens the Photos app, where the newest photo is first in Recents.
            Button { openURL(URL(string: "photos-redirect://")!) } label: {
                ZStack {
                    Circle().fill(.ultraThinMaterial)
                    if let img = coach.lastPhoto?.preview {
                        Image(uiImage: img).resizable().scaledToFill()
                            .id(coach.photoCount)
                            .transition(.scale(scale: 0.3).combined(with: .opacity))
                    } else {
                        Image(systemName: "photo.on.rectangle").foregroundStyle(.white.opacity(0.5))
                    }
                }
                .frame(width: 54, height: 54)
                .clipShape(Circle())
                .overlay(Circle().stroke(.white.opacity(0.35), lineWidth: 1.5))
            }
            .disabled(coach.lastPhoto == nil)
            .accessibilityLabel("Last photo")
            .accessibilityHint("Opens the Photos app")

            Spacer()

            Button { coach.capture() } label: {
                IrisShutter(opening: coach.isCapturing ? 0.05 : coach.state.readiness,
                            ready: coach.state.readyToCapture)
                    .frame(width: 84, height: 84)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Take photo")
            .accessibilityValue("\(Int(coach.state.readiness * 100)) percent ready")

            Spacer()

            GlassButton(symbol: "arrow.triangle.2.circlepath.camera",
                        label: coach.usingFrontCamera ? "Switch to back camera" : "Switch to selfie camera") {
                coach.flipCamera()
            }
            .scaleEffect(1.3)
            .frame(width: 54, height: 54)
            .disabled(coach.isSwitchingCamera)
        }
        .padding(.horizontal, 28)
    }
}

/// A camera aperture: its blades open as the frame gets ready and snap shut when the photo is taken.
private struct IrisShutter: View {
    var opening: Double
    var ready: Bool

    var body: some View {
        ZStack {
            Circle().stroke(ready ? Color.green : .white.opacity(0.9), lineWidth: 3)
                .shadow(color: ready ? .green.opacity(0.8) : .clear, radius: 8)
            IrisShape(opening: 0.12 + 0.83 * opening)
                .fill(LinearGradient(colors: [Color(white: 0.32), Color(white: 0.12)], startPoint: .topLeading, endPoint: .bottomTrailing),
                      style: FillStyle(eoFill: true))
                .overlay(IrisShape(opening: 0.12 + 0.83 * opening, bladesOnly: true)
                    .stroke(.white.opacity(0.35), lineWidth: 0.8))
                .clipShape(Circle())
                .padding(7)
            // Light through the open aperture.
            Circle()
                .fill(RadialGradient(colors: [ready ? .green.opacity(0.9) : .white.opacity(0.85), .clear],
                                     center: .center, startRadius: 0, endRadius: 30))
                .padding(7)
                .mask(IrisShape(opening: 0.12 + 0.83 * opening, holeOnly: true).padding(7))
        }
        .animation(.spring(duration: 0.35, bounce: 0.25), value: opening)
        .animation(.snappy, value: ready)
    }
}

/// Seven blades around a polygonal hole. `opening` 0 = shut, 1 = wide open.
private struct IrisShape: Shape {
    var opening: Double
    var bladesOnly = false
    var holeOnly = false
    var animatableData: Double {
        get { opening }
        set { opening = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let n = 7
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let R = min(rect.width, rect.height) / 2
        let r = R * opening
        let twist = (1 - opening) * 0.9
        let verts = (0..<n).map { i -> CGPoint in
            let a = Double(i) * 2 * .pi / Double(n) + twist
            return CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
        }
        var hole = Path()
        hole.addLines(verts); hole.closeSubpath()
        if holeOnly { return hole }

        var blades = Path()
        for (i, v) in verts.enumerated() {
            // Each blade edge leaves the hole roughly tangentially and runs to the rim.
            let a = Double(i) * 2 * .pi / Double(n) + twist + .pi / 2 + 0.45
            blades.move(to: v)
            blades.addLine(to: CGPoint(x: v.x + 2 * R * cos(a), y: v.y + 2 * R * sin(a)))
        }
        if bladesOnly { return blades }
        var p = Path(ellipseIn: CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R))
        p.addPath(hole)
        return p
    }
}

// MARK: - Zoom

private struct ZoomStops: View {
    @Environment(CoachController.self) private var coach

    var body: some View {
        // The front camera has one lens: nothing to pick.
        if coach.camera.opticalZoomStops.count > 1, !coach.usingFrontCamera {
            HStack(spacing: 4) {
                ForEach(coach.camera.opticalZoomStops, id: \.self) { z in
                    let current = abs(coach.camera.zoomFactor - z) < 0.05
                    let suggested = coach.state.plan.suggestedZoom.map { abs($0 - z) < 0.05 } ?? false
                    Button { coach.setZoom(z) } label: {
                        Text(current ? label(z) : short(z))
                            .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                            .frame(width: current ? 36 : 28, height: current ? 36 : 28)
                            .background(Circle().fill(.black.opacity(current ? 0.55 : 0.3)))
                            .overlay(Circle().stroke(suggested ? Color.yellow : .clear, lineWidth: 1.5))
                            .foregroundStyle(current ? Color.yellow : .white)
                    }
                    .accessibilityLabel("\(label(z)) zoom\(suggested ? ", suggested" : "")")
                }
            }
            .padding(4)
            .background(.ultraThinMaterial.opacity(0.7), in: Capsule())
            .animation(.snappy, value: coach.camera.zoomFactor)
        }
    }

    private func label(_ z: Double) -> String { short(z) + "×" }
    private func short(_ z: Double) -> String {
        z == z.rounded() ? "\(Int(z))" : String(format: "%.1f", z).replacingOccurrences(of: "0.", with: ".")
    }
}

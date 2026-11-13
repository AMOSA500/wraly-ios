import SwiftUI

@main
struct WralyApp: App {
    @State private var coach = CoachController()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(coach)
                .preferredColorScheme(.dark)
                .statusBarHidden()
        }
    }
}

struct RootView: View {
    @Environment(CoachController.self) private var coach

    var body: some View {
        Group {
            switch coach.permission {
            case .authorized:
                CameraScreen()
            case .denied:
                PermissionView(denied: true)
            case .unknown:
                PermissionView(denied: false)
            }
        }
        .task { await coach.start() }
    }
}

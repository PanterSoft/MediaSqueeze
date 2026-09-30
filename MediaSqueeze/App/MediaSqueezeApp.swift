import SwiftUI

@main
struct MediaSqueezeApp: App {
    @State private var library = PhotoLibraryService()
    @State private var settings = SettingsStore()
    @State private var queue = CompressionQueue()
    @State private var scanner = DuplicateScanner()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .environment(settings)
                .environment(queue)
                .environment(scanner)
        }
    }
}

struct RootView: View {
    @Environment(PhotoLibraryService.self) private var library
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if library.hasAccess {
                TabView {
                    VideosView()
                        .tabItem { Label("Compress", systemImage: "arrow.down.right.and.arrow.up.left") }
                    DuplicatesView()
                        .tabItem { Label("Clean Up", systemImage: "square.on.square") }
                    SettingsView()
                        .tabItem { Label("Settings", systemImage: "gearshape") }
                }
                .task {
                    if !library.hasLoadedVideos {
                        await library.reloadVideos()
                    }
                }
            } else {
                PermissionView()
            }
        }
        .onAppear { library.refreshAuthorization() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { library.refreshAuthorization() }
        }
    }
}

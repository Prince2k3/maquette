import SwiftUI

@main
struct MaquetteDemoApp: App {
    var body: some Scene {
        #if os(visionOS)
        // The plain window hosts the demo, because it is the scene every launch path can connect:
        // this simulator's shell requests UIWindowSceneSessionRoleApplication at launch even when
        // UIApplicationPreferredDefaultSceneSessionRole names the volumetric role (verified against
        // the shipped plist), and an app whose only scene is volumetric dies in findSceneListItem
        // before a window exists. The volumetric window is a button away — see ContentView's
        // visionOS header control — which is also the reliable order: open it from a running app
        // rather than during scene bring-up, where the hand-off proved racy.
        WindowGroup {
            ContentView()
        }

        WindowGroup(id: "volume") {
            ContentView(isVolume: true)
        }
        .windowStyle(.volumetric)
        .defaultSize(width: 1.0, height: 1.0, depth: 1.0, in: .meters)
        #elseif os(macOS)
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1000, height: 760)
        #else
        WindowGroup {
            ContentView()
        }
        #endif
    }
}

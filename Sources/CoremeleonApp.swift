import SwiftUI

@main
struct CoremeleonApp: App {
    @StateObject private var store = ModelStore()
    var body: some Scene {
        WindowGroup { ContentView().environmentObject(store) }
    }
}

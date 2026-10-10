import SwiftUI

@main
struct DanceCountApp: App {
    @State private var model = CountModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
    }
}

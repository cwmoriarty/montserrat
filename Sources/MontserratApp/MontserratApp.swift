import SwiftUI

@main
struct MontserratApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("Montserrat", systemImage: "externaldrive.badge.checkmark") {
            DiskMenuView(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

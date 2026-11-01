import SwiftUI

@main
struct ReklamsizRadyoApp: App {
    @StateObject private var depo = Depo()
    @StateObject private var oynatici = Oynatici()
    @StateObject private var bildirim = Bildirim.shared

    init() {
        try? FileManager.default.createDirectory(at: Depo.kayitKlasoru, withIntermediateDirectories: true)
    }

    var body: some Scene {
        WindowGroup {
            AnaEkran()
                .environmentObject(depo)
                .environmentObject(oynatici)
                .environmentObject(bildirim)
        }
    }
}

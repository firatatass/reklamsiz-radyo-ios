import SwiftUI

@main
struct ReklamsizRadyoApp: App {
    @StateObject private var liste = ListeDeposu()
    @StateObject private var oynatici = Oynatici()

    var body: some Scene {
        WindowGroup {
            AnaEkran()
                .environmentObject(liste)
                .environmentObject(oynatici)
        }
    }
}

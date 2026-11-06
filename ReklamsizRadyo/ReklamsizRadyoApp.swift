import SwiftUI

@main
struct ReklamsizRadyoApp: App {
    @StateObject private var depo = Depo()
    @StateObject private var oynatici = Oynatici()
    @StateObject private var bildirim = Bildirim.shared
    @StateObject private var asistan = SesliAsistan.shared
    @AppStorage("app_theme") private var tema = 2
    @Environment(\.scenePhase) private var sahne

    init() {
        try? FileManager.default.createDirectory(at: Depo.kayitKlasoru, withIntermediateDirectories: true)
    }

    var body: some Scene {
        WindowGroup {
            AnaEkran()
                .environmentObject(depo)
                .environmentObject(oynatici)
                .environmentObject(bildirim)
                .environmentObject(asistan)
                .preferredColorScheme(tema == 0 ? .light : tema == 1 ? .dark : nil)
                .onAppear {
                    asistan.depo = depo
                    asistan.oynatici = oynatici
                    SallamaAlgilayici.shared.tetiklendi = {
                        if asistan.acik { asistan.dinlemeyeYenidenBasla() } else { asistan.pencereyiAc() }
                    }
                    SallamaAlgilayici.shared.baslat()
                }
                .onChange(of: sahne) { s in
                    // Android'de de sallama sadece uygulama ekrandayken dinlenir (onResume/onPause).
                    if s == .active { SallamaAlgilayici.shared.baslat() } else { SallamaAlgilayici.shared.durdur() }
                    // Liste açılıp kapatıldıysa ya da ilk açılışta inmediyse uygulama öne gelince öğrenir.
                    if s == .active { Task { await depo.internettenGuncelle() } }
                }
        }
    }
}

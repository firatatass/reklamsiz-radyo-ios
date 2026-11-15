import Intents
import UIKit

/// "Hey Siri, Reklamsız Radyo'da TRT 1 aç/çal": Siri bu cümleleri müzik isteği sayıp Apple'ın medya
/// bölümüne gönderiyor. Bu dosya o isteği (INPlayMediaIntent) uygulamaya bağlar; Kestirmeler açılmadan,
/// uygulama ekrana gelmeden kanal çalar.
enum SiriMedya {
    /// Söylenen ada uyan kanallar (sesli asistanla aynı eşleştirme).
    @MainActor static func bul(_ ad: String) -> [INMediaItem] {
        let d = Depo.paylasilan
        let kayitlar = d.asistanListesi
        var bulunan = KanalBulucu.kesinBul(ad, kayitlar, tvMi: { d.tvMi($0) }, tvKategorisiAcik: false)
        if bulunan.isEmpty {
            let aranan = KanalBulucu.normalize(ad)
            if !aranan.isEmpty { bulunan = kayitlar.filter { KanalBulucu.normalize($0.ad).contains(aranan) } }
        }
        return bulunan.prefix(10).map {
            INMediaItem(identifier: $0.url, title: $0.ad, type: d.tvMi($0) ? .station : .radioStation, artwork: nil)
        }
    }

    /// Kanalı çalar. Uygulama ekrandaysa sesli asistanla aynı yoldan (liste de doğru sekmeye geçer),
    /// değilse doğrudan oynatıcıdan.
    @MainActor static func cal(_ adres: String) -> Bool {
        let d = Depo.paylasilan
        guard let k = d.asistanListesi.first(where: { $0.url == adres }) else {
            OlcumKaydi.shared.yaz("siri medya: kanal listede yok")
            return false
        }
        if UIApplication.shared.applicationState == .active {
            OlcumKaydi.shared.yaz("siri medya: \(k.ad) açılıyor (ekranda)")
            SesliAsistan.shared.istek = .cal(k)
        } else {
            OlcumKaydi.shared.yaz("siri medya: \(k.ad) açılıyor (arka planda)")
            let tv = d.tvMi(k)
            Oynatici.paylasilan.baslat(k, liste: d.asistanListesi.filter { d.tvMi($0) == tv })
        }
        return true
    }
}

final class SiriMedyaIsleyici: NSObject, INPlayMediaIntentHandling {
    func resolveMediaItems(for intent: INPlayMediaIntent,
                           with completion: @escaping ([INPlayMediaMediaItemResolutionResult]) -> Void) {
        let arama = intent.mediaSearch
        let ad = arama?.mediaName ?? ""
        Task { @MainActor in
            OlcumKaydi.shared.yaz("siri medya duydu: ad \"\(ad)\", tür \(arama?.mediaType.rawValue ?? -1)")
            let ogeler = SiriMedya.bul(ad)
            OlcumKaydi.shared.yaz("siri medya: \(ogeler.count) sonuç: \(ogeler.prefix(4).compactMap(\.title).joined(separator: ", "))")
            if ogeler.isEmpty {
                completion([INPlayMediaMediaItemResolutionResult.unsupported()])
            } else if ogeler.count == 1 {
                completion([INPlayMediaMediaItemResolutionResult.success(with: ogeler[0])])
            } else {
                completion([INPlayMediaMediaItemResolutionResult.disambiguation(with: Array(ogeler.prefix(4)))])
            }
        }
    }

    func handle(intent: INPlayMediaIntent, completion: @escaping (INPlayMediaIntentResponse) -> Void) {
        // Çalma uygulamada yapılır: sistem uygulamayı (gerekirse arka planda) açıp temsilciye iletir.
        completion(INPlayMediaIntentResponse(code: .handleInApp, userActivity: nil))
    }
}

/// SwiftUI uygulamasının Siri isteklerini alan temsilcisi.
final class UygulamaTemsilcisi: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
        intent is INPlayMediaIntent ? SiriMedyaIsleyici() : nil
    }

    func application(_ application: UIApplication, handle intent: INIntent,
                     completionHandler: @escaping (INIntentResponse) -> Void) {
        guard let i = intent as? INPlayMediaIntent, let adres = i.mediaItems?.first?.identifier else {
            completionHandler(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
            return
        }
        let tamam = SiriMedya.cal(adres)
        completionHandler(INPlayMediaIntentResponse(code: tamam ? .success : .failure, userActivity: nil))
    }
}

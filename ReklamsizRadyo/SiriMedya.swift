import Intents
import UIKit

/// "Hey Siri, Reklamsız Radyo'da TRT 1 aç/çal": Siri bu cümleleri müzik isteği sayıp Apple'ın medya
/// bölümüne gönderiyor. Bu dosya o isteği (INPlayMediaIntent) uygulamaya bağlar; Kestirmeler açılmadan,
/// uygulama ekrana gelmeden kanal çalar.
enum SiriMedya {
    /// Siri uygulamanın adını kanal adına katıyor ("Kanal D Reklamsız", "Reklamsız Radyo Seymen") ya da
    /// kanal adı yerine yalnızca "Reklamsız" gönderiyor. Uygulama adı atılır; geriye kalan kanal adıdır.
    static func adiTemizle(_ ham: String) -> String {
        var s = " " + KanalBulucu.normalize(ham) + " "
        for k in [" reklamsiz radyo ", " reklamsiz radyoda ", " reklamsiz radyoya ", " reklamsiz radyonun ",
                  " reklamsizda ", " reklamsiz "] {
            s = s.replacingOccurrences(of: k, with: " ")
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Söylenen ada uyan kanallar (sesli asistanla aynı eşleştirme).
    @MainActor static func bul(_ hamAd: String) -> [INMediaItem] {
        let ad = adiTemizle(hamAd)
        if ad.isEmpty { return [] }
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
        let digerleri = [arama?.artistName, arama?.albumName, arama?.genreNames?.joined(separator: "/"),
                         arama?.moodNames?.joined(separator: "/"), arama?.mediaIdentifier].compactMap { $0 }
        Task { @MainActor in
            OlcumKaydi.shared.yaz("siri medya duydu: ad \"\(ad)\", tür \(arama?.mediaType.rawValue ?? -1), diğer: \(digerleri.joined(separator: " | "))")
            // Siri yalnızca uygulama adını gönderdiyse kanal adı eksiktir: Siri kullanıcıya ne açılacağını sorar.
            if SiriMedya.adiTemizle(ad).isEmpty {
                OlcumKaydi.shared.yaz("siri medya: kanal adı yok, Siri soracak")
                completion([INPlayMediaMediaItemResolutionResult.needsValue()])
                return
            }
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

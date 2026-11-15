import AVFoundation
import SwiftUI

/// Güncellemeden sonra bir kez gösterilen "Yenilikler" penceresi.
/// Uygulamayı güncelleyenlere, her sürümde bir kez açılır; Kapat'a basınca o sürüm için bir daha açılmaz.
/// Yeni kurulumda gösterilmez (kullanıcı zaten her şeyi ilk kez görüyor).
enum Yenilikler {
    static let surum = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""

    /// Sürüm başına yenilikler, madde madde. Her madde ekran okuyucuda ayrı bir satır olarak okunur.
    /// Bir sürümün maddesi yoksa pencere açılmaz.
    static let notlar: [String: [String]] = [
        "1.2": [
            "1. Yayınlar daha hızlı açılıyor. Bazı kanallarda yaşanan takılma, donma ve açılmama sorunları giderildi.",
            "2. Ayarlar'a \"Sekmelerin Yeri\" eklendi. Sekmeleri ekranın üstünde veya altında kullanabilirsiniz.",
            "3. Ayarlar'a \"Ekranı Açık Tut\" eklendi. Açıkken, yayın dinlerken ekran kapanmaz.",
            "4. Ayarlar'a \"Asistan Sesi\" eklendi. Sesli asistanın konuşma sesini telefonunuzdaki Türkçe sesler arasından seçebilirsiniz.",
            "5. Çalan bir radyo, kanal veya kayıt silindiğinde yayın artık tamamen duruyor.",
            "6. Sesli asistan, anlaşılamayan komutlarda yüzlerce kanalı okumak yerine komutu tekrar istiyor.",
            "7. Siri ile radyo ve TV kanalı açabilirsiniz. Örneğin \"Hey Siri, Kanal D'yi Reklamsız Radyo'da aç\" deyin. Siri, listenizdeki kanalı açar.",
        ],
    ]

    static var buSurumunNotu: [String]? { notlar[surum] }
}

/// Başlık, maddeler ve en sonda Kapat düğmesi: ekran okuyucuyla sağa kaydırarak sırayla dolaşılır.
struct YeniliklerPenceresi: View {
    @Environment(\.dismiss) private var kapat

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Yenilikler, Sürüm \(Yenilikler.surum)")
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                ForEach(Array((Yenilikler.buSurumunNotu ?? []).enumerated()), id: \.offset) { _, madde in
                    Text(madde)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                BuyukDugme(baslik: "Kapat") { kapat() }
                    .padding(.top, 8)
            }
            .padding()
        }
        .accessibilityAction(.escape) { kapat() }
    }
}

/// Sesli asistanın konuşma sesi (Ayarlar > Asistan Sesi). Yalnızca telefonda yüklü Türkçe sesler seçilebilir;
/// Siri'nin sesleri uygulamalara açık değildir.
enum AsistanSesi {
    static let anahtar = "asistan_sesi"

    static var turkceSesler: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased().hasPrefix("tr") }
            .sorted { $0.name == $1.name ? $0.quality.rawValue > $1.quality.rawValue : $0.name < $1.name }
    }

    /// Seçilen ses; seçilmediyse veya telefondan silindiyse Türkçe varsayılan ses.
    static var secili: AVSpeechSynthesisVoice? {
        if let id = UserDefaults.standard.string(forKey: anahtar), !id.isEmpty, let v = AVSpeechSynthesisVoice(identifier: id) {
            return v
        }
        return AVSpeechSynthesisVoice(language: "tr-TR")
    }

    static func ad(_ v: AVSpeechSynthesisVoice) -> String {
        var ek: [String] = []
        switch v.gender {
        case .female: ek.append("Kadın")
        case .male: ek.append("Erkek")
        default: break
        }
        // iPhone kalite bilgisini adına zaten yazıyorsa ("Cem (Geliştirilmiş)") tekrar eklenmez.
        if !v.name.contains("(") {
            switch v.quality {
            case .enhanced: ek.append("Gelişmiş")
            case .premium: ek.append("Üstün Kalite")
            default: break
            }
        }
        return ek.isEmpty ? v.name : "\(v.name) (\(ek.joined(separator: ", ")))"
    }

    @MainActor private static let onizleyici = AVSpeechSynthesizer()

    /// Seçilen sesle kısa bir örnek cümle okur.
    @MainActor static func dene() {
        let s = AVSpeechUtterance(string: "Merhaba, sesli asistan bu sesle konuşacak.")
        s.voice = secili
        onizleyici.stopSpeaking(at: .immediate)
        onizleyici.speak(s)
    }

    /// Test derlemesinde telefondaki Türkçe sesler ölçüm kaydına yazılır.
    static func kaydaYaz() {
        let hepsi = AVSpeechSynthesisVoice.speechVoices()
        OlcumKaydi.shared.yaz("sesler: telefonda \(hepsi.count) ses, Türkçe \(turkceSesler.count)")
        for v in turkceSesler {
            OlcumKaydi.shared.yaz("ses: \(v.name) | \(v.identifier) | kalite \(v.quality.rawValue) | cinsiyet \(v.gender.rawValue)")
        }
    }
}

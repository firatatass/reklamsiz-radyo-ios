import AVFoundation
import Speech
import UIKit

/// Asistanın ana ekrandan yapılmasını istediği işler (Android'de MainActivity callback'leri).
enum AsistanIstegi: Equatable {
    case cal(Kayit)
    case sekme(String)
    case kategori(String)
    case durdurAnaEkran
}

/// Henüz yazılmamış özellikler: hazır olunca true yapılacak.
enum Hazirlik {
    static let kayit = true
    static let alarm = false
    static let sonrakiSurumMesaji = "Bu özellik bir sonraki deneme sürümünde eklenecek."
    /// Kullanıcı kararı (02.11.2026): çalar saat ve zamanlı kayıt iPhone'da Android'deki gibi çalışamadığı için kaldırıldı.
    static let alarmYokMesaji = "Çalar saat ve zamanlı kayıt özellikleri bu sürümde bulunmuyor."
}

/// Sesli asistan (Android VoiceAssistantManager'ın birebir karşılığı).
@MainActor
final class SesliAsistan: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = SesliAsistan()

    // Pencere
    @Published var acik = false
    @Published var rehberAcik = false
    @Published private(set) var durum = "Dinleniyor, lütfen konuşun..."
    @Published private(set) var durumHata = false
    @Published private(set) var kullaniciSozu = ""
    @Published private(set) var cevap = ""
    @Published private(set) var dinliyor = false
    @Published private(set) var mikIpucu = "Dinleniyor..."
    @Published var istek: AsistanIstegi?

    weak var depo: Depo?
    weak var oynatici: Oynatici?

    private enum Durum {
        case bos, alarmRadyosu, alarmSaati, kayitRadyosu, kayitSaati, zamanlayiciSuresi, temaSecimi, radyoNetlestirme, veriSiniri
    }

    private var durumMakinesi = Durum.bos
    private var seciliAlarmRadyosu: Kayit?
    private var seciliKayitRadyosu: Kayit?
    private var netlestirmeAdaylari: [Kayit]?
    private var netlestirmeEylemi: String?
    private var denemeSayisi = 0

    private let ayar = UserDefaults.standard
    private let tanima = SFSpeechRecognizer(locale: Locale(identifier: "tr-TR"))
    /// Her dinlemede, ses oturumu "çalma ve kayıt"a geçtikten SONRA yeniden kurulur.
    /// (Önceden kurulan motor, mikrofon kapalıyken okunan biçimi saklayıp kayda başlarken uygulamayı çökertiyordu.)
    private var motor: AVAudioEngine?
    private var dinleyiciKurulu = false
    private var tanimaIstegi: SFSpeechAudioBufferRecognitionRequest?
    private var tanimaGorevi: SFSpeechRecognitionTask?
    private var oturum = 0
    private var sonMetin = ""
    private var sessizlikGorevi: Task<Void, Never>?
    private var zamanAsimiGorevi: Task<Void, Never>?
    private let konusucu = AVSpeechSynthesizer()
    private var konusmaSonrasiDinle = false
    private var yedekGorev: Task<Void, Never>?
    private var kapatmaGorevi: Task<Void, Never>?

    override init() {
        super.init()
        konusucu.delegate = self
    }

    private var varsayilanIpucu: String {
        (ayar.object(forKey: "shake_assistant_enabled") as? Bool ?? true)
            ? "Mikrofona dokunun veya telefonu sallayın" : "Konuşmak için mikrofona dokunun"
    }

    // MARK: Pencere

    func pencereyiAc() {
        Task {
            guard await izinleriAl() else {
                Bildirim.shared.goster("Sesli asistan için mikrofon izni gereklidir.")
                return
            }
            durumMakinesi = .bos
            denemeSayisi = 0
            seciliAlarmRadyosu = nil
            seciliKayitRadyosu = nil
            netlestirmeAdaylari = nil
            netlestirmeEylemi = nil
            kullaniciSozu = ""
            cevap = ""
            acik = true
            oynatici?.kis(true)
            durumYaz("Dinleniyor, lütfen konuşun...")
            mikIpucu = "Dinleniyor..."
            dinlemeyeBasla()
        }
    }

    /// Sallama ile: pencere açıksa yeniden dinlemeye başlar.
    func dinlemeyeYenidenBasla() {
        guard acik else { return }
        konusmayiDurdur()
        denemeSayisi = 0
        dinlemeyeBasla()
    }

    func kapat() {
        acik = false
        kapatildi()
    }

    /// Pencere kapandığında (Android setOnDismissListener).
    func kapatildi() {
        kapatmaGorevi?.cancel()
        yedekGorev?.cancel()
        oynatici?.kis(false)
        dinlemeyiDurdur()
        konusmayiDurdur()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
    }

    func mikrofonaDokunuldu() {
        if dinliyor {
            dinlemeyiDurdur()
            durumYaz("Dinleme duraklatıldı. Mikrofona dokunarak konuşabilirsiniz.")
        } else {
            denemeSayisi = 0
            dinlemeyeBasla()
        }
    }

    /// Belirtilen süre geçince, asistan o an konuşuyorsa cümlesini bitirmesini bekleyip pencereyi kapatır.
    private func sonraKapat(_ saniye: Double, sonra: (() -> Void)? = nil) {
        kapatmaGorevi?.cancel()
        kapatmaGorevi = Task {
            try? await Task.sleep(nanoseconds: UInt64(saniye * 1_000_000_000))
            await self.konusmaninBitmesiniBekle()
            if Task.isCancelled { return }
            self.kapat()
            sonra?()
        }
    }

    private func konusmaninBitmesiniBekle() async {
        var bekleme = 0
        while konusucu.isSpeaking && bekleme < 75 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            bekleme += 1
        }
    }

    private func kapatmayiIptalEt() { kapatmaGorevi?.cancel() }

    private func izinleriAl() async -> Bool {
        let konusma: Bool = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        let mikrofon: Bool = await withCheckedContinuation { c in
            AVAudioSession.sharedInstance().requestRecordPermission { c.resume(returning: $0) }
        }
        return konusma && mikrofon
    }

    // MARK: Dinleme

    private func dinlemeyeBasla() {
        kapatmayiIptalEt()
        yedekGorev?.cancel()
        guard let tanima, tanima.isAvailable else {
            durumYaz("Cihazınızda ses tanıma servisi bulunamadı.", hata: true)
            return
        }
        dinlemeyiDurdur()
        konusmayiDurdur()
        do {
            let ses = AVAudioSession.sharedInstance()
            try ses.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP])
            try ses.setActive(true)
            let istek = SFSpeechAudioBufferRecognitionRequest()
            istek.shouldReportPartialResults = true
            let m = AVAudioEngine()
            let giris = m.inputNode
            let bicim = giris.outputFormat(forBus: 0)
            guard bicim.sampleRate > 0, bicim.channelCount > 0 else {
                durumYaz("Mikrofon başlatılamadı. Lütfen tekrar deneyin.", hata: true)
                return
            }
            tanimaIstegi = istek
            giris.installTap(onBus: 0, bufferSize: 1024, format: bicim) { tampon, _ in istek.append(tampon) }
            dinleyiciKurulu = true
            motor = m
            m.prepare()
            try m.start()
            oturum += 1
            let buOturum = oturum
            sonMetin = ""
            tanimaGorevi = tanima.recognitionTask(with: istek) { [weak self] sonuc, hata in
                let metin = sonuc?.bestTranscription.formattedString
                let bitti = sonuc?.isFinal ?? false
                let hataVar = hata != nil
                Task { @MainActor in self?.tanimaGeldi(buOturum, metin, bitti, hataVar) }
            }
            dinliyor = true
            durumYaz("Dinliyorum, lütfen konuşun...")
            mikIpucu = "Dinleniyor..."
            zamanAsimiGorevi = Task {
                try? await Task.sleep(nanoseconds: 7_000_000_000)
                if !Task.isCancelled, self.oturum == buOturum, self.dinliyor, self.sonMetin.isEmpty {
                    self.dinlemeyiDurdur()
                    self.hataOldu(sessizlik: true)
                }
            }
        } catch {
            durumYaz("Mikrofon başlatılamadı: \(error.localizedDescription)", hata: true)
        }
    }

    private func tanimaGeldi(_ buOturum: Int, _ metin: String?, _ bitti: Bool, _ hataVar: Bool) {
        guard buOturum == oturum, dinliyor else { return }
        if let metin, !metin.isEmpty {
            if sonMetin.isEmpty { durumYaz("Konuşma algılandı...") }
            sonMetin = metin
            kullaniciSozu = "\"\(metin)\""
            zamanAsimiGorevi?.cancel()
            if bitti {
                bitir()
                return
            }
            // Konuşma bitince (1,5 sn sessizlik) sonucu işle.
            sessizlikGorevi?.cancel()
            sessizlikGorevi = Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if !Task.isCancelled, self.oturum == buOturum, self.dinliyor { self.bitir() }
            }
        } else if hataVar {
            dinlemeyiDurdur()
            hataOldu(sessizlik: false)
        }
    }

    private func bitir() {
        let metin = sonMetin
        dinlemeyiDurdur()
        durumYaz("İşleniyor...")
        mikIpucu = varsayilanIpucu
        denemeSayisi = 0
        if metin.isEmpty {
            durumYaz("Söylediğiniz anlaşılamadı.", hata: true)
        } else {
            kullaniciSozu = "\"\(metin)\""
            komutuIsle(metin)
        }
    }

    /// Android onError: soru beklerken susmaya devam eder; normalde birkaç kez yeniden dener, sonra uyku moduna geçer.
    private func hataOldu(sessizlik: Bool) {
        mikIpucu = varsayilanIpucu
        if durumMakinesi != .bos {
            denemeSayisi += 1
            if denemeSayisi < 20 {
                durumYaz("Dinleniyor...")
                yenidenDinle()
                return
            }
        } else {
            denemeSayisi += 1
            if denemeSayisi < 6 {
                durumYaz("Dinleniyor, lütfen konuşun...")
                yenidenDinle()
                return
            }
        }
        let hataMesaji = sessizlik ? "Ses duyulamadı." : "Ses algılanamadı."
        let sallama = ayar.object(forKey: "shake_assistant_enabled") as? Bool ?? true
        let son = sallama
            ? "\(hataMesaji) Asistan uyku moduna geçti. Tekrar aktif etmek için telefonu sallayabilir veya mikrofona dokunabilirsiniz."
            : "\(hataMesaji) Asistan uyku moduna geçti."
        durumYaz("Uyku modunda")
        konus(son)
        kapatmayiIptalEt()
        sonraKapat(5)
    }

    private func yenidenDinle() {
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if self.acik && !self.dinliyor { self.dinlemeyeBasla() }
        }
    }

    private func dinlemeyiDurdur() {
        dinliyor = false
        sessizlikGorevi?.cancel()
        zamanAsimiGorevi?.cancel()
        if let m = motor {
            if m.isRunning { m.stop() }
            if dinleyiciKurulu { m.inputNode.removeTap(onBus: 0) }
        }
        motor = nil
        dinleyiciKurulu = false
        tanimaIstegi?.endAudio()
        tanimaGorevi?.cancel()
        tanimaIstegi = nil
        tanimaGorevi = nil
    }

    // MARK: Konuşma

    private func konus(_ metin: String, sonraDinle: Bool = false) {
        yedekGorev?.cancel()
        konusmaSonrasiDinle = sonraDinle
        konusucu.stopSpeaking(at: .immediate)
        kapatmayiIptalEt()
        if sonraDinle {
            // Seslendirme bitiş haberi gelmezse diye tahmini süre sonunda yine de dinlemeye başla.
            let sure = max(1.2, Double(metin.count) * 0.065) + 0.6
            yedekGorev = Task {
                try? await Task.sleep(nanoseconds: UInt64(sure * 1_000_000_000))
                if !Task.isCancelled, self.acik, !self.dinliyor, !self.konusucu.isSpeaking { self.dinlemeyeBasla() }
            }
        }
        let s = AVSpeechUtterance(string: metin)
        s.voice = AVSpeechSynthesisVoice(language: "tr-TR")
        konusucu.speak(s)
    }

    private func konusmayiDurdur() {
        yedekGorev?.cancel()
        konusucu.stopSpeaking(at: .immediate)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.konusmaBitti() }
    }

    private func konusmaBitti() {
        yedekGorev?.cancel()
        if konusmaSonrasiDinle {
            konusmaSonrasiDinle = false
            Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if self.acik && !self.dinliyor { self.dinlemeyeBasla() }
            }
        } else if acik && (kapatmaGorevi == nil || kapatmaGorevi!.isCancelled) {
            // Android: cevap bitince 6 sn sessiz kalırsa pencere kapanır (önceden kurulmuş kapanma varsa o geçerli).
            sonraKapat(6)
        }
    }

    private func durumYaz(_ m: String, hata: Bool = false) {
        durum = m
        durumHata = hata
    }

    private func cevapYaz(_ m: String) { cevap = m }

    // MARK: Uygulama bağlantıları (Android AssistantCallbacks)

    private var tumKayitlar: [Kayit] { depo?.asistanListesi ?? [] }
    private var aktifKayit: Kayit? {
        guard let c = oynatici?.calan else { return nil }
        return depo?.kayitlar.first { $0.url == c.url } ?? c
    }
    private var yayinAktif: Bool { (oynatici?.caliyor ?? false) && oynatici?.calan != nil }
    private func tvMi(_ k: Kayit) -> Bool { depo?.tvMi(k) ?? false }
    private var tvKategorisiAcik: Bool {
        (ayar.string(forKey: "last_tab") ?? "home") == "home" && ayar.string(forKey: "last_category") == TV_KATEGORI
    }

    private func calanBilgisi() -> String {
        guard let o = oynatici, let r = o.calan else { return "" }
        if !o.caliyor { return "\(r.ad) duraklatılmış durumda." }
        let tur = tvMi(r) ? "TV kanalı" : "radyo"
        return o.bilgi.isEmpty ? "Şu anda \(r.ad) \(tur) çalıyor." : "Şu anda \(r.ad) \(tur) çalıyor. Çalan: \(o.bilgi)"
    }

    private func gorevOzeti() -> String {
        var s = ""
        if oynatici?.uykuAktif == true { s += "Aktif bir uyku zamanlayıcı devrede. " }
        if s.isEmpty { s = "Şu anda ayarlanmış herhangi bir çalar saat, zamanlayıcı veya kayıt görevi bulunmuyor." }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private func tumGorevleriIptal() -> Int {
        oynatici?.uykuyuIptalEt() == true ? 1 : 0
    }

    private func temaDegistir(_ i: Int) {
        ayar.set(i, forKey: "app_theme")
    }

    // MARK: Komut işleme (Android processVoiceCommand, sırası aynı)

    func komutuIsle(_ hamMetin: String) {
        let metin = hamMetin.trimmingCharacters(in: .whitespaces)
        let k = KanalBulucu.normalize(metin)

        if ["iptal", "vazgec", "bosver", "istemiyorum", "vazgectim", "geri don"].contains(k), durumMakinesi != .bos {
            durumMakinesi = .bos
            seciliAlarmRadyosu = nil
            seciliKayitRadyosu = nil
            netlestirmeAdaylari = nil
            netlestirmeEylemi = nil
            let c = "İşlem iptal edildi. Başka bir işlem için dinliyorum."
            cevapYaz(c)
            konus(c, sonraDinle: true)
            return
        }

        switch durumMakinesi {
        case .alarmRadyosu: alarmRadyosuSecildi(metin); return
        case .alarmSaati: alarmSaatiSecildi(metin); return
        case .kayitRadyosu: kayitRadyosuSecildi(metin); return
        case .kayitSaati: kayitSaatiSecildi(metin); return
        case .zamanlayiciSuresi: zamanlayiciSuresiSecildi(metin); return
        case .temaSecimi: temaSecildi(metin); return
        case .radyoNetlestirme: radyoNetlestir(metin); return
        case .veriSiniri: veriSiniriGirildi(k); return
        case .bos: break
        }

        // 1. Rehber
        if k.contains("rehber") || k.contains("yardim") || k.contains("neler yapabilirsin") || k.contains("komutlar") || k.contains("nasil kullanilir") {
            rehberAcik = true
            return
        }

        // 2. Görevler / durum
        if k.contains("aktif alarm") || k.contains("kurulu alarm") || k.contains("gorevlerim") || k.contains("hangi alarm") || k.contains("zamanlayici durumu") || k.contains("kurulan gorevler") {
            let o = gorevOzeti()
            cevapYaz(o); konus(o); sonraKapat(5)
            return
        }

        // 3. İptal
        if iptalKomutuMu(k) {
            iptalEt(metin, k)
            return
        }

        // 4. Uygulamayı kapat (iPhone'da uygulama kendini kapatamaz: yayın durdurulur)
        if k.contains("uygulamayi kapat") || k.contains("uygulamadan cik") || k.contains("kapat uygulamayi") || k.contains("programi kapat") || k.contains("cikis yap") ||
            (k.contains("kapat") && !k.contains("sonra") && !k.contains("dakika") && !k.contains("saat") && !k.contains("yayini") && !k.contains("alarm") && !k.contains("zamanlayici")) {
            let c = "Yayın durduruldu. İyi günler dilerim."
            cevapYaz(c); konus(c)
            sonraKapat(1.5) { self.istek = .durdurAnaEkran }
            return
        }

        // 5. Yayını durdur / ana ekrana dön
        if k.contains("yayini durdur") || k.contains("yayini kapat") || k.contains("ana ekrana don") || k.contains("calmayi durdur") || k.contains("radyoyu durdur ve kapat") {
            let c = "Yayın durduruldu ve ana ekrana dönüldü."
            cevapYaz(c); konus(c)
            istek = .durdurAnaEkran
            sonraKapat(1.5)
            return
        }

        // 6. Oynat / devam et
        if ["oynat", "devam et", "baslat", "muzigi baslat", "radyoyu baslat"].contains(k) {
            let c = "Radyo oynatılıyor."
            cevapYaz(c); konus(c)
            if let o = oynatici, o.calan != nil, !o.caliyor { o.oynatDuraklat() }
            sonraKapat(1.5)
            return
        }

        // 7. Durdur / duraklat
        if ["durdur", "duraklat", "kes", "sustur", "beklet", "muzigi durdur", "radyoyu durdur"].contains(k) {
            let c = "Radyo duraklatıldı."
            cevapYaz(c); konus(c)
            if let o = oynatici, o.caliyor { o.oynatDuraklat() }
            sonraKapat(1.5)
            return
        }

        // 6b. Şarkı tanıma kaldırıldı
        if k.contains("sarkiyi bul") || k.contains("calan sarki") || k.contains("sarki tani") || k.contains("sarkiyi tani") || k.contains("bu sarki ne") ||
            k.contains("sarkilarim") || k.contains("taninan sarki") || k.contains("bulunan sarki") || k.contains("sarkilar sekme") ||
            k == "sarkilari ac" || k == "sarkilari goster" || k == "sarkilar" {
            let c = "Şarkı tanıma özelliği uygulamadan kaldırıldı."
            cevapYaz(c); konus(c)
            return
        }

        // 7a. Sekme değiştirme
        if let s = sekmeBul(k) {
            let ad = s == "fav" ? "Favoriler" : s == "rec" ? "Kayıtlar" : "Tüm radyolar"
            let c = "\(ad) sekmesine geçildi."
            cevapYaz(c); konus(c)
            istek = .sekme(s)
            sonraKapat(1.5)
            return
        }

        // 7b. Şu an ne çalıyor
        let neCaliyor = (k.contains("ne caliyor") || k.contains("su an ne") || k.contains("neyi dinliyorum") || k.contains("hangi radyo acik") ||
                         k.contains("hangi kanal acik") || k.contains("hangi radyodayim") || k.contains("hangi kanaldayim") || k.contains("hangi istasyon")) &&
            !k.contains("alarm") && !k.contains("kayit") && !k.contains("zamanl") && !k.contains("sarki")
        if neCaliyor {
            var bilgi = calanBilgisi()
            if bilgi.trimmingCharacters(in: .whitespaces).isEmpty {
                bilgi = (aktifKayit != nil && yayinAktif) ? "Şu anda \(aktifKayit!.ad) çalıyor." : "Şu anda çalan bir yayın yok."
            }
            cevapYaz(bilgi); konus(bilgi); sonraKapat(3)
            return
        }

        // 8. Kategori
        if let kat = kategoriBul(k) {
            let c = "\(kat) kategorisine geçildi."
            cevapYaz(c); konus(c)
            istek = .kategori(kat)
            sonraKapat(1.5)
            return
        }

        // 9. Sonraki / önceki
        if k.contains("sonraki") || k.contains("ileri") || k.contains("bir sonraki") {
            let c = "Sonraki radyo istasyonuna geçiliyor."
            cevapYaz(c); konus(c)
            oynatici?.sonraki()
            sonraKapat(1.5)
            return
        }
        if k.contains("onceki") || k.contains("geri") || k.contains("bir onceki") {
            let c = "Önceki radyo istasyonuna geçiliyor."
            cevapYaz(c); konus(c)
            oynatici?.onceki()
            sonraKapat(1.5)
            return
        }

        // 10. Ses
        if k.contains("sesi ac") || k.contains("sesi arttir") || k.contains("sesi yukselt") || k.contains("sesi cogalt") || k.contains("ses ac") {
            let c = "Ses seviyesi arttırıldı."
            cevapYaz(c); konus(c)
            SesSeviyesi.degistir(0.0625)
            sonraKapat(1.5)
            return
        }
        if k.contains("sesi kis") || k.contains("sesi azalt") || k.contains("sesi dusur") || k.contains("ses kis") {
            let c = "Ses seviyesi azaltıldı."
            cevapYaz(c); konus(c)
            SesSeviyesi.degistir(-0.0625)
            sonraKapat(1.5)
            return
        }

        // 11. Favori
        if k.contains("favori") || k.contains("begen") || k.contains("favorilere ekle") || k.contains("favoriye al") {
            if let a = aktifKayit {
                let cikar = k.contains("cikar") || k.contains("kaldir") || k.contains("sil")
                let ekle = !cikar && (k.contains("ekle") || k.contains("al") || k.contains("begen"))
                let c: String
                if cikar && !a.favori {
                    c = "\(a.ad) zaten favorilerinizde değil."
                } else if ekle && a.favori {
                    c = "\(a.ad) zaten favorilerinizde."
                } else {
                    let olacak = !a.favori
                    depo?.favoriDegistir(a)
                    c = olacak ? "\(a.ad) favorilere eklendi." : "\(a.ad) favorilerden çıkarıldı."
                }
                cevapYaz(c); konus(c)
            } else {
                let c = "Şu anda çalan bir radyo bulunmuyor."
                cevapYaz(c); konus(c)
            }
            sonraKapat(2)
            return
        }

        // 13. Canlı yayın kaydı
        if k.contains("kayit al") || k.contains("kaydi baslat") || k.contains("kaydetmeye basla") || k.contains("radyoyu kaydet") || k.contains("kayit baslat") {
            let c: String
            if !Hazirlik.kayit {
                c = Hazirlik.sonrakiSurumMesaji
            } else if yayinAktif {
                oynatici?.kaydiBaslat()
                c = "Canlı yayın kaydı başlatıldı."
            } else {
                c = "Canlı yayın kaydı başlatılamadı. Şu anda çalan bir radyo yayını bulunmuyor."
            }
            cevapYaz(c); konus(c); sonraKapat(2)
            return
        }
        if k.contains("kaydi durdur") || k.contains("kayit durdur") || k.contains("kaydi bitir") {
            let c: String
            if !Hazirlik.kayit {
                c = Hazirlik.sonrakiSurumMesaji
            } else if oynatici?.kayitYapiliyor == true {
                oynatici?.kaydiDurdur()
                c = "Yayın kaydı durduruldu ve kaydedildi."
            } else {
                c = "Şu anda devam eden bir ses kaydı bulunmuyor."
            }
            cevapYaz(c); konus(c); sonraKapat(2)
            return
        }

        // 14. Zamanlanmış kayıt
        if k.contains("zamanlanmis gorev") || k.contains("zamanli kayit") || k.contains("kayit gorevi") || k.contains("otomatik kayit") {
            if !Hazirlik.alarm {
                let c = Hazirlik.alarmYokMesaji
                cevapYaz(c); konus(c); sonraKapat(3)
                return
            }
            let eslesen = kanalBul(metin, tumKayitlar, zamanKomutu: true)
            let saat = saatAyikla(k)
            if eslesen.count == 1, let saat {
                zamanliKaydiKur(eslesen[0], saat.0, saat.1, 30)
            } else if eslesen.count > 1 {
                belirsizRadyolar(eslesen, "RECORD_SELECTION")
            } else if eslesen.count == 1 {
                seciliKayitRadyosu = eslesen[0]
                durumMakinesi = .kayitSaati
                let p = "\(eslesen[0].ad) için zamanlanmış kayıt saat kaçta başlasın? Örneğin 14:00 veya sekiz buçuk diyebilirsiniz."
                durumYaz(p); konus(p, sonraDinle: true)
            } else {
                durumMakinesi = .kayitRadyosu
                let p = "Hangi radyo istasyonu için zamanlanmış kayıt oluşturmak istersiniz?"
                durumYaz(p); konus(p, sonraDinle: true)
            }
            return
        }

        // 15. Uyku zamanlayıcı
        if k.contains("zamanlayici") || k.contains("uyku modu") || (k.contains("kapan") && (k.contains("sonra") || k.contains("dakika") || k.contains("saat"))) || k.contains("dakika sonra") || k.contains("saat sonra") {
            if let dk = sureAyikla(k), dk > 0 {
                oynatici?.uykuKur(dk)
                let c = "Zamanlayıcı \(dk) dakika sonraya ayarlandı. Süre dolduğunda yayın kapatılacak."
                cevapYaz(c); konus(c); sonraKapat(2)
            } else {
                durumMakinesi = .zamanlayiciSuresi
                let p = "Yayının kaç dakika sonra otomatik kapanmasını istersiniz? Örneğin 15, 30 veya 60 dakika diyebilirsiniz."
                durumYaz(p); konus(p, sonraDinle: true)
            }
            return
        }

        // 16. Çalar saat
        if k.contains("calar saat") || k.contains("alarm") || k.contains("sabah cal") || (k.contains("saat") && k.contains("kur")) || k.contains("beni uyandir") {
            if !Hazirlik.alarm {
                let c = Hazirlik.alarmYokMesaji
                cevapYaz(c); konus(c); sonraKapat(3)
                return
            }
            let eslesen = kanalBul(metin, tumKayitlar, zamanKomutu: true)
            let saat = saatAyikla(k)
            if eslesen.count == 1, let saat {
                alarmiKur(eslesen[0], saat.0, saat.1)
            } else if eslesen.count > 1 {
                belirsizRadyolar(eslesen, "ALARM_SELECTION")
            } else if eslesen.count == 1 {
                seciliAlarmRadyosu = eslesen[0]
                durumMakinesi = .alarmSaati
                let p = "\(eslesen[0].ad) için çalar saat saat kaça kurulsun? Örneğin 08:30 veya sekiz buçuk diyebilirsiniz."
                durumYaz(p); konus(p, sonraDinle: true)
            } else {
                durumMakinesi = .alarmRadyosu
                let p = "Hangi radyo istasyonu için çalar saat kurmak istersiniz?"
                durumYaz(p); konus(p, sonraDinle: true)
            }
            return
        }

        // 17. Radyo / TV aç
        let eslesen = kanalBul(metin, tumKayitlar)
        if eslesen.count == 1 {
            let r = eslesen[0]
            let c = "\(r.ad) açılıyor..."
            cevapYaz(c); konus(c)
            // Cümle bitince asistan kapanır, sonra kanal açılır (Android: konuş, kapat, aç).
            sonraKapat(1.2) { self.istek = .cal(r) }
            return
        } else if eslesen.count > 1 {
            belirsizRadyolar(eslesen, "PLAY")
            return
        }

        // 18. Veri / kota
        if k.contains("veri limitini sinirla") || k.contains("interneti sinirla") || k.contains("kotayi ayarla") || k.contains("kota belirle") || k.contains("veri limiti") {
            durumMakinesi = .veriSiniri
            let c = "Ne kadar sınır koymak istersiniz? Örnek olarak sadece 10 megabayt şeklinde söyleyebilirsiniz."
            cevapYaz(c); konus(c, sonraDinle: true)
            return
        }

        // 19. Tema
        if k.contains("tema") || k.contains("tasarim") {
            if !temaUygula(k) {
                durumMakinesi = .temaSecimi
                let p = "Hangi temaya geçmek istersiniz? Açık, Koyu veya Sistem diyebilirsiniz."
                durumYaz(p); konus(p, sonraDinle: true)
            }
            return
        }

        let c = "\"\(metin)\" komutunu anlayamadım. Bir radyo adı söyleyebilir, zamanlayıcı kurabilir, ya da 'rehber' diyebilirsiniz."
        durumYaz(c, hata: true)
        konus(c, sonraDinle: true)
    }

    // MARK: Belirsiz radyo seçimi

    private func belirsizRadyolar(_ tumAdaylar: [Kayit], _ eylem: String) {
        // Sesle en fazla 4 seçenek seçilebildiği için ilk 4'ü okunur ve sorulur.
        let adaylar = Array(tumAdaylar.prefix(4))
        netlestirmeAdaylari = adaylar
        netlestirmeEylemi = eylem
        durumMakinesi = .radyoNetlestirme
        denemeSayisi = 0
        let sayi: String
        switch tumAdaylar.count {
        case 2: sayi = "İki tane sonuç bulundu"
        case 3: sayi = "Üç tane sonuç bulundu"
        case 4: sayi = "Dört tane sonuç bulundu"
        default: sayi = "\(tumAdaylar.count) tane sonuç bulundu, ilk dördü şunlar"
        }
        let karisik = adaylar.contains { tvMi($0) } && adaylar.contains { !tvMi($0) }
        let adlar = adaylar.enumerated().map { i, r in
            let etiket = karisik ? (tvMi(r) ? " TV kanalı" : " radyo") : ""
            return "\(i + 1). \(r.ad)\(etiket)"
        }.joined(separator: ", ")
        let p = "\(sayi): \(adlar). Hangisini açayım?"
        durumYaz(p); cevapYaz(p); konus(p, sonraDinle: true)
    }

    private func radyoNetlestir(_ metin: String) {
        guard let adaylar = netlestirmeAdaylari, let eylem = netlestirmeEylemi else { return }
        let k = KanalBulucu.normalize(metin)
        var secilen: Kayit?

        let birinci = k == "1" || k == "bir" || k.contains("birinci") || k.contains("birincisi") || k.contains("birinciyi") ||
            k.contains("ilk") || k.contains("ilki") || k.contains("ilkini") || k.contains("bastaki") || k.contains("1.") ||
            k.contains("1 numara") || k.contains("bir numara") || k.hasPrefix("1 ") || k.hasPrefix("bir ") || k.hasSuffix(" 1") ||
            k.hasSuffix(" bir") || k.contains(" 1 ") || k.contains(" bir ")
        let ikinci = k == "2" || k == "iki" || k.contains("ikinci") || k.contains("ikincisi") || k.contains("ikinciyi") ||
            k.contains("ikisi") || k.contains("ikisini") || k.contains("2.") || k.contains("2 numara") || k.contains("iki numara") ||
            k.hasPrefix("2 ") || k.hasPrefix("iki ") || k.hasSuffix(" 2") || k.hasSuffix(" iki") || k.contains(" 2 ") || k.contains(" iki ")
        let ucuncu = k == "3" || k == "uc" || k.contains("ucuncu") || k.contains("ucuncusu") || k.contains("ucuncuyu") ||
            k.contains("3.") || k.contains("3 numara") || k.contains("uc numara") || k.hasPrefix("3 ") || k.hasPrefix("uc ") ||
            k.hasSuffix(" 3") || k.hasSuffix(" uc")
        let dorduncu = k == "4" || k == "dort" || k.contains("dorduncu") || k.contains("dorduncusu") ||
            k.contains("4.") || k.contains("4 numara") || k.contains("dort numara")
        let sonuncu = k.contains("sonuncu") || k.contains("sondaki") || k.contains("en son")

        let kelimeler = k.bol()
        let tvDedi = kelimeler.contains { $0 == "tv" || $0.hasPrefix("televizyon") || $0 == "kanal" || $0 == "kanali" }
        let radyoDedi = kelimeler.contains { $0.hasPrefix("radyo") || $0 == "fm" }
        if tvDedi != radyoDedi {
            let tur = adaylar.filter { tvMi($0) == tvDedi }
            if tur.count == 1 { secilen = tur[0] }
        }

        if secilen != nil {
        } else if birinci {
            secilen = adaylar.first
        } else if ikinci {
            if adaylar.count > 1 { secilen = adaylar[1] }
        } else if ucuncu {
            if adaylar.count > 2 { secilen = adaylar[2] }
        } else if dorduncu {
            if adaylar.count > 3 { secilen = adaylar[3] }
        } else if sonuncu {
            secilen = adaylar.last
        }

        if secilen == nil {
            let yeni = kanalBul(metin, adaylar)
            if yeni.count == 1 {
                secilen = yeni[0]
            } else if yeni.count > 1 {
                belirsizRadyolar(yeni, eylem)
                return
            }
        }

        if secilen == nil {
            for r in adaylar {
                let parcalar = KanalBulucu.normalize(r.ad).bol().filter { $0.count >= 2 && $0 != "radyo" && $0 != "fm" }
                if !parcalar.isEmpty && parcalar.contains(where: { k.contains($0) }) {
                    secilen = r
                    break
                }
            }
        }

        if let r = secilen {
            durumMakinesi = .bos
            netlestirmeAdaylari = nil
            netlestirmeEylemi = nil
            denemeSayisi = 0
            switch eylem {
            case "PLAY":
                let c = "\(r.ad) açılıyor..."
                cevapYaz(c); konus(c)
                sonraKapat(1.5) { self.istek = .cal(r) }
            case "ALARM_SELECTION":
                seciliAlarmRadyosu = r
                durumMakinesi = .alarmSaati
                let p = "\(r.ad) seçildi. Çalar saati saat kaça kurmak istiyorsunuz?"
                durumYaz(p); konus(p, sonraDinle: true)
            case "RECORD_SELECTION":
                seciliKayitRadyosu = r
                durumMakinesi = .kayitSaati
                let p = "\(r.ad) seçildi. Zamanlanmış kayıt saat kaçta başlasın?"
                durumYaz(p); konus(p, sonraDinle: true)
            default: break
            }
        } else {
            denemeSayisi = 0
            let p = "Lütfen 1 veya 2 diyerek ya da radyonun tam adını söyleyerek seçin."
            durumYaz(p); konus(p, sonraDinle: true)
        }
    }

    // MARK: Veri sınırı

    private func veriSiniriGirildi(_ k: String) {
        if let m = RX.ilk(k, "(\\d+)"), var deger = Int(m[1]) {
            if k.contains("gb") || k.contains("gigabayt") || k.contains("cigabayt") { deger *= 1024 }
            if let a = aktifKayit {
                ayar.set(deger, forKey: "data_limit_" + a.url)
                ayar.set(0, forKey: "data_usage_" + a.url)
                depo?.veriSinirlariniAyarla(a.url, sinir: deger)
                oynatici?.veriyiYenile()
                let c = "Veri limiti \(deger) megabayt olarak ayarlandı."
                cevapYaz(c); konus(c)
            } else {
                let c = "Şu anda çalan bir radyo yok. Veri limiti ayarlamak için önce bir yayın açmalısınız."
                durumYaz(c, hata: true); konus(c)
            }
            durumMakinesi = .bos
            sonraKapat(3)
        } else {
            let p = "Rakam algılayamadım. Lütfen sadece 50 megabayt gibi bir değer söyleyin."
            durumYaz(p, hata: true); konus(p, sonraDinle: true)
        }
    }

    // MARK: İptal

    private func iptalKomutuMu(_ k: String) -> Bool {
        k.contains("iptal") || k.contains("sil") || k.contains("kaldir") ||
            (k.contains("kapat") && (k.contains("alarm") || k.contains("zamanlayici") || k.contains("gorev") || k.contains("mod"))) ||
            (k.contains("durdur") && (k.contains("zamanlayici") || k.contains("alarm")))
    }

    private func iptalEt(_ metin: String, _ k: String) {
        let eslesen = kanalBul(metin, tumKayitlar, zamanKomutu: true).first

        if k.contains("tum") || k.contains("butun") || k.contains("hepsini") || k.contains("her seyi") {
            let c = tumGorevleriIptal() > 0
                ? "Tüm çalar saatler, zamanlayıcılar ve kayıt görevleri başarıyla iptal edildi."
                : "İptal edilecek aktif herhangi bir alarm veya zamanlayıcı bulunamadı."
            cevapYaz(c); konus(c); sonraKapat(3)
            return
        }
        if k.contains("zamanlayici") || k.contains("uyku modu") || k.contains("kapanma") {
            let c = oynatici?.uykuyuIptalEt() == true
                ? "Zamanlayıcı iptal edildi. Yayın açık kalmaya devam edecek."
                : "Şu anda aktif ayarlanmış bir zamanlayıcı bulunmuyor."
            cevapYaz(c); konus(c); sonraKapat(3)
            return
        }
        if k.contains("kayit") || k.contains("gorev") {
            let c = "İptal edilecek herhangi bir kayıt görevi bulunamadı."
            _ = eslesen
            cevapYaz(c); konus(c); sonraKapat(3)
            return
        }
        if k.contains("alarm") || k.contains("saat") {
            let c = "Kurulu herhangi bir çalar saat bulunamadı."
            cevapYaz(c); konus(c); sonraKapat(3)
            return
        }
        let c = tumGorevleriIptal() > 0 ? "Kurulu olan görevler iptal edildi." : "İptal edilecek aktif bir görev bulunamadı."
        cevapYaz(c); konus(c)
    }

    // MARK: Çok aşamalı sorular

    private func alarmRadyosuSecildi(_ metin: String) {
        let eslesen = kanalBul(metin, tumKayitlar, zamanKomutu: true)
        if eslesen.count == 1 {
            seciliAlarmRadyosu = eslesen[0]
            durumMakinesi = .alarmSaati
            let p = "\(eslesen[0].ad) seçildi. Çalar saati saat kaça kurmak istiyorsunuz?"
            durumYaz(p); konus(p, sonraDinle: true)
        } else if eslesen.count > 1 {
            belirsizRadyolar(eslesen, "ALARM_SELECTION")
        } else {
            let p = "Belirttiğiniz isimde bir radyo istasyonu bulamadım. Lütfen radyo adını tekrar söyleyin."
            durumYaz(p, hata: true); konus(p, sonraDinle: true)
        }
    }

    private func alarmSaatiSecildi(_ metin: String) {
        if let r = seciliAlarmRadyosu, let s = saatAyikla(KanalBulucu.normalize(metin)) {
            alarmiKur(r, s.0, s.1)
        } else {
            let p = "Saati anlayamadım. Örneğin 'sekiz buçuk', '08:30' veya 'sabah yedi' diyebilirsiniz."
            durumYaz(p, hata: true); konus(p, sonraDinle: true)
        }
    }

    private func alarmiKur(_ r: Kayit, _ saat: Int, _ dakika: Int) {
        durumMakinesi = .bos
        let c = Hazirlik.sonrakiSurumMesaji
        cevapYaz(c); konus(c); sonraKapat(2.5)
    }

    private func kayitRadyosuSecildi(_ metin: String) {
        let eslesen = kanalBul(metin, tumKayitlar, zamanKomutu: true)
        if eslesen.count == 1 {
            seciliKayitRadyosu = eslesen[0]
            durumMakinesi = .kayitSaati
            let p = "\(eslesen[0].ad) seçildi. Zamanlanmış kayıt saat kaçta başlasın?"
            durumYaz(p); konus(p, sonraDinle: true)
        } else if eslesen.count > 1 {
            belirsizRadyolar(eslesen, "RECORD_SELECTION")
        } else {
            let p = "Kayıt için belirtilen radyo istasyonu bulunamadı. Lütfen radyo ismini tekrar söyleyin."
            durumYaz(p, hata: true); konus(p, sonraDinle: true)
        }
    }

    private func kayitSaatiSecildi(_ metin: String) {
        if let r = seciliKayitRadyosu, let s = saatAyikla(KanalBulucu.normalize(metin)) {
            zamanliKaydiKur(r, s.0, s.1, 30)
        } else {
            let p = "Kayıt saatini anlayamadım. Örneğin '14:30' veya 'sekiz buçuk' diyebilirsiniz."
            durumYaz(p, hata: true); konus(p, sonraDinle: true)
        }
    }

    private func zamanliKaydiKur(_ r: Kayit, _ saat: Int, _ dakika: Int, _ sure: Int) {
        durumMakinesi = .bos
        let c = Hazirlik.sonrakiSurumMesaji
        cevapYaz(c); konus(c); sonraKapat(2.5)
    }

    private func zamanlayiciSuresiSecildi(_ metin: String) {
        if let dk = sureAyikla(KanalBulucu.normalize(metin)), dk > 0 {
            durumMakinesi = .bos
            oynatici?.uykuKur(dk)
            let c = "Zamanlayıcı \(dk) dakika sonraya ayarlandı. Süre dolunca yayın kapatılacak."
            cevapYaz(c); konus(c); sonraKapat(2)
        } else {
            let p = "Süreyi anlayamadım. Örneğin '30 dakika' veya '1 saat' diyebilirsiniz."
            durumYaz(p, hata: true); konus(p, sonraDinle: true)
        }
    }

    private func temaSecildi(_ metin: String) {
        let k = KanalBulucu.normalize(metin)
        durumMakinesi = .bos
        if !temaUygula(k) {
            let p = "Tema seçimini anlayamadım. Hangi temaya geçmek istersiniz? Açık, Koyu veya Sistem diyebilirsiniz."
            durumMakinesi = .temaSecimi
            durumYaz(p, hata: true); konus(p, sonraDinle: true)
        }
    }

    /// Teması anlaşılırsa uygular ve true döner.
    private func temaUygula(_ k: String) -> Bool {
        let secim: (String, Int)?
        if k.contains("koyu") || k.contains("siyah") || k.contains("gece") {
            secim = ("Koyu temaya geçiliyor.", 1)
        } else if k.contains("acik") || k.contains("beyaz") || k.contains("aydinlik") {
            secim = ("Açık temaya geçiliyor.", 0)
        } else if k.contains("sistem") || k.contains("varsayilan") {
            secim = ("Sistem temasına geçiliyor.", 2)
        } else {
            secim = nil
        }
        guard let s = secim else { return false }
        let (c, i) = s
        cevapYaz(c); konus(c)
        sonraKapat(1.5) { self.temaDegistir(i) }
        return true
    }

    // MARK: Rehber

    static let rehberMetni = """
    Reklamsız Radyo Sesli Asistan Komutları:

    1. Radyo ve TV Kanalı Açma (hangi sekmede olursanız olun):
    - "[Radyo Adı] aç" veya "[Radyo Adı] dinle" (Örn: "Kral FM aç", "Süper FM dinle")
    - "[TV Kanalı] aç" (Örn: "TRT 1 aç", "Kanal D aç", "Show TV aç", "360 aç", "A2 aç")
    - Aynı adlı radyo ve TV kanalı varsa ayırmak için "TV" veya "radyo" deyin:
      "A Haber TV aç", "A Haber radyo aç", "TRT Radyo 1 aç"
    - Adı tam söylenen kanal açılır: "TRT 1 aç" TV'deki TRT 1'i, "TRT Radyo 1 aç" radyoyu açar.
    - Ad ikisinde de aynıysa (Örn: "Power aç") ve "TV" veya "radyo" demezseniz:
      ekranda TV Kanalları açıksa TV kanalı, değilse radyo seçilir.
    - Asistan iki seçenek sorarsa "birinci", "ikinci", "TV olanı" veya "radyo olanı" diyebilirsiniz.
    - TV kanalı açınca liste TV Kanallarına, radyo açınca Tümü'ne geçer; böylece
      "Sonraki" ve "Önceki" aynı türde kalır.

    2. Çalma Kontrolleri:
    - "Oynat", "Devam et" veya "Başlat"
    - "Durdur" veya "Duraklat"
    - "Yayını durdur" (Yayını kapatıp ana ekrana döner)
    - "Sonraki radyo" veya "Önceki radyo"
    - "Şu an ne çalıyor?" veya "Hangi kanal açık?"

    3. Ses Seviyesi:
    - "Sesi aç", "Sesi arttır" veya "Sesi yükselt"
    - "Sesi kıs" veya "Sesi azalt"

    4. Kategori ve Sekme Geçişleri:
    - "Haber kategorisine geç", "Pop sekmesi", "Pop aç", "Slow", "Arabesk", "Spor", "Dini", "Yerel", "Oyun havası"
    - "TV kanalları" veya "TV aç" (TV Kanalları kategorisi)
    - "Tüm radyolar", "Favorilerim", "Kayıtlarım" (alt sekmeler)

    5. Canlı Yayın Kaydı:
    - "Kayıt al" veya "Kaydı başlat" (Çalan canlı yayını kaydeder)
    - "Kaydı durdur" (Yayındaki kaydı sonlandırır)

    6. Uyku Zamanlayıcı:
    - "30 dakika zamanlayıcı kur" veya "1 saat sonra kapan"
    - "Zamanlayıcıyı iptal et"

    7. Durum Öğrenme:
    - "Zamanlayıcı durumu"

    8. Favoriler:
    - "Favorilere ekle" veya "Favoriye al" / "Favorilerden çıkar"

    9. Veri ve Kota Limiti:
    - "Veri limitini sınırla", "Kotayı ayarla" veya "İnterneti sınırla"

    10. Uygulama:
    - "Uygulamayı kapat" veya "Çıkış yap"
    - "Rehber" veya "Yardım"
    """

    /// Liste kapalıyken rehberde kanal adı örnekleri ve TV yazıları gösterilmez.
    /// Liste açılınca rehberMetni olduğu gibi geri gelir. Komutların çalışması değişmez.
    var gosterilecekRehber: String {
        guard depo?.listeKapali == true,
              let bas = Self.rehberMetni.range(of: "1. Radyo ve TV Kanalı Açma"),
              let son = Self.rehberMetni.range(of: "2. Çalma Kontrolleri") else { return Self.rehberMetni }
        let genel = "1. Yayın Açma (hangi sekmede olursanız olun):\n"
            + "- \"[Yayın Adı] aç\" veya \"[Yayın Adı] dinle\": Listenize eklediğiniz yayını açar.\n"
            + "- Asistan iki seçenek sorarsa \"birinci\" veya \"ikinci\" diyebilirsiniz.\n\n"
        return Self.rehberMetni.replacingCharacters(in: bas.lowerBound..<son.lowerBound, with: genel)
            .replacingOccurrences(of: "- \"TV kanalları\" veya \"TV aç\" (TV Kanalları kategorisi)\n", with: "")
    }

    func rehberiSeslendir() {
        let giris = depo?.listeKapali == true
            ? "Sesli asistan komutları: Listenize eklediğiniz yayını açmak için yayının adını söyleyin."
            : "Sesli asistan komutları: Radyo dinlemek için radyonun adını, televizyon kanalı açmak için kanalın adını söyleyin; örneğin Kral FM aç ya da TRT 1 aç. Aynı adlı radyo ve TV kanalı varsa sonuna TV veya radyo ekleyin; örneğin A Haber TV aç."
        konus(giris + " Şu an ne çalıyor diyebilir, favorilerim veya kayıtlarım diyerek sekmeler arasında geçebilirsiniz. Oynat, durdur, sonraki veya önceki radyo diyebilirsiniz. Yayını durdur diyerek yayını kapatıp ana ekrana dönebilirsiniz. Sesi aç veya kıs diyebilirsiniz. Dini, haber, pop, slow gibi kategorilere geçebilirsiniz. Kayıt alabilir, zamanlayıcı veya kota limiti kurabilirsiniz. Uygulamayı kapat diyerek çıkabilirsiniz.")
    }

    // MARK: Metin ayrıştırma (Android parseCategory, parseTab, parseTime, parseDurationMinutes)

    private func kategoriBul(_ k: String) -> String? {
        let kelimeler = k.bol().filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        func kategorisi(_ ws: [String], _ t: String) -> String? {
            if ws.contains("dini") || ws.contains("din") { return "Dini" }
            if ws.contains("haber") || ws.contains("haberler") { return "Haber" }
            if ws.contains("pop") { return "Pop" }
            if ws.contains("slow") { return "Slow" }
            if ws.contains("arabesk") || ws.contains("damar") { return "Arabesk" }
            if ws.contains("spor") { return "Spor" }
            if t.contains("oyun havasi") || t.contains("oyun havalari") { return "Oyun Havası" }
            if ws.contains("yerel") { return "Yerel" }
            if t.contains("tv kanallari") || t.contains("televizyon kanallari") || ws.contains("tv") || ws.contains("televizyon") || ws.contains("televizyonlar") { return TV_KATEGORI }
            if ws.contains("tumu") || ws.contains("hepsi") || t.contains("tum radyolar") { return "Tümü" }
            return nil
        }
        let acik = kelimeler.contains { $0.hasPrefix("kategori") || $0.hasPrefix("sekme") || $0 == "gec" || $0 == "listesi" || $0 == "listesine" || $0 == "listesini" } ||
            k.contains("tv kanallari") || k.contains("televizyon kanallari")
        if acik { return kategorisi(kelimeler, k) }
        let eylemler: Set<String> = ["ac", "gec", "goster", "getir", "lutfen", "listele", "kategorisi", "kategorisine"]
        let kalan = kelimeler.filter { !eylemler.contains($0) }
        let kalanMetin = kalan.joined(separator: " ")
        let tekler: Set<String> = ["dini", "din", "haber", "haberler", "pop", "slow", "arabesk", "damar", "spor", "yerel", "tv", "televizyon", "televizyonlar", "tumu", "hepsi", "oyun havasi", "oyun havalari"]
        return tekler.contains(kalanMetin) ? kategorisi(kalan, kalanMetin) : nil
    }

    private func sekmeBul(_ t: String) -> String? {
        if t.contains("favorilerim") || t.contains("favoriler sekme") || t.contains("favorilere git") || t.contains("favori listesi") ||
            t.contains("favorileri ac") || t.contains("favorileri goster") || t == "favoriler" { return "fav" }
        if t.contains("kayitlarim") || t.contains("kayitlar sekme") || t.contains("kayitlari ac") || t.contains("kayitlari goster") ||
            t.contains("kayitlara git") || t == "kayitlar" { return "rec" }
        if t.contains("tum radyolar") || t.contains("ana sayfa") || t.contains("ana sayfaya") { return "home" }
        return nil
    }

    private func kanalBul(_ ham: String, _ kayitlar: [Kayit], zamanKomutu: Bool = false) -> [Kayit] {
        if kayitlar.isEmpty { return [] }
        let kesin = KanalBulucu.kesinBul(ham, kayitlar, tvMi: { self.tvMi($0) }, tvKategorisiAcik: tvKategorisiAcik, zamanKomutu: zamanKomutu)
        if !kesin.isEmpty { return kesin }
        var n = KanalBulucu.normalize(KanalBulucu.kesmeEkleriniSil(ham))
        if zamanKomutu { n = KanalBulucu.zamanIfadeleriniSil(n) }
        return eskiYontemleBul(n, kayitlar)
    }

    private func eskiYontemleBul(_ girdi: String, _ kayitlar: [Kayit]) -> [Kayit] {
        let durak = [
            "ac", "cal", "baslat", "dinle", "oynat", "lutfen",
            "radyo", "radyosu", "radyosunu", "istasyonu", "istasyonunu", "kanalini",
            "icin", "istiyorum", "bana", "hemen", "su", "bir", "calar", "saat", "saati", "saate", "alarm", "alarmi", "alarma",
            "zamanlanmis", "gorev", "gorevi", "gorevini", "kayit", "kaydi", "kaydet", "kaydini",
            "kur", "kurulsun", "kuralim", "kuruver", "ayarla", "ayarlansin", "iptal", "et", "kapat", "sil", "durdur", "kaldir",
            "kac", "dakika", "sure", "zamanlayici", "zamanlayiciyi", "uyku", "modu", "modunu", "yayin", "yayini",
            "sabah", "aksam", "oglen", "gece", "bucuk", "ceyrek", "var", "gece", "saatinde", "saatlerinde", "beni", "uyandir",
        ]
        var temiz = girdi
        for w in durak { temiz = RX.degistir(temiz, "\\b\(w)\\b", " ") }
        temiz = RX.degistir(temiz, "\\b\\d{1,2}[:.]\\d{2}\\b", " ")
        temiz = RX.degistir(temiz, "\\b\\d+\\b", " ")
        temiz = RX.degistir(temiz, "\\s+", " ").trimmingCharacters(in: .whitespaces)
        if temiz.count < 2 { return [] }
        let girdiParcalari = temiz.bol().filter { $0.count >= 2 }
        if girdiParcalari.isEmpty { return [] }

        let tam = kayitlar.filter { KanalBulucu.normalize($0.ad) == temiz }
        if !tam.isEmpty { return tam }

        let hepsi = kayitlar.filter { r in
            let p = KanalBulucu.normalize(r.ad).bol().filter { !$0.isEmpty }
            return girdiParcalari.allSatisfy { p.contains($0) }
        }
        if !hepsi.isEmpty { return hepsi }

        let tek = kayitlar.filter { r in
            let c = KanalBulucu.normalize(r.ad).replacingOccurrences(of: "radyo", with: "").replacingOccurrences(of: "fm", with: "").trimmingCharacters(in: .whitespaces)
            return c.count >= 3 && girdiParcalari.contains(c)
        }
        if !tek.isEmpty { return tek }

        var enIyiler: [Kayit] = []
        var enIyiPuan = 0
        let girdiSuzulmus = Set(girdiParcalari.filter { $0.count >= 3 && $0 != "radyo" && $0 != "turk" })
        for r in kayitlar {
            let rp = Set(KanalBulucu.normalize(r.ad).bol().filter { $0.count >= 3 && $0 != "radyo" && $0 != "turk" })
            let ortak = girdiSuzulmus.intersection(rp).count
            if ortak > enIyiPuan && ortak >= 1 &&
                (Double(ortak) / Double(max(girdiSuzulmus.count, 1)) >= 0.5 || Double(ortak) / Double(max(rp.count, 1)) >= 0.5) {
                enIyiPuan = ortak
                enIyiler = [r]
            } else if ortak > 0 && ortak == enIyiPuan {
                enIyiler.append(r)
            }
        }
        return enIyiler
    }

    private func saatAyikla(_ n: String) -> (Int, Int)? {
        if let m = RX.ilk(n, "\\b(\\d{1,2})[:.](\\d{2})\\b") {
            let h = Int(m[1]) ?? 0, d = Int(m[2]) ?? 0
            if (0...23).contains(h) && (0...59).contains(d) { return (h, d) }
        }
        if let m = RX.ilk(n, "\\b(\\d{1,2})\\s+(\\d{2})\\b") {
            let h = Int(m[1]) ?? 0, d = Int(m[2]) ?? 0
            if (0...23).contains(h) && (0...59).contains(d) { return (h, d) }
        }
        let saatKelimeleri: [(String, Int)] = [
            ("bir", 1), ("iki", 2), ("uc", 3), ("dort", 4), ("bes", 5),
            ("alti", 6), ("yedi", 7), ("sekiz", 8), ("dokuz", 9), ("on", 10),
            ("on bir", 11), ("on iki", 12), ("on uc", 13), ("on dort", 14),
            ("on bes", 15), ("on alti", 16), ("on yedi", 17), ("on sekiz", 18),
            ("on dokuz", 19), ("yirmi", 20), ("yirmi bir", 21), ("yirmi iki", 22),
            ("yirmi uc", 23), ("sifir", 0), ("gece yarisi", 0),
        ]
        var bulunan: Int?
        let ogledenSonra = n.contains("aksam") || n.contains("ogleden sonra") || n.contains("gece")
        let sabah = n.contains("sabah") || n.contains("oglen")
        if let m = RX.ilk(n, "(?:saat\\s+)?(\\d{1,2})(?:\\s*['de|da|te|ta|e|a])?"), let h = Int(m[1]), (0...23).contains(h) {
            bulunan = h
        }
        if bulunan == nil {
            for (w, h) in saatKelimeleri where RX.iceriyor(n, "\\b\(w)\\b") {
                bulunan = h
                break
            }
        }
        guard var saat = bulunan else { return nil }
        if ogledenSonra && saat < 12 { saat += 12 }
        if sabah && saat == 12 { saat = 0 }
        var dakika = 0
        if n.contains("bucuk") {
            dakika = 30
        } else if n.contains("ceyrek") {
            if n.contains("kala") || n.contains("var") {
                saat = saat == 0 ? 23 : saat - 1
                dakika = 45
            } else {
                dakika = 15
            }
        } else {
            let hepsi = RX.hepsi(n, "\\b(\\d{1,2})\\s*(?:gece|kala|geciyor|dakika)?\\b")
            if hepsi.count > 1, let d = Int(hepsi[1][1]), (0...59).contains(d) { dakika = d }
        }
        return (saat, dakika)
    }

    private func sureAyikla(_ n: String) -> Int? {
        if n.contains("yarim saat") { return 30 }
        if n.contains("bir bucuk saat") || n.contains("1.5 saat") { return 90 }
        if let m = RX.ilk(n, "(\\d+)\\s*(?:saat)") { return (Int(m[1]) ?? 1) * 60 }
        if let m = RX.ilk(n, "(\\d+)\\s*(?:dakika|dk|dak)") { return Int(m[1]) }
        let kelimeler: [(String, Int)] = [
            ("on", 10), ("on bes", 15), ("yirmi", 20), ("yirmi bes", 25),
            ("otuz", 30), ("kirk", 40), ("kirk bes", 45), ("elli", 50), ("altmis", 60),
            ("bir saat", 60), ("iki saat", 120),
        ]
        for (w, d) in kelimeler where n.contains(w) { return d }
        if let m = RX.ilk(n, "\\b(\\d+)\\b"), let s = Int(m[1]), (1...360).contains(s) { return s }
        return nil
    }
}

/// Android'deki ses tuşu karşılığı: sistem ses seviyesini bir adım değiştirir.
enum SesSeviyesi {
    @MainActor
    static func degistir(_ fark: Float) {
        let gorunum = MPVolumeViewKopru.paylasilan
        gorunum.degistir(fark)
    }
}

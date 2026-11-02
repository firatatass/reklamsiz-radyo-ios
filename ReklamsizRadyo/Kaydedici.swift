import AVFoundation
import Foundation

/// Canlı yayın kaydı (Android RadioService.startRecording / stopRecording).
/// Android'deki gibi yayına ayrı bir bağlantıyla bağlanır ve sesi seçilen biçimde (M4A, MP3, WAV) kaydeder.
/// iPhone'da FFmpeg olmadığı için: radyo akışı olduğu gibi indirilir; TV (HLS) yayınında parçalar indirilip içlerinden ses ayıklanır;
/// sonra Apple'ın kendi ses dönüştürücüsüyle istenen biçime çevrilir.
@MainActor
final class Kaydedici: NSObject, ObservableObject, URLSessionDataDelegate {
    static let shared = Kaydedici()

    @Published private(set) var kayitta = false

    private enum Kaynak { case mp3, aac }

    private var oturum: URLSession?
    private var gorev: URLSessionDataTask?
    private var hlsGorevi: Task<Void, Never>?
    private var sureGorevi: Task<Void, Never>?
    private var gecici: URL?
    private var yazici: FileHandle?
    private var kaynak: Kaynak?
    private var ad = ""
    private var yazilan = 0
    private var bitiriliyor = false

    // MARK: Başlat / durdur

    /// - Parameter sure: saniye; 0 ise elle durdurulana kadar (Android "DURATION").
    func baslat(url: String, ad: String, sure: Int = 0) {
        if kayitta { return }
        self.ad = ad
        kayitta = true
        bitiriliyor = false
        yazilan = 0
        kaynak = nil
        let gecici = FileManager.default.temporaryDirectory.appendingPathComponent("temp_record_\(Int(Date().timeIntervalSince1970 * 1000)).bin")
        FileManager.default.createFile(atPath: gecici.path, contents: nil)
        self.gecici = gecici
        yazici = try? FileHandle(forWritingTo: gecici)
        Bildirim.shared.goster("Kayıt Başladı (\(Self.bicimAdi(Self.secilenBicim)))...")

        var adres = url.trimmingCharacters(in: .whitespaces)
        adres = adres.replacingOccurrences(of: "?checkedby:iptvcat.com", with: "").replacingOccurrences(of: "&checkedby:iptvcat.com", with: "")
        if adres.lowercased().hasSuffix("/listen.pls") { adres = String(adres.dropLast("/listen.pls".count)) }
        else if adres.lowercased().hasSuffix(".pls") { adres = String(adres.dropLast(4)) }
        adres = Oynatici.calinabilirAdres(adres)
        guard let u = URL(string: adres) else { bitir(basarili: false); return }

        if adres.lowercased().contains(".m3u8") {
            hlsGorevi = Task { await self.hlsKaydet(u) }
        } else {
            let o = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
            var istek = URLRequest(url: u)
            istek.setValue(Oynatici.kimlik(u), forHTTPHeaderField: "User-Agent")
            istek.timeoutInterval = 20
            oturum = o
            gorev = o.dataTask(with: istek)
            gorev?.resume()
        }
        if sure > 0 {
            sureGorevi = Task {
                try? await Task.sleep(nanoseconds: UInt64(sure + 2) * 1_000_000_000)
                if !Task.isCancelled { self.durdur() }
            }
        }
    }

    /// Kaydı bitirir ve dosyayı Kayıtlar'a kaydeder.
    func durdur() {
        guard kayitta, !bitiriliyor else { return }
        bitir(basarili: true)
    }

    private func bitir(basarili: Bool) {
        bitiriliyor = true
        sureGorevi?.cancel()
        hlsGorevi?.cancel()
        gorev?.cancel()
        oturum?.invalidateAndCancel()
        oturum = nil
        gorev = nil
        try? yazici?.close()
        yazici = nil
        let gecici = self.gecici
        let kaynak = self.kaynak
        let ad = self.ad
        let bicim = Self.secilenBicim
        let yeterli = yazilan > 1024
        Task {
            var sonuc: (Bool, String) = (false, bicim)
            if basarili, yeterli, let gecici, let kaynak {
                sonuc = await Task.detached { Self.donustur(gecici, kaynak: kaynak, ad: ad, bicim: bicim) }.value
            }
            if let gecici { try? FileManager.default.removeItem(at: gecici) }
            self.kayitta = false
            self.bitiriliyor = false
            if sonuc.0 {
                Bildirim.shared.goster("Kayıt \(Self.bicimAdi(sonuc.1)) olarak başarıyla tamamlandı!")
            } else {
                Bildirim.shared.goster("Kayıt başarısız: Radyo akışı alınamadı veya bağlantı koptu.")
            }
        }
    }

    // MARK: Radyo akışı (Icecast / Shoutcast)

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                                completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let tur = (response.mimeType ?? "").lowercased()
        let durum = (response as? HTTPURLResponse)?.statusCode ?? 200
        Task { @MainActor in
            if tur.contains("aac") { self.kaynak = .aac } else if tur.contains("mpeg") || tur.contains("mp3") { self.kaynak = .mp3 }
            if durum >= 400 { self.bitir(basarili: false) }
        }
        completionHandler(durum >= 400 ? .cancel : .allow)
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        Task { @MainActor in self.yaz(data) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Bağlantı koptu: o ana kadar kaydedilen saklanır (Android'de FFmpeg de böyle bitirir).
        Task { @MainActor in
            if self.kayitta && !self.bitiriliyor { self.bitir(basarili: true) }
        }
    }

    private func yaz(_ veri: Data) {
        guard kayitta, !bitiriliyor else { return }
        if kaynak == nil { kaynak = Self.sesTuruBul(veri) }
        try? yazici?.write(contentsOf: veri)
        yazilan += veri.count
    }

    // MARK: TV ve HLS radyolar

    private func hlsKaydet(_ adres: URL) async {
        var gorulen = Set<String>()
        var ilkTur = true
        var hataSayisi = 0
        var medya = adres
        // Ana listeden en düşük bant genişlikli (en az veri harcayan) yayını, ayrı ses yayını varsa onu seç.
        if let ana = await Self.indirMetin(adres), ana.0.contains("#EXT-X-STREAM-INF") || ana.0.contains("#EXT-X-MEDIA") {
            medya = Self.medyaListesiSec(ana.0, taban: ana.1) ?? adres
        }
        while !Task.isCancelled && kayitta && !bitiriliyor {
            guard let liste = await Self.indirMetin(medya) else {
                hataSayisi += 1
                if hataSayisi > 5 { bitir(basarili: true); return }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                continue
            }
            hataSayisi = 0
            let (metin, son) = liste
            let satirlar = metin.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            if satirlar.contains(where: { $0.hasPrefix("#EXT-X-MAP") }) {
                // fMP4 parçalı yayınlar desteklenmiyor.
                bitir(basarili: false)
                return
            }
            var hedef = 6.0
            if let s = satirlar.first(where: { $0.hasPrefix("#EXT-X-TARGETDURATION:") }), let d = Double(s.dropFirst(22)) { hedef = d }
            var parcalar = satirlar.filter { !$0.isEmpty && !$0.hasPrefix("#") }
            // Kayıt "şu an"dan başlar: ilk turda sadece en son parça alınır.
            if ilkTur { parcalar = Array(parcalar.suffix(1)); ilkTur = false }
            for p in parcalar where !gorulen.contains(p) {
                if Task.isCancelled || !kayitta || bitiriliyor { return }
                gorulen.insert(p)
                guard let u = URL(string: p, relativeTo: son)?.absoluteURL, let veri = await Self.indirVeri(u) else { continue }
                let (ses, tur) = Self.parcadanSes(veri)
                if let tur, kaynak == nil { kaynak = tur }
                if !ses.isEmpty {
                    try? yazici?.write(contentsOf: ses)
                    yazilan += ses.count
                }
            }
            if satirlar.contains("#EXT-X-ENDLIST") { bitir(basarili: true); return }
            try? await Task.sleep(nanoseconds: UInt64(max(1, hedef / 2) * 1_000_000_000))
        }
    }

    private nonisolated static func indirMetin(_ u: URL) async -> (String, URL)? {
        var istek = URLRequest(url: u)
        istek.setValue(Oynatici.kimlik(u), forHTTPHeaderField: "User-Agent")
        istek.timeoutInterval = 15
        istek.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (v, c) = try? await URLSession.shared.data(for: istek), (c as? HTTPURLResponse)?.statusCode ?? 200 < 400 else { return nil }
        return (String(decoding: v, as: UTF8.self), c.url ?? u)
    }

    private nonisolated static func indirVeri(_ u: URL) async -> Data? {
        var istek = URLRequest(url: u)
        istek.setValue(Oynatici.kimlik(u), forHTTPHeaderField: "User-Agent")
        istek.timeoutInterval = 20
        guard let (v, c) = try? await URLSession.shared.data(for: istek), (c as? HTTPURLResponse)?.statusCode ?? 200 < 400 else { return nil }
        return v
    }

    private nonisolated static func medyaListesiSec(_ ana: String, taban: URL) -> URL? {
        let satirlar = ana.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        // Ayrı ses yayını (#EXT-X-MEDIA:TYPE=AUDIO,...URI="...")
        for s in satirlar where s.hasPrefix("#EXT-X-MEDIA") && s.contains("TYPE=AUDIO") {
            if let r = s.range(of: "URI=\""), let son = s[r.upperBound...].firstIndex(of: "\"") {
                return URL(string: String(s[r.upperBound..<son]), relativeTo: taban)?.absoluteURL
            }
        }
        var enIyi: (Int, URL)?
        for (i, s) in satirlar.enumerated() where s.hasPrefix("#EXT-X-STREAM-INF") {
            guard i + 1 < satirlar.count else { continue }
            var bant = Int.max
            if let r = s.range(of: "BANDWIDTH=") {
                bant = Int(s[r.upperBound...].prefix { $0.isNumber }) ?? Int.max
            }
            if let u = URL(string: satirlar[i + 1], relativeTo: taban)?.absoluteURL, enIyi == nil || bant < enIyi!.0 {
                enIyi = (bant, u)
            }
        }
        return enIyi?.1
    }

    // MARK: Ses ayıklama

    private nonisolated static func sesTuruBul(_ v: Data) -> Kaynak? {
        let b = [UInt8](v.prefix(4096))
        if b.count >= 3, b[0] == 0x49, b[1] == 0x44, b[2] == 0x33 { return .mp3 }
        var i = 0
        while i + 1 < b.count {
            if b[i] == 0xFF && (b[i + 1] & 0xE0) == 0xE0 {
                return (b[i + 1] & 0x06) == 0 ? .aac : .mp3
            }
            i += 1
        }
        return nil
    }

    /// HLS parçasından sesi çıkarır: MPEG-TS ise içindeki ses akışını, düz AAC/MP3 parçaysa ID3 başlığını atıp kendisini.
    private nonisolated static func parcadanSes(_ v: Data) -> (Data, Kaynak?) {
        let b = [UInt8](v)
        if b.count > 188 && b[0] == 0x47 && b[188] == 0x47 { return tsSes(b) }
        var bas = 0
        if b.count > 10 && b[0] == 0x49 && b[1] == 0x44 && b[2] == 0x33 {
            let boyut = (Int(b[6]) << 21) | (Int(b[7]) << 14) | (Int(b[8]) << 7) | Int(b[9])
            bas = min(b.count, 10 + boyut)
        }
        let ses = Data(b[bas...])
        return (ses, sesTuruBul(ses))
    }

    private nonisolated static func tsSes(_ b: [UInt8]) -> (Data, Kaynak?) {
        var pmtPid = -1
        var sesPid = -1
        var tur: Kaynak?
        var cikis = Data()
        var i = 0
        while i + 188 <= b.count {
            defer { i += 188 }
            guard b[i] == 0x47 else { continue }
            let pusi = (b[i + 1] & 0x40) != 0
            let pid = (Int(b[i + 1] & 0x1F) << 8) | Int(b[i + 2])
            let uyarlama = (b[i + 3] >> 4) & 0x3
            var p = i + 4
            if uyarlama == 2 { continue }
            if uyarlama == 3 { p += 1 + Int(b[i + 4]) }
            if p >= i + 188 { continue }
            if pid == 0 && pusi {
                p += 1 + Int(b[p])
                // PAT: ilk programın PMT kimliği
                let bolumSonu = p + 3 + ((Int(b[p + 1] & 0x0F) << 8) | Int(b[p + 2])) - 4
                var q = p + 8
                while q + 4 <= min(bolumSonu, i + 188) {
                    let program = (Int(b[q]) << 8) | Int(b[q + 1])
                    let k = (Int(b[q + 2] & 0x1F) << 8) | Int(b[q + 3])
                    if program != 0 { pmtPid = k; break }
                    q += 4
                }
            } else if pid == pmtPid && pusi && sesPid < 0 {
                p += 1 + Int(b[p])
                let bolumSonu = p + 3 + ((Int(b[p + 1] & 0x0F) << 8) | Int(b[p + 2])) - 4
                let programBilgi = (Int(b[p + 10] & 0x0F) << 8) | Int(b[p + 11])
                var q = p + 12 + programBilgi
                while q + 5 <= min(bolumSonu, i + 188) {
                    let akisTuru = b[q]
                    let k = (Int(b[q + 1] & 0x1F) << 8) | Int(b[q + 2])
                    let bilgi = (Int(b[q + 3] & 0x0F) << 8) | Int(b[q + 4])
                    if akisTuru == 0x0F { sesPid = k; tur = .aac; break }
                    if akisTuru == 0x03 || akisTuru == 0x04 { sesPid = k; tur = .mp3; break }
                    q += 5 + bilgi
                }
            } else if pid == sesPid {
                if pusi {
                    // PES başlığını atla
                    guard p + 9 <= i + 188, b[p] == 0, b[p + 1] == 0, b[p + 2] == 1 else { continue }
                    p += 9 + Int(b[p + 8])
                }
                if p < i + 188 { cikis.append(contentsOf: b[p..<(i + 188)]) }
            }
        }
        return (cikis, tur)
    }

    // MARK: MP3 kodlama (LAME, Android'deki FFmpeg libmp3lame -b:a 128k ile aynı ayar)

    private nonisolated static func mp3Kodla(_ kaynak: URL, _ hedef: URL) -> Bool {
        guard let giris = try? AVAudioFile(forReading: kaynak) else { return false }
        let bicim = giris.processingFormat
        let kanal = Int(bicim.channelCount)
        guard kanal > 0, let lame = lame_init() else { return false }
        defer { lame_close(lame) }
        lame_set_in_samplerate(lame, Int32(bicim.sampleRate))
        lame_set_num_channels(lame, Int32(min(kanal, 2)))
        lame_set_brate(lame, 128)
        lame_set_quality(lame, 2)
        guard lame_init_params(lame) >= 0 else { return false }
        FileManager.default.createFile(atPath: hedef.path, contents: nil)
        guard let yazici = try? FileHandle(forWritingTo: hedef) else { return false }
        defer { try? yazici.close() }
        let kare: AVAudioFrameCount = 8192
        guard let tampon = AVAudioPCMBuffer(pcmFormat: bicim, frameCapacity: kare) else { return false }
        var mp3 = [UInt8](repeating: 0, count: Int(Double(kare) * 1.25) + 7200)
        var toplam = 0
        while true {
            do { try giris.read(into: tampon) } catch { break }
            let n = Int(tampon.frameLength)
            if n == 0 { break }
            guard let veri = tampon.floatChannelData else { return false }
            let sol = UnsafePointer(veri[0])
            let sag = UnsafePointer(kanal > 1 ? veri[1] : veri[0])
            let yazilan = lame_encode_buffer_ieee_float(lame, sol, sag, Int32(n), &mp3, Int32(mp3.count))
            if yazilan < 0 { return false }
            if yazilan > 0 { yazici.write(Data(mp3[0..<Int(yazilan)])); toplam += Int(yazilan) }
        }
        let son = lame_encode_flush(lame, &mp3, Int32(mp3.count))
        if son > 0 { yazici.write(Data(mp3[0..<Int(son)])); toplam += Int(son) }
        return toplam > 1024
    }

    // MARK: Dönüştürme ve kaydetme

    static var secilenBicim: String { UserDefaults.standard.string(forKey: "record_format") ?? "m4a" }

    nonisolated static func bicimAdi(_ b: String) -> String { b == "mp3" ? "MP3" : b.uppercased() }

    /// Geçici dosyayı seçilen biçime çevirip Kayıtlar klasörüne koyar. Döner: (başarılı mı, kullanılan biçim).
    private nonisolated static func donustur(_ gecici: URL, kaynak: Kaynak, ad: String, bicim: String) -> (Bool, String) {
        let fm = FileManager.default
        let uzanti = kaynak == .mp3 ? "mp3" : "aac"
        let kaynakDosya = gecici.deletingPathExtension().appendingPathExtension(uzanti)
        try? fm.removeItem(at: kaynakDosya)
        guard (try? fm.moveItem(at: gecici, to: kaynakDosya)) != nil else { return (false, bicim) }
        defer { try? fm.removeItem(at: kaynakDosya) }

        // Yayın zaten MP3 ise olduğu gibi saklanır; değilse uygulamadaki LAME kodlayıcısıyla MP3'e çevrilir.
        let hedefBicim = bicim

        let klasor = Depo.kayitKlasoru
        try? fm.createDirectory(at: klasor, withIntermediateDirectories: true)
        let guvenliAd = String(ad.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) && ($0.isASCII || "öçşığüÖÇŞİĞÜ".unicodeScalars.contains($0)) || $0 == " "
        }).trimmingCharacters(in: .whitespaces)
        var hedef = klasor.appendingPathComponent("\(guvenliAd)-reklamsiz_radyo.\(hedefBicim)")
        var sayac = 1
        while fm.fileExists(atPath: hedef.path) {
            hedef = klasor.appendingPathComponent("\(guvenliAd)-reklamsiz_radyo (\(sayac)).\(hedefBicim)")
            sayac += 1
        }

        if hedefBicim == "mp3" {
            if kaynak == .mp3 {
                return ((try? fm.copyItem(at: kaynakDosya, to: hedef)) != nil, "mp3")
            }
            let tamam = mp3Kodla(kaynakDosya, hedef)
            if !tamam { try? fm.removeItem(at: hedef) }
            return (tamam, "mp3")
        }
        do {
            let giris = try AVAudioFile(forReading: kaynakDosya)
            let bicimGiris = giris.processingFormat
            let ayarlar: [String: Any]
            if hedefBicim == "wav" {
                ayarlar = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: bicimGiris.sampleRate,
                           AVNumberOfChannelsKey: bicimGiris.channelCount, AVLinearPCMBitDepthKey: 16,
                           AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
            } else {
                ayarlar = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: bicimGiris.sampleRate,
                           AVNumberOfChannelsKey: bicimGiris.channelCount, AVEncoderBitRateKey: 128_000]
            }
            let cikis = try AVAudioFile(forWriting: hedef, settings: ayarlar, commonFormat: bicimGiris.commonFormat,
                                        interleaved: bicimGiris.isInterleaved)
            guard let tampon = AVAudioPCMBuffer(pcmFormat: bicimGiris, frameCapacity: 8192) else { return (false, hedefBicim) }
            while true {
                do { try giris.read(into: tampon) } catch { break }
                if tampon.frameLength == 0 { break }
                try cikis.write(from: tampon)
            }
            let boyut = (try? fm.attributesOfItem(atPath: hedef.path)[.size] as? Int) ?? 0
            if boyut < 1024 { try? fm.removeItem(at: hedef); return (false, hedefBicim) }
            return (true, hedefBicim)
        } catch {
            try? fm.removeItem(at: hedef)
            return (false, hedefBicim)
        }
    }
}

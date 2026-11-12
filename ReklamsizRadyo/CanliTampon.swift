import Foundation
import Network

/// Canlı HLS yayınları için uygulama içi aracı.
///
/// Birçok yayın yalnızca son 9-24 saniyeyi tutuyor. Apple'ın oynatıcısı bu kadar kısa pencerede ya parça
/// silinince donuyor ya da ara belleği yetmeyip takılıyordu (Safari'de de aynısı oluyor, Android'de olmuyor).
/// Aracı, yayının parçalarını yayınlanır yayınlanmaz indirip son iki dakikayı telefonda tutar ve oynatıcıya
/// telefondaki bu daha uzun listeyi verir. Yalnızca bu telefonda (127.0.0.1) çalışır, dışarıya açık değildir.
/// Şifreli, fMP4 veya ayrı ses kanallı yayınlarda kullanılmaz; o yayınlar eskisi gibi doğrudan çalar.
final class CanliTampon: @unchecked Sendable {
    static let shared = CanliTampon()

    private struct Parca {
        let no: Int
        let sure: Double
        let veri: Data
        let uzanti: String
        let kesinti: Bool
    }

    private struct Satir {
        let uri: String
        let sure: Double
        let kesinti: Bool
    }

    private struct MedyaListesi {
        var hedef = 6
        var sira = 0
        var satirlar: [Satir] = []
        var uygunDegil = false
    }

    /// Telefonda tutulan yayın süresi (saniye).
    private let tutulacakSure: Double = 120
    /// Kaynak liste bundan uzunsa yayının penceresi zaten yeterli: aracı kullanılmaz, yayın doğrudan çalar
    /// (ATV, Kanal D, Star TV gibi uzun listeli yayınlar aracıdan geçince açılmıyordu).
    private let kisaPencereSiniri: Double = 45

    private let kuyruk = DispatchQueue(label: "reklamsizradyo.canlitampon")
    private var dinleyici: NWListener?
    private var port: UInt16 = 0
    private var oturum = ""
    private var parcalar: [Parca] = []
    private var hedefSure = 6
    private var kesintiSirasi = 0
    private var sonrakiNo = 1
    private var sonKaynakNo: Int?
    private var bekleyenKesinti = false
    private var gorev: Task<Void, Never>?

    /// Adres bir HLS yayını olabilir mi (.m3u8). Asıl karar liste indirilince verilir.
    static func hlsOlabilir(_ u: URL) -> Bool {
        u.path.lowercased().hasSuffix(".m3u8") && u.host != "127.0.0.1"
    }

    /// Yayını aracıdan çalmak için telefondaki adresi döner. Uygun değilse nil: yayın doğrudan çalınır.
    func hazirla(_ kaynak: URL, kimlik: String) async -> URL? {
        durdur()
        guard let port = await dinleyiciyiBaslat() else { return nil }
        guard let bulunan = await medyaListesiBul(kaynak, kimlik: kimlik) else { return nil }
        let yeniOturum = String(UUID().uuidString.prefix(8))
        kuyruk.sync {
            oturum = yeniOturum
            parcalar = []
            kesintiSirasi = 0
            sonrakiNo = 1
            sonKaynakNo = nil
            bekleyenKesinti = false
            hedefSure = max(bulunan.0.hedef, 1)
        }
        await isle(bulunan.0, adres: bulunan.1, kimlik: kimlik, oturumNo: yeniOturum)
        if kuyruk.sync(execute: { parcalar.isEmpty }) { return nil }
        let adres = bulunan.1
        gorev = Task.detached { [weak self] in
            await self?.dongu(adres, kimlik: kimlik, oturumNo: yeniOturum)
        }
        return URL(string: "http://127.0.0.1:\(port)/\(yeniOturum)/canli.m3u8")
    }

    func durdur() {
        gorev?.cancel()
        gorev = nil
        kuyruk.sync {
            oturum = ""
            parcalar = []
        }
    }

    // MARK: Kaynak yayını izleme

    private func dongu(_ adres: URL, kimlik: String, oturumNo: String) async {
        while !Task.isCancelled {
            let bekle = kuyruk.sync { min(max(Double(hedefSure) / 2, 1), 4) }
            try? await Task.sleep(nanoseconds: UInt64(bekle * 1_000_000_000))
            guard !Task.isCancelled, kuyruk.sync(execute: { oturum == oturumNo }) else { return }
            guard let r = await metinIndir(adres, kimlik: kimlik) else { continue }
            let l = cozumle(r.0)
            if l.satirlar.isEmpty || l.uygunDegil { continue }
            await isle(l, adres: r.1, kimlik: kimlik, oturumNo: oturumNo)
        }
    }

    /// Listede yeni çıkan parçaları indirip telefondaki listeye ekler.
    private func isle(_ l: MedyaListesi, adres: URL, kimlik: String, oturumNo: String) async {
        let son = l.sira + l.satirlar.count - 1
        var yeniler: [(Int, Satir)] = []
        kuyruk.sync {
            guard oturum == oturumNo else { return }
            hedefSure = max(l.hedef, 1)
            if let s = sonKaynakNo {
                if son < s - 3 {
                    // Yayın baştan başladı (numaralar geriye gitti).
                    sonKaynakNo = l.sira - 1
                    bekleyenKesinti = true
                } else if l.sira > s + 1 {
                    // Aradaki parçalar kaçırıldı (bağlantı bir süre kesildi).
                    bekleyenKesinti = true
                }
            }
            // İlk açılışta listedeki bütün parçalar alınır (kısa liste, aynı anda iner):
            // oynatıcı başlamak için yayının sonundan en az üç parça süresi ister.
            let alt = sonKaynakNo ?? (l.sira - 1)
            for (i, satir) in l.satirlar.enumerated() where l.sira + i > alt {
                yeniler.append((l.sira + i, satir))
            }
        }
        // Yeni parçalar aynı anda indirilir (açılış hızlansın), listeye sırayla eklenir.
        let adresler = yeniler.map { URL(string: $0.1.uri, relativeTo: adres)?.absoluteURL }
        var indirilen = await withTaskGroup(of: (Int, Data?).self) { grup -> [Int: Data] in
            for (i, u) in adresler.enumerated() {
                guard let u else { continue }
                grup.addTask { (i, await self.veriIndir(u, kimlik: kimlik)) }
            }
            var sonuc: [Int: Data] = [:]
            for await (i, veri) in grup {
                if let veri { sonuc[i] = veri }
            }
            return sonuc
        }
        for (i, (no, satir)) in yeniler.enumerated() {
            if Task.isCancelled { return }
            guard let u = adresler[i] else { continue }
            var veri = indirilen.removeValue(forKey: i)
            if veri == nil { veri = await veriIndir(u, kimlik: kimlik) }
            kuyruk.sync {
                guard oturum == oturumNo else { return }
                if let veri {
                    let uzanti = u.pathExtension.isEmpty ? "ts" : u.pathExtension.lowercased()
                    parcalar.append(Parca(no: sonrakiNo, sure: satir.sure, veri: veri, uzanti: uzanti,
                                          kesinti: satir.kesinti || bekleyenKesinti))
                    sonrakiNo += 1
                    bekleyenKesinti = false
                } else {
                    bekleyenKesinti = true
                }
                sonKaynakNo = no
                buda()
            }
        }
    }

    /// Telefonda en fazla iki dakika tutulur, en az 6 parça kalır.
    private func buda() {
        var toplam = parcalar.reduce(0) { $0 + $1.sure }
        while parcalar.count > 6, toplam > tutulacakSure {
            let p = parcalar.removeFirst()
            toplam -= p.sure
            if p.kesinti { kesintiSirasi += 1 }
        }
    }

    // MARK: Liste okuma

    private func medyaListesiBul(_ u: URL, kimlik: String) async -> (MedyaListesi, URL)? {
        guard let r = await metinIndir(u, kimlik: kimlik),
              r.0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") else { return nil }
        if r.0.contains("#EXT-X-STREAM-INF") {
            // Ayrı ses kanalı olan yayınlarda alt listelerde ses yok: aracı kullanılmaz.
            if r.0.range(of: #"#EXT-X-MEDIA:[^\n]*TYPE=AUDIO[^\n]*URI="#, options: .regularExpression) != nil { return nil }
            guard let alt = enDusukAltListe(r.0, taban: r.1), let r2 = await metinIndir(alt, kimlik: kimlik) else { return nil }
            let l = cozumle(r2.0)
            return uygun(l) ? (l, r2.1) : nil
        }
        let l = cozumle(r.0)
        return uygun(l) ? (l, r.1) : nil
    }

    /// Aracı yalnızca kısa pencereli (donma yapan) yayınlarda kullanılır.
    private func uygun(_ l: MedyaListesi) -> Bool {
        if l.uygunDegil || l.satirlar.isEmpty { return false }
        return l.satirlar.reduce(0) { $0 + $1.sure } < kisaPencereSiniri
    }

    /// Uygulama yalnızca ses çaldığı için sesi olan en düşük kaliteli alt liste seçilir.
    private func enDusukAltListe(_ metin: String, taban: URL) -> URL? {
        let satirlar = metin.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        var en: (Int, URL)?
        for (i, s) in satirlar.enumerated() where s.hasPrefix("#EXT-X-STREAM-INF") {
            if let kod = nitelik("CODECS", s)?.lowercased(),
               !["mp4a", "ac-3", "ec-3", "mp3", "opus"].contains(where: { kod.contains($0) }) { continue }
            var bant = Int.max
            if let r = s.range(of: #"[:,]BANDWIDTH=\d+"#, options: .regularExpression) {
                bant = Int(s[r].filter(\.isNumber)) ?? Int.max
            }
            guard let uri = satirlar[(i + 1)...].first(where: { !$0.isEmpty && !$0.hasPrefix("#") }),
                  let u = URL(string: uri, relativeTo: taban)?.absoluteURL else { continue }
            if en == nil || bant < en!.0 { en = (bant, u) }
        }
        return en?.1
    }

    private func nitelik(_ ad: String, _ s: String) -> String? {
        guard let r = s.range(of: ad + "=") else { return nil }
        let kalan = s[r.upperBound...]
        if kalan.hasPrefix("\"") { return String(kalan.dropFirst().prefix { $0 != "\"" }) }
        return String(kalan.prefix { $0 != "," })
    }

    private func cozumle(_ metin: String) -> MedyaListesi {
        var l = MedyaListesi()
        var sure: Double?
        var kesinti = false
        func deger(_ s: String, _ onek: String) -> String {
            String(s.dropFirst(onek.count)).trimmingCharacters(in: .whitespaces)
        }
        for ham in metin.components(separatedBy: .newlines) {
            let s = ham.trimmingCharacters(in: .whitespaces)
            if s.isEmpty { continue }
            if s.hasPrefix("#EXT-X-TARGETDURATION:") {
                l.hedef = Int(Double(deger(s, "#EXT-X-TARGETDURATION:")) ?? 6)
            } else if s.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                l.sira = Int(deger(s, "#EXT-X-MEDIA-SEQUENCE:")) ?? 0
            } else if (s.hasPrefix("#EXT-X-KEY") && !s.contains("METHOD=NONE")) || s.hasPrefix("#EXT-X-MAP")
                        || s.hasPrefix("#EXT-X-ENDLIST") || s.hasPrefix("#EXT-X-BYTERANGE") {
                l.uygunDegil = true
            } else if s.hasPrefix("#EXTINF:") {
                sure = Double(deger(s, "#EXTINF:").prefix { $0 != "," })
            } else if s == "#EXT-X-DISCONTINUITY" {
                kesinti = true
            } else if !s.hasPrefix("#") {
                l.satirlar.append(Satir(uri: s, sure: sure ?? Double(l.hedef), kesinti: kesinti))
                sure = nil
                kesinti = false
            }
        }
        return l
    }

    // MARK: İndirme

    private func istek(_ u: URL, kimlik: String) -> URLRequest {
        var r = URLRequest(url: u)
        r.setValue(kimlik, forHTTPHeaderField: "User-Agent")
        r.cachePolicy = .reloadIgnoringLocalCacheData
        r.timeoutInterval = 15
        return r
    }

    private func metinIndir(_ u: URL, kimlik: String) async -> (String, URL)? {
        guard let (veri, cevap) = try? await URLSession.shared.data(for: istek(u, kimlik: kimlik)),
              (cevap as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (String(decoding: veri, as: UTF8.self), cevap.url ?? u)
    }

    private func veriIndir(_ u: URL, kimlik: String) async -> Data? {
        guard let (veri, cevap) = try? await URLSession.shared.data(for: istek(u, kimlik: kimlik)),
              let kod = (cevap as? HTTPURLResponse)?.statusCode, kod == 200 || kod == 206, !veri.isEmpty else { return nil }
        return veri
    }

    // MARK: Telefondaki küçük sunucu

    private func dinleyiciyiBaslat() async -> UInt16? {
        if let p = kuyruk.sync(execute: { dinleyici != nil && port != 0 ? port : nil }) { return p }
        return await withCheckedContinuation { (c: CheckedContinuation<UInt16?, Never>) in
            kuyruk.async {
                let param = NWParameters.tcp
                param.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
                guard let d = try? NWListener(using: param) else {
                    c.resume(returning: nil)
                    return
                }
                var bitti = false
                d.stateUpdateHandler = { [weak self] durum in
                    switch durum {
                    case .ready:
                        let p = d.port?.rawValue ?? 0
                        self?.port = p
                        if !bitti {
                            bitti = true
                            c.resume(returning: p == 0 ? nil : p)
                        }
                    case .failed, .cancelled:
                        self?.dinleyici = nil
                        self?.port = 0
                        if !bitti {
                            bitti = true
                            c.resume(returning: nil)
                        }
                    default:
                        break
                    }
                }
                d.newConnectionHandler = { [weak self] b in self?.baglantiyiKarsila(b) }
                self.dinleyici = d
                d.start(queue: self.kuyruk)
            }
        }
    }

    private func baglantiyiKarsila(_ b: NWConnection) {
        b.start(queue: kuyruk)
        b.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] veri, _, _, _ in
            guard let self, let veri, let metin = String(data: veri, encoding: .utf8) else {
                b.cancel()
                return
            }
            let cevap = self.cevapla(metin)
            b.send(content: cevap, completion: .contentProcessed { _ in b.cancel() })
        }
    }

    /// Kuyrukta çalışır (bağlantılar kuyruğa bağlı), bu yüzden durum doğrudan okunur.
    private func cevapla(_ istekMetni: String) -> Data {
        let satirlar = istekMetni.components(separatedBy: "\r\n")
        let ilk = satirlar.first?.split(separator: " ") ?? []
        guard ilk.count >= 2, !oturum.isEmpty else { return yanit(404, "text/plain", Data()) }
        let yol = String(ilk[1])
        let bas = "/\(oturum)/"
        guard yol.hasPrefix(bas) else { return yanit(404, "text/plain", Data()) }
        let kalan = yol.dropFirst(bas.count)
        if kalan == "canli.m3u8" {
            return yanit(200, "application/vnd.apple.mpegurl", Data(listeMetni().utf8))
        }
        guard kalan.hasPrefix("p/"), let no = Int(kalan.dropFirst(2).prefix { $0.isNumber }),
              let p = parcalar.first(where: { $0.no == no }) else { return yanit(404, "text/plain", Data()) }
        let tur = Self.tur(p.uzanti)
        if let aralik = satirlar.first(where: { $0.lowercased().hasPrefix("range: bytes=") }) {
            let d = aralik.dropFirst("range: bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
            let a = Int(d.first ?? "") ?? 0
            let b = min(d.count > 1 ? (Int(d[1]) ?? p.veri.count - 1) : p.veri.count - 1, p.veri.count - 1)
            if a <= b {
                return yanit(206, tur, p.veri.subdata(in: a..<(b + 1)), ek: "Content-Range: bytes \(a)-\(b)/\(p.veri.count)\r\n")
            }
        }
        return yanit(200, tur, p.veri)
    }

    private func listeMetni() -> String {
        let enUzun = Int((parcalar.map(\.sure).max() ?? 0).rounded(.up))
        var s = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:\(max(hedefSure, enUzun))\n"
        s += "#EXT-X-MEDIA-SEQUENCE:\(parcalar.first?.no ?? 0)\n#EXT-X-DISCONTINUITY-SEQUENCE:\(kesintiSirasi)\n"
        for p in parcalar {
            if p.kesinti { s += "#EXT-X-DISCONTINUITY\n" }
            s += "#EXTINF:\(String(format: "%.3f", p.sure)),\np/\(p.no).\(p.uzanti)\n"
        }
        return s
    }

    private static func tur(_ uzanti: String) -> String {
        switch uzanti {
        case "aac": return "audio/aac"
        case "mp3": return "audio/mpeg"
        case "ac3": return "audio/ac3"
        default: return "video/mp2t"
        }
    }

    private func yanit(_ kod: Int, _ tur: String, _ govde: Data, ek: String = "") -> Data {
        let durum = [200: "OK", 206: "Partial Content"][kod] ?? "Not Found"
        var d = Data(("HTTP/1.1 \(kod) \(durum)\r\nContent-Type: \(tur)\r\nContent-Length: \(govde.count)\r\n"
                      + ek + "Cache-Control: no-cache\r\nConnection: close\r\n\r\n").utf8)
        d.append(govde)
        return d
    }
}

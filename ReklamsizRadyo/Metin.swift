import Foundation

/// Kotlin'deki Regex işlemlerinin karşılıkları.
enum RX {
    private static var onbellek: [String: NSRegularExpression] = [:]
    private static let kilit = NSLock()

    static func ifade(_ desen: String, buyukKucuk: Bool = false) -> NSRegularExpression {
        let anahtar = desen + (buyukKucuk ? "#i" : "")
        kilit.lock(); defer { kilit.unlock() }
        if let r = onbellek[anahtar] { return r }
        let r = try! NSRegularExpression(pattern: desen, options: buyukKucuk ? [.caseInsensitive] : [])
        onbellek[anahtar] = r
        return r
    }

    static func degistir(_ metin: String, _ desen: String, _ yeni: String, buyukKucuk: Bool = false) -> String {
        let r = ifade(desen, buyukKucuk: buyukKucuk)
        return r.stringByReplacingMatches(in: metin, range: NSRange(metin.startIndex..., in: metin), withTemplate: yeni)
    }

    static func iceriyor(_ metin: String, _ desen: String) -> Bool {
        ifade(desen).firstMatch(in: metin, range: NSRange(metin.startIndex..., in: metin)) != nil
    }

    /// İlk eşleşmenin grupları (0: tamamı). Grup yoksa boş metin.
    static func ilk(_ metin: String, _ desen: String) -> [String]? {
        guard let m = ifade(desen).firstMatch(in: metin, range: NSRange(metin.startIndex..., in: metin)) else { return nil }
        return gruplar(m, metin)
    }

    static func hepsi(_ metin: String, _ desen: String) -> [[String]] {
        ifade(desen).matches(in: metin, range: NSRange(metin.startIndex..., in: metin)).map { gruplar($0, metin) }
    }

    private static func gruplar(_ m: NSTextCheckingResult, _ metin: String) -> [String] {
        (0..<m.numberOfRanges).map { i in
            guard let r = Range(m.range(at: i), in: metin) else { return "" }
            return String(metin[r])
        }
    }
}

extension String {
    /// Kotlin split(" ") gibi: boş parçalar da kalır.
    func bol(_ ayirici: Character = " ") -> [String] {
        split(separator: ayirici, omittingEmptySubsequences: false).map(String.init)
    }
}

/// Android RadioMatcher: söylenen cümleden radyo / TV kanalı bulma.
enum KanalBulucu {
    enum TurIpucu { case yok, tv, radyo }

    private static let tvIpucu: Set<String> = ["tv", "televizyon", "televizyonu", "kanal", "kanali", "kanalini", "kanalina", "kanallari"]
    private static let radyoIpucu: Set<String> = ["radyo", "radyosu", "radyosunu", "radyoyu", "fm", "istasyonu", "istasyonunu"]
    private static let turKelimeleri: Set<String> = ["radyo", "radyosu", "radyosunu", "radyoyu", "fm", "tv", "televizyon", "televizyonu",
                                                     "kanali", "kanalini", "kanalina", "istasyonu", "istasyonunu"]
    private static let dolguKelimeler: Set<String> = [
        "ac", "acar", "acsana", "acin", "cal", "calsin", "baslat", "dinle", "dinlet", "oynat", "lutfen",
        "icin", "istiyorum", "bana", "hemen", "su", "simdi", "bir", "calar", "saat", "saati", "saate", "alarm", "alarmi", "alarma",
        "zamanlanmis", "gorev", "gorevi", "gorevini", "kayit", "kaydi", "kaydet", "kaydini",
        "kur", "kurulsun", "kuralim", "kuruver", "ayarla", "ayarlansin", "iptal", "et", "kapat", "sil", "durdur", "kaldir",
        "kac", "dakika", "sure", "zamanlayici", "zamanlayiciyi", "uyku", "modu", "modunu", "yayin", "yayini",
        "sabah", "aksam", "oglen", "gece", "bucuk", "ceyrek", "var", "saatinde", "saatlerinde", "beni", "uyandir",
        "acilsin", "aciver", "goster", "gec", "izle", "izlet", "sesini",
        "sonra", "once", "itibaren", "kadar",
    ]
    private static let sayiKelimeleri: [String: Int] = [
        "sifir": 0, "bir": 1, "iki": 2, "uc": 3, "dort": 4, "bes": 5, "alti": 6, "yedi": 7,
        "sekiz": 8, "dokuz": 9, "on": 10, "yirmi": 20, "otuz": 30, "kirk": 40, "elli": 50,
        "altmis": 60, "yetmis": 70, "seksen": 80, "doksan": 90,
    ]

    static func normalize(_ girdi: String) -> String {
        var s = girdi.lowercased(with: Locale(identifier: "tr_TR"))
        for (a, b) in [("ı", "i"), ("ğ", "g"), ("ü", "u"), ("ş", "s"), ("ö", "o"), ("ç", "c")] {
            s = s.replacingOccurrences(of: a, with: b)
        }
        s = RX.degistir(s, "[^a-z0-9\\s:]", " ")
        s = RX.degistir(s, "\\s+", " ")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "TRT 1'i", "Kanal D'yi" -> eki at.
    static func kesmeEkleriniSil(_ ham: String) -> String { RX.degistir(ham, "['’`]\\p{L}+", "") }

    /// "uc yuz altmis" -> "360", "kanal yedi" -> "kanal 7"
    static func sayiKelimeleriniRakamaCevir(_ s: String) -> String {
        var cikis: [String] = []
        var simdiki = 0
        var sayida = false
        for p in s.bol() {
            if p == "yuz" {
                simdiki = (simdiki == 0 ? 1 : simdiki) * 100
                sayida = true
            } else if let v = sayiKelimeleri[p] {
                simdiki += v
                sayida = true
            } else {
                if sayida { cikis.append(String(simdiki)); simdiki = 0; sayida = false }
                cikis.append(p)
            }
        }
        if sayida { cikis.append(String(simdiki)) }
        return cikis.joined(separator: " ")
    }

    static func turIpucu(_ s: String) -> TurIpucu {
        let k = Set(s.bol())
        let tv = k.contains { tvIpucu.contains($0) }
        let radyo = k.contains { radyoIpucu.contains($0) }
        if tv && !radyo { return .tv }
        if radyo && !tv { return .radyo }
        return .yok
    }

    /// Saat/süre ifadelerini siler; kanal adındaki sayılara dokunmaz.
    static func zamanIfadeleriniSil(_ s: String) -> String {
        var t = RX.degistir(s, "\\b\\d{1,2}[:.]\\d{2}(\\s*(den|dan|ten|tan|de|da|te|ta|e|a|ye|ya)\\b)?", " ")
        t = RX.degistir(t, "\\b\\d{1,2}\\s*(den|dan|ten|tan|de|da|te|ta|e|a|ye|ya)\\b", " ")
        t = RX.degistir(t, "\\bsaat\\s+\\d{1,2}\\b", " ")
        t = RX.degistir(t, "\\b\\d+\\s+(dakika|saat|dakikalik|saatlik)\\b", " ")
        return RX.degistir(t, "\\s+", " ").trimmingCharacters(in: .whitespaces)
    }

    static func kesinBul(_ hamMetin: String, _ kayitlar: [Kayit], tvMi: (Kayit) -> Bool, tvKategorisiAcik: Bool, zamanKomutu: Bool = false) -> [Kayit] {
        if kayitlar.isEmpty { return [] }
        let ham = zamanKomutu ? RX.degistir(hamMetin, "(\\d)['’`](den|dan|ten|tan|de|da|te|ta)\\b", "$1 $2", buyukKucuk: true) : hamMetin
        var n = normalize(kesmeEkleriniSil(ham))
        if zamanKomutu { n = zamanIfadeleriniSil(n) }
        let ipucu = turIpucu(n)
        var enIyi: (Int, [Kayit])?
        var denenen: [String] = []
        for v in [n, sayiKelimeleriniRakamaCevir(n)] where !denenen.contains(v) {
            denenen.append(v)
            guard let r = eslestir(v, kayitlar, ipucu, tvMi, tvKategorisiAcik) else { continue }
            if enIyi == nil || r.0 < enIyi!.0 { enIyi = r }
        }
        return enIyi?.1 ?? []
    }

    private static func benzersiz(_ l: [Kayit], _ anahtar: (Kayit) -> String) -> [Kayit] {
        var gorulen = Set<String>()
        return l.filter { gorulen.insert(anahtar($0)).inserted }
    }

    private static func eslestir(_ n: String, _ kayitlar: [Kayit], _ ipucu: TurIpucu, _ tvMi: (Kayit) -> Bool, _ tvKategorisiAcik: Bool) -> (Int, [Kayit])? {
        let parcalar = n.bol().filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let kalan = parcalar.filter { !dolguKelimeler.contains($0) }
            .map { ($0 == "radyosu" || $0 == "radyosunu" || $0 == "radyoyu") ? "radyo" : $0 }
        let cekirdek = kalan.filter { !turKelimeleri.contains($0) }
        if cekirdek.isEmpty { return nil }
        let kalanBitisik = kalan.joined()
        let cekirdekBitisik = cekirdek.joined()

        struct Aday { let k: Kayit; let ad: [String]; let cekirdekAd: [String] }
        let adaylar = kayitlar.map { k -> Aday in
            let a = normalize(k.ad).bol().filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            return Aday(k: k, ad: a, cekirdekAd: a.filter { !turKelimeleri.contains($0) })
        }
        let k1 = adaylar.filter { $0.ad.joined() == kalanBitisik }
        let k2 = adaylar.filter { let c = $0.cekirdekAd.joined(); return !c.isEmpty && c == cekirdekBitisik }
        let k3 = adaylar.filter { a in a.cekirdekAd.count == cekirdek.count && cekirdek.allSatisfy { a.cekirdekAd.contains($0) } }
        let k4 = adaylar.filter { a in cekirdek.allSatisfy { a.ad.contains($0) } }

        let katlar = [k1, k2, k3, k4].map { t in benzersiz(t.map(\.k)) { normalize($0.ad) + "|" + $0.url } }
        guard let ilkSira = katlar.firstIndex(where: { !$0.isEmpty }) else { return nil }
        let ilkDolu = katlar[ilkSira]

        if ipucu != .yok {
            for (i, t) in katlar.enumerated() {
                let tur = t.filter { tvMi($0) == (ipucu == .tv) }
                if !tur.isEmpty { return (i, tekeIndir(tur)) }
            }
            return (ilkSira, tekeIndir(ilkDolu))
        }
        let tvler = ilkDolu.filter { tvMi($0) }
        let radyolar = ilkDolu.filter { !tvMi($0) }
        if !tvler.isEmpty && !radyolar.isEmpty {
            return (ilkSira, tekeIndir(tvKategorisiAcik ? tvler : radyolar))
        }
        return (ilkSira, tekeIndir(ilkDolu))
    }

    private static func tekeIndir(_ l: [Kayit]) -> [Kayit] {
        benzersiz(l) { normalize($0.ad).replacingOccurrences(of: " ", with: "") }
    }
}

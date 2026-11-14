import Foundation

/// Uygulamadaki bir radyo/TV kaydı (Android'deki RadioStation). Kayıtlar sekmesindeki dosyalar da bu yapıyla gösterilir.
struct Kayit: Codable, Identifiable, Hashable {
    var no: Int
    var ad: String
    var url: String
    var favori: Bool = false
    /// Listeden geldiyse M3U'daki tvg-id; kullanıcının eklediği ya da düzenlediği kayıtta boş.
    var kaynak: String?
    var id: Int { no }
    var dosyaMi: Bool { !url.lowercased().hasPrefix("http") }
}

enum FavoriYon { case yukari, asagi, enBasa, enSona }

/// Sadece TestFlight'a giden test derlemesinde true. Mağaza derlemesi bu ayar olmadan derlenir,
/// bu yüzden aşağıdaki test seçenekleri App Store sürümünde hiç çalışmaz.
#if TEST_LISTESI
let testDerlemesi = true
#else
let testDerlemesi = false
#endif

/// Ayarlardaki liste açma kapama satırı yalnızca geliştiricinin kendi test derlemesinde bulunur.
#if TEST_AYARI
let testAyariVar = true
#else
let testAyariVar = false
#endif

let TV_KATEGORI = "TV Kanalları"
let OTOMATIK_KATEGORI = "Otomatik (İsimden Bul)"
let KATEGORI_SECENEKLERI = [OTOMATIK_KATEGORI, "Pop", "Arabesk", "Haber", "Slow", "Spor", "Dini", "Oyun Havası", "Yerel", TV_KATEGORI]
/// Kayıtlı sekme sırasını okur. Eski sürümden gelen kullanıcının sırası korunur, TV sekmesi radyoların yanına eklenir.
func sekmeSirasiniCoz(_ kayitli: String, eskiNo: Int) -> [String] {
    let sira = kayitli.split(separator: ",").map(String.init)
    if Set(sira) == ["home", "tv", "fav", "rec"] && sira.count == 4 { return sira }
    var eski: [String]
    switch eskiNo {
    case 1: eski = ["home", "rec", "fav"]
    case 2: eski = ["fav", "home", "rec"]
    case 3: eski = ["fav", "rec", "home"]
    case 4: eski = ["rec", "home", "fav"]
    case 5: eski = ["rec", "fav", "home"]
    default: eski = ["home", "fav", "rec"]
    }
    eski.insert("tv", at: (eski.firstIndex(of: "home") ?? 0) + 1)
    return eski
}

func sekmeEtiketi(_ s: String, listeKapali: Bool) -> String {
    switch s {
    case "fav": return "Favoriler"
    case "rec": return "Kayıtlar"
    case "tv": return TV_KATEGORI
    default: return listeKapali ? "Tüm Radyolar" : "Radyolar"
    }
}

let KATEGORI_DUGMELERI = ["Tümü", "Pop", "Arabesk", "Haber", "Slow", "Spor", "Dini", "Oyun Havası", "Yerel", TV_KATEGORI]

/// M3U'daki bir girdi (Android RemoteListSync.Entry).
struct ListeGirdisi {
    let id: String
    let ad: String
    let url: String
}

enum M3U {
    static func oku(_ metin: String) -> [ListeGirdisi] {
        var sonuc: [ListeGirdisi] = []
        var kimlik: String?
        var ad: String?
        for ham in metin.components(separatedBy: .newlines) {
            let satir = ham.trimmingCharacters(in: .whitespaces)
            if satir.uppercased().hasPrefix("#EXTINF") {
                kimlik = ozellik("tvg-id", satir)
                // Ad, son tırnaktan sonraki ilk virgülden başlar ("TV8,5" gibi adlar bölünmesin).
                let bas = satir.range(of: "\"", options: .backwards)?.upperBound ?? satir.startIndex
                if let virgul = satir[bas...].firstIndex(of: ",") {
                    let a = String(satir[satir.index(after: virgul)...]).trimmingCharacters(in: .whitespaces)
                    ad = a.isEmpty ? nil : a
                } else {
                    ad = nil
                }
            } else if satir.lowercased().hasPrefix("http") {
                if let k = kimlik, let a = ad { sonuc.append(ListeGirdisi(id: k, ad: a, url: satir)) }
                kimlik = nil
                ad = nil
            }
        }
        return sonuc
    }

    private static func ozellik(_ ad: String, _ satir: String) -> String? {
        guard let r = satir.range(of: ad + "=\"") else { return nil }
        let kalan = satir[r.upperBound...]
        guard let son = kalan.firstIndex(of: "\"") else { return nil }
        let deger = String(kalan[..<son])
        return deger.isEmpty ? nil : deger
    }
}

/// Kayıtları saklar ve internetteki listeyle eşitler (Android RemoteListSync ile aynı kurallar):
/// kullanıcının sildiği veya düzenlediği kayıt geri getirilmez, kullanıcının eklediği kayda dokunulmaz.
@MainActor
final class Depo: ObservableObject {
    /// Uygulamanın tek listesi: ekranlar da Siri de aynı listeyi kullanır.
    static let paylasilan = Depo()

    @Published private(set) var kayitlar: [Kayit] = []
    /// Kategori, veri sayacı gibi ayarlar değişince ekranın yenilenmesi için.
    @Published private(set) var degisim = 0
    /// Liste indirilirken true. Açılışta indirme hemen başladığı için ilk değer true.
    @Published private(set) var listeIndiriliyor = true
    private var guncelleniyor = false
    /// Liste GitHub'dan kapatıldıysa true. Kapalıyken kayıtların hepsi gizlenir, ek radyolar gösterilmez.
    /// Yeni kurulum da kapalı başlar: GitHub "açık" demeden hiçbir radyo gösterilmez.
    @Published private(set) var listeKapali = false

    /// TV kanallarının kendi sekmesi var, kategori düğmelerinde gösterilmez.
    var kategoriDugmeleri: [String] { KATEGORI_DUGMELERI.filter { $0 != TV_KATEGORI } }
    /// Liste kapalıyken "TV Kanalları" gösterilmez, liste açılınca kendiliğinden geri gelir.
    var kategoriSecenekleri: [String] { listeKapali ? KATEGORI_SECENEKLERI.filter { $0 != TV_KATEGORI } : KATEGORI_SECENEKLERI }

    /// Kapatılınca gizlenen kayıtlar. Silinmez; liste açılınca sırası ve favorileriyle aynen geri gelir.
    private var gizliKayitlar: [Kayit] = []
    /// Favoriler sekmesinin kullanıcı sırası. Kayıt numarası tutulur: link değişse de sıra bozulmaz.
    private var favoriSirasi: [Int] = []

    /// Android'deki gibi radio-browser.info'dan gelen ek Türk radyoları (sadece bellekte, her açılışta yeniden alınır).
    @Published private(set) var apiKayitlar: [Kayit] = []
    private var apiKategoriler: [String: String] = [:]
    /// Kullanıcının sildiği/düzenlediği ek radyoların adresleri (Android "deleted_api_urls").
    private var silinenApi: Set<String> = []

    private var silinenler: Set<String> = []
    private var sonNo = 0
    private let ayar = UserDefaults.standard

    private enum Tur: CaseIterable {
        case radyo, tv
        var anahtar: String { self == .radyo ? "radyo" : "tv" }
        var dosya: String { anahtar + ".m3u" }
        var onek: String { self == .radyo ? "r-" : "t-" }
    }

    // Önce GitHub: jsDelivr saatlerce eski dosyayı verebilir, liste kapatılınca uygulama geç öğrenir.
    private let tabanlar = [
        "https://raw.githubusercontent.com/firatatass/reklamsiz-radyo-liste/main/",
        "https://cdn.jsdelivr.net/gh/firatatass/reklamsiz-radyo-liste@main/",
    ]

    private enum Indirme {
        case metin(String)
        /// Sunucular cevap verdi ama dosya yok (404): liste kaldırılmış demektir.
        case yok
        /// İnternet yok ya da sunucu hatası: listenin durumu bilinmiyor.
        case hata
    }

    private struct Kayitli: Codable {
        var kayitlar: [Kayit]
        var silinenler: [String]
        var sonNo: Int
        var gizli: [Kayit]?
    }

    init() {
        yukle()
        favoriSirasi = ayar.array(forKey: "favori_sirasi") as? [Int] ?? []
        listeKapali = ayar.bool(forKey: "liste_kapali") || !cihazdaListeVar
        if let m = ayar.string(forKey: "deleted_api_urls"), let d = try? JSONSerialization.jsonObject(with: Data(m.utf8)) as? [String] {
            silinenApi = Set(d)
        }
        esitle()
        Task { await internettenGuncelle() }
        Task { await radioBrowserAl() }
    }

    // MARK: Ayarlar (Android'deki RadioPrefs anahtarlarıyla aynı adlar)

    func kategori(_ url: String) -> String? { ayar.string(forKey: "cat_" + url) }

    func kategoriAyarla(_ url: String, _ k: String) {
        if k != OTOMATIK_KATEGORI {
            ayar.set(k, forKey: "cat_" + url)
        } else {
            ayar.removeObject(forKey: "cat_" + url)
        }
        degisim += 1
    }

    func tvMi(_ k: Kayit) -> Bool { kategori(k.url) == TV_KATEGORI }

    func veriSiniri(_ url: String) -> Int { ayar.integer(forKey: "data_limit_" + url) }
    func veriTuketimi(_ url: String) -> Int { ayar.integer(forKey: "data_usage_" + url) }

    func veriSinirlariniAyarla(_ url: String, sinir: Int) {
        ayar.set(sinir, forKey: "data_limit_" + url)
        ayar.set(false, forKey: "limit_reached_" + url)
        degisim += 1
    }

    func veriyiSifirla(_ url: String) {
        ayar.set(0, forKey: "data_usage_" + url)
        ayar.set(false, forKey: "limit_reached_" + url)
        degisim += 1
    }

    // MARK: Kullanıcı işlemleri

    func favoriDegistir(_ k: Kayit) {
        guard let i = kayitlar.firstIndex(where: { $0.no == k.no }) else {
            // Ek radyo (radio-browser): Android'deki gibi favorilere alınınca kendi listemize eklenir.
            sonNo += 1
            kayitlar.append(Kayit(no: sonNo, ad: k.ad, url: k.url, favori: !k.favori))
            favoriSirasiniGuncelle(sonNo, favori: !k.favori)
            kaydet()
            return
        }
        kayitlar[i].favori.toggle()
        favoriSirasiniGuncelle(kayitlar[i].no, favori: kayitlar[i].favori)
        kaydet()
    }

    /// Favoriler, kullanıcının belirlediği sırayla. Sırası olmayanlar sona gelir.
    var favoriler: [Kayit] {
        let yer = Dictionary(favoriSirasi.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { a, _ in a })
        return kayitlar.filter { $0.favori }.enumerated()
            .sorted { (yer[$0.element.no] ?? Int.max, $0.offset) < (yer[$1.element.no] ?? Int.max, $1.offset) }
            .map { $0.element }
    }

    /// Yeni favori sona eklenir, çıkarılan sıradan silinir.
    private func favoriSirasiniGuncelle(_ no: Int, favori: Bool) {
        favoriSirasi = favoriler.map { $0.no }.filter { $0 != no } + (favori ? [no] : [])
        ayar.set(favoriSirasi, forKey: "favori_sirasi")
    }

    /// Favoriyi taşır, yeni sırasını (1'den başlar) döner. Taşınamıyorsa nil.
    func favoriTasi(_ k: Kayit, _ yon: FavoriYon) -> Int? {
        var sira = favoriler.map { $0.no }
        guard let i = sira.firstIndex(of: k.no) else { return nil }
        let hedef: Int
        switch yon {
        case .yukari: hedef = max(i - 1, 0)
        case .asagi: hedef = min(i + 1, sira.count - 1)
        case .enBasa: hedef = 0
        case .enSona: hedef = sira.count - 1
        }
        guard hedef != i else { return nil }
        sira.insert(sira.remove(at: i), at: hedef)
        favoriSirasi = sira
        ayar.set(sira, forKey: "favori_sirasi")
        degisim += 1
        return hedef + 1
    }

    func sil(_ k: Kayit) {
        guard let i = kayitlar.firstIndex(where: { $0.no == k.no }) else {
            silinenApi.insert(k.url)
            silinenApiKaydet()
            kaydet()
            return
        }
        if let kaynak = kayitlar[i].kaynak { silinenler.insert(kaynak) }
        kayitlar.remove(at: i)
        kaydet()
    }

    func duzenle(_ k: Kayit, ad: String, url: String, kategori kat: String) {
        guard let i = kayitlar.firstIndex(where: { $0.no == k.no }) else {
            // Ek radyo düzenlendi: kendi listemize eklenir, eskisi bir daha gösterilmez (Android ile aynı).
            sonNo += 1
            kayitlar.append(Kayit(no: sonNo, ad: ad, url: url, favori: k.favori))
            silinenApi.insert(k.url)
            silinenApiKaydet()
            kategoriAyarla(url, kat)
            kaydet()
            return
        }
        // Düzenlenen kayıt artık kullanıcınındır; liste güncellemeleri üzerine yazmaz.
        if let kaynak = kayitlar[i].kaynak { silinenler.insert(kaynak) }
        kayitlar[i].kaynak = nil
        kayitlar[i].ad = ad
        kayitlar[i].url = url
        kategoriAyarla(url, kat)
        kaydet()
    }

    func ekle(ad: String, url: String, kategori kat: String) {
        sonNo += 1
        kayitlar.append(Kayit(no: sonNo, ad: ad, url: url))
        if kat != OTOMATIK_KATEGORI { kategoriAyarla(url, kat) }
        kaydet()
    }

    // MARK: Ayarlar işlemleri (Android showRestoreDefaultListWarning, showDeleteAllWarning, importPlaylist, exportJson, importJson)

    /// "Varsayılan Radyo Listesini Yükle": her şey silinir, liste ilk günkü haline döner.
    func varsayilaniYukle() {
        kayitlar = []
        silinenler = []
        silinenApi = []
        ayar.removeObject(forKey: "deleted_api_urls")
        ayar.set(false, forKey: "user_deleted_all")
        esitle()
        // Liste daha önce hiç indirilmediyse internetten gelir.
        Task { await internettenGuncelle() }
    }

    /// "Tüm Listeyi Temizle": listeden gelen hiçbir kayıt geri gelmez.
    func tumunuSil() {
        // Liste kapalıyken sadece görünen kayıtlar silinir, gizlenenler açılınca geri gelir.
        if listeKapali {
            kayitlar = []
            kaydet()
            return
        }
        // İndirilmiş liste olmasa da eldeki kayıtlar sonradan geri gelmesin.
        kayitlar.compactMap { $0.kaynak }.forEach { silinenler.insert($0) }
        kayitlar = []
        for t in Tur.allCases { guncelListe(t).forEach { silinenler.insert($0.id) } }
        silinenApi = []
        ayar.removeObject(forKey: "deleted_api_urls")
        ayar.set(true, forKey: "user_deleted_all")
        kaydet()
    }

    /// M3U veya PLS dosyasındaki yayınları ekler, eklenen sayısını döner.
    func listeIceAktar(_ metin: String) -> Int {
        let satirlar = metin.components(separatedBy: .newlines)
        var eklenen = 0
        if satirlar.contains(where: { $0.range(of: "[playlist]", options: .caseInsensitive) != nil }) {
            var adresler: [(String, String)] = []
            var basliklar: [String: String] = [:]
            for satir in satirlar {
                let t = satir.trimmingCharacters(in: .whitespaces)
                guard let esittir = t.firstIndex(of: "=") else { continue }
                let sol = String(t[..<esittir])
                let sag = String(t[t.index(after: esittir)...]).trimmingCharacters(in: .whitespaces)
                let anahtar = sol.filter(\.isNumber)
                if sol.lowercased().hasPrefix("file") {
                    adresler.append((anahtar, sag))
                } else if sol.lowercased().hasPrefix("title") {
                    basliklar[anahtar] = sag
                }
            }
            for (anahtar, url) in adresler where url.lowercased().hasPrefix("http") {
                sonNo += 1
                kayitlar.append(Kayit(no: sonNo, ad: basliklar[anahtar] ?? "Bilinmeyen Radyo", url: url))
                eklenen += 1
            }
        } else {
            var ad = "Bilinmeyen Radyo"
            for satir in satirlar {
                let t = satir.trimmingCharacters(in: .whitespaces)
                if t.uppercased().hasPrefix("#EXTINF") {
                    let sonra = t.contains("\"") ? String(t[t.range(of: "\"", options: .backwards)!.upperBound...]) : t
                    let a = sonra.firstIndex(of: ",").map { String(sonra[sonra.index(after: $0)...]).trimmingCharacters(in: .whitespaces) } ?? ""
                    ad = a.isEmpty ? "Bilinmeyen Radyo" : a
                } else if t.lowercased().hasPrefix("http") {
                    sonNo += 1
                    kayitlar.append(Kayit(no: sonNo, ad: ad, url: t))
                    eklenen += 1
                    ad = "Bilinmeyen Radyo"
                }
            }
        }
        kaydet()
        return eklenen
    }

    /// "Tümünü Yedekle": Android'deki yedek dosyasıyla aynı biçim ([{"name","url"}]).
    func yedekVerisi() -> Data {
        let dizi = kayitlar.map { ["name": $0.ad, "url": $0.url] }
        return (try? JSONSerialization.data(withJSONObject: dizi, options: [.prettyPrinted])) ?? Data("[]".utf8)
    }

    /// "Geri Yükle": yedekteki yayınları ekler, eklenen sayısını döner. Dosya okunamazsa nil.
    func yedektenYukle(_ veri: Data) -> Int? {
        guard let dizi = try? JSONSerialization.jsonObject(with: veri) as? [[String: Any]] else { return nil }
        var eklenen = 0
        for o in dizi {
            let ad = o["name"] as? String ?? "Bilinmeyen Radyo"
            let url = o["url"] as? String ?? ""
            if url.hasPrefix("http") {
                sonNo += 1
                kayitlar.append(Kayit(no: sonNo, ad: ad, url: url))
                eklenen += 1
            }
        }
        kaydet()
        return eklenen
    }

    // MARK: Ek radyolar (Android fetchRadioBrowserApi)

    /// Tüm Radyolar sekmesinin kaynağı: kendi listemiz + listede olmayan ve silinmemiş ek radyolar.
    var birlesikListe: [Kayit] {
        let adresler = Set(kayitlar.map(\.url))
        return kayitlar + apiKayitlar.filter { !adresler.contains($0.url) && !silinenApi.contains($0.url) }
    }

    /// Asistanın aradığı liste (Android getAllRadios: adrese göre tekil).
    var asistanListesi: [Kayit] {
        var gorulen = Set<String>()
        return (kayitlar + apiKayitlar).filter { gorulen.insert($0.url).inserted }
    }

    private func silinenApiKaydet() {
        if let v = try? JSONSerialization.data(withJSONObject: Array(silinenApi)) {
            ayar.set(String(decoding: v, as: UTF8.self), forKey: "deleted_api_urls")
        }
    }

    func radioBrowserAl() async {
        guard !listeKapali, let url = URL(string: "https://de1.api.radio-browser.info/json/stations/search?countrycode=TR&hidebroken=true&lastcheckok=1&order=clickcount&reverse=true&limit=500") else { return }
        var istek = URLRequest(url: url)
        istek.setValue("ReklamsizRadyo/3.0", forHTTPHeaderField: "User-Agent")
        istek.timeoutInterval = 20
        guard let (veri, cevap) = try? await URLSession.shared.data(for: istek),
              (cevap as? HTTPURLResponse)?.statusCode == 200,
              let dizi = try? JSONSerialization.jsonObject(with: veri) as? [[String: Any]] else { return }
        var yeni: [Kayit] = []
        var kategoriler: [String: String] = [:]
        for (i, o) in dizi.enumerated() {
            let ad = (o["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let adres = o["url_resolved"] as? String ?? ""
            if adres.isEmpty { continue }
            let etiket = (o["tags"] as? String ?? "").lowercased()
            var kat = "Tümü"
            if etiket.contains("pop") && !etiket.contains("arabesk") { kat = "Pop" }
            else if etiket.contains("news") || etiket.contains("haber") || etiket.contains("information") { kat = "Haber" }
            else if etiket.contains("slow") || etiket.contains("romantic") || etiket.contains("love") { kat = "Slow" }
            else if etiket.contains("islam") || etiket.contains("dini") || etiket.contains("quran") || etiket.contains("religion") { kat = "Dini" }
            // Ek radyoların numarası eksi büyük sayılar: kendi listemizle ve kayıt dosyalarıyla karışmaz.
            yeni.append(Kayit(no: -100_000 - i, ad: ad, url: adres))
            if kat != "Tümü" { kategoriler[adres] = kat }
        }
        // İstek sürerken liste kapatılmış olabilir.
        guard !listeKapali else { return }
        apiKayitlar = yeni
        apiKategoriler = kategoriler
        degisim += 1
    }

    // MARK: Kategori süzgeci (Android getCategoryFilteredList)

    func filtrele(_ liste: [Kayit], kategori aktif: String) -> [Kayit] {
        if aktif == TV_KATEGORI { return liste.filter { tvMi($0) } }
        // TV kanalları sadece "TV Kanalları" kategorisinde görünür, "Tümü" listesinde yer almaz.
        if aktif == "Tümü" { return liste.filter { !tvMi($0) } }
        // Bu kategorilerde sadece kendi listemizdeki radyolar gösterilir (ek radyolar karışmasın).
        let kisitli = ["Oyun Havası", "Yerel", "Arabesk", "Spor"].contains(aktif)
        let adresler = Set(kayitlar.map(\.url))
        return liste.filter { k in
            if kisitli && !adresler.contains(k.url) { return false }
            if let kayitli = kategori(k.url), kayitli != OTOMATIK_KATEGORI { return kayitli == aktif }
            if let apiKat = apiKategoriler[k.url] { return apiKat == aktif }
            let ad = k.ad.lowercased()
            func icerir(_ kelimeler: [String]) -> Bool { kelimeler.contains { ad.contains($0) } }
            switch aktif {
            case "Pop": return icerir(["pop", "power", "fenomen", "pal", "number", "metro", "süper"])
            case "Arabesk": return icerir(["arabesk", "damar", "kral", "baba", "afşin", "müslüm"])
            case "Haber": return icerir(["haber", "trt", "ntv", "cnn", "radyo 1", "bloomberg"])
            case "Slow": return icerir(["slow", "joy", "aşk", "akustik", "romantik"])
            case "Spor": return icerir(["spor", "lig", "aspor", "fenerbahçe", "galatasaray", "beşiktaş"])
            case "Dini": return icerir(["dini", "diyanet", "kuran", "semerkand", "moral", "islam"])
            case "Oyun Havası": return ["ankara havaları", "radyo seymen", "radyo vizyon ankara", "s1lhouttel- ankara havaları"].contains(ad)
            case "Yerel":
                if icerir(["yerel", "yöresel", "bölge", "kent"]) { return true }
                let plaka = #"\b(radyo|fm|radyosu)\s?(0[1-9]|[1-7][0-9]|8[0-1])\b|\b(0[1-9]|[1-7][0-9]|8[0-1])\s?(radyo|fm|radyosu)\b"#
                return ad.range(of: plaka, options: .regularExpression) != nil
            default: return true
            }
        }
    }

    // MARK: Kayıtlar sekmesi (kaydedilen dosyalar)

    nonisolated static var kayitKlasoru: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Reklamsiz Radyo")
    }

    func kayitDosyalari() -> [Kayit] {
        let fm = FileManager.default
        guard let dosyalar = try? fm.contentsOfDirectory(at: Self.kayitKlasoru, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        let sesler = dosyalar.filter { ["m4a", "mp3", "wav"].contains($0.pathExtension.lowercased()) }
        let tarih: (URL) -> Date = { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        return sesler.sorted { tarih($0) > tarih($1) }.enumerated().map { i, u in
            Kayit(no: -(i + 1), ad: u.lastPathComponent, url: u.path)
        }
    }

    // MARK: Eşitleme

    private var klasor: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    private func onbellek(_ t: Tur) -> URL { klasor.appendingPathComponent("uzak_" + t.dosya) }

    /// En son internetten indirilen liste. Uygulamanın içinde gömülü liste yoktur.
    private func guncelListe(_ t: Tur) -> [ListeGirdisi] {
        guard let m = try? String(contentsOf: onbellek(t), encoding: .utf8) else { return [] }
        return M3U.oku(m)
    }

    /// Radyo ya da TV listesi henüz hiç indirilemediyse true.
    var listeEksik: Bool {
        Tur.allCases.contains { !FileManager.default.fileExists(atPath: onbellek($0).path) }
    }

    private func esitle() {
        guard !listeKapali else { return }
        for t in Tur.allCases {
            let girdiler = guncelListe(t)
            if girdiler.isEmpty { continue }
            let uzakKimlikler = Set(girdiler.map(\.id))
            for g in girdiler {
                if silinenler.contains(g.id) { continue }
                if let i = kayitlar.firstIndex(where: { $0.kaynak == g.id }) {
                    if kayitlar[i].url != g.url || kayitlar[i].ad != g.ad {
                        adresAyarlariniTasi(kayitlar[i].url, g.url)
                        kayitlar[i].ad = g.ad
                        kayitlar[i].url = g.url // favori durumu korunur
                    }
                    if t == .tv { ayar.set(TV_KATEGORI, forKey: "cat_" + g.url) }
                    continue
                }
                // Ad ve link birebir aynı, sahibi olmayan kayıt varsa sahiplen (aynı türden olmak şartıyla).
                if let i = kayitlar.firstIndex(where: {
                    $0.kaynak == nil && $0.url == g.url && $0.ad == g.ad && (kategori($0.url) == TV_KATEGORI) == (t == .tv)
                }) {
                    kayitlar[i].kaynak = g.id
                    continue
                }
                sonNo += 1
                kayitlar.append(Kayit(no: sonNo, ad: g.ad, url: g.url, kaynak: g.id))
                if t == .tv { ayar.set(TV_KATEGORI, forKey: "cat_" + g.url) }
            }
            // Listeden kaldırılmış kayıtları uygulamadan da kaldır (sadece listeden gelenler).
            kayitlar.removeAll { k in
                guard let kaynak = k.kaynak, kaynak.hasPrefix(t.onek), !uzakKimlikler.contains(kaynak) else { return false }
                if t == .tv { ayar.removeObject(forKey: "cat_" + k.url) }
                return true
            }
        }
        kaydet()
    }

    /// Liste bu cihaza daha önce gelmiş mi. Gelmediyse yeni kurulumdur.
    private var cihazdaListeVar: Bool {
        kayitlar.contains { $0.kaynak != nil } || Tur.allCases.contains {
            FileManager.default.fileExists(atPath: onbellek($0).path)
        }
    }

    /// Liste kapatıldı: herkeste bütün kayıtlar gizlenir. Hiçbir şey silinmez, indirilen listeler de durur.
    private func listeyiKapat() {
        guard !listeKapali else { return }
        listeKapali = true
        ayar.set(true, forKey: "liste_kapali")
        gizliKayitlar = kayitlar
        kayitlar = []
        apiKayitlar = []
        apiKategoriler = [:]
        kaydet()
    }

    /// Liste açıldı: gizlenen kayıtlar aynen geri gelir, kapalıyken eklenenler sona geçer.
    private func listeyiAc() {
        listeKapali = false
        ayar.removeObject(forKey: "liste_kapali")
        kayitlar = gizliKayitlar + kayitlar
        gizliKayitlar = []
        esitle()
        Task { await radioBrowserAl() }
    }

    /// Bir yayının linki değişince linke bağlı ayarları (kategori, veri sayacı, sınır) yeni linke taşır.
    private func adresAyarlariniTasi(_ eski: String, _ yeni: String) {
        guard eski != yeni else { return }
        for onek in ["cat_", "data_usage_", "data_limit_", "limit_reached_"] {
            if let deger = ayar.object(forKey: onek + eski) {
                ayar.set(deger, forKey: onek + yeni)
                ayar.removeObject(forKey: onek + eski)
            }
        }
    }

    /// surum.json'a bakar; sürümü değişen ya da henüz indirilmemiş listeyi indirir, doğrular ve saklar.
    func internettenGuncelle() async {
        guard !guncelleniyor else { return }
        guncelleniyor = true
        listeIndiriliyor = true
        defer {
            guncelleniyor = false
            listeIndiriliyor = false
        }
        var surumler: [String: Any]?
        switch await indir("surum.json") {
        case .metin(let s):
            surumler = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any]
        case .yok:
            listeyiKapat()
            return
        case .hata:
            break
        }
        // surum.json okunamadıysa durum bilinmiyor: hiçbir şey değişmez, liste indirilmez.
        guard let surumler = surumler else { return }
        // surum.json'daki "ios_aktif": false listeyi bu uygulamada herkes için kapatır.
        // Test derlemesi buna bakmaz, listenin durumunu ayarlardaki test seçeneğinden alır.
        let kapatilsin = testDerlemesi ? ayar.bool(forKey: "test_liste_kapali") : (surumler["ios_aktif"] as? Bool) == false
        if kapatilsin {
            listeyiKapat()
            return
        }
        var bosListeler = 0
        var degisti = false
        for t in Tur.allCases {
            let onbellekVar = FileManager.default.fileExists(atPath: onbellek(t).path)
            let uzak = (surumler[t.anahtar] as? Int) ?? 0
            let uygulanan = ayar.integer(forKey: "ver_" + t.anahtar)
            if uzak <= uygulanan && onbellekVar { continue }
            let metin: String
            switch await indir(t.dosya) {
            case .metin(let m):
                metin = m
            case .yok:
                bosListeler += 1
                continue
            case .hata:
                continue
            }
            let girdiler = M3U.oku(metin)
            if girdiler.isEmpty {
                bosListeler += 1
                continue
            }
            let simdiki = guncelListe(t).count
            // Bozuk/yarım dosyaya karşı: çok az kayıt gelirse ya da kimlikler tekrarlıysa kabul etme.
            if girdiler.count < 10 || girdiler.count < simdiki / 2 || Set(girdiler.map(\.id)).count != girdiler.count { continue }
            try? FileManager.default.createDirectory(at: klasor, withIntermediateDirectories: true)
            if (try? metin.write(to: onbellek(t), atomically: true, encoding: .utf8)) != nil {
                ayar.set(uzak, forKey: "ver_" + t.anahtar)
                degisti = true
            }
        }
        // İki liste de kaldırılmış ya da boşaltılmışsa liste kapatılmış sayılır.
        if bosListeler == Tur.allCases.count {
            listeyiKapat()
            return
        }
        if listeKapali {
            listeyiAc()
        } else if degisti {
            esitle()
        }
    }

    private func indir(_ yol: String) async -> Indirme {
        var hepsi404 = true
        for taban in tabanlar {
            guard let url = URL(string: taban + yol) else { continue }
            var istek = URLRequest(url: url)
            istek.cachePolicy = .reloadIgnoringLocalCacheData
            istek.timeoutInterval = 10
            let kod: Int?
            if let (veri, cevap) = try? await URLSession.shared.data(for: istek) {
                kod = (cevap as? HTTPURLResponse)?.statusCode
                if kod == 200 { return .metin(String(decoding: veri, as: UTF8.self)) }
            } else {
                kod = nil
            }
            if kod != 404 { hepsi404 = false }
        }
        return hepsi404 ? .yok : .hata
    }

    // MARK: Saklama

    private var depoDosyasi: URL { klasor.appendingPathComponent("kayitlar.json") }

    private func yukle() {
        guard let veri = try? Data(contentsOf: depoDosyasi),
              let k = try? JSONDecoder().decode(Kayitli.self, from: veri) else { return }
        kayitlar = k.kayitlar
        gizliKayitlar = k.gizli ?? []
        silinenler = Set(k.silinenler)
        sonNo = k.sonNo
    }

    private func kaydet() {
        try? FileManager.default.createDirectory(at: klasor, withIntermediateDirectories: true)
        let k = Kayitli(kayitlar: kayitlar, silinenler: Array(silinenler), sonNo: sonNo, gizli: gizliKayitlar)
        if let veri = try? JSONEncoder().encode(k) { try? veri.write(to: depoDosyasi, options: .atomic) }
        degisim += 1
    }
}

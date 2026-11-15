import AppIntents

/// Siri ve Kestirmeler için kanal listesi: kullanıcının listesindeki radyo istasyonları ve TV kanalları.
/// `sadeceTV`: true yalnızca TV kanalları, nil hepsi.
@MainActor private func siriListesi(sadeceTV: Bool?) -> [(Kayit, Bool)] {
    let d = Depo.paylasilan
    return d.asistanListesi.map { ($0, d.tvMi($0)) }.filter { sadeceTV == nil || $0.1 == sadeceTV }
}

/// Söylenen ada uyan kanallar (sesli asistanla aynı eşleştirme).
@MainActor private func siriBul(_ ad: String, sadeceTV: Bool?) -> [(Kayit, Bool)] {
    let d = Depo.paylasilan
    let kayitlar = siriListesi(sadeceTV: sadeceTV).map { $0.0 }
    let temiz = SiriMedya.adiTemizle(ad)
    if temiz.isEmpty { return [] }
    var bulunan = KanalBulucu.kesinBul(temiz, kayitlar, tvMi: { d.tvMi($0) }, tvKategorisiAcik: sadeceTV == true)
    if bulunan.isEmpty {
        let aranan = KanalBulucu.normalize(temiz)
        if !aranan.isEmpty { bulunan = kayitlar.filter { KanalBulucu.normalize($0.ad).contains(aranan) } }
    }
    return bulunan.prefix(10).map { ($0, d.tvMi($0)) }
}

/// Kestirmeler'deki listede kaç kanal ve kaç TV kanalı verildiği test kaydına yazılır.
@MainActor private func oneriKaydi(_ l: [(Kayit, Bool)], _ ne: String) {
    OlcumKaydi.shared.yaz("siri öneri (\(ne)): \(l.count) kanal, \(l.filter { $0.1 }.count) TV")
}

// MARK: Bütün kanallar

struct SiriKanali: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Kanal")
    static var defaultQuery = SiriKanalSorgusu()

    /// Yayının adresi (listedeki kaydı bulmak için).
    let id: String
    let ad: String
    let tv: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(ad)", subtitle: tv ? "TV kanalı" : "Radyo")
    }
}

struct SiriKanalSorgusu: EntityStringQuery {
    private static func donustur(_ l: [(Kayit, Bool)]) -> [SiriKanali] {
        l.map { SiriKanali(id: $0.0.url, ad: $0.0.ad, tv: $0.1) }
    }

    func entities(for identifiers: [SiriKanali.ID]) async throws -> [SiriKanali] {
        let l = await siriListesi(sadeceTV: nil)
        return Self.donustur(l).filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [SiriKanali] {
        Self.donustur(await siriBul(string, sadeceTV: nil))
    }

    func suggestedEntities() async throws -> [SiriKanali] {
        let l = await siriListesi(sadeceTV: nil)
        await oneriKaydi(l, "hepsi")
        return Self.donustur(l)
    }
}

/// "Reklamsız Radyo'da TRT 1 aç": uygulamayı açar ve kanalı sesli asistanla aynı yoldan çalar.
struct KanalAcIntent: AppIntent {
    static var title: LocalizedStringResource = "Kanal Aç"
    static var description = IntentDescription("Listenizdeki bir radyo istasyonunu veya TV kanalını açar.")
    static var openAppWhenRun = true

    @Parameter(title: "Kanal", requestValueDialog: "Hangi radyoyu veya kanalı açayım?")
    var kanal: SiriKanali

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let k = Depo.paylasilan.asistanListesi.first(where: { $0.url == kanal.id }) else {
            return .result(dialog: "\(kanal.ad) listenizde bulunamadı.")
        }
        OlcumKaydi.shared.yaz("siri: \(k.ad) açılıyor")
        SesliAsistan.shared.istek = .cal(k)
        return .result(dialog: "\(k.ad) açılıyor.")
    }
}

// MARK: Yalnızca TV kanalları

struct SiriTVKanali: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "TV Kanalı")
    static var defaultQuery = SiriTVSorgusu()

    let id: String
    let ad: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(ad)") }
}

struct SiriTVSorgusu: EntityStringQuery {
    private static func donustur(_ l: [(Kayit, Bool)]) -> [SiriTVKanali] {
        l.map { SiriTVKanali(id: $0.0.url, ad: $0.0.ad) }
    }

    func entities(for identifiers: [SiriTVKanali.ID]) async throws -> [SiriTVKanali] {
        let l = await siriListesi(sadeceTV: true)
        return Self.donustur(l).filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [SiriTVKanali] {
        Self.donustur(await siriBul(string, sadeceTV: true))
    }

    func suggestedEntities() async throws -> [SiriTVKanali] {
        let l = await siriListesi(sadeceTV: true)
        await oneriKaydi(l, "TV")
        return Self.donustur(l)
    }
}

struct TVKanaliAcIntent: AppIntent {
    static var title: LocalizedStringResource = "TV Kanalı Aç"
    static var description = IntentDescription("Listenizdeki bir TV kanalını açar.")
    static var openAppWhenRun = true

    @Parameter(title: "TV Kanalı", requestValueDialog: "Hangi TV kanalını açayım?")
    var kanal: SiriTVKanali

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let k = Depo.paylasilan.asistanListesi.first(where: { $0.url == kanal.id }) else {
            return .result(dialog: "\(kanal.ad) listenizde bulunamadı.")
        }
        OlcumKaydi.shared.yaz("siri: \(k.ad) açılıyor (TV)")
        SesliAsistan.shared.istek = .cal(k)
        return .result(dialog: "\(k.ad) açılıyor.")
    }
}

// MARK: Siri cümleleri

/// Siri'ye ayrıca bir şey kurmadan söylenebilen cümleler. Apple, cümlede uygulama adının geçmesini şart koşar.
struct ReklamsizRadyoKisayollari: AppShortcutsProvider {
    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: KanalAcIntent(), phrases: [
            "\(.applicationName)'da \(\.$kanal) aç",
            "\(.applicationName) ile \(\.$kanal) aç",
            "\(.applicationName) uygulamasında \(\.$kanal) aç",
            "\(.applicationName) \(\.$kanal) aç",
            "\(.applicationName)'da \(\.$kanal) çal",
            "\(.applicationName)'da kanal aç",
            "\(.applicationName)'da radyo aç",
        ])
        AppShortcut(intent: TVKanaliAcIntent(), phrases: [
            "\(.applicationName)'da TV kanalı aç",
            "\(.applicationName)'da televizyon aç",
            "\(.applicationName)'da \(\.$kanal) kanalını aç",
        ])
    }
}

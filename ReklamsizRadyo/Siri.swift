import AppIntents

/// Siri ve Kestirmeler uygulaması için kanal: kullanıcının listesindeki radyo istasyonu ya da TV kanalı.
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

/// Siri, söylenen kanal adını kullanıcının kendi listesinden bulur (sesli asistanla aynı eşleştirme).
struct SiriKanalSorgusu: EntityStringQuery {
    @MainActor private static func liste() -> [SiriKanali] {
        let d = Depo.paylasilan
        return d.asistanListesi.map { SiriKanali(id: $0.url, ad: $0.ad, tv: d.tvMi($0)) }
    }

    func entities(for identifiers: [SiriKanali.ID]) async throws -> [SiriKanali] {
        let l = await Self.liste()
        return l.filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [SiriKanali] {
        await MainActor.run {
            let d = Depo.paylasilan
            let kayitlar = d.asistanListesi
            var bulunan = KanalBulucu.kesinBul(string, kayitlar, tvMi: { d.tvMi($0) }, tvKategorisiAcik: false)
            if bulunan.isEmpty {
                let aranan = KanalBulucu.normalize(string)
                if !aranan.isEmpty {
                    bulunan = kayitlar.filter { KanalBulucu.normalize($0.ad).contains(aranan) }
                }
            }
            return bulunan.prefix(10).map { SiriKanali(id: $0.url, ad: $0.ad, tv: d.tvMi($0)) }
        }
    }

    func suggestedEntities() async throws -> [SiriKanali] {
        await Self.liste()
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
        let d = Depo.paylasilan
        guard let k = d.asistanListesi.first(where: { $0.url == kanal.id }) else {
            return .result(dialog: "\(kanal.ad) listenizde bulunamadı.")
        }
        OlcumKaydi.shared.yaz("siri: \(k.ad) açılıyor")
        SesliAsistan.shared.istek = .cal(k)
        return .result(dialog: "\(k.ad) açılıyor.")
    }
}

/// Siri'ye ayrıca bir şey kurmadan söylenebilen cümleler. Apple, cümlede uygulama adının geçmesini şart koşar.
struct ReklamsizRadyoKisayollari: AppShortcutsProvider {
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
    }
}

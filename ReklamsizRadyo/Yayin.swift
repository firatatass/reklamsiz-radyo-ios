import Foundation

/// Listedeki bir radyo ya da TV kanalı.
struct Yayin: Identifiable, Hashable {
    let id: String
    let ad: String
    let grup: String
    let url: String
    let logo: String?
    let tvMi: Bool
}

/// Android sürümüyle aynı M3U listelerini okur.
enum M3UOkuyucu {
    static func oku(_ metin: String, tv: Bool) -> [Yayin] {
        var sonuc: [Yayin] = []
        var bekleyen: (id: String?, ad: String, grup: String, logo: String?)?
        for hamSatir in metin.components(separatedBy: .newlines) {
            let satir = hamSatir.trimmingCharacters(in: .whitespaces)
            if satir.hasPrefix("#EXTINF") {
                bekleyen = (ozellik("tvg-id", satir), ad(satir),
                            ozellik("group-title", satir) ?? (tv ? "TV" : "RADYO"),
                            ozellik("tvg-logo", satir))
            } else if !satir.isEmpty, !satir.hasPrefix("#"), let b = bekleyen {
                sonuc.append(Yayin(id: b.id ?? satir, ad: b.ad, grup: b.grup, url: satir, logo: b.logo, tvMi: tv))
                bekleyen = nil
            }
        }
        return sonuc
    }

    /// Ad, son özelliğin kapanış tırnağından sonraki ilk virgülden başlar ("TV8,5" gibi adlar bölünmesin diye).
    private static func ad(_ satir: String) -> String {
        let bas = satir.range(of: "\"", options: .backwards)?.upperBound ?? satir.startIndex
        guard let virgul = satir[bas...].firstIndex(of: ",") else { return "" }
        return String(satir[satir.index(after: virgul)...]).trimmingCharacters(in: .whitespaces)
    }

    private static func ozellik(_ ad: String, _ satir: String) -> String? {
        guard let r = satir.range(of: ad + "=\"") else { return nil }
        let kalan = satir[r.upperBound...]
        guard let son = kalan.firstIndex(of: "\"") else { return nil }
        let deger = String(kalan[..<son])
        return deger.isEmpty ? nil : deger
    }
}

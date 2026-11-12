import Foundation

/// Yalnızca geliştiricinin test derlemesinde çalışır: yayın açılırken olan her adımı saatiyle kaydeder.
/// Kayıt telefonda kalır; Ayarlar'daki test satırlarıyla kopyalanır, paylaşılır veya silinir.
/// Mağaza ve dış test derlemelerinde hiçbir şey yazmaz.
final class OlcumKaydi: @unchecked Sendable {
    static let shared = OlcumKaydi()

    private let kuyruk = DispatchQueue(label: "reklamsizradyo.olcumkaydi")
    private var satirlar: [String] = []
    private let enFazla = 3000
    private let bicim: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// Paylaşmak için kaydın tutulduğu dosya.
    var dosya: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OlcumKaydi.txt")
    }

    private init() {
        guard testAyariVar else { return }
        if let eski = try? String(contentsOf: dosya, encoding: .utf8) {
            satirlar = eski.components(separatedBy: "\n").filter { !$0.isEmpty }
        }
    }

    func yaz(_ olay: String) {
        guard testAyariVar else { return }
        let an = Date()
        kuyruk.async {
            self.satirlar.append("\(self.bicim.string(from: an)) \(olay)")
            if self.satirlar.count > self.enFazla { self.satirlar.removeFirst(self.satirlar.count - self.enFazla) }
            try? (self.satirlar.joined(separator: "\n") + "\n").write(to: self.dosya, atomically: true, encoding: .utf8)
        }
    }

    var metin: String {
        kuyruk.sync { satirlar.joined(separator: "\n") }
    }

    var satirSayisi: Int {
        kuyruk.sync { satirlar.count }
    }

    func sil() {
        kuyruk.sync {
            satirlar = []
            try? FileManager.default.removeItem(at: dosya)
        }
    }
}

/// Kayıtta adresin yalnızca sunucu ve dosya adı görünür (uzun tokenlar okunmayı zorlaştırmasın).
func kisaAdres(_ u: URL?) -> String {
    guard let u else { return "-" }
    if u.isFileURL { return "dosya" }
    return "\(u.host ?? "")/…/\(u.lastPathComponent)"
}

func gecenSure(_ baslangic: Date) -> String {
    String(format: "%.2f sn", Date().timeIntervalSince(baslangic))
}

import Foundation

/// Radyo ve TV listelerini internetten alır, son alınanı telefonda saklar.
@MainActor
final class ListeDeposu: ObservableObject {
    @Published var radyolar: [Yayin] = []
    @Published var tvler: [Yayin] = []
    @Published var yukleniyor = false
    @Published var hata: String?

    private let taban = "https://cdn.jsdelivr.net/gh/firatatass/reklamsiz-radyo-liste@main/"

    init() {
        onbellektenYukle()
        Task { await yenile() }
    }

    func yenile() async {
        yukleniyor = true
        defer { yukleniyor = false }
        do {
            async let r = indir("radyo.m3u")
            async let t = indir("tv.m3u")
            let (radyoMetni, tvMetni) = try await (r, t)
            let yeniRadyolar = M3UOkuyucu.oku(radyoMetni, tv: false)
            let yeniTvler = M3UOkuyucu.oku(tvMetni, tv: true)
            guard !yeniRadyolar.isEmpty else { throw URLError(.cannotParseResponse) }
            radyolar = yeniRadyolar
            tvler = yeniTvler
            hata = nil
            kaydet(radyoMetni, "radyo.m3u")
            kaydet(tvMetni, "tv.m3u")
        } catch {
            if radyolar.isEmpty {
                hata = "Liste yüklenemedi. İnternet bağlantınızı kontrol edin."
            }
        }
    }

    private func indir(_ ad: String) async throws -> String {
        var istek = URLRequest(url: URL(string: taban + ad)!)
        istek.cachePolicy = .reloadIgnoringLocalCacheData
        istek.timeoutInterval = 20
        let (veri, _) = try await URLSession.shared.data(for: istek)
        return String(decoding: veri, as: UTF8.self)
    }

    private var klasor: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    private func kaydet(_ metin: String, _ ad: String) {
        try? FileManager.default.createDirectory(at: klasor, withIntermediateDirectories: true)
        try? metin.write(to: klasor.appendingPathComponent(ad), atomically: true, encoding: .utf8)
    }

    private func onbellektenYukle() {
        if let m = try? String(contentsOf: klasor.appendingPathComponent("radyo.m3u"), encoding: .utf8) {
            radyolar = M3UOkuyucu.oku(m, tv: false)
        }
        if let m = try? String(contentsOf: klasor.appendingPathComponent("tv.m3u"), encoding: .utf8) {
            tvler = M3UOkuyucu.oku(m, tv: true)
        }
    }
}

import AVFoundation
import MediaPlayer

/// Yayını çalar; arka planda, kilit ekranında ve kulaklık tuşlarıyla çalışır.
@MainActor
final class Oynatici: ObservableObject {
    enum Durum: Equatable {
        case durdu, baglaniyor, caliyor, duraklatildi
        case hata(String)
    }

    @Published private(set) var calan: Yayin?
    @Published private(set) var durum: Durum = .durdu

    private var player: AVPlayer?
    private var gozlemciler: [NSKeyValueObservation] = []

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        uzaktanKomutlariKur()
    }

    var caliyorMu: Bool { durum == .caliyor || durum == .baglaniyor }

    func cal(_ yayin: Yayin) {
        temizle()
        calan = yayin
        durum = .baglaniyor
        try? AVAudioSession.sharedInstance().setActive(true)
        guard let url = URL(string: Self.calinabilirAdres(yayin.url)) else {
            durum = .hata("Yayın adresi geçersiz.")
            return
        }
        let asset = AVURLAsset(url: url, options: [AVURLAssetHTTPUserAgentKey: Self.kimlik(url)])
        let oge = AVPlayerItem(asset: asset)
        let p = AVPlayer(playerItem: oge)
        p.automaticallyWaitsToMinimizeStalling = true
        gozlemciler = [
            oge.observe(\.status) { [weak self] o, _ in
                Task { @MainActor in self?.ogeDurumu(o) }
            },
            p.observe(\.timeControlStatus) { [weak self] pl, _ in
                Task { @MainActor in self?.calmaDurumu(pl) }
            },
        ]
        player = p
        p.play()
        bilgiyiGuncelle()
    }

    func oynatDuraklat() {
        guard let p = player, let yayin = calan else { return }
        if caliyorMu {
            p.pause()
            durum = .duraklatildi
        } else if case .hata = durum {
            cal(yayin)
            return
        } else {
            // Canlı yayında duraklatıp devam edince en güncel yere dönülür.
            cal(yayin)
            return
        }
        bilgiyiGuncelle()
    }

    func durdur() {
        temizle()
        calan = nil
        durum = .durdu
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func temizle() {
        gozlemciler.forEach { $0.invalidate() }
        gozlemciler = []
        player?.pause()
        player = nil
    }

    private func ogeDurumu(_ oge: AVPlayerItem) {
        if oge.status == .failed {
            durum = .hata("Yayın açılamadı.")
            bilgiyiGuncelle()
        }
    }

    private func calmaDurumu(_ p: AVPlayer) {
        guard durum != .duraklatildi else { return }
        if case .hata = durum { return }
        switch p.timeControlStatus {
        case .playing: durum = .caliyor
        case .waitingToPlayAtSpecifiedRate: durum = .baglaniyor
        default: break
        }
        bilgiyiGuncelle()
    }

    private func bilgiyiGuncelle() {
        guard let yayin = calan else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: yayin.ad,
            MPMediaItemPropertyArtist: yayin.tvMi ? "TV" : "Radyo",
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: durum == .caliyor ? 1.0 : 0.0,
        ]
    }

    private func uzaktanKomutlariKur() {
        let m = MPRemoteCommandCenter.shared()
        m.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            if !self.caliyorMu { self.oynatDuraklat() }
            return .success
        }
        m.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            if self.caliyorMu { self.oynatDuraklat() }
            return .success
        }
        m.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.oynatDuraklat()
            return .success
        }
        m.stopCommand.addTarget { [weak self] _ in
            self?.durdur()
            return .success
        }
    }

    /// Android'deki gibi: "adres:port" ile biten Shoutcast yayınlarının sonuna "/;" eklenir.
    static func calinabilirAdres(_ adres: String) -> String {
        if adres.range(of: "^https?://[^/:]+:[0-9]+/?$", options: [.regularExpression, .caseInsensitive]) != nil {
            return adres + (adres.hasSuffix("/") ? ";" : "/;")
        }
        return adres
    }

    /// streamtheworld sunucuları tarayıcı kimliğiyle gelen bağlantıyı birkaç saniye sonra kesiyor (Süper FM sorunu).
    static func kimlik(_ url: URL) -> String {
        if (url.host ?? "").lowercased().hasSuffix("streamtheworld.com") {
            return "Mozilla/5.0 (iPhone) ReklamsizRadyo/1.0"
        }
        return "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    }
}

import AVFoundation
import Combine
import MediaPlayer

/// Veri sınırı dolunca gösterilen uyarı (Android RADIO_LIMIT_REACHED).
struct LimitUyarisi: Identifiable {
    let url: String
    let sinirMB: Int
    let guncelMB: Int
    var id: String { url }
}

/// Yayını ve kayıt dosyalarını çalar (Android RadioService karşılığı).
/// Arka planda, kilit ekranında ve kulaklık tuşlarıyla çalışır.
@MainActor
final class Oynatici: NSObject, ObservableObject, AVPlayerItemMetadataOutputPushDelegate {
    @Published private(set) var calan: Kayit?
    /// Android'deki isPlaying: kullanıcı çalmayı istedi mi (bağlanırken de true).
    @Published private(set) var caliyor = false
    /// Radyonun gönderdiği yazı (şarkı adı vb.), Android'deki activeMetadata.
    @Published private(set) var bilgi = ""
    /// Önceki/Sonraki için, çalmanın başlatıldığı listenin kopyası (Android playingRadioList).
    @Published private(set) var liste: [Kayit] = []
    @Published private(set) var konum: Double = 0
    @Published private(set) var sure: Double = 0
    @Published private(set) var veri = 0
    @Published private(set) var kayitYapiliyor = false
    @Published var limitUyarisi: LimitUyarisi?
    @Published private(set) var uykuAktif = false

    private var player: AVPlayer?
    private var kisik = false
    private var uykuGorevi: Task<Void, Never>?
    private var kayitAboneligi: AnyCancellable?
    private var gozlemciler: [NSKeyValueObservation] = []
    private var bildirimGozlemcisi: NSObjectProtocol?
    private var hataGozlemcisi: NSObjectProtocol?
    private var oturumGozlemcileri: [NSObjectProtocol] = []
    /// Yayın çalıyor görünüp kaç saniyedir ses gelmediği. Uzun sürerse yeniden bağlanılır.
    private var beklemeSayaci = 0
    /// Kısa pencereli canlı yayınlarda canlıya uzaklık ayarlandı mı (her bağlantıda bir kez).
    private var payAyarlandi = false
    private var zamanlayici: Timer?
    private var sonBayt: Int64 = 0
    private var yenidenDeneme = 0
    private let ayar = UserDefaults.standard

    /// Ayarlardaki yayın ses seviyesi. Sadece yayını etkiler, VoiceOver'ın sesi değişmez.
    private var sesCarpani: Float {
        Float(ayar.object(forKey: "yayin_ses_seviyesi") as? Int ?? 100) / 100
    }

    func sesiUygula() {
        player?.volume = sesCarpani * (kisik ? 0.25 : 1)
    }

    override init() {
        super.init()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        uzaktanKomutlariKur()
        oturumuDinle()
        kayitAboneligi = Kaydedici.shared.$kayitta.sink { [weak self] v in self?.kayitYapiliyor = v }
    }

    // MARK: Kayıt (Android START_RECORD / STOP_RECORD)

    func kaydiBaslat() {
        guard let k = calan, !k.dosyaMi else { return }
        Kaydedici.shared.baslat(url: k.url, ad: k.ad)
    }

    func kaydiDurdur() {
        Kaydedici.shared.durdur()
    }

    // MARK: Önceki / Sonraki

    private var sira: Int? {
        guard let c = calan else { return nil }
        return liste.firstIndex { $0.url.caseInsensitiveCompare(c.url) == .orderedSame && $0.ad.caseInsensitiveCompare(c.ad) == .orderedSame }
    }

    var oncekiVar: Bool { liste.count > 1 && (sira ?? 0) > 0 }
    var sonrakiVar: Bool { liste.count > 1 && sira.map { $0 < liste.count - 1 } == true }

    func onceki() { komsuyaGec(-1) }
    func sonraki() { komsuyaGec(1) }

    private func komsuyaGec(_ yon: Int) {
        guard liste.count > 1, let i = sira else { return }
        let yeni = i + yon
        guard yeni >= 0, yeni < liste.count else { return }
        cal(liste[yeni])
        UIAccessibility.post(notification: .announcement, argument: liste[yeni].ad)
    }

    // MARK: Çalma

    /// Listeden bir kayıt seçildi: çalmayı başlat ve o anki listeyi Önceki/Sonraki için sakla.
    func baslat(_ k: Kayit, liste yeniListe: [Kayit]) {
        liste = yeniListe
        cal(k)
    }

    private func cal(_ k: Kayit) {
        // Android'de de başka yayına geçince süren kayıt bitirilip kaydedilir.
        if Kaydedici.shared.kayitta { Kaydedici.shared.durdur() }
        temizle()
        calan = k
        bilgi = ""
        caliyor = true
        konum = 0
        sure = 0
        yenidenDeneme = 0
        veri = ayar.integer(forKey: "data_usage_" + k.url)
        oynaticiKur(k)
    }

    private func oynaticiKur(_ k: Kayit) {
        try? AVAudioSession.sharedInstance().setActive(true)
        let url: URL
        if k.dosyaMi {
            url = URL(fileURLWithPath: k.url)
        } else {
            guard let u = URL(string: Self.calinabilirAdres(k.url)) else {
                hata()
                return
            }
            url = u
        }
        let asset = AVURLAsset(url: url, options: [AVURLAssetHTTPUserAgentKey: Self.kimlik(url)])
        let oge = AVPlayerItem(asset: asset)
        if !k.dosyaMi {
            // Uygulama yalnızca ses çalar: görüntülü yayınlarda en düşük görüntü kalitesi seçilir.
            // Ses kalitesi değişmez; yayın daha hızlı açılır, daha az takılır ve daha az internet harcar.
            oge.preferredPeakBitRate = 900_000
            oge.preferredMaximumResolution = CGSize(width: 640, height: 360)
            // Takılmadan sonra geride kalmak yerine canlıya yetişir; çalınacak parça listeden silinip donmaz.
            oge.automaticallyPreservesTimeOffsetFromLive = true
        }
        let cikis = AVPlayerItemMetadataOutput(identifiers: nil)
        cikis.setDelegate(self, queue: .main)
        oge.add(cikis)
        let p = AVPlayer(playerItem: oge)
        p.automaticallyWaitsToMinimizeStalling = true
        p.volume = sesCarpani * (kisik ? 0.25 : 1)
        gozlemciler = [
            oge.observe(\.status) { [weak self] o, _ in
                Task { @MainActor in
                    if o.status == .failed { self?.yayinKoptu() }
                    // Görüntü ekranda gösterilmediği için çözülmez, yalnızca ses çalınır.
                    if o.status == .readyToPlay {
                        for t in o.tracks where t.assetTrack?.mediaType == .video { t.isEnabled = false }
                    }
                }
            },
        ]
        bildirimGozlemcisi = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: oge, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sonaGeldi() }
        }
        // Yayın yarıda hata verip durursa yeniden bağlanılır.
        hataGozlemcisi = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: oge, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.yayinKoptu() }
        }
        player = p
        sonBayt = 0
        beklemeSayaci = 0
        payAyarlandi = false
        p.play()
        zamanlayici = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tik() }
        }
        bilgiyiGuncelle()
    }

    func oynatDuraklat() {
        guard let k = calan else { return }
        if caliyor {
            player?.pause()
            caliyor = false
        } else if k.dosyaMi {
            player?.play()
            caliyor = true
        } else {
            // Canlı yayında devam edince en güncel yerden yeniden bağlanılır.
            let eski = konum
            temizle()
            caliyor = true
            yenidenDeneme = 0
            oynaticiKur(k)
            konum = eski
        }
        bilgiyiGuncelle()
    }

    func durdur() {
        if Kaydedici.shared.kayitta { Kaydedici.shared.durdur() }
        temizle()
        calan = nil
        caliyor = false
        bilgi = ""
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Sesli asistan açıkken yayının sesi kısılır (Android DUCK_VOLUME / RESTORE_VOLUME).
    func kis(_ evet: Bool) {
        kisik = evet
        sesiUygula()
    }

    // MARK: Uyku zamanlayıcı (iPhone'da uygulama kendini kapatamadığı için süre dolunca yayın durdurulur)

    func uykuKur(_ dakika: Int) {
        uykuGorevi?.cancel()
        uykuAktif = true
        uykuGorevi = Task {
            try? await Task.sleep(nanoseconds: UInt64(dakika) * 60 * 1_000_000_000)
            if Task.isCancelled { return }
            self.uykuAktif = false
            self.durdur()
        }
        Bildirim.shared.goster("\(dakika) dakika sonra yayın kapanacak")
    }

    @discardableResult
    func uykuyuIptalEt() -> Bool {
        guard uykuAktif else { return false }
        uykuGorevi?.cancel()
        uykuGorevi = nil
        uykuAktif = false
        Bildirim.shared.goster("Zamanlayıcı iptal edildi")
        return true
    }

    func atla(_ saniye: Double) {
        guard let p = player else { return }
        let hedef = max(0, min(sure > 0 ? sure : .greatestFiniteMagnitude, p.currentTime().seconds + saniye))
        konumaGit(hedef)
    }

    func konumaGit(_ saniye: Double) {
        player?.seek(to: CMTime(seconds: saniye, preferredTimescale: 600))
        konum = saniye
    }

    private func temizle() {
        zamanlayici?.invalidate()
        zamanlayici = nil
        gozlemciler.forEach { $0.invalidate() }
        gozlemciler = []
        ogeGozlemcileriniKaldir()
        player?.pause()
        player = nil
    }

    private func ogeGozlemcileriniKaldir() {
        if let g = bildirimGozlemcisi { NotificationCenter.default.removeObserver(g) }
        bildirimGozlemcisi = nil
        if let g = hataGozlemcisi { NotificationCenter.default.removeObserver(g) }
        hataGozlemcisi = nil
    }

    /// Telefon araması, Siri, sesli asistan, başka bir uygulamanın sesi veya kulaklık çıkarılması gibi
    /// durumlarda iPhone yayını durdurur. Önceden uygulama bunu fark etmiyor, yayın kapatıp açınca düzeliyordu.
    private func oturumuDinle() {
        let nc = NotificationCenter.default
        oturumGozlemcileri = [
            nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
                let tur = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                Task { @MainActor in self?.sesKesintisi(tur) }
            },
            nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
                let neden = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                Task { @MainActor in self?.sesYoluDegisti(neden) }
            },
            nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.sesServisiSifirlandi() }
            },
        ]
    }

    private func sesKesintisi(_ tur: UInt?) {
        guard let tur, AVAudioSession.InterruptionType(rawValue: tur) == .ended, caliyor, let k = calan else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        if k.dosyaMi {
            player?.play()
        } else {
            yenidenBaglan(k)
        }
    }

    /// Kulaklık çıkarılınca yayın hoparlörden devam etmesin diye durur (Apple'ın önerdiği davranış).
    private func sesYoluDegisti(_ neden: UInt?) {
        guard let neden, AVAudioSession.RouteChangeReason(rawValue: neden) == .oldDeviceUnavailable, caliyor else { return }
        player?.pause()
        caliyor = false
        bilgiyiGuncelle()
    }

    private func sesServisiSifirlandi() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        guard caliyor, let k = calan else { return }
        if k.dosyaMi {
            caliyor = false
            bilgiyiGuncelle()
        } else {
            yenidenBaglan(k)
        }
    }

    /// Canlı yayını baştan, en güncel yerinden yeniden açar.
    private func yenidenBaglan(_ k: Kayit) {
        temizleAmaKoru()
        yenidenDeneme = 0
        oynaticiKur(k)
    }

    private func hata() {
        caliyor = false
        Bildirim.shared.goster("Bağlantı hatası: Yayın açılamıyor")
        bilgiyiGuncelle()
    }

    /// Canlı yayın koptu ya da açılamadı: birkaç kez artan aralıklarla yeniden bağlan.
    private func yayinKoptu() {
        guard let k = calan, caliyor else { return }
        if !k.dosyaMi && yenidenDeneme < 5 {
            yenidenDeneme += 1
            let bekle = UInt64(1 << (yenidenDeneme - 1)) * 1_000_000_000
            temizleAmaKoru()
            Task {
                try? await Task.sleep(nanoseconds: bekle)
                if self.caliyor, self.calan?.url == k.url { self.oynaticiKur(k) }
            }
        } else {
            temizleAmaKoru()
            hata()
        }
    }

    private func temizleAmaKoru() {
        zamanlayici?.invalidate()
        zamanlayici = nil
        gozlemciler.forEach { $0.invalidate() }
        gozlemciler = []
        ogeGozlemcileriniKaldir()
        player?.pause()
        player = nil
    }

    private func sonaGeldi() {
        guard let k = calan else { return }
        if k.dosyaMi {
            caliyor = false
            bilgiyiGuncelle()
        } else {
            yayinKoptu()
        }
    }

    // MARK: Her saniye: konum ve internet tüketimi

    private func tik() {
        guard let p = player, let k = calan else { return }
        if k.dosyaMi {
            konum = p.currentTime().seconds
            let s = p.currentItem?.duration.seconds ?? 0
            if s.isFinite { sure = s }
            return
        }
        if !payAyarlandi { canliPayiAyarla() }
        if p.timeControlStatus == .playing {
            yenidenDeneme = 0
            beklemeSayaci = 0
            payiKoru()
        } else if caliyor {
            // Yayın takıldı: önce canlıya atla, 15 saniyede hâlâ ses yoksa baştan bağlan.
            beklemeSayaci += 1
            if beklemeSayaci == 4 { canliyaAtla() }
            if beklemeSayaci >= 15 {
                beklemeSayaci = 0
                yayinKoptu()
                return
            }
        }
        let bayt = p.currentItem?.accessLog()?.events.reduce(Int64(0)) { $0 + max(0, $1.numberOfBytesTransferred) } ?? 0
        let fark = bayt - sonBayt
        sonBayt = bayt
        guard fark > 0 else { return }
        let toplam = ayar.integer(forKey: "data_usage_" + k.url) + Int(fark)
        ayar.set(toplam, forKey: "data_usage_" + k.url)
        veri = toplam
        let sinir = ayar.integer(forKey: "data_limit_" + k.url)
        if sinir > 0 && toplam >= sinir * 1024 * 1024 && !ayar.bool(forKey: "limit_reached_" + k.url) {
            ayar.set(true, forKey: "limit_reached_" + k.url)
            player?.pause()
            caliyor = false
            bilgiyiGuncelle()
            limitUyarisi = LimitUyarisi(url: k.url, sinirMB: sinir, guncelMB: toplam / (1024 * 1024))
        }
    }

    // MARK: Kısa pencereli canlı yayınlar
    // Birçok yayın yalnızca son 9-24 saniyeyi tutuyor. Apple'ın oynatıcısı canlıdan fazla geride başlayınca
    // küçük bir yavaşlamada çalınacak parça silinmiş oluyor ve yayın donuyordu (Safari'de de aynısı oluyor).

    /// Canlı penceresi: oynatıcının geri sarılabildiği aralık. Dosyalarda ve düz radyo yayınlarında yok.
    private var canliPencere: CMTimeRange? {
        guard let o = player?.currentItem, o.duration.isIndefinite,
              let r = o.seekableTimeRanges.last?.timeRangeValue, r.duration.seconds.isFinite, r.duration.seconds > 0 else { return nil }
        return r
    }

    /// Canlıdan ne kadar geride çalınacağı: pencerenin yaklaşık yarısı, en az 2 en çok 10 saniye.
    private func canliPay(_ r: CMTimeRange) -> CMTime {
        CMTime(seconds: max(2, min(r.duration.seconds * 0.4, 10)), preferredTimescale: 600)
    }

    private func canliPayiAyarla() {
        guard let r = canliPencere, let o = player?.currentItem else { return }
        payAyarlandi = true
        guard r.duration.seconds < 60 else { return }
        let pay = canliPay(r)
        o.configuredTimeOffsetFromLive = pay
        player?.seek(to: CMTimeSubtract(r.end, pay))
    }

    /// Çalınan yer pencerenin başına çok yaklaştıysa, parça silinmeden canlıya yaklaş.
    private func payiKoru() {
        guard let p = player, let r = canliPencere, r.duration.seconds < 60 else { return }
        if CMTimeSubtract(p.currentTime(), r.start).seconds < 1 { canliyaAtla() }
    }

    private func canliyaAtla() {
        guard let p = player, let r = canliPencere else { return }
        p.seek(to: CMTimeSubtract(r.end, canliPay(r)))
        p.play()
    }

    /// "Sıfırla ve Devam Et"
    func sinirSifirlaDevam() {
        guard let k = calan else { return }
        ayar.set(0, forKey: "data_usage_" + k.url)
        ayar.set(false, forKey: "limit_reached_" + k.url)
        veri = 0
        if !caliyor { oynatDuraklat() }
    }

    func veriyiYenile() {
        if let k = calan { veri = ayar.integer(forKey: "data_usage_" + k.url) }
    }

    // MARK: Şarkı bilgisi (yayının gönderdiği yazı)

    nonisolated func metadataOutput(_ output: AVPlayerItemMetadataOutput,
                                    didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup],
                                    from track: AVPlayerItemTrack?) {
        let metin = groups.flatMap(\.items).compactMap { $0.stringValue }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        Task { @MainActor in self.bilgiGeldi(metin ?? "") }
    }

    private func bilgiGeldi(_ m: String) {
        guard let k = calan else { return }
        let temiz = m.lowercased().contains("http") || m.caseInsensitiveCompare(k.ad) == .orderedSame ? "" : m
        if temiz != bilgi {
            bilgi = temiz
            bilgiyiGuncelle()
        }
    }

    // MARK: Kilit ekranı ve kulaklık

    private func bilgiyiGuncelle() {
        guard let k = calan else { return }
        var b: [String: Any] = [
            MPMediaItemPropertyTitle: bilgi.isEmpty ? k.ad : bilgi,
            MPMediaItemPropertyArtist: k.ad,
            MPNowPlayingInfoPropertyIsLiveStream: !k.dosyaMi,
            MPNowPlayingInfoPropertyPlaybackRate: caliyor ? 1.0 : 0.0,
        ]
        if k.dosyaMi {
            b[MPMediaItemPropertyPlaybackDuration] = sure
            b[MPNowPlayingInfoPropertyElapsedPlaybackTime] = konum
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = b
    }

    private func uzaktanKomutlariKur() {
        let m = MPRemoteCommandCenter.shared()
        m.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            if !self.caliyor { self.oynatDuraklat() }
            return .success
        }
        m.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            if self.caliyor { self.oynatDuraklat() }
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
        m.nextTrackCommand.addTarget { [weak self] _ in
            self?.sonraki()
            return .success
        }
        m.previousTrackCommand.addTarget { [weak self] _ in
            self?.onceki()
            return .success
        }
    }

    /// Android'deki gibi: "adres:port" ile biten Shoutcast yayınlarının sonuna "/;" eklenir.
    nonisolated static func calinabilirAdres(_ adres: String) -> String {
        if adres.range(of: "^https?://[^/:]+:[0-9]+/?$", options: [.regularExpression, .caseInsensitive]) != nil {
            return adres + (adres.hasSuffix("/") ? ";" : "/;")
        }
        return adres
    }

    /// streamtheworld sunucuları tarayıcı kimliğiyle gelen bağlantıyı birkaç saniye sonra kesiyor (Süper FM sorunu).
    nonisolated static func kimlik(_ url: URL) -> String {
        if (url.host ?? "").lowercased().hasSuffix("streamtheworld.com") {
            return "Mozilla/5.0 (iPhone) ReklamsizRadyo/1.0"
        }
        return "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    }
}

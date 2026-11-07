import SwiftUI
import UniformTypeIdentifiers

/// Ana ekran (Android MainActivity): üst çubuk, arama, kategoriler, sekmeler, liste ve alttaki küçük oynatıcı.
struct AnaEkran: View {
    @EnvironmentObject private var depo: Depo
    @EnvironmentObject private var oynatici: Oynatici
    @EnvironmentObject private var bildirim: Bildirim
    @EnvironmentObject private var asistan: SesliAsistan

    @AppStorage("last_tab") private var sekme = "home"
    @AppStorage("last_category") private var kategori = "Tümü"
    @AppStorage("tab_order_index") private var sekmeSiraNo = 0
    @AppStorage("tv_data_warning_ignored") private var tvUyarisiGizli = false

    @State private var arama = ""
    @State private var oynaticiAcik = false
    @State private var duzenlenen: Kayit?
    @State private var eklemeAcik = false
    @State private var listeUyarisiAcik = false
    @State private var listeSecici = false
    @State private var listeUyarisiGosterildi = false
    @State private var silinecek: Kayit?
    @State private var tvUyarisiIcin: Kayit?
    @State private var tvUyarisiSonrasi: Kayit?
    @State private var limitDoluIcin: Kayit?
    @State private var paylasilacak: PaylasilacakDosya?
    @State private var kayitDosyalari: [Kayit] = []
    @State private var kaydirHedefi: Int?
    /// Asistan penceresi kapanırken gelen istek, pencere tamamen kapandıktan sonra yapılır
    /// (iPhone/iPad bir pencere kapanırken başka pencere açamıyor).
    /// İlk kurulumda bir kez gösterilen teşekkür yazısı; "Kapat"a basılınca bir daha gösterilmez.
    @AppStorage("tesekkur_bilgisi_gosterildi") private var gelistiriciBilgisiGosterildi = false
    @State private var gelistiriciBilgisiAcik = false
    @State private var ayarlarAcik = false
    @State private var hakkindaAcik = false
    @Environment(\.openURL) private var adresAc
    @State private var asistanGorunur = false
    @State private var oynaticiGorunur = false
    @State private var bekleyenIstek: AsistanIstegi?
    @AccessibilityFocusState private var odak: Int?

    private var sekmeSirasi: [String] {
        switch sekmeSiraNo {
        case 1: return ["home", "rec", "fav"]
        case 2: return ["fav", "home", "rec"]
        case 3: return ["fav", "rec", "home"]
        case 4: return ["rec", "home", "fav"]
        case 5: return ["rec", "fav", "home"]
        default: return ["home", "fav", "rec"]
        }
    }

    private func sekmeAdi(_ s: String) -> String {
        switch s {
        case "fav": return "Favoriler"
        case "rec": return "Kayıtlar"
        default: return "Tüm Radyolar"
        }
    }

    private var gorunen: [Kayit] {
        _ = depo.degisim
        let temel: [Kayit]
        switch sekme {
        case "fav": temel = depo.kayitlar.filter(\.favori)
        case "rec": temel = kayitDosyalari
        default: temel = depo.filtrele(depo.birlesikListe, kategori: kategori)
        }
        let a = arama.trimmingCharacters(in: .whitespaces)
        return a.isEmpty ? temel : temel.filter { $0.ad.localizedCaseInsensitiveContains(a) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ustCubuk
            TextField("Radyo ara", text: $arama)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .padding(.horizontal)
                .padding(.vertical, 6)
            // Android'de de sekmeler kod içinde arama kutusunun hemen altına, kategoriler onların altına taşınıyor.
            sekmeCubugu
            if sekme == "home" { kategoriCubugu }
            liste
            if oynatici.calan != nil { kucukOynatici }
        }
        .overlay(alignment: .bottom) {
            if let m = bildirim.metin {
                Text(m)
                    .padding(12)
                    .background(.black.opacity(0.8))
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.bottom, 90)
                    .accessibilityHidden(true)
            }
        }
        .onAppear {
            if sekme == "rec" { kayitDosyalari = depo.kayitDosyalari() }
            listeUyarisiniGoster()
            if !gelistiriciBilgisiGosterildi {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { gelistiriciBilgisiAcik = true }
            }
        }
        .alert("Uygulamanın geliştirilmesindeki katkılarından dolayı Ahmet Yılmaz'a teşekkür ederiz.", isPresented: $gelistiriciBilgisiAcik) {
            Button("Kapat", role: .cancel) { gelistiriciBilgisiGosterildi = true }
        }
        .alert("Radyo Listesi Boş", isPresented: $listeUyarisiAcik) {
            Button("Link Ekle") { sonra { eklemeAcik = true } }
            Button("Liste Ekle") { sonra { listeSecici = true } }
            Button("Kapat", role: .cancel) {}
        } message: {
            Text("Uygulamada hazır radyo listesi bulunmuyor. Dinlemek istediğiniz radyonun linkini ya da kendi M3U veya PLS listenizi ekleyebilirsiniz.")
        }
        .fileImporter(isPresented: $listeSecici, allowedContentTypes: [.item]) { listeDosyasiSecildi($0) }
        .onChange(of: depo.listeKapali) { kapali in
            // Liste kapanınca çalan yayın da durur. Kaydedilmiş dosya dinleniyorsa dokunulmaz.
            if kapali, let k = oynatici.calan, !k.dosyaMi {
                oynaticiAcik = false
                oynatici.durdur()
            }
        }
        .onChange(of: listeUyarisiZamani) { zamani in
            if zamani { listeUyarisiniGoster() }
        }
        .onChange(of: gelistiriciBilgisiGosterildi) { _ in
            // Teşekkür yazısı açıkken ikinci uyarı açılamaz; o kapandıktan sonra gösterilir.
            sonra { listeUyarisiniGoster() }
        }
        .onChange(of: oynatici.kayitYapiliyor) { _ in
            // Kayıt bitince Kayıtlar sekmesi açıksa yeni dosya görünsün (dönüştürme birkaç saniye sürebilir).
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { if sekme == "rec" { kayitDosyalari = depo.kayitDosyalari() } }
        }
        .fullScreenCover(isPresented: $oynaticiAcik, onDismiss: {
            oynaticiGorunur = false
            odagiGeriVer()
        }) {
            OynaticiEkrani().environmentObject(depo).environmentObject(oynatici).environmentObject(bildirim)
                .onAppear { oynaticiGorunur = true }
        }
        .fullScreenCover(item: $duzenlenen) { k in
            DuzenleEkrani(kayit: k).environmentObject(depo).environmentObject(oynatici).environmentObject(bildirim)
        }
        .sheet(isPresented: $eklemeAcik) {
            EkleEkrani().environmentObject(depo).environmentObject(bildirim)
        }
        .sheet(item: $tvUyarisiIcin, onDismiss: {
            if let k = tvUyarisiSonrasi {
                tvUyarisiSonrasi = nil
                baslat(k)
            }
        }) { k in
            TvUyarisi { tvUyarisiSonrasi = k }
        }
        .sheet(item: $paylasilacak) { d in PaylasPenceresi(ogeler: [d.url]) }
        .sheet(isPresented: $ayarlarAcik) {
            AyarlarEkrani().environmentObject(depo).environmentObject(oynatici).environmentObject(bildirim)
        }
        .alert("Hakkında", isPresented: $hakkindaAcik) {
            Button("E-posta Gönder") {
                let konu = "Reklamsız Radyo Hakkında Görüş/Öneri".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                if let u = URL(string: "mailto:tknljderslblrlk@gmail.com?subject=\(konu)") {
                    adresAc(u) { basarili in if !basarili { bildirim.goster("E-posta uygulaması bulunamadı!") } }
                }
            }
            Button("Kapat", role: .cancel) {}
        } message: {
            let surum = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
            Text("Reklamsız Radyo v\(surum)\nGeliştirici: Fırat Ataş\n\nGörüş ve önerileriniz için iletişime geçebilirsiniz.\n\nMP3 kayıtları LAME kodlayıcısıyla yapılır (GNU LGPL lisansı, lame.sourceforge.io). Uygulamanın kaynak kodu: github.com/firatatass/reklamsiz-radyo-ios")
        }
        .sheet(isPresented: Binding(get: { asistan.acik && !oynaticiAcik }, set: { if !$0 && asistan.acik { asistan.kapat() } }),
               onDismiss: {
            asistanGorunur = false
            if let i = bekleyenIstek {
                bekleyenIstek = nil
                asistanIstegi(i)
            }
        }) {
            AsistanPenceresi(asistan: asistan)
                .onAppear { asistanGorunur = true }
        }
        .onChange(of: asistan.istek) { i in
            guard let i else { return }
            asistan.istek = nil
            if asistanGorunur {
                bekleyenIstek = i
            } else {
                asistanIstegi(i)
            }
        }
        .alert(silinecek.map { "\($0.ad) silinsin mi?" } ?? "", isPresented: Binding(
            get: { silinecek != nil }, set: { if !$0 { silinecek = nil } }), presenting: silinecek) { k in
            Button("Evet", role: .destructive) { sil(k) }
            Button("İptal", role: .cancel) {}
        }
        .alert("Veri Sınırı Dolu!", isPresented: Binding(
            get: { limitDoluIcin != nil }, set: { if !$0 { limitDoluIcin = nil } }), presenting: limitDoluIcin) { k in
            Button("Sıfırla ve Aç") {
                depo.veriyiSifirla(k.url)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { tvKontroluIleBaslat(k) }
            }
            Button("İptal", role: .cancel) {}
        } message: { k in
            Text("Bu yayın için belirlediğiniz \(depo.veriSiniri(k.url)) MB sınırı daha önceden dolmuş durumda.\n\nYayını açabilmek için veri tüketimini sıfırlamak ister misiniz?")
        }
        .alert("Veri Sınırına Ulaşıldı", isPresented: Binding(
            get: { oynatici.limitUyarisi != nil && !oynaticiAcik },
            set: { if !$0 { oynatici.limitUyarisi = nil } }), presenting: oynatici.limitUyarisi) { _ in
            Button("Sıfırla ve Devam Et") { oynatici.sinirSifirlaDevam(); depo.veriyiSifirla(oynatici.calan?.url ?? "") }
            Button("Kapat", role: .cancel) {}
        } message: { u in
            Text("Bu istasyon için belirlediğiniz \(u.sinirMB) MB sınırına ulaştınız (Güncel Tüketim: \(u.guncelMB) MB).\n\nKotanızı korumak için yayın (ve varsa kayıt) otomatik olarak durduruldu.\n\nSıfırlayıp devam etmek ister misiniz?")
        }
    }

    // MARK: Üst çubuk

    private var ustCubuk: some View {
        HStack(spacing: 12) {
            Text("Reklamsız Radyo")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button { asistan.pencereyiAc() } label: {
                Image(systemName: "mic.fill").font(.title2)
            }
            .accessibilityLabel("Sesli Asistan")
            Menu {
                Button("Ekle") { eklemeAcik = true }
                Button("Ayarlar") { ayarlarAcik = true }
                Button("Hakkında") { hakkindaAcik = true }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title2)
            }
            .accessibilityLabel("Diğer Seçenekler")
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    // MARK: Kategoriler

    private var kategoriCubugu: some View {
        ScrollViewReader { kaydirici in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(KATEGORI_DUGMELERI, id: \.self) { k in
                        let secili = k == kategori
                        Button {
                            kategori = k
                            arama = ""
                            bildirim.goster("\(k) kategorisi seçildi")
                        } label: {
                            Text(k)
                                .font(.system(size: 15, weight: secili ? .bold : .regular))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(secili ? lacivert : Color.clear)
                                .foregroundColor(secili ? .white : .secondary)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(secili ? "\(k) seçili" : k)
                        .id(k)
                    }
                }
                .padding(.horizontal)
            }
            .onAppear { kaydirici.scrollTo(kategori, anchor: .center) }
        }
        .padding(.vertical, 4)
    }

    // MARK: Sekmeler

    private var sekmeCubugu: some View {
        HStack(spacing: 4) {
            ForEach(sekmeSirasi, id: \.self) { s in
                let secili = s == sekme
                Button {
                    sekme = s
                    arama = ""
                    if s == "rec" { kayitDosyalari = depo.kayitDosyalari() }
                } label: {
                    Text(sekmeAdi(s))
                        .font(.system(size: 14, weight: secili ? .bold : .regular))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(secili ? lacivert : Color(.systemGray5))
                        .foregroundColor(secili ? .white : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(secili ? "\(sekmeAdi(s)) seçili" : sekmeAdi(s))
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
    }

    // MARK: Hazır liste kapalıyken

    private var listeUyarisiGerekli: Bool { depo.listeKapali && depo.kayitlar.isEmpty }

    /// Uyarı GitHub'dan cevap beklenirken açılmaz: liste açıksa boş yere çıkmasın.
    private var listeUyarisiZamani: Bool { listeUyarisiGerekli && !depo.listeIndiriliyor }

    /// Uygulama her açılışında en fazla bir kez gösterilir, öne her gelişte tekrar çıkmaz.
    private func listeUyarisiniGoster() {
        guard listeUyarisiZamani && gelistiriciBilgisiGosterildi && !listeUyarisiGosterildi else { return }
        listeUyarisiGosterildi = true
        listeUyarisiAcik = true
    }

    /// Uyarı kapanırken başka pencere açılamadığı için kısa bir süre sonra çalışır.
    private func sonra(_ eylem: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: eylem)
    }

    private func listeDosyasiSecildi(_ sonuc: Result<URL, Error>) {
        guard case .success(let url) = sonuc else { return }
        let erisim = url.startAccessingSecurityScopedResource()
        defer { if erisim { url.stopAccessingSecurityScopedResource() } }
        guard let veri = try? Data(contentsOf: url) else {
            bildirim.goster("Dosya okuma hatası!")
            return
        }
        let sayi = depo.listeIceAktar(String(decoding: veri, as: UTF8.self))
        bildirim.goster("\(sayi) radyo listeye eklendi!")
    }

    // MARK: Liste

    @ViewBuilder private var liste: some View {
        let ogeler = gorunen
        if ogeler.isEmpty {
            Spacer()
            if sekme != "rec" && sekme != "fav" && listeUyarisiGerekli {
                Text("Radyo Listesi Boş. Dinlemek İstediğiniz Radyonun Linkini ya da Kendi Listenizi Ekleyin.")
                    .font(.title3)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button("Link Ekle") { eklemeAcik = true }
                    .font(.title3)
                    .frame(minHeight: 44)
                Button("Liste Ekle") { listeSecici = true }
                    .font(.title3)
                    .frame(minHeight: 44)
            } else if sekme != "rec" && sekme != "fav" && depo.listeEksik && !depo.listeKapali {
                Text(depo.listeIndiriliyor ? "Liste İndiriliyor" : "Liste İndirilemedi. İnternet Bağlantınızı Kontrol Edin.")
                    .font(.title3)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                if !depo.listeIndiriliyor {
                    Button("Yeniden Dene") { Task { await depo.internettenGuncelle() } }
                        .font(.title3)
                        .frame(minHeight: 44)
                }
            } else {
                Text(sekme == "rec" ? "Kayıt Bulunamadı" : sekme == "fav" ? "Favori Radyo Bulunamadı" : "Radyo Bulunamadı")
                    .font(.title3)
                    .foregroundColor(.secondary)
            }
            Spacer()
        } else {
            ScrollViewReader { kaydirici in
                List(ogeler) { k in satir(k) }
                    .listStyle(.plain)
                    .refreshable { await depo.internettenGuncelle() }
                    .onChange(of: kaydirHedefi) { h in
                        if let h { kaydirici.scrollTo(h, anchor: .center) }
                    }
            }
        }
    }

    private func satir(_ k: Kayit) -> some View {
        let calanMi = oynatici.calan?.url == k.url
        return HStack(spacing: 8) {
            Button { tikla(k) } label: {
                Text(k.ad)
                    .font(.system(size: 19, weight: .bold))
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityFocused($odak, equals: k.no)
            .accessibilityActions {
                if sekme == "rec" {
                    Button("Paylaş") { paylasilacak = PaylasilacakDosya(url: URL(fileURLWithPath: k.url)) }
                    Button("Sil") { silinecek = k }
                } else {
                    Button(k.favori ? "Favorilerden Çıkar" : "Favorilere Ekle") { favori(k) }
                    Button("Düzenle") { duzenlenen = k }
                    Button("Sil") { silinecek = k }
                }
            }
            if sekme != "rec" {
                Button { favori(k) } label: {
                    Image(systemName: k.favori ? "star.fill" : "star")
                        .font(.title2)
                        .foregroundColor(Color(red: 0x21 / 255, green: 0x96 / 255, blue: 0xF3 / 255))
                        .frame(minWidth: 48, minHeight: 44)
                }
                .buttonStyle(.plain)
                // VoiceOver'da favori işlemi satırın yukarı/aşağı kaydırma eylemlerinde; her radyo tek öğe olur.
                .accessibilityHidden(true)
            }
        }
        .listRowBackground(calanMi ? Color(.systemGray4) : Color.clear)
        .id(k.no)
    }

    // MARK: Küçük oynatıcı

    private var kucukOynatici: some View {
        let k = oynatici.calan!
        let bilgi = oynatici.bilgi.isEmpty ? "" : " - " + oynatici.bilgi
        let kayit = oynatici.kayitYapiliyor ? " (Kayıtta)" : ""
        let metin = k.ad + bilgi + kayit
        return Button { oynaticiyiAc() } label: {
            Text(metin)
                .font(.headline)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                .padding(.horizontal)
                .background(lacivert)
                .foregroundColor(.white)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(metin + ", oynatıcı penceresini açmak için dokunun")
    }

    // MARK: İşlemler

    private func tikla(_ k: Kayit) {
        if sekme == "rec" {
            baslat(k)
            return
        }
        let sinir = depo.veriSiniri(k.url)
        if sinir > 0 && depo.veriTuketimi(k.url) >= sinir * 1024 * 1024 {
            limitDoluIcin = k
        } else {
            tvKontroluIleBaslat(k)
        }
    }

    private func tvKontroluIleBaslat(_ k: Kayit) {
        let tv = depo.tvMi(k) || (sekme == "home" && kategori == TV_KATEGORI)
        if tv && !tvUyarisiGizli {
            tvUyarisiIcin = k
        } else {
            baslat(k)
        }
    }

    private func baslat(_ k: Kayit) {
        oynatici.baslat(k, liste: gorunen)
        oynaticiyiAc()
    }

    /// Oynatıcı penceresini açar. Pencere açık sanılıp ekranda değilse (başka pencere kapanırken açılamadıysa) yeniden dener.
    private func oynaticiyiAc() {
        if oynaticiAcik && oynaticiGorunur { return }
        if oynaticiAcik {
            oynaticiAcik = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { oynaticiAcik = true }
        } else {
            oynaticiAcik = true
        }
    }

    private func favori(_ k: Kayit) {
        let olacak = !k.favori
        depo.favoriDegistir(k)
        bildirim.goster(olacak ? "Favorilere Eklendi" : "Favorilerden Çıkarıldı")
    }

    private func sil(_ k: Kayit) {
        if sekme == "rec" {
            if FileManager.default.fileExists(atPath: k.url) {
                try? FileManager.default.removeItem(atPath: k.url)
                bildirim.goster("Kayıt kalıcı olarak silindi.")
            } else {
                bildirim.goster("Dosya zaten silinmiş.")
            }
            kayitDosyalari = depo.kayitDosyalari()
        } else {
            depo.sil(k)
            bildirim.goster("Radyo silindi.")
        }
    }

    /// Sesli asistanın istediği işler (Android AssistantCallbacks).
    private func asistanIstegi(_ i: AsistanIstegi) {
        switch i {
        case .cal(let k):
            // Kanal ekranda görünen listedeyse doğrudan aç; değilse doğru listeye geç (TV ise TV Kanalları, radyo ise Tümü).
            if gorunen.contains(where: { $0.url == k.url }) {
                tikla(k)
            } else {
                kategori = depo.tvMi(k) ? TV_KATEGORI : "Tümü"
                sekme = "home"
                arama = ""
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { tikla(k) }
            }
        case .sekme(let s):
            sekme = s
            arama = ""
            if s == "rec" { kayitDosyalari = depo.kayitDosyalari() }
        case .kategori(let k):
            kategori = k
            sekme = "home"
            arama = ""
        case .durdurAnaEkran:
            oynatici.durdur()
            oynaticiAcik = false
            sekme = "home"
        }
    }

    /// Oynatıcı kapanınca, çalan kanala kaydır ve ekran okuyucuyu oraya getir (Android'deki gibi).
    private func odagiGeriVer() {
        guard let u = oynatici.calan?.url, let k = gorunen.first(where: { $0.url == u }) else { return }
        kaydirHedefi = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            kaydirHedefi = k.no
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { odak = k.no }
        }
    }
}

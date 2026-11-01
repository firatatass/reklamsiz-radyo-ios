import SwiftUI

/// Ana ekran (Android MainActivity): üst çubuk, arama, kategoriler, sekmeler, liste ve alttaki küçük oynatıcı.
struct AnaEkran: View {
    @EnvironmentObject private var depo: Depo
    @EnvironmentObject private var oynatici: Oynatici
    @EnvironmentObject private var bildirim: Bildirim

    @AppStorage("last_tab") private var sekme = "home"
    @AppStorage("last_category") private var kategori = "Tümü"
    @AppStorage("tab_order_index") private var sekmeSiraNo = 0
    @AppStorage("tv_data_warning_ignored") private var tvUyarisiGizli = false

    @State private var arama = ""
    @State private var oynaticiAcik = false
    @State private var duzenlenen: Kayit?
    @State private var eklemeAcik = false
    @State private var silinecek: Kayit?
    @State private var tvUyarisiIcin: Kayit?
    @State private var tvUyarisiSonrasi: Kayit?
    @State private var limitDoluIcin: Kayit?
    @State private var paylasilacak: PaylasilacakDosya?
    @State private var kayitDosyalari: [Kayit] = []
    @State private var kaydirHedefi: Int?
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
        default: temel = depo.filtrele(depo.kayitlar, kategori: kategori)
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
            if sekme == "home" { kategoriCubugu }
            sekmeCubugu
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
        .onAppear { if sekme == "rec" { kayitDosyalari = depo.kayitDosyalari() } }
        .fullScreenCover(isPresented: $oynaticiAcik, onDismiss: odagiGeriVer) {
            OynaticiEkrani().environmentObject(depo).environmentObject(oynatici).environmentObject(bildirim)
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
            Button { bildirim.goster("Çalar saatler ve zamanlanmış görevler sonraki deneme sürümünde gelecek.") } label: {
                Image(systemName: "line.3.horizontal").font(.title2)
            }
            .accessibilityLabel("Menü")
            Text("Reklamsız Radyo")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button { bildirim.goster("Sesli asistan sonraki deneme sürümünde gelecek.") } label: {
                Image(systemName: "mic.fill").font(.title2)
            }
            .accessibilityLabel("Sesli Asistan")
            Menu {
                Button("Ekle") { eklemeAcik = true }
                Button("Ayarlar") { bildirim.goster("Ayarlar sonraki deneme sürümünde gelecek.") }
                Button("Hakkında") { bildirim.goster("Hakkında sonraki deneme sürümünde gelecek.") }
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

    // MARK: Liste

    @ViewBuilder private var liste: some View {
        let ogeler = gorunen
        if ogeler.isEmpty {
            Spacer()
            Text(sekme == "rec" ? "Kayıt Bulunamadı" : sekme == "fav" ? "Favori Radyo Bulunamadı" : "Radyo Bulunamadı")
                .font(.title3)
                .foregroundColor(.secondary)
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
                .accessibilityLabel(k.favori ? "Favorilerden Çıkar" : "Favorilere Ekle")
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
        return Button { oynaticiAcik = true } label: {
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
        oynaticiAcik = true
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

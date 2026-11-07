import SwiftUI

/// Oynatıcı penceresi (Android layout_player + showPlayerDialog).
/// Canlı yayında: Kaydet düğmesi görünür, konum çubuğu ve 10 sn düğmeleri gizlidir.
/// Kayıt dosyasında: konum çubuğu ve 10 sn geri/ileri görünür, Kaydet gizlidir.
struct OynaticiEkrani: View {
    @EnvironmentObject private var depo: Depo
    @EnvironmentObject private var oynatici: Oynatici
    @EnvironmentObject private var bildirim: Bildirim
    @ObservedObject private var asistan = SesliAsistan.shared
    @Environment(\.dismiss) private var kapat

    @State private var sinirAcik = false
    @State private var sinirMetni = ""
    @State private var surukleniyor = false
    @State private var surukKonumu: Double = 0

    /// Sadece VoiceOver'ın yukarı/aşağı kaydırma eylemlerinde görünür, ekranda hiçbir şeyi değiştirmez.
    @ViewBuilder private func favoriEylemi(_ k: Kayit) -> some View {
        if !k.dosyaMi {
            let guncel = depo.kayitlar.first { $0.url == k.url } ?? Kayit(no: k.no, ad: k.ad, url: k.url)
            Button(guncel.favori ? "Favorilerden Çıkar" : "Favorilere Ekle") {
                depo.favoriDegistir(guncel)
                bildirim.goster(guncel.favori ? "Favorilerden Çıkarıldı" : "Favorilere Eklendi")
            }
        }
    }

    var body: some View {
        ScrollView {
            if let k = oynatici.calan {
                VStack(spacing: 18) {
                    // Android'deki geri tuşunun karşılığı: pencereyi kapatır, yayın çalmaya devam eder.
                    // iPad klavyesinde Esc tuşu da aynı işi yapar.
                    HStack {
                        Button { kapat() } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left")
                                Text("Geri")
                            }
                            .font(.title3)
                            .frame(minHeight: 44)
                        }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityLabel("Geri")
                        Spacer()
                    }

                    Text(oynatici.bilgi.isEmpty ? k.ad : k.ad + "\n" + oynatici.bilgi)
                        .font(.title.bold())
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 10)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityActions { favoriEylemi(k) }

                    if k.dosyaMi { konumAlani }

                    HStack(spacing: 10) {
                        BuyukDugme(baslik: "Önceki", etkin: oynatici.oncekiVar) { oynatici.onceki() }
                        BuyukDugme(baslik: oynatici.caliyor ? "duraklat" : "oynat") { oynatici.oynatDuraklat() }
                            .accessibilityActions { favoriEylemi(k) }
                        BuyukDugme(baslik: "Sonraki", etkin: oynatici.sonrakiVar) { oynatici.sonraki() }
                    }

                    BuyukDugme(baslik: "Sesli Asistan") { asistan.pencereyiAc() }

                    if !k.dosyaMi {
                        BuyukDugme(baslik: oynatici.kayitYapiliyor ? "Kaydı Durdur" : "Kaydı Başlat") {
                            if oynatici.kayitYapiliyor { oynatici.kaydiDurdur() } else { oynatici.kaydiBaslat() }
                        }
                    }

                    // Kayıt dosyası internetten gelmediği için internet tüketimi ve sınır gösterilmez.
                    if !k.dosyaMi { veriAlani(k) }

                    BuyukDugme(baslik: "Kapat") {
                        oynatici.durdur()
                        kapat()
                    }
                    .padding(.top, 10)
                }
                .padding()
            }
        }
        // VoiceOver'da iki parmakla "Z" (geri) hareketi pencereyi kapatır, yayın çalmaya devam eder.
        .accessibilityAction(.escape) { kapat() }
        .onChange(of: oynatici.calan) { yeni in
            if yeni == nil { kapat() }
        }
        .onAppear { oynatici.veriyiYenile() }
        .sheet(isPresented: Binding(get: { asistan.acik }, set: { if !$0 && asistan.acik { asistan.kapat() } })) {
            AsistanPenceresi(asistan: asistan)
        }
        .alert("Veri Sınırı Belirle (MB)", isPresented: $sinirAcik) {
            TextField("Örn: 100 (MB cinsinden)", text: $sinirMetni)
                .keyboardType(.numberPad)
            Button("Kaydet") { siniriKaydet() }
            Button("İptal", role: .cancel) {}
        } message: {
            Text("Bu kanal için harcanacak maksimum MB değerini girin. Kotayı kaldırmak için 0 yazın veya boş bırakın.")
        }
        .alert("Veri Sınırına Ulaşıldı", isPresented: Binding(
            get: { oynatici.limitUyarisi != nil }, set: { if !$0 { oynatici.limitUyarisi = nil } }),
            presenting: oynatici.limitUyarisi) { _ in
            Button("Sıfırla ve Devam Et") { oynatici.sinirSifirlaDevam(); depo.veriyiSifirla(oynatici.calan?.url ?? "") }
            Button("Kapat", role: .cancel) {}
        } message: { u in
            Text("Bu istasyon için belirlediğiniz \(u.sinirMB) MB sınırına ulaştınız (Güncel Tüketim: \(u.guncelMB) MB).\n\nKotanızı korumak için yayın (ve varsa kayıt) otomatik olarak durduruldu.\n\nSıfırlayıp devam etmek ister misiniz?")
        }
    }

    // MARK: Kayıt dosyasında konum çubuğu ve 10 sn düğmeleri

    private var konumAlani: some View {
        VStack(spacing: 10) {
            let gosterilen = surukleniyor ? surukKonumu : oynatici.konum
            HStack {
                Text(zamanMetni(gosterilen)).accessibilityHidden(true)
                Slider(value: Binding(
                    get: { surukleniyor ? surukKonumu : oynatici.konum },
                    set: { surukKonumu = $0 }),
                       in: 0...max(oynatici.sure, 1),
                       onEditingChanged: { basladi in
                    if basladi {
                        surukKonumu = oynatici.konum
                        surukleniyor = true
                    } else {
                        surukleniyor = false
                        oynatici.konumaGit(surukKonumu)
                    }
                })
                .accessibilityLabel("Oynatma konumu")
                .accessibilityValue(zamanMetni(gosterilen))
                .accessibilityAdjustableAction { yon in
                    switch yon {
                    case .increment: oynatici.atla(10)
                    case .decrement: oynatici.atla(-10)
                    @unknown default: break
                    }
                }
                Text(zamanMetni(oynatici.sure)).accessibilityHidden(true)
            }
            HStack(spacing: 10) {
                BuyukDugme(baslik: "10 Sn Geri") { oynatici.atla(-10) }
                BuyukDugme(baslik: "10 Sn İleri") { oynatici.atla(10) }
            }
        }
    }

    // MARK: İnternet tüketimi

    private func veriAlani(_ k: Kayit) -> some View {
        _ = depo.degisim
        let sinir = depo.veriSiniri(k.url)
        let sinirMetin = sinir > 0 ? " / Sınır: \(sinir) MB" : ""
        let tuketim = veriMetni(oynatici.veri)
        return VStack(spacing: 10) {
            Text("İnternet Tüketimi: \(tuketim)\(sinirMetin)")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .accessibilityLabel("Toplam İnternet Tüketimi: \(tuketim). \(sinirMetin)")
            HStack(spacing: 10) {
                BuyukDugme(baslik: "Veriyi Sıfırla") {
                    depo.veriyiSifirla(k.url)
                    oynatici.veriyiYenile()
                    bildirim.goster("Veri sıfırlandı")
                }
                BuyukDugme(baslik: "Sınır Belirle") {
                    let s = depo.veriSiniri(k.url)
                    sinirMetni = s > 0 ? String(s) : ""
                    sinirAcik = true
                }
            }
        }
        .padding(.top, 20)
    }

    private func siniriKaydet() {
        guard let k = oynatici.calan else { return }
        let sinir = Int(sinirMetni.trimmingCharacters(in: .whitespaces)) ?? 0
        depo.veriSinirlariniAyarla(k.url, sinir: sinir)
        bildirim.goster(sinir > 0 ? "Sınır \(sinir) MB olarak ayarlandı!" : "Sınır kaldırıldı!")
    }
}

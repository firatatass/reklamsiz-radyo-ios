import SwiftUI

/// "Radyoyu Düzenle" (Android showEditDialog).
struct DuzenleEkrani: View {
    let kayit: Kayit
    @EnvironmentObject private var depo: Depo
    @EnvironmentObject private var bildirim: Bildirim
    @Environment(\.dismiss) private var kapat
    @State private var ad = ""
    @State private var url = ""
    @State private var kat = OTOMATIK_KATEGORI

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Radyo Adı", text: $ad)
                    TextField("Radyo URL'si", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("Kategori", selection: $kat) {
                        ForEach(KATEGORI_SECENEKLERI, id: \.self) { Text($0).tag($0) }
                    }
                }
                Section {
                    HStack(spacing: 12) {
                        BuyukDugme(baslik: "İptal") { kapat() }
                        BuyukDugme(baslik: "Kaydet") { kaydet() }
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Radyoyu Düzenle")
        }
        .onAppear {
            ad = kayit.ad
            url = kayit.url
            let k = depo.kategori(kayit.url) ?? OTOMATIK_KATEGORI
            kat = KATEGORI_SECENEKLERI.contains(k) ? k : OTOMATIK_KATEGORI
        }
    }

    private func kaydet() {
        let yeniAd = ad.trimmingCharacters(in: .whitespaces)
        let yeniUrl = url.trimmingCharacters(in: .whitespaces)
        guard !yeniAd.isEmpty, !yeniUrl.isEmpty else {
            bildirim.goster("Lütfen boş alan bırakmayın!")
            return
        }
        depo.duzenle(kayit, ad: yeniAd, url: yeniUrl, kategori: kat)
        bildirim.goster("Radyo güncellendi!")
        kapat()
    }
}

/// "Yeni Radyo Ekle" (Android showAddRadioDialog).
struct EkleEkrani: View {
    @EnvironmentObject private var depo: Depo
    @EnvironmentObject private var bildirim: Bildirim
    @Environment(\.dismiss) private var kapat
    @State private var ad = ""
    @State private var url = ""
    @State private var kat = OTOMATIK_KATEGORI

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Radyo Adı", text: $ad)
                    TextField("Radyo URL'si (m3u8, pls, mp3 vs.)", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("Kategori Seçimi:", selection: $kat) {
                        ForEach(KATEGORI_SECENEKLERI, id: \.self) { Text($0).tag($0) }
                    }
                }
                Section {
                    HStack(spacing: 12) {
                        BuyukDugme(baslik: "İptal") { kapat() }
                        BuyukDugme(baslik: "Kaydet") { kaydet() }
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Yeni Radyo Ekle")
        }
    }

    private func kaydet() {
        let yeniAd = ad.trimmingCharacters(in: .whitespaces)
        let yeniUrl = url.trimmingCharacters(in: .whitespaces)
        if yeniUrl.hasPrefix("http://") || yeniUrl.hasPrefix("https://") {
            depo.ekle(ad: yeniAd, url: yeniUrl, kategori: kat)
            bildirim.goster("Radyo başarıyla kaydedildi!")
            kapat()
        } else {
            bildirim.goster("Desteklenmeyen URL!")
        }
    }
}

/// TV kanalı açılırken veri uyarısı (Android showTvDataWarningDialog).
struct TvUyarisi: View {
    let anladim: () -> Void
    @Environment(\.dismiss) private var kapat
    @AppStorage("tv_data_warning_ignored") private var gizli = false
    @State private var birDahaGosterme = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Veri Tüketimi Uyarısı")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Text("TV kanalları (Ses Yayınları), radyo istasyonlarına göre çok daha fazla internet verisi tüketir. Wi-Fi kullanmıyorsanız mobil kotanızı hızlı tüketebileceğini lütfen unutmayın.")
            Toggle("Bir daha gösterme", isOn: $birDahaGosterme)
            HStack(spacing: 12) {
                BuyukDugme(baslik: "İptal") { kapat() }
                BuyukDugme(baslik: "Anladım") {
                    if birDahaGosterme { gizli = true }
                    anladim()
                    kapat()
                }
            }
            Spacer()
        }
        .padding(24)
        .presentationDetents([.medium, .large])
    }
}

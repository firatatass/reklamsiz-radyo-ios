import SwiftUI
import UniformTypeIdentifiers

/// "Ayarlar" (Android showSettings): seçenekler aynı sırada ve aynı adlarla.
struct AyarlarEkrani: View {
    @EnvironmentObject private var depo: Depo
    @EnvironmentObject private var oynatici: Oynatici
    @EnvironmentObject private var bildirim: Bildirim
    @ObservedObject private var asistan = SesliAsistan.shared
    @Environment(\.dismiss) private var kapat

    @AppStorage("shake_assistant_enabled") private var sallama = true
    @AppStorage("app_theme") private var tema = 2
    @AppStorage("record_format") private var kayitBicimi = "m4a"
    @AppStorage("tab_order_index") private var sekmeSiraNo = 0
    @AppStorage("tab_order_v2") private var sekmeSirasiV2 = true

    private enum AltPencere: Identifiable {
        case uyku, sekme, bicim, tema
        var id: Int { hashValue }
    }

    private enum DosyaIsi { case iceAktar, geriYukle }

    @State private var altPencere: AltPencere?
    @State private var rehberAcik = false
    @State private var dosyaSecici = false
    @State private var dosyaIsi = DosyaIsi.iceAktar
    @State private var yedekAcik = false
    @State private var varsayilanUyarisi = false
    @State private var temizlemeUyarisi = false

    var body: some View {
        NavigationStack {
            List {
                satir("Sesli Asistan Rehberi ve Komutlar") { rehberAcik = true }
                satir(sallama ? "Sallayarak Asistanı Aç: Açık" : "Sallayarak Asistanı Aç: Kapalı") {
                    sallama.toggle()
                    bildirim.goster(sallama ? "Telefonu sallayarak sesli asistanı açma aktif edildi." : "Sallama ile asistan açma kapatıldı.")
                }
                satir("Uyku Zamanlayıcı") { altPencere = .uyku }
                satir("Radyo Listesini İçe Aktar (M3U/PLS)") { dosyaIsi = .iceAktar; dosyaSecici = true }
                satir("Tümünü Yedekle") { yedekAcik = true }
                if !depo.listeKapali {
                    satir("Geri Yükle") { dosyaIsi = .geriYukle; dosyaSecici = true }
                }
                satir("Sekme Sırasını Değiştir") { altPencere = .sekme }
                satir("Kayıt Formatı") { altPencere = .bicim }
                satir("Tema Seçimi") { altPencere = .tema }
                if !depo.listeKapali {
                    satir("Varsayılan Radyo Listesini Yükle") { varsayilanUyarisi = true }
                }
                satir("Tüm Listeyi Temizle") { temizlemeUyarisi = true }
            }
            .navigationTitle("Ayarlar")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Kapat") { kapat() }.keyboardShortcut(.cancelAction) }
            }
        }
        .accessibilityAction(.escape) { kapat() }
        .sheet(isPresented: $rehberAcik) { RehberPenceresi(asistan: asistan) }
        .sheet(item: $altPencere) { p in altPencereGorunumu(p) }
        .fileImporter(isPresented: $dosyaSecici, allowedContentTypes: [.item]) { sonuc in dosyaSecildi(sonuc) }
        .fileExporter(isPresented: $yedekAcik, document: YedekBelgesi(veri: depo.yedekVerisi()),
                      contentType: .json, defaultFilename: "ReklamsizRadyo_Yedek") { sonuc in
            switch sonuc {
            case .success: bildirim.goster("Yedekleme başarılı!")
            case .failure: bildirim.goster("Yedekleme hatası!")
            }
        }
        .alert("Uyarı", isPresented: $varsayilanUyarisi) {
            Button("Evet", role: .destructive) {
                depo.varsayilaniYukle()
                bildirim.goster("Varsayılan radyo istasyonları başarıyla yüklendi.")
            }
            Button("Hayır", role: .cancel) {}
        } message: {
            Text("Varsayılan radyo listesini geri yüklemek istediğinize emin misiniz? Mevcut tüm özel eklemeleriniz silinecek ve listeler ilk günkü haline dönecektir.")
        }
        .alert("Uyarı", isPresented: $temizlemeUyarisi) {
            Button("Evet", role: .destructive) {
                depo.tumunuSil()
                bildirim.goster("Tüm radyo istasyonları silindi.")
            }
            Button("Hayır", role: .cancel) {}
        } message: {
            Text("Tüm radyo listesini silmek istediğinize emin misiniz?")
        }
    }

    private func satir(_ baslik: String, _ eylem: @escaping () -> Void) -> some View {
        Button(action: eylem) {
            Text(baslik).foregroundColor(.primary).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
    }

    @ViewBuilder private func altPencereGorunumu(_ p: AltPencere) -> some View {
        switch p {
        case .uyku:
            let dakikalar = [5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60]
            SecimPenceresi(baslik: "Kaç dakika sonra kapansın?", secenekler: dakikalar.map { "\($0) Dakika" }, secili: nil) { i in
                oynatici.uykuKur(dakikalar[i])
            }
        case .sekme:
            SecimPenceresi(baslik: "Sekme Sırasını Seçin", secenekler: [
                "Tüm Radyolar - Favoriler - Kayıtlar",
                "Tüm Radyolar - Kayıtlar - Favoriler",
                "Favoriler - Tüm Radyolar - Kayıtlar",
                "Favoriler - Kayıtlar - Tüm Radyolar",
                "Kayıtlar - Tüm Radyolar - Favoriler",
                "Kayıtlar - Favoriler - Tüm Radyolar",
            ], secili: sekmeSiraNo) { i in
                sekmeSiraNo = i
                sekmeSirasiV2 = true
                bildirim.goster("Sekme sırası güncellendi!")
            }
        case .bicim:
            let bicimler = ["mp3", "wav", "m4a"]
            SecimPenceresi(baslik: "Kayıt Formatı Seçin", secenekler: [
                "MP3 (Tüm Cihazlar İçin Önerilen)", "WAV (Yüksek Kalite / Sıkıştırmasız)", "M4A (Varsayılan / Standart)",
            ], secili: bicimler.firstIndex(of: kayitBicimi) ?? 2) { i in
                kayitBicimi = bicimler[i]
                bildirim.goster("Kayıt formatı \(bicimler[i].uppercased()) olarak güncellendi!")
            }
        case .tema:
            SecimPenceresi(baslik: "Tema Seçimi", secenekler: ["Açık Tema", "Koyu Tema", "Sistem Varsayılanı"], secili: tema) { i in
                tema = i
            }
        }
    }

    private func dosyaSecildi(_ sonuc: Result<URL, Error>) {
        guard case .success(let url) = sonuc else { return }
        let erisim = url.startAccessingSecurityScopedResource()
        defer { if erisim { url.stopAccessingSecurityScopedResource() } }
        guard let veri = try? Data(contentsOf: url) else {
            bildirim.goster(dosyaIsi == .iceAktar ? "Dosya okuma hatası!" : "Geri yükleme hatası!")
            return
        }
        switch dosyaIsi {
        case .iceAktar:
            let sayi = depo.listeIceAktar(String(decoding: veri, as: UTF8.self))
            bildirim.goster("\(sayi) radyo listeye eklendi!")
        case .geriYukle:
            if let sayi = depo.yedektenYukle(veri) {
                bildirim.goster("\(sayi) radyo geri yüklendi!")
            } else {
                bildirim.goster("Geri yükleme hatası!")
            }
        }
    }
}

/// Android'deki tek seçimli liste penceresi (setSingleChoiceItems / setItems). Seçilen "seçili" diye okunur.
struct SecimPenceresi: View {
    let baslik: String
    let secenekler: [String]
    let secili: Int?
    let secildi: (Int) -> Void
    @Environment(\.dismiss) private var kapat

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(secenekler.enumerated()), id: \.offset) { i, s in
                    Button {
                        secildi(i)
                        kapat()
                    } label: {
                        HStack {
                            Text(s).foregroundColor(.primary)
                            Spacer()
                            if i == secili { Image(systemName: "checkmark").foregroundColor(.accentColor) }
                        }
                        .frame(minHeight: 44)
                    }
                    .accessibilityLabel(i == secili ? "\(s), seçili" : s)
                }
            }
            .navigationTitle(baslik)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("İptal") { kapat() }.keyboardShortcut(.cancelAction) }
            }
        }
        .accessibilityAction(.escape) { kapat() }
    }
}

/// "Tümünü Yedekle" ile kaydedilen dosya.
struct YedekBelgesi: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var veri: Data
    init(veri: Data) { self.veri = veri }
    init(configuration: ReadConfiguration) throws { veri = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: veri) }
}

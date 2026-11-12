import SwiftUI
import UIKit
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
    @AppStorage("oynatici_penceresi_ac") private var oynaticiPenceresiAcilsin = false
    @AppStorage("yayin_ses_seviyesi") private var sesSeviyesi = 100
    @AppStorage("test_liste_kapali") private var testListeKapali = false

    private enum AltPencere: Identifiable {
        case uyku, sekme, bicim, tema, ses
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
    @State private var olcumPaylas: PaylasilacakDosya?

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
                satir("Yayın Ses Seviyesi: %\(sesSeviyesi)") { altPencere = .ses }
                satir(oynaticiPenceresiAcilsin ? "Yayın Açılınca Oynatıcıyı Göster: Açık" : "Yayın Açılınca Oynatıcıyı Göster: Kapalı") {
                    oynaticiPenceresiAcilsin.toggle()
                    bildirim.goster(oynaticiPenceresiAcilsin ? "Yayın açılınca oynatıcı gösterilecek." : "Yayın açılınca oynatıcı gösterilmeyecek.")
                }
                satir("Tema Seçimi") { altPencere = .tema }
                if !depo.listeKapali {
                    satir("Varsayılan Radyo Listesini Yükle") { varsayilanUyarisi = true }
                }
                satir("Tüm Listeyi Temizle") { temizlemeUyarisi = true }
                if testAyariVar {
                    satir(testListeKapali ? "Test: Liste Kapalı" : "Test: Liste Açık") {
                        testListeKapali.toggle()
                        Task { await depo.internettenGuncelle() }
                    }
                    satir("Test: Ölçüm Kaydını Kopyala") {
                        UIPasteboard.general.string = OlcumKaydi.shared.metin
                        bildirim.goster("Ölçüm kaydı kopyalandı, \(OlcumKaydi.shared.satirSayisi) satır")
                    }
                    satir("Test: Ölçüm Kaydını Paylaş") {
                        olcumPaylas = PaylasilacakDosya(url: OlcumKaydi.shared.dosya)
                    }
                    satir("Test: Ölçüm Kaydını Sil") {
                        OlcumKaydi.shared.sil()
                        bildirim.goster("Ölçüm kaydı silindi")
                    }
                }
            }
            .navigationTitle("Ayarlar")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Kapat") { kapat() }.keyboardShortcut(.cancelAction) }
            }
        }
        .accessibilityAction(.escape) { kapat() }
        .sheet(isPresented: $rehberAcik) { RehberPenceresi(asistan: asistan) }
        .sheet(item: $altPencere) { p in altPencereGorunumu(p) }
        .sheet(item: $olcumPaylas) { d in PaylasPenceresi(ogeler: [d.url]) }
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
            SekmeSirasiPenceresi().environmentObject(depo).environmentObject(bildirim)
        case .bicim:
            let bicimler = ["mp3", "wav", "m4a"]
            SecimPenceresi(baslik: "Kayıt Formatı Seçin", secenekler: [
                "MP3 (Tüm Cihazlar İçin Önerilen)", "WAV (Yüksek Kalite / Sıkıştırmasız)", "M4A (Varsayılan / Standart)",
            ], secili: bicimler.firstIndex(of: kayitBicimi) ?? 2) { i in
                kayitBicimi = bicimler[i]
                bildirim.goster("Kayıt formatı \(bicimler[i].uppercased()) olarak güncellendi!")
            }
        case .ses:
            let seviyeler = [25, 50, 75, 100]
            SecimPenceresi(baslik: "Yayın Ses Seviyesi", secenekler: seviyeler.map { "%\($0)" },
                           secili: seviyeler.firstIndex(of: sesSeviyesi)) { i in
                sesSeviyesi = seviyeler[i]
                oynatici.sesiUygula()
                bildirim.goster("Yayın ses seviyesi %\(seviyeler[i]) olarak ayarlandı.")
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

/// Sekme sırası: her sekme yukarı veya aşağı taşınır. VoiceOver'da satır tek öğedir, taşıma kaydırma eylemlerindedir.
struct SekmeSirasiPenceresi: View {
    @EnvironmentObject private var depo: Depo
    @EnvironmentObject private var bildirim: Bildirim
    @Environment(\.dismiss) private var kapat
    @AppStorage("sekme_sirasi") private var kayitliSira = ""
    @AppStorage("tab_order_index") private var eskiSiraNo = 0

    private var tumSira: [String] { sekmeSirasiniCoz(kayitliSira, eskiNo: eskiSiraNo) }
    private var gorunen: [String] { tumSira.filter { $0 != "tv" || !depo.listeKapali } }

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(gorunen.enumerated()), id: \.element) { i, s in
                    let ad = sekmeEtiketi(s, listeKapali: depo.listeKapali)
                    HStack {
                        Text(ad).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        Button { tasi(s, -1) } label: {
                            Image(systemName: "chevron.up").frame(minWidth: 44, minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .disabled(i == 0)
                        Button { tasi(s, 1) } label: {
                            Image(systemName: "chevron.down").frame(minWidth: 44, minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .disabled(i == gorunen.count - 1)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(ad), \(i + 1). sıra")
                    .accessibilityActions {
                        if i > 0 { Button("Yukarı Taşı") { tasi(s, -1) } }
                        if i < gorunen.count - 1 { Button("Aşağı Taşı") { tasi(s, 1) } }
                    }
                }
            }
            .navigationTitle("Sekme Sırası")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Kapat") { kapat() }.keyboardShortcut(.cancelAction) }
            }
        }
        .accessibilityAction(.escape) { kapat() }
    }

    private func tasi(_ s: String, _ yon: Int) {
        var liste = gorunen
        guard let i = liste.firstIndex(of: s), liste.indices.contains(i + yon) else { return }
        liste.swapAt(i, i + yon)
        // Liste kapalıyken görünmeyen TV sekmesi yerini korur.
        if depo.listeKapali, let tv = tumSira.firstIndex(of: "tv") { liste.insert("tv", at: min(tv, liste.count)) }
        kayitliSira = liste.joined(separator: ",")
        let yeni = gorunen.firstIndex(of: s).map { $0 + 1 } ?? i + yon + 1
        bildirim.goster("\(sekmeEtiketi(s, listeKapali: depo.listeKapali)), \(yeni). sıraya taşındı")
    }
}

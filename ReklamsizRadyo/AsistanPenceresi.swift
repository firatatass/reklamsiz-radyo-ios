import SwiftUI

/// Sesli asistan penceresi (Android dialog_voice_assistant).
struct AsistanPenceresi: View {
    @ObservedObject var asistan: SesliAsistan

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: "mic.circle.fill")
                        .font(.largeTitle)
                        .foregroundColor(lacivert)
                        .accessibilityLabel("Sesli Asistan Simgesi")
                    Text("Sesli Asistan")
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button { asistan.rehberAcik = true } label: {
                        Image(systemName: "questionmark.circle").font(.title)
                    }
                    .accessibilityLabel("Sesli Asistan Rehberi ve Komut Listesi")
                    Button { asistan.kapat() } label: {
                        Image(systemName: "xmark.circle").font(.title)
                    }
                    .accessibilityLabel("Sesli Asistanı Kapat")
                }

                Text(asistan.durum)
                    .font(.headline)
                    .foregroundColor(asistan.durumHata ? .red : .blue)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)

                if !asistan.kullaniciSozu.isEmpty {
                    Text(asistan.kullaniciSozu)
                        .font(.body.italic())
                        .multilineTextAlignment(.center)
                }

                if !asistan.cevap.isEmpty {
                    Text(asistan.cevap)
                        .font(.body)
                        .multilineTextAlignment(.center)
                }

                Button { asistan.mikrofonaDokunuldu() } label: {
                    Image(systemName: asistan.dinliyor ? "waveform.circle.fill" : "mic.circle")
                        .font(.system(size: 72))
                        .foregroundColor(lacivert)
                }
                .accessibilityLabel(asistan.dinliyor ? "Mikrofon açık, konuşabilirsiniz" : asistan.mikIpucu)

                Text(asistan.mikIpucu)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)

                Text("Örnek Komutlar:")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)

                ornek("A Haber Aç", "Örnek Komut: A Haber Aç", "A Haber aç")
                ornek("Çalar Saat Kur", "Örnek Komut: Çalar Saat Kur", "Çalar saat kur")
                ornek("30 Dk Zamanlayıcı", "Örnek Komut: 30 Dakika Zamanlayıcı Kur", "30 dakika zamanlayıcı")
                ornek("Durdur", "Örnek Komut: Radyoyu Durdur", "Yayını durdur")
                ornek("Uygulamayı Kapat", "Örnek Komut: Uygulamayı Kapat", "Uygulamayı kapat")
            }
            .padding()
        }
        .accessibilityAction(.escape) { asistan.kapat() }
        .sheet(isPresented: $asistan.rehberAcik) {
            RehberPenceresi(asistan: asistan)
        }
    }

    private func ornek(_ baslik: String, _ etiket: String, _ komut: String) -> some View {
        BuyukDugme(baslik: baslik) { asistan.komutuIsle(komut) }
            .accessibilityLabel(etiket)
    }
}

/// "Sesli Asistan Rehberi" (Android showHelpGuideDialog).
struct RehberPenceresi: View {
    @ObservedObject var asistan: SesliAsistan
    @Environment(\.dismiss) private var kapat

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(SesliAsistan.rehberMetni)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("Sesli Asistan Rehberi")
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    BuyukDugme(baslik: "Kapat") { kapat() }
                    BuyukDugme(baslik: "Sesli Olarak Dinle") {
                        kapat()
                        asistan.rehberiSeslendir()
                    }
                }
                .padding()
                .background(.bar)
            }
        }
    }
}

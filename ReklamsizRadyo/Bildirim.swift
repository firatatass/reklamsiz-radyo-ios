import SwiftUI
import UIKit

/// Android'deki Toast karşılığı: ekranda kısa süre yazı gösterir ve VoiceOver'a okutur.
@MainActor
final class Bildirim: ObservableObject {
    static let shared = Bildirim()
    @Published private(set) var metin: String?

    func goster(_ m: String) {
        metin = m
        UIAccessibility.post(notification: .announcement, argument: m)
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if metin == m { metin = nil }
        }
    }
}

func zamanMetni(_ saniye: Double) -> String {
    let t = max(0, Int(saniye.isFinite ? saniye : 0))
    return String(format: "%02d:%02d", t / 60, t % 60)
}

func veriMetni(_ bayt: Int) -> String {
    let mb = Double(bayt) / (1024 * 1024)
    return mb > 1024 ? String(format: "%.2f GB", mb / 1024) : String(format: "%.2f MB", mb)
}

let lacivert = Color(red: 0, green: 0x20 / 255, blue: 0x60 / 255)

/// Android'deki erişilebilir düğme görünümü: geniş, lacivert zemin, beyaz kalın yazı.
struct BuyukDugme: View {
    let baslik: String
    var etkin = true
    let eylem: () -> Void

    var body: some View {
        Button(action: eylem) {
            Text(baslik)
                .font(.system(size: 17, weight: .bold))
                .frame(maxWidth: .infinity, minHeight: 50)
                .foregroundColor(.white)
                .background(lacivert)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(!etkin)
        .opacity(etkin ? 1 : 0.5)
    }
}

/// Kayıt dosyası paylaşma penceresi.
struct PaylasPenceresi: UIViewControllerRepresentable {
    let ogeler: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: ogeler, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct PaylasilacakDosya: Identifiable {
    let url: URL
    var id: String { url.path }
}

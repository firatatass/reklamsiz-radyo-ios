import SwiftUI

struct AnaEkran: View {
    @EnvironmentObject private var liste: ListeDeposu
    @EnvironmentObject private var oynatici: Oynatici

    var body: some View {
        TabView {
            YayinListesi(baslik: "Radyolar", yayinlar: liste.radyolar, gruplu: false)
                .tabItem { Label("Radyolar", systemImage: "radio") }
            YayinListesi(baslik: "TV Kanalları", yayinlar: liste.tvler, gruplu: true)
                .tabItem { Label("TV Kanalları", systemImage: "tv") }
        }
    }
}

struct YayinListesi: View {
    @EnvironmentObject private var liste: ListeDeposu
    @EnvironmentObject private var oynatici: Oynatici
    let baslik: String
    let yayinlar: [Yayin]
    let gruplu: Bool
    @State private var arama = ""

    private var suzulmus: [Yayin] {
        let a = arama.trimmingCharacters(in: .whitespaces)
        guard !a.isEmpty else { return yayinlar }
        return yayinlar.filter { $0.ad.localizedStandardContains(a) }
    }

    private var gruplar: [(String, [Yayin])] {
        var sira: [String] = []
        var harita: [String: [Yayin]] = [:]
        for y in suzulmus {
            if harita[y.grup] == nil { sira.append(y.grup) }
            harita[y.grup, default: []].append(y)
        }
        return sira.map { ($0, harita[$0]!) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if yayinlar.isEmpty {
                    if let hata = liste.hata {
                        VStack(spacing: 16) {
                            Text(hata)
                            Button("Tekrar Dene") { Task { await liste.yenile() } }
                        }
                        .padding()
                    } else {
                        ProgressView("Liste yükleniyor")
                    }
                } else {
                    List {
                        if gruplu {
                            ForEach(gruplar, id: \.0) { grup, ogeler in
                                Section(grup) { ForEach(ogeler) { YayinSatiri(yayin: $0) } }
                            }
                        } else {
                            ForEach(suzulmus) { YayinSatiri(yayin: $0) }
                        }
                    }
                    .listStyle(.plain)
                    .refreshable { await liste.yenile() }
                }
            }
            .safeAreaInset(edge: .bottom) { CalarCubugu() }
            .navigationTitle(baslik)
            .searchable(text: $arama, prompt: "Ara")
        }
    }
}

struct YayinSatiri: View {
    @EnvironmentObject private var oynatici: Oynatici
    let yayin: Yayin

    private var buCaliyor: Bool { oynatici.calan?.id == yayin.id && oynatici.calan?.url == yayin.url }

    var body: some View {
        Button {
            oynatici.cal(yayin)
        } label: {
            HStack {
                Text(yayin.ad).foregroundStyle(.primary)
                Spacer()
                if buCaliyor {
                    Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(yayin.ad)
        .accessibilityValue(buCaliyor ? durumMetni(oynatici.durum) : "")
        .accessibilityAddTraits(.isButton)
    }
}

struct CalarCubugu: View {
    @EnvironmentObject private var oynatici: Oynatici

    var body: some View {
        if let yayin = oynatici.calan {
            HStack(spacing: 16) {
                VStack(alignment: .leading) {
                    Text(yayin.ad).font(.headline).lineLimit(1)
                    Text(durumMetni(oynatici.durum)).font(.subheadline).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                Spacer()
                Button {
                    oynatici.oynatDuraklat()
                } label: {
                    Image(systemName: oynatici.caliyorMu ? "pause.fill" : "play.fill").font(.title)
                }
                .accessibilityLabel(oynatici.caliyorMu ? "Duraklat" : "Oynat")
                Button {
                    oynatici.durdur()
                } label: {
                    Image(systemName: "stop.fill").font(.title)
                }
                .accessibilityLabel("Durdur")
            }
            .padding()
            .background(.bar)
        }
    }
}

func durumMetni(_ d: Oynatici.Durum) -> String {
    switch d {
    case .durdu: return "Durdu"
    case .baglaniyor: return "Bağlanıyor"
    case .caliyor: return "Çalıyor"
    case .duraklatildi: return "Duraklatıldı"
    case .hata(let m): return m
    }
}

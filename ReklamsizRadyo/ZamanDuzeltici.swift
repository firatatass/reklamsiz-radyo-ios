import Foundation

/// Bazı yayınlarda (Show Max) görüntünün çözme zamanı (DTS) ve yayının saati (PCR), gösterme zamanının (PTS)
/// yaklaşık 25 saniye gerisinde; bu yüzden ses her parçanın sonuna yığılmış. Apple'ın oynatıcısı bu saate uyup
/// 25 saniye veri biriktirmeye çalışıyor ve yayın açılmıyordu (Android'deki oynatıcı bu saate bakmıyor).
/// Düzeltici DTS'i ve PCR'ı sabit bir miktar ileri alır, paketleri yeni zamana göre harmanlar.
/// Ses ve görüntü verisine dokunulmaz; her akışın kendi paket sırası korunur, parçanın boyu değişmez.
enum ZamanDuzeltici {
    private static let tur: Int64 = 1 << 33

    /// 33 bitlik iki zamanın farkı (a - b), sayacın başa dönmesi hesaba katılarak.
    private static func fark(_ a: Int64, _ b: Int64) -> Int64 {
        var f = (a - b) % tur
        if f < 0 { f += tur }
        return f > tur / 2 ? f - tur : f
    }

    private static func oku(_ b: [UInt8], _ i: Int) -> Int64 {
        (Int64(b[i] >> 1) & 7) << 30 | Int64(b[i + 1]) << 22 | (Int64(b[i + 2]) >> 1) << 15
            | Int64(b[i + 3]) << 7 | Int64(b[i + 4]) >> 1
    }

    private static func yaz(_ b: inout [UInt8], _ i: Int, _ zaman: Int64) {
        let t = ((zaman % tur) + tur) % tur
        b[i] = (b[i] & 0xF0) | UInt8((t >> 29) & 0x0E) | 1
        b[i + 1] = UInt8((t >> 22) & 0xFF)
        b[i + 2] = UInt8((t >> 14) & 0xFE) | 1
        b[i + 3] = UInt8((t >> 7) & 0xFF)
        b[i + 4] = UInt8((t << 1) & 0xFE) | 1
    }

    /// Paketin içinde zaman bilgili PES başlığı başlıyorsa yeri, yoksa nil.
    private static func pesBasi(_ b: [UInt8], _ i: Int) -> Int? {
        guard b[i + 1] & 0x40 != 0 else { return nil }
        let af = (b[i + 3] >> 4) & 3
        guard af & 1 != 0 else { return nil }
        var k = i + 4
        if af & 2 != 0 { k += 1 + Int(b[i + 4]) }
        guard k + 14 <= i + 188, b[k] == 0, b[k + 1] == 0, b[k + 2] == 1, b[k + 7] & 0x80 != 0 else { return nil }
        return k
    }

    private static func dtsVar(_ b: [UInt8], _ i: Int, _ k: Int) -> Bool {
        b[k + 7] & 0xC0 == 0xC0 && k + 19 <= i + 188
    }

    private static func gecerli(_ b: [UInt8]) -> Bool {
        b.count >= 188 && b.count % 188 == 0 && b[0] == 0x47
    }

    /// Görüntünün DTS'i PTS'den 3 saniyeden fazla gerideyse ileri alınacak miktar (90 kHz birim), değilse nil.
    static func kaydirma(_ veri: Data) -> Int64? {
        let b = [UInt8](veri)
        guard gecerli(b) else { return nil }
        var enAz = Int64.max
        for i in stride(from: 0, to: b.count, by: 188) where b[i] == 0x47 {
            guard let k = pesBasi(b, i), dtsVar(b, i, k) else { continue }
            enAz = min(enAz, fark(oku(b, k + 9), oku(b, k + 14)))
        }
        guard enAz != .max, enAz > 3 * 90_000 else { return nil }
        // Normal yayınlardaki gibi 0,1 saniyelik pay bırakılır.
        return enAz - 9_000
    }

    /// Parçanın DTS ve PCR değerlerini `c` kadar ileri alır ve paketleri zamana göre harmanlar.
    /// Beklenmeyen bir yapı görülürse parça olduğu gibi döner.
    static func duzelt(_ veri: Data, kaydirma c: Int64) -> Data {
        var b = [UInt8](veri)
        guard gecerli(b) else { return veri }
        let n = b.count / 188
        var anahtar = [Int64](repeating: Int64.min, count: n)
        var sonAnahtar: [Int: Int64] = [:]
        var taban: Int64?
        for j in 0..<n {
            let i = j * 188
            guard b[i] == 0x47 else { return veri }
            let pid = Int(b[i + 1] & 0x1F) << 8 | Int(b[i + 2])
            // Yayının saati (PCR) ileri alınır.
            if (b[i + 3] >> 4) & 2 != 0, b[i + 4] >= 7, b[i + 5] & 0x10 != 0 {
                var t = Int64(b[i + 6]) << 25 | Int64(b[i + 7]) << 17 | Int64(b[i + 8]) << 9
                    | Int64(b[i + 9]) << 1 | Int64(b[i + 10] >> 7)
                t = (((t + c) % tur) + tur) % tur
                b[i + 6] = UInt8((t >> 25) & 0xFF)
                b[i + 7] = UInt8((t >> 17) & 0xFF)
                b[i + 8] = UInt8((t >> 9) & 0xFF)
                b[i + 9] = UInt8((t >> 1) & 0xFF)
                b[i + 10] = (b[i + 10] & 0x7F) | UInt8((t & 1) << 7)
            }
            if let k = pesBasi(b, i) {
                let pts = oku(b, k + 9)
                var zaman = pts
                if dtsVar(b, i, k) {
                    let dts = oku(b, k + 14)
                    // DTS ileri alınır ama PTS'yi geçmez.
                    let yeni = fark(pts, dts) > c ? dts + c : pts
                    yaz(&b, k + 14, yeni)
                    zaman = yeni
                }
                if taban == nil { taban = zaman }
                let goreli = fark(zaman, taban ?? zaman)
                sonAnahtar[pid] = max(sonAnahtar[pid] ?? Int64.min, goreli)
            }
            anahtar[j] = sonAnahtar[pid] ?? Int64.min
        }
        // Her akışın anahtarı kendi içinde azalmadığından, (anahtar, sıra) dizilimi akış içi sırayı bozmaz.
        let sira = (0..<n).sorted { anahtar[$0] != anahtar[$1] ? anahtar[$0] < anahtar[$1] : $0 < $1 }
        var cikis = [UInt8]()
        cikis.reserveCapacity(b.count)
        for j in sira { cikis.append(contentsOf: b[(j * 188)..<(j * 188 + 188)]) }
        return Data(cikis)
    }
}

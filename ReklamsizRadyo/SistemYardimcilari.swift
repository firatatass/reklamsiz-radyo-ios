import CoreMotion
import MediaPlayer
import UIKit

/// Sistem ses seviyesini değiştirmek için iOS'un kendi ses kaydırıcısı kullanılır (Android'de ses tuşu adımı).
@MainActor
final class MPVolumeViewKopru {
    static let paylasilan = MPVolumeViewKopru()
    private let gorunum = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 10, height: 10))

    func degistir(_ fark: Float) {
        if gorunum.superview == nil,
           let pencere = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first {
            gorunum.isAccessibilityElement = false
            gorunum.accessibilityElementsHidden = true
            pencere.addSubview(gorunum)
        }
        guard let kaydirici = gorunum.subviews.compactMap({ $0 as? UISlider }).first else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            kaydirici.setValue(min(1, max(0, kaydirici.value + fark)), animated: false)
            kaydirici.sendActions(for: .valueChanged)
        }
    }
}

/// Telefonu sallayarak sesli asistanı açma (Android'deki ivmeölçer algoritmasının aynısı).
@MainActor
final class SallamaAlgilayici {
    static let shared = SallamaAlgilayici()
    private let hareket = CMMotionManager()
    private var sallamaSayisi = 0
    private var ilkSallama: TimeInterval = 0
    private var sonSallama: TimeInterval = 0
    private var sonTetikleme: TimeInterval = 0
    private var sonX = 0.0, sonY = 0.0, sonZ = 0.0
    private var hazir = false
    var tetiklendi: () -> Void = {}

    func baslat() {
        guard hareket.isAccelerometerAvailable, !hareket.isAccelerometerActive else { return }
        hareket.accelerometerUpdateInterval = 0.06
        hareket.startAccelerometerUpdates(to: .main) { [weak self] veri, _ in
            guard let a = veri?.acceleration else { return }
            Task { @MainActor in self?.olcum(a.x * 9.80665, a.y * 9.80665, a.z * 9.80665) }
        }
    }

    func durdur() { hareket.stopAccelerometerUpdates() }

    private func olcum(_ x: Double, _ y: Double, _ z: Double) {
        if !(UserDefaults.standard.object(forKey: "shake_assistant_enabled") as? Bool ?? true) { return }
        let simdi = Date().timeIntervalSince1970 * 1000
        if simdi - sonTetikleme < 2500 { return }
        if !hazir {
            sonX = x; sonY = y; sonZ = z
            hazir = true
            return
        }
        let dx = abs(sonX - x), dy = abs(sonY - y), dz = abs(sonZ - z)
        sonX = x; sonY = y; sonZ = z
        let g = 9.80665
        let kuvvet = ((x / g) * (x / g) + (y / g) * (y / g) + (z / g) * (z / g)).squareRoot()
        let salliyor = kuvvet > 2.0 || dx + dy + dz > 12.0
        if salliyor {
            if simdi - sonSallama > 200 {
                if ilkSallama == 0 || simdi - ilkSallama > 2500 {
                    sallamaSayisi = 1
                    ilkSallama = simdi
                    sonSallama = simdi
                } else {
                    sallamaSayisi += 1
                    sonSallama = simdi
                    if sallamaSayisi >= 4 {
                        sallamaSayisi = 0
                        ilkSallama = 0
                        sonTetikleme = simdi
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        tetiklendi()
                    }
                }
            }
        } else if ilkSallama > 0 && simdi - ilkSallama > 1200 {
            sallamaSayisi = 0
            ilkSallama = 0
        }
    }
}

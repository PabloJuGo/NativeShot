import AVFoundation
import SwiftUI
import NativeShotKit

/// Keys overlay switch: turning it on goes through the consent explanation first.
struct KeyOverlayToggle: View {
    @AppStorage(RecorderPrefs.keys) private var keys = false

    var body: some View {
        Toggle("Mostrar atajos de teclado (⌘ ⌃ ⌥)", isOn: Binding(get: { keys }, set: { keys = $0 ? KeyOverlayConsent.ask() : false }))
    }
}

/// UI-15
struct RecordingSettings: View {
    @AppStorage(RecorderPrefs.fps) private var fps = 30
    @AppStorage(RecorderPrefs.systemAudio) private var systemAudio = true
    @AppStorage(RecorderPrefs.microphone) private var microphone = false
    @AppStorage(RecorderPrefs.micDevice) private var micDevice = ""
    @AppStorage(RecorderPrefs.micChannels) private var micChannels = 1
    @AppStorage(RecorderPrefs.webcam) private var webcam = false
    @AppStorage(RecorderPrefs.webcamDevice) private var webcamDevice = ""
    @AppStorage(RecorderPrefs.webcamShape) private var webcamShape = "circle"
    @AppStorage(RecorderPrefs.webcamSize) private var webcamSize = 180
    @AppStorage(RecorderPrefs.webcamCorner) private var webcamCorner = "bottomLeft"
    @AppStorage(RecorderPrefs.clicks) private var clicks = true
    @AppStorage(RecorderPrefs.countdown) private var countdown = 3
    @AppStorage(RecorderPrefs.codec) private var codec = "h264"
    @AppStorage(RecorderPrefs.quality) private var quality = "standard"

    private var mics: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }
    /// Probed once per view: asking the writer is cheap but not free.
    private let hevcAvailable = VideoCodec.hevc.isSupported(width: 1920, height: 1080)

    var body: some View {
        Form {
            Picker("Fotogramas por segundo", selection: $fps) {
                ForEach([15, 24, 30, 60], id: \.self) { Text("\($0)").tag($0) }
            }
            Picker("Códec de vídeo", selection: $codec) {
                Text("H.264 (compatible)").tag("h264")
                if hevcAvailable || codec == "hevc" { Text("HEVC (archivos más pequeños)").tag("hevc") }
            }
            if !hevcAvailable {
                Text("Este Mac no admite HEVC en la grabación: se usará H.264.").font(.caption).foregroundStyle(.secondary)
            }
            Picker("Calidad", selection: $quality) {
                Text("Baja (archivos pequeños)").tag("low")
                Text("Estándar").tag("standard")
                Text("Alta").tag("high")
            }
            Toggle("Audio del sistema", isOn: $systemAudio)
            Toggle("Micrófono", isOn: $microphone)
            if microphone {
                Picker("Dispositivo de micrófono", selection: $micDevice) {
                    Text("Predeterminado del sistema").tag("")
                    ForEach(mics, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                }
                Picker("Canales del micrófono", selection: $micChannels) {
                    Text("Mono").tag(1)
                    Text("Estéreo").tag(2)
                }
                .pickerStyle(.segmented)
            }
            Toggle("Webcam flotante", isOn: $webcam)
            if webcam {
                Picker("Cámara", selection: $webcamDevice) {
                    Text("Predeterminada del sistema").tag("")
                    ForEach(CameraSession.devices(), id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                }
                Picker("Forma de la webcam", selection: $webcamShape) {
                    Text("Círculo").tag("circle")
                    Text("Rectángulo redondeado").tag("rect")
                }
                .pickerStyle(.segmented)
                Picker("Tamaño de la webcam", selection: $webcamSize) {
                    Text("Pequeño").tag(120)
                    Text("Mediano").tag(180)
                    Text("Grande").tag(260)
                }
                .pickerStyle(.segmented)
                Picker("Posición de la webcam", selection: $webcamCorner) {
                    Text("Arriba izquierda").tag("topLeft")
                    Text("Arriba derecha").tag("topRight")
                    Text("Abajo izquierda").tag("bottomLeft")
                    Text("Abajo derecha").tag("bottomRight")
                }
            }
            Toggle("Resaltar clics", isOn: $clicks)
            KeyOverlayToggle()
            Text("Las teclas se muestran solo mientras graba, nunca se guardan y requieren el permiso «Monitorización de entrada». Solo se muestran atajos con ⌘, ⌃ o ⌥; el texto normal nunca aparece.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Cuenta atrás", selection: $countdown) {
                Text("Sin cuenta atrás").tag(0)
                ForEach([3, 5, 10], id: \.self) { Text("\($0) s").tag($0) }
            }
        }
        .formStyle(.grouped)
    }
}

import AppKit
import AVFoundation
import AVKit
import SwiftUI
import NativeShotKit

func formatTime(_ t: Double) -> String {
    let s = max(t, 0)
    return String(format: "%d:%02d.%d", Int(s) / 60, Int(s) % 60, Int((s * 10).truncatingRemainder(dividingBy: 10)))
}

/// UI-11: preview, timeline, inspector and the global shortcuts (space, S, delete, ⌘Z, ⇧⌘Z, ⌘S, ⌘E).
struct VideoEditorView: View {
    @ObservedObject var model: VideoEditorModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 8) {
                PreviewArea(model: model)
                transport
                TimelineView(model: model).frame(height: 132)
            }
            .padding(12)
            Divider()
            VideoInspector(model: model).frame(width: 250)
        }
        .sheet(isPresented: $model.showExportSheet) { ExportSheet(model: model) }
    }

    private var transport: some View {
        HStack(spacing: 10) {
            Button { model.togglePlay() } label: { Image(systemName: model.isPlaying ? "pause.fill" : "play.fill") }
                .keyboardShortcut(.space, modifiers: [])
                .help("Reproducir / pausar (espacio)")
                .accessibilityLabel(Text(model.isPlaying ? LocalizedStringKey("Pausar") : LocalizedStringKey("Reproducir")))
            Text("\(formatTime(model.playhead)) / \(formatTime(model.sourceDuration))")
                .font(.system(.caption, design: .monospaced))
                .accessibilityLabel(Text("Posición"))
                .accessibilityValue(Text(formatTime(model.playhead)))
            Divider().frame(height: 16)
            Button { model.split() } label: { Label("Dividir", systemImage: "scissors") }
                .keyboardShortcut("s", modifiers: [])
                .help("Dividir en el cabezal (S)")
            Button { model.deleteSelection() } label: { Label("Eliminar tramo", systemImage: "trash") }
                .keyboardShortcut(.delete, modifiers: [])
                .help("Eliminar el tramo o el zoom seleccionado (⌫)")
            Button { model.trimStart() } label: { Label("Recortar inicio", systemImage: "arrow.right.to.line") }
                .keyboardShortcut("[", modifiers: [])
                .help("Quitar todo lo anterior al cabezal ([)")
            Button { model.trimEnd() } label: { Label("Recortar final", systemImage: "arrow.left.to.line") }
                .keyboardShortcut("]", modifiers: [])
                .help("Quitar todo lo posterior al cabezal (])")
            Divider().frame(height: 16)
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .keyboardShortcut("z", modifiers: .command).disabled(!model.history.canUndo)
                .help("Deshacer (⌘Z)").accessibilityLabel(Text("Deshacer"))
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!model.history.canRedo)
                .help("Rehacer (⇧⌘Z)").accessibilityLabel(Text("Rehacer"))
            Spacer()
            Button("Guardar proyecto") { model.saveProject() }
                .keyboardShortcut("s", modifiers: .command)
            Button("Exportar…") { model.showExportSheet = true }
                .keyboardShortcut("e", modifiers: .command)
                .buttonStyle(.borderedProminent)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .controlSize(.regular)
    }
}

// MARK: - Preview

struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.controlsStyle = .none
        v.player = player
        v.videoGravity = .resizeAspect
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) { v.player = player }
}

private struct PreviewArea: View {
    @ObservedObject var model: VideoEditorModel
    @State private var draft: NormalizedRect?

    var body: some View {
        GeometryReader { geo in
            let frame = AVMakeRect(aspectRatio: model.outputSize, insideRect: CGRect(origin: .zero, size: geo.size))
            ZStack(alignment: .topLeading) {
                PlayerSurface(player: model.player)
                    .accessibilityLabel(Text("Vista previa del vídeo"))
                if let key = model.project.zooms.first(where: { $0.id == model.selectedZoom }) {
                    ZoomRectOverlay(rect: draft ?? key.rect, frame: frame)
                        .gesture(DragGesture()
                            .onChanged { v in
                                var r = key.rect
                                r.x += v.translation.width / frame.width; r.y += v.translation.height / frame.height
                                draft = r.clamped()
                            }
                            .onEnded { _ in commit(key) })
                        .accessibilityElement()
                        .accessibilityLabel(Text("Rectángulo del zoom"))
                    Circle().fill(Color.accentColor).frame(width: 14, height: 14)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                        .position(x: frame.minX + (draft ?? key.rect).maxX(in: frame), y: frame.minY + (draft ?? key.rect).maxY(in: frame))
                        .gesture(DragGesture()
                            .onChanged { v in
                                var r = key.rect
                                // The frame keeps its aspect ratio, so equal normalized sides keep the video proportions.
                                let side = min(max(key.rect.width + v.translation.width / frame.width, 0.1), 1 - max(r.x, r.y))
                                r.width = side; r.height = side
                                draft = r
                            }
                            .onEnded { _ in commit(key) })
                        .accessibilityLabel(Text("Cambiar tamaño del zoom"))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func commit(_ key: ZoomKeyframe) {
        if let d = draft { var k = key; k.rect = d; model.apply(.updateZoom(k)) }
        draft = nil
    }
}

private extension NormalizedRect {
    func maxX(in f: CGRect) -> CGFloat { CGFloat(x + width) * f.width }
    func maxY(in f: CGRect) -> CGFloat { CGFloat(y + height) * f.height }
}

private struct ZoomRectOverlay: View {
    let rect: NormalizedRect
    let frame: CGRect
    var body: some View {
        let r = CGRect(x: frame.minX + rect.x * frame.width, y: frame.minY + rect.y * frame.height,
                       width: rect.width * frame.width, height: rect.height * frame.height)
        ZStack {
            Path { p in p.addRect(frame); p.addRect(r) }.fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
            Rectangle().stroke(Color.accentColor, lineWidth: 2).frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
        }
        .contentShape(Path(r))
    }
}

// MARK: - Timeline

struct TimelineView: View {
    @ObservedObject var model: VideoEditorModel
    @State private var trimStartDraft: Double?
    @State private var trimEndDraft: Double?
    @State private var zoomDrag: (id: UUID, time: Double)?
    private let rulerH: CGFloat = 16, trackH: CGFloat = 56, zoomH: CGFloat = 28

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let dur = model.sourceDuration
            let x = { (t: Double) in CGFloat(t / dur) * w }
            let time = { (px: CGFloat) in min(max(Double(px / w) * dur, 0), dur) }
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 6) {
                    ruler(w: w, x: x).frame(height: rulerH)
                    videoTrack(w: w, x: x, time: time).frame(height: trackH)
                    zoomTrack(w: w, x: x, time: time).frame(height: zoomH)
                }
                Rectangle().fill(Color.red).frame(width: 2, height: rulerH + trackH + zoomH + 12)
                    .offset(x: x(model.playhead) - 1)
                    .allowsHitTesting(false)
                    .accessibilityRepresentation {
                        Slider(value: Binding(get: { model.playhead }, set: { model.seek(to: $0) }), in: 0...dur, step: 1.0 / 30)
                            .accessibilityLabel(Text("Cabezal de reproducción"))
                            .accessibilityValue(Text(formatTime(model.playhead)))
                    }
            }
        }
        .coordinateSpace(name: "track")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Línea de tiempo"))
    }

    private func ruler(w: CGFloat, x: @escaping (Double) -> CGFloat) -> some View {
        let step = [1.0, 2, 5, 10, 15, 30, 60, 120, 300, 600].first { x($0) >= 70 } ?? 600
        return ZStack(alignment: .topLeading) {
            ForEach(Array(stride(from: 0.0, through: model.sourceDuration, by: step)), id: \.self) { t in
                Text(formatTime(t).dropLast(2)).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).offset(x: x(t) + 2)
            }
        }
        .accessibilityHidden(true)
    }

    private func videoTrack(w: CGFloat, x: @escaping (Double) -> CGFloat, time: @escaping (CGFloat) -> Double) -> some View {
        let segs = model.project.segments
        let first = segs.first?.start ?? 0, last = segs.last?.end ?? model.sourceDuration
        return ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                ForEach(Array(model.thumbnails.enumerated()), id: \.offset) { _, img in
                    Image(nsImage: img).resizable().scaledToFill().frame(width: w / CGFloat(model.thumbnails.count), height: trackH).clipped()
                }
            }
            .frame(width: w, height: trackH, alignment: .leading)
            .background(Color.gray.opacity(0.25))
            .accessibilityHidden(true)

            // Removed stretches are dimmed; kept ones get an outline (accent when selected).
            ForEach(gaps(segs), id: \.0) { g in
                Rectangle().fill(Color.black.opacity(0.65)).frame(width: x(g.1 - g.0), height: trackH).offset(x: x(g.0))
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            ForEach(Array(segs.enumerated()), id: \.element.id) { i, s in
                let selected = model.selectedSegment == s.id
                Rectangle().stroke(selected ? Color.accentColor : Color.white.opacity(0.6), lineWidth: selected ? 3 : 1)
                    .frame(width: max(x(s.duration), 1), height: trackH).offset(x: x(s.start))
                    .allowsHitTesting(false)
                    .accessibilityElement()
                    .accessibilityLabel(Text("Segmento \(i + 1)"))
                    .accessibilityValue(Text("de \(formatTime(s.start)) a \(formatTime(s.end))"))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityAction(.default) { model.selectedSegment = s.id; model.selectedZoom = nil; model.seek(to: s.start) }
                    .accessibilityAction(named: Text("Eliminar tramo")) { model.apply(.deleteSegment(s.id)) }
            }
        }
        .frame(width: w, height: trackH, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { v in model.isScrubbing = true; model.seek(to: time(v.location.x), exact: false) }
            .onEnded { v in
                model.isScrubbing = false
                let t = time(v.location.x)
                model.seek(to: t)
                model.selectedZoom = nil
                model.selectedSegment = segs.first { t >= $0.start && t <= $0.end }?.id
            })
        .overlay(alignment: .topLeading) {
            trimHandle(at: trimStartDraft ?? first, x: x, label: "Recortar inicio",
                       drag: { trimStartDraft = min(time($0), last - 0.2) },
                       end: { if let t = trimStartDraft { model.apply(.trimStart(to: t)) }; trimStartDraft = nil },
                       step: { model.apply(.trimStart(to: first + $0)) })
            trimHandle(at: trimEndDraft ?? last, x: x, label: "Recortar final",
                       drag: { trimEndDraft = max(time($0), first + 0.2) },
                       end: { if let t = trimEndDraft { model.apply(.trimEnd(to: t)) }; trimEndDraft = nil },
                       step: { model.apply(.trimEnd(to: last - $0)) })
        }
    }

    private func gaps(_ segs: [VideoSegment]) -> [(Double, Double)] {
        var out: [(Double, Double)] = []
        var cursor = 0.0
        for s in segs { if s.start > cursor + 0.001 { out.append((cursor, s.start)) }; cursor = s.end }
        if model.sourceDuration > cursor + 0.001 { out.append((cursor, model.sourceDuration)) }
        return out
    }

    private func trimHandle(at t: Double, x: @escaping (Double) -> CGFloat, label: LocalizedStringKey,
                            drag: @escaping (CGFloat) -> Void, end: @escaping () -> Void, step: @escaping (Double) -> Void) -> some View {
        Capsule().fill(Color.yellow).frame(width: 8, height: trackH)
            .overlay(Capsule().stroke(.black.opacity(0.5), lineWidth: 1))
            .offset(x: x(t) - 4)
            .gesture(DragGesture(coordinateSpace: .named("track")).onChanged { drag($0.location.x) }.onEnded { _ in end() })
            .accessibilityElement()
            .accessibilityLabel(Text(label))
            .accessibilityAdjustableAction { direction in if direction == .increment { step(1) } else { step(-1) } }
            .help(label)
    }

    private func zoomTrack(w: CGFloat, x: @escaping (Double) -> CGFloat, time: @escaping (CGFloat) -> Double) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.gray.opacity(0.15)).frame(width: w, height: zoomH)
                .onTapGesture { model.selectedZoom = nil }
                .accessibilityHidden(true)
            ForEach(model.project.zooms) { k in
                let t = zoomDrag?.id == k.id ? zoomDrag!.time : k.time
                let selected = model.selectedZoom == k.id
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.accentColor.opacity(0.25)).frame(width: max(x(k.duration), 6), height: 8)
                    Image(systemName: k.rect == .full ? "arrow.down.right.and.arrow.up.left.circle.fill" : "magnifyingglass.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(selected ? Color.accentColor : (k.auto ? Color.orange : Color.primary))
                        .offset(x: -10)
                }
                .offset(x: x(t))
                .contentShape(Rectangle().inset(by: -4))
                .onTapGesture {
                    model.selectedZoom = k.id; model.selectedSegment = nil
                    model.seek(to: k.time)
                }
                .gesture(DragGesture(coordinateSpace: .named("track"))
                    .onChanged { zoomDrag = (k.id, time($0.location.x)) }
                    .onEnded { v in
                        var moved = k; moved.time = time(v.location.x); zoomDrag = nil
                        if abs(moved.time - k.time) > 0.01 { model.apply(.updateZoom(moved)) }
                    })
                .accessibilityElement()
                .accessibilityLabel(Text(k.rect == .full ? LocalizedStringKey("Zoom: volver a la vista completa") : LocalizedStringKey("Zoom")))
                .accessibilityValue(Text("en \(formatTime(k.time))"))
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityAction(.default) { model.selectedZoom = k.id; model.selectedSegment = nil; model.seek(to: k.time) }
                .accessibilityAction(named: Text("Eliminar zoom")) { model.apply(.removeZoom(k.id)) }
                .accessibilityAdjustableAction { d in
                    var moved = k; moved.time = min(max(k.time + (d == .increment ? 0.1 : -0.1), 0), model.sourceDuration)
                    model.apply(.updateZoom(moved))
                }
            }
        }
        .frame(width: w, height: zoomH, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Pista de zooms"))
    }
}

// MARK: - Inspector

struct VideoInspector: View {
    @ObservedObject var model: VideoEditorModel
    private static let speeds: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2, 4]

    var body: some View {
        Form {
            Section("Velocidad") {
                let speeds = Self.speeds.contains(model.project.speed) ? Self.speeds : (Self.speeds + [model.project.speed]).sorted()
                Picker("Velocidad", selection: Binding(get: { model.project.speed }, set: { model.apply(.setSpeed($0)) })) {
                    ForEach(speeds, id: \.self) { Text("\($0.formatted())×").tag($0) }
                }
            }
            Section("Zoom") {
                Button("Añadir zoom en el cabezal") { model.addZoom() }
                Button("Zoom automático por clics") { model.suggestZooms() }
                    .disabled(model.clicks == nil)
                    .help(model.clicks == nil ? Text("Esta grabación no tiene registro de clics") : Text("Sugiere zooms a partir de los clics; puedes moverlos o borrarlos"))
                if let k = model.project.zooms.first(where: { $0.id == model.selectedZoom }) {
                    Stepper(value: Binding(get: { k.duration }, set: { var n = k; n.duration = $0; model.apply(.updateZoom(n)) }), in: 0.1...5, step: 0.1) {
                        Text("Transición: \(k.duration.formatted(.number.precision(.fractionLength(1)))) s")
                    }
                    Picker("Curva", selection: Binding(get: { k.curve }, set: { var n = k; n.curve = $0; model.apply(.updateZoom(n)) })) {
                        Text("Suave (ease in-out)").tag(ZoomCurve.easeInOut)
                        Text("Lineal").tag(ZoomCurve.linear)
                    }
                    Button("Volver a la vista completa aquí") { var n = k; n.rect = .full; model.apply(.updateZoom(n)) }
                    Button("Eliminar zoom", role: .destructive) { model.apply(.removeZoom(k.id)) }
                    Text("Arrastra el rectángulo sobre la vista previa para ajustarlo.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Seguimiento del cursor") { FollowControl(model: model) }
            Section("Recorte") { CropControls(model: model) }
            Section("Silencios") { MuteControls(model: model) }
            Section("Rótulos") { CaptionControls(model: model) }
            if model.audioTrackCount > 0 {
                Section("Audio") {
                    if model.audioTrackCount == 2 {
                        Picker("Canales de salida", selection: Binding(get: { model.project.audioSelection }, set: { model.apply(.setAudioSelection($0)) })) {
                            Text("Sistema y micrófono").tag(AudioSelection.both)
                            Text("Solo sistema").tag(AudioSelection.system)
                            Text("Solo micrófono").tag(AudioSelection.microphone)
                        }
                    }
                    ForEach(0..<min(model.audioTrackCount, model.project.audio.count), id: \.self) { AudioRow(model: model, index: $0) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct FollowControl: View {
    @ObservedObject var model: VideoEditorModel
    @State private var value = 0.0

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Slider(value: $value, in: 0...1) { editing in
                    if !editing { model.apply(.setFollow(value)) }
                }
                .accessibilityLabel(Text("Intensidad del seguimiento"))
                .accessibilityValue(Text(value == 0 ? String(localized: "Desactivado") : "\(Int(value * 100)) %"))
                Text(value == 0 ? String(localized: "No") : "\(Int(value * 100)) %").font(.caption).monospacedDigit().frame(width: 40, alignment: .trailing)
            }
            .disabled(!model.hasCursorTrack)
            Text(model.hasCursorTrack ? "La vista sigue al cursor grabado; con un zoom activo se mueve dentro de él."
                                      : "Esta grabación no tiene registro del cursor.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { value = model.project.followIntensity }
        .onChange(of: model.project.followIntensity) { _, v in value = v } // undo/redo
    }
}

private struct CropControls: View {
    @ObservedObject var model: VideoEditorModel

    private enum Side { case left, top, right, bottom }

    private func percent(_ side: Side) -> Int {
        let c = model.project.crop
        let v: Double = switch side { case .left: c.x; case .top: c.y; case .right: 1 - c.x - c.width; case .bottom: 1 - c.y - c.height }
        return Int((v * 100).rounded())
    }

    private func set(_ side: Side, _ pct: Int) {
        var l = Double(percent(.left)) / 100, t = Double(percent(.top)) / 100, r = Double(percent(.right)) / 100, b = Double(percent(.bottom)) / 100
        let v = Double(pct) / 100
        switch side { case .left: l = v; case .top: t = v; case .right: r = v; case .bottom: b = v }
        model.apply(.setCrop(NormalizedRect(x: l, y: t, width: 1 - l - r, height: 1 - t - b)))
    }

    private func stepper(_ title: String, _ side: Side) -> some View {
        Stepper(value: Binding(get: { percent(side) }, set: { set(side, $0) }), in: 0...45) {
            Text("\(title): \(percent(side)) %")
        }
    }

    var body: some View {
        stepper(String(localized: "Izquierda"), .left)
        stepper(String(localized: "Arriba"), .top)
        stepper(String(localized: "Derecha"), .right)
        stepper(String(localized: "Abajo"), .bottom)
        Button("Quitar recorte") { model.apply(.setCrop(.full)) }.disabled(model.project.crop == .full)
        Text("Máscara de la salida: la vista previa y la exportación solo muestran el área recortada.").font(.caption).foregroundStyle(.secondary)
    }
}

private struct MuteControls: View {
    @ObservedObject var model: VideoEditorModel

    var body: some View {
        Button("Silenciar tramo seleccionado o 3 s desde el cabezal") { model.addMute() }
            .disabled(model.audioTrackCount == 0)
        ForEach(model.project.mutes) { m in
            HStack {
                Image(systemName: "speaker.slash").accessibilityHidden(true)
                Text("\(formatTime(m.start)) – \(formatTime(m.end))").font(.caption).monospacedDigit()
                Spacer()
                Button { model.seek(to: m.start) } label: { Image(systemName: "arrow.right.to.line") }
                    .accessibilityLabel(Text("Ir al silencio")).help("Ir al inicio del silencio")
                Button { model.apply(.removeMute(m.id)) } label: { Image(systemName: "trash") }
                    .accessibilityLabel(Text("Quitar silencio")).help("Quitar silencio")
            }
            .buttonStyle(.borderless)
        }
    }
}

private struct CaptionControls: View {
    @ObservedObject var model: VideoEditorModel

    var body: some View {
        Button("Añadir rótulo en el cabezal") { model.addCaption() }
        ForEach(model.project.captions) { c in
            Button { model.selectedCaption = c.id; model.seek(to: c.start) } label: {
                HStack {
                    Image(systemName: "textformat").accessibilityHidden(true)
                    Text(c.text).lineLimit(1)
                    Spacer()
                    Text(formatTime(c.start)).font(.caption).monospacedDigit()
                }
            }
            .buttonStyle(.borderless)
            .accessibilityAddTraits(model.selectedCaption == c.id ? .isSelected : [])
        }
        if let c = model.project.captions.first(where: { $0.id == model.selectedCaption }) {
            CaptionEditor(model: model, caption: c).id(c.id)
        }
    }
}

private struct CaptionEditor: View {
    @ObservedObject var model: VideoEditorModel
    let caption: VideoCaption
    @State private var text = ""
    @State private var x = 0.5
    @State private var y = 0.88
    @State private var size = 0.06

    private func commit() {
        var c = caption
        c.text = text.isEmpty ? caption.text : text
        c.x = x; c.y = y; c.size = size
        model.apply(.updateCaption(c))
    }

    var body: some View {
        TextField("Texto del rótulo", text: $text).onSubmit(commit).accessibilityLabel(Text("Texto del rótulo"))
        slider("Posición horizontal", $x, 0...1)
        slider("Posición vertical", $y, 0...1)
        slider("Tamaño del texto", $size, VideoCaption.sizeRange)
        Stepper(value: Binding(get: { caption.end - caption.start }, set: { d in
            var c = caption; c.end = min(caption.start + d, model.sourceDuration); model.apply(.updateCaption(c))
        }), in: 0.5...30, step: 0.5) {
            Text("Duración: \((caption.end - caption.start).formatted(.number.precision(.fractionLength(1)))) s")
        }
        HStack {
            Button("Aplicar texto") { commit() }
            Spacer()
            Button("Eliminar rótulo", role: .destructive) { model.apply(.removeCaption(caption.id)) }
        }
        .onAppear { text = caption.text; x = caption.x; y = caption.y; size = caption.size }
        .onChange(of: caption) { _, c in text = c.text; x = c.x; y = c.y; size = c.size } // undo/redo
    }

    private func slider(_ title: LocalizedStringKey, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        Slider(value: value, in: range) { editing in if !editing { commit() } } label: { Text(title) }
            .accessibilityLabel(Text(title))
    }
}

private struct AudioRow: View {
    @ObservedObject var model: VideoEditorModel
    let index: Int
    @State private var gain = 1.0

    private var settings: AudioTrackSettings { model.project.audio[index] }
    private var title: LocalizedStringKey { model.audioTrackCount == 1 ? "Audio" : (index == 0 ? "Audio del sistema" : "Micrófono") }

    var body: some View {
        VStack(alignment: .leading) {
            Toggle(isOn: Binding(get: { settings.muted }, set: { var s = settings; s.muted = $0; model.apply(.setAudio(index: index, s)) })) { Text(title) }
                .accessibilityLabel(Text("Silenciar")).accessibilityValue(Text(title))
            HStack {
                Image(systemName: "speaker.wave.2").accessibilityHidden(true)
                Slider(value: $gain, in: 0...2) { editing in
                    if !editing { var s = settings; s.gain = gain; model.apply(.setAudio(index: index, s)) }
                }
                .accessibilityLabel(Text("Volumen")).accessibilityValue(Text("\(Int(gain * 100)) %"))
                Text("\(Int(gain * 100)) %").font(.caption).monospacedDigit().frame(width: 40, alignment: .trailing)
            }
            .disabled(settings.muted)
            Stepper(value: Binding(get: { settings.fadeIn }, set: { var s = settings; s.fadeIn = $0; model.apply(.setAudio(index: index, s)) }), in: 0...10, step: 0.5) {
                Text("Fundido de entrada: \(settings.fadeIn.formatted()) s")
            }
            Stepper(value: Binding(get: { settings.fadeOut }, set: { var s = settings; s.fadeOut = $0; model.apply(.setAudio(index: index, s)) }), in: 0...10, step: 0.5) {
                Text("Fundido de salida: \(settings.fadeOut.formatted()) s")
            }
        }
        .onAppear { gain = settings.gain }
        .onChange(of: settings.gain) { _, g in gain = g } // undo/redo
    }
}

// MARK: - Export

private struct ExportSheet: View {
    @ObservedObject var model: VideoEditorModel
    private enum Choice: Hashable { case tutorial, messaging, highQuality, reducedSize, custom }
    @State private var choice = Choice.tutorial
    @State private var height = 1080
    @State private var mbps = 8.0
    @State private var options = ExportOptions()
    @State private var fpsChoice = 0 // 0 = same as the source
    private let hevcAvailable = VideoCodec.hevc.isSupported(width: 1920, height: 1080)

    private var preset: ExportPreset {
        switch choice {
        case .tutorial: .tutorial
        case .messaging: .messaging
        case .highQuality: .highQuality
        case .reducedSize: .reducedSize
        case .custom: .custom(maxHeight: height, videoBitrate: Int(mbps * 1_000_000))
        }
    }

    /// Codec, container and frame rate only apply to Personalizado; the named presets stay H.264 MP4 at the source rate.
    private var exportOptions: ExportOptions {
        choice == .custom ? ExportOptions(codec: options.codec, container: options.container, fps: fpsChoice == 0 ? nil : fpsChoice) : ExportOptions()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Exportar vídeo").font(.headline)
            if let phase = model.exportPhase {
                ProgressView(value: model.exportProgress) { Text(label(phase)) }
                    .accessibilityValue(Text("\(Int(model.exportProgress * 100)) %"))
                HStack { Spacer(); Button("Cancelar exportación") { model.cancelExport() } }
            } else {
                Picker("Preset", selection: $choice) {
                    Text("Tutorial").tag(Choice.tutorial)
                    Text("Mensajería").tag(Choice.messaging)
                    Text("Alta calidad").tag(Choice.highQuality)
                    Text("Peso reducido").tag(Choice.reducedSize)
                    Text("Personalizado").tag(Choice.custom)
                }
                .onChange(of: choice) { _, c in
                    if c != .custom { height = preset.maxHeight ?? Int(model.videoSize.height); mbps = Double(preset.videoBitrate) / 1_000_000 }
                }
                if choice == .custom {
                    HStack {
                        TextField("Alto máximo (px)", value: $height, format: .number)
                        TextField("Bitrate de vídeo (Mbps)", value: $mbps, format: .number)
                    }
                    if !preset.isValid { Text("Alto entre 120 y 4320 px, bitrate entre 0,1 y 100 Mbps.").font(.caption).foregroundStyle(.red) }
                    Picker("Códec", selection: $options.codec) {
                        Text("H.264").tag(VideoCodec.h264)
                        if hevcAvailable { Text("HEVC").tag(VideoCodec.hevc) }
                    }
                    Picker("Contenedor", selection: $options.container) {
                        Text("MP4").tag(VideoContainer.mp4)
                        Text("MOV").tag(VideoContainer.mov)
                    }
                    Picker("Fotogramas por segundo", selection: $fpsChoice) {
                        Text("Como el original").tag(0)
                        ForEach([15, 24, 30, 60], id: \.self) { Text("\($0)").tag($0) }
                    }
                    if !hevcAvailable { Text("Este Mac no admite HEVC: se exportará en H.264.").font(.caption).foregroundStyle(.secondary) }
                }
                let size = preset.outputSize(width: Int(model.outputSize.width), height: Int(model.outputSize.height))
                Text("\(size.width)×\(size.height) · tamaño aproximado \(ByteCountFormatter.string(fromByteCount: preset.estimatedBytes(duration: model.outputDuration), countStyle: .file))")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancelar") { model.showExportSheet = false }.keyboardShortcut(.cancelAction)
                    Button("Exportar") { model.export(preset: preset, options: exportOptions) }
                        .keyboardShortcut(.defaultAction).disabled(!preset.isValid)
                }
            }
        }
        .padding(20)
        .frame(width: 400)
        .interactiveDismissDisabled(model.exportPhase != nil)
    }

    private func label(_ p: ExportPhase) -> LocalizedStringKey {
        switch p {
        case .queued: "En cola"
        case .preparing: "Preparando…"
        case .encoding: "Codificando…"
        case .writing: "Escribiendo el archivo…"
        case .validating: "Validando…"
        case .completed: "Completada"
        case .cancelled: "Cancelada"
        case .failed: "Error"
        }
    }
}

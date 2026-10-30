import RadioDSP
import SwiftUI

@main
struct EnhancedFMApp: App {
    @StateObject private var radio = Radio()

    init() {
        signal(SIGPIPE, SIG_IGN) // writing IQ to an exited nrsc5 must not kill the app
    }

    var body: some Scene {
        WindowGroup("EnhancedFM") {
            ContentView(radio: radio)
                .frame(minWidth: 900, minHeight: 640)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    radio.stop()
                }
        }
        .windowResizability(.contentMinSize)
    }
}

/// RBDS (North America) programme types.
let ptyNames = ["None", "News", "Information", "Sports", "Talk", "Rock", "Classic Rock", "Adult Hits", "Soft Rock",
                "Top 40", "Country", "Oldies", "Soft", "Nostalgia", "Jazz", "Classical", "R&B", "Soft R&B", "Language",
                "Religious Music", "Religious Talk", "Personality", "Public", "College", "", "", "", "", "",
                "Weather", "Emergency Test", "Emergency"]

struct ContentView: View {
    @ObservedObject var radio: Radio

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Band", selection: $radio.band) {
                    ForEach(Band.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
                Spacer()
                Text(radio.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
            if radio.band == .fm { fmScreen } else { weatherScreen }
        }
        .padding()
        .onChange(of: radio.band) { retune() }
        .onChange(of: radio.rdsOn) { retune() }
        .onChange(of: radio.hdOn) { retune() }
        .onChange(of: radio.hdProgram) { retune() }
        .onChange(of: radio.scaOn) { retune() }
        .onChange(of: radio.scaKHz) { retune() }
        .onChange(of: radio.wxChannel) { retune() }
    }

    func retune() { radio.retune() }

    var playButton: some View {
        Button {
            radio.playing ? radio.stop() : radio.play()
        } label: {
            Label(radio.playing ? "Stop" : "Play", systemImage: radio.playing ? "stop.fill" : "play.fill")
                .frame(width: 70)
        }
        .keyboardShortcut(.space, modifiers: [])
        .controlSize(.large)
        .disabled(radio.scanning)
    }

    /// Rescan button plus what seek is currently looking for.
    var seekInfo: some View {
        HStack(spacing: 8) {
            Button("Rescan") { radio.scan() }
            if radio.scanning { ProgressView().controlSize(.small) }
            let target = radio.seekTarget
            Text(radio.found[target].map { "Seek: \($0.count) \(target.label)" } ?? "Seek: \(target.label)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    var volume: some View {
        HStack {
            Image(systemName: "speaker.wave.2").accessibilityHidden(true)
            Slider(value: $radio.volume, in: 0...1) { Text("Volume") }
                .labelsHidden()
                .frame(width: 140)
        }
    }

    // MARK: FM

    var fmScreen: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button { radio.seek(up: false) } label: { Image(systemName: "backward.end.fill") }
                    .help("Seek down").accessibilityLabel("Seek down")
                Button { radio.step(-0.2) } label: { Image(systemName: "chevron.left") }
                    .help("Down 0.2 MHz").accessibilityLabel("Tune down")
                TextField("Frequency", value: $radio.freq, format: .number.precision(.fractionLength(1)))
                    .frame(width: 64)
                    .multilineTextAlignment(.trailing)
                    .onSubmit(retune)
                Text("MHz")
                Button { radio.step(0.2) } label: { Image(systemName: "chevron.right") }
                    .help("Up 0.2 MHz").accessibilityLabel("Tune up")
                Button { radio.seek(up: true) } label: { Image(systemName: "forward.end.fill") }
                    .help("Seek up").accessibilityLabel("Seek up")
                seekInfo
                Spacer()
                playButton
                volume
            }
            .disabled(radio.scanning)

            HStack(spacing: 16) {
                Toggle("RDS", isOn: $radio.rdsOn)
                HStack(spacing: 4) {
                    Toggle("HD Radio", isOn: $radio.hdOn)
                        .help("Plays analog FM and switches to the digital HD stream when the station has one")
                    Picker("HD program", selection: $radio.hdProgram) {
                        ForEach(0..<4) { Text("HD\($0 + 1)").tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 80)
                    .disabled(!radio.hdOn)
                }
                HStack(spacing: 4) {
                    Toggle("SCA subcarrier", isOn: $radio.scaOn)
                    Picker("SCA subcarrier", selection: $radio.scaKHz) {
                        Text("67 kHz").tag(67.0)
                        Text("92 kHz").tag(92.0)
                    }
                    .labelsHidden()
                    .frame(width: 90)
                    .disabled(!radio.scaOn)
                }
                Toggle("Online album art", isOn: $radio.artLookup)
            }
            .toggleStyle(.checkbox)

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 12) {
                    nowPlaying
                    if radio.scaOn {
                        GroupBox("FM multiplex spectrum") {
                            SpectrumView(db: radio.spectrum, maxKHz: radio.spectrumMaxKHz, marker: radio.scaKHz)
                                .frame(minHeight: 140, maxHeight: .infinity)
                        }
                    }
                    if radio.hdDetected { hdServices }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                if radio.rdsOn || radio.hdDetected {
                    VStack(spacing: 12) {
                        if radio.rdsOn {
                            GroupBox("RDS groups  (type · A B C D · content)") { PacketLog(lines: radio.rdsPackets) }
                        }
                        if radio.hdDetected {
                            GroupBox("HD Radio packets") { PacketLog(lines: radio.hdPackets) }
                        }
                    }
                    .frame(minWidth: 340, idealWidth: 420, maxWidth: 520, maxHeight: .infinity)
                }
            }
        }
    }

    var nowPlaying: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 16) {
                Group {
                    if let art = radio.artwork {
                        Image(nsImage: art).resizable().scaledToFit()
                    } else {
                        RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                            .overlay(Image(systemName: "music.note").font(.largeTitle).foregroundStyle(.secondary))
                    }
                }
                .frame(width: 160, height: 160)
                .accessibilityLabel("Album art")

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(String(format: "%.1f", radio.freq))
                            .font(.system(size: 44, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        if let call = radio.callSign { Text(call).font(.title2.bold()) }
                        Spacer()
                        if let logo = radio.stationLogo {
                            Image(nsImage: logo).resizable().scaledToFit().frame(height: 48)
                                .accessibilityLabel("Station logo")
                        }
                    }
                    HStack(spacing: 6) {
                        if !radio.stationName.isEmpty {
                            Text(radio.stationName).font(.system(.title2, design: .monospaced))
                        }
                        if radio.stereo { Badge("STEREO") }
                        if radio.hdAudio { Badge("HD\(radio.hdProgram + 1)") }
                        if radio.scaOn { Badge("SCA \(Int(radio.scaKHz))k") }
                    }
                    if let alert = radio.hdAlert {
                        Label(alert, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).bold()
                    }
                    Text(radio.nowPlaying).font(.title3).lineLimit(3)
                    if let album = radio.hd["Album"] { Text(album).foregroundStyle(.secondary) }
                    HStack(spacing: 12) {
                        if radio.rds.pi != nil { Text(ptyNames[radio.rds.pty]) }
                        if let pi = radio.rds.pi { Text("PI \(String(format: "%04X", pi))") }
                        if let s = radio.hd["Slogan"] { Text(s) }
                        if let b = radio.hd["Audio bit rate"] { Text(b) }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    var hdServices: some View {
        HStack(alignment: .top, spacing: 12) {
            GroupBox("Traffic") {
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    ForEach(0..<3, id: \.self) { r in
                        GridRow {
                            ForEach(0..<3, id: \.self) { c in
                                if let tile = radio.trafficTiles[r][c] {
                                    Image(nsImage: tile).resizable().aspectRatio(1, contentMode: .fit)
                                } else {
                                    Rectangle().fill(.quaternary).aspectRatio(1, contentMode: .fit)
                                }
                            }
                        }
                    }
                }
                .accessibilityLabel("Traffic map")
            }
            GroupBox("Weather radar") {
                Group {
                    if let wx = radio.weatherRadar {
                        Image(nsImage: wx).resizable().scaledToFit().background(Color.black)
                    } else {
                        Rectangle().fill(.quaternary)
                            .overlay(Text("Waiting for data — not every station sends traffic or weather")
                                .font(.caption).foregroundStyle(.secondary).padding())
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .accessibilityLabel("Weather radar")
            }
        }
        .frame(maxHeight: 420)
    }

    // MARK: Weather

    var weatherScreen: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Picker("Channel", selection: $radio.wxChannel) {
                    ForEach(weatherChannels.indices, id: \.self) { i in
                        Text(String(format: "WX%d  %.3f MHz", i + 1, weatherChannels[i])).tag(weatherChannels[i])
                    }
                }
                .frame(width: 260)
                Button { radio.seek(up: false) } label: { Image(systemName: "backward.end.fill") }
                    .help("Previous active channel").accessibilityLabel("Seek down")
                Button { radio.seek(up: true) } label: { Image(systemName: "forward.end.fill") }
                    .help("Next active channel").accessibilityLabel("Seek up")
                seekInfo
                Spacer()
                playButton
                volume
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Text("NOAA Weather Radio").font(.largeTitle.bold())
                    Text(String(format: "%.3f MHz", radio.wxChannel)).font(.title2).monospacedDigit()
                    Text("Try each channel; usually only one or two are receivable nearby.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer()
        }
    }
}

struct Badge: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption.bold())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.tint.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(.tint)
    }
}

/// Scrolling monospaced log that follows the newest line.
struct PacketLog: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(lines.indices, id: \.self) { i in
                        Text(lines[i]).font(.system(size: 11, design: .monospaced)).lineLimit(1).id(i)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .frame(minHeight: 120, maxHeight: .infinity)
            .onChange(of: lines.count) { proxy.scrollTo(lines.count - 1, anchor: .bottom) }
        }
    }
}

/// MPX spectrum with the usual FM landmarks and the selected subcarrier marked.
struct SpectrumView: View {
    let db: [Float]
    let maxKHz: Double
    let marker: Double // kHz

    var body: some View {
        Canvas { ctx, size in
            func x(_ khz: Double) -> CGFloat { size.width * khz / maxKHz }
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
            for (khz, label) in [(19.0, "pilot"), (38.0, "L−R"), (57.0, "RDS"), (67.0, "67"), (92.0, "92")] {
                ctx.stroke(Path { $0.move(to: CGPoint(x: x(khz), y: 0)); $0.addLine(to: CGPoint(x: x(khz), y: size.height)) },
                           with: .color(.gray.opacity(0.4)), lineWidth: 1)
                ctx.draw(Text(label).font(.system(size: 9)).foregroundColor(.gray), at: CGPoint(x: x(khz) + 2, y: 8), anchor: .leading)
            }
            ctx.stroke(Path { $0.move(to: CGPoint(x: x(marker), y: 0)); $0.addLine(to: CGPoint(x: x(marker), y: size.height)) },
                       with: .color(.orange), lineWidth: 2)
            guard let top = db.max(), db.count > 1 else { return }
            let range: Float = 80 // dB shown
            var path = Path()
            for (i, v) in db.enumerated() {
                let p = CGPoint(x: size.width * CGFloat(i) / CGFloat(db.count - 1),
                                y: size.height * CGFloat(min(max((top - v) / range, 0), 1)))
                i == 0 ? path.move(to: p) : path.addLine(to: p)
            }
            ctx.stroke(path, with: .color(.green), lineWidth: 1)
        }
        .accessibilityLabel("Multiplex spectrum")
    }
}

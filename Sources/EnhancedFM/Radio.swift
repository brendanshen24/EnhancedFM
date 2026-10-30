import AppKit
import AVFoundation
import Foundation
import os
import RadioDSP

enum Band: String, CaseIterable, Identifiable {
    case fm = "FM", weather = "Weather"
    var id: Self { self }
}

/// What seek looks for: it follows the band and the options that are switched on.
/// HD isn't a target: every FM station is analog first and upgrades to HD when nrsc5 locks on.
enum SeekTarget: Hashable {
    case fm, sca(Double), weather
    var label: String {
        switch self {
        case .fm: "FM stations"
        case .sca(let k): "stations with \(Int(k)) kHz SCA"
        case .weather: "weather channels"
        }
    }
}

/// Probe one capture of a tuned FM station for the target's signal.
func probe(_ iq: [UInt8], rate: Double, for target: SeekTarget) -> Bool {
    switch target {
    case .sca(let k):
        let d = FMDemod(inputRate: rate, decim: 6, cutoff: 110_000, deviation: 75_000)
        return hasSubcarrier(mpx: d.process(iq), sampleRate: d.outputRate, kHz: k)
    case .fm, .weather:
        return true
    }
}

/// NOAA Weather Radio channels WX1–WX7 (MHz).
let weatherChannels = [162.550, 162.400, 162.475, 162.425, 162.450, 162.500, 162.525]

/// Pull-model stereo output fed from a jitter buffer.
final class AudioOut {
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private let lock = NSLock()
    private var buf: [Float] = [], head = 0, primed = false, rate = 48_000.0

    var volume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = newValue }
    }

    func start(rate: Double) throws {
        stop()
        self.rate = rate
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let node = AVAudioSourceNode(format: format) { [unowned self] _, _, frames, abl in
            let ch = UnsafeMutableAudioBufferListPointer(abl)
            let l = ch[0].mData!.assumingMemoryBound(to: Float.self), r = ch[1].mData!.assumingMemoryBound(to: Float.self)
            lock.lock()
            if !primed { primed = buf.count - head >= Int(self.rate * 0.3) * 2 } // 300 ms prebuffer
            for f in 0..<Int(frames) {
                if primed && head + 1 < buf.count {
                    l[f] = buf[head]; r[f] = buf[head + 1]; head += 2
                } else {
                    l[f] = 0; r[f] = 0; primed = false
                }
            }
            if head > 1 << 16 { buf.removeFirst(head); head = 0 }
            lock.unlock()
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        source = node
        try engine.start()
    }

    func write(_ samples: [Float]) {
        lock.lock()
        buf += samples
        let max = Int(rate) * 2 // drop audio beyond ~1 s of backlog (SDR clock runs faster than the sound card)
        if buf.count - head > max { head = buf.count - max / 2 }
        lock.unlock()
    }

    func stop() {
        engine.stop()
        if let source { engine.detach(source) }
        source = nil
        lock.lock(); buf = []; head = 0; primed = false; lock.unlock()
    }
}

/// Splits a pipe's output into lines.
final class LineReader {
    private var text = ""
    func feed(_ d: Data) -> [String] {
        text += String(decoding: d, as: UTF8.self)
        var lines: [String] = []
        while let nl = text.firstIndex(of: "\n") {
            let line = text[..<nl].trimmingCharacters(in: .whitespaces)
            text.removeSubrange(...nl)
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }
}

@MainActor final class Radio: ObservableObject {
    static let fmIQRate = 1_488_375.0 // nrsc5's input rate, so one IQ stream serves analog and HD

    // Controls
    @Published var band = Band.fm
    @Published var freq = 98.5
    @Published var wxChannel = weatherChannels[0]
    @Published var rdsOn = true
    @Published var hdOn = true // upgrade to HD automatically when the station has it
    @Published var hdProgram = 0
    @Published var scaOn = false
    @Published var scaKHz = 67.0
    @Published var artLookup = true
    @Published var volume: Float = 0.8 { didSet { analogOut.volume = volume; hdOut.volume = volume } }

    // State
    @Published private(set) var playing = false
    @Published private(set) var scanning = false
    @Published private(set) var status = "Stopped"
    @Published private(set) var found: [SeekTarget: [Double]] = [:] // scan results, per seek target
    @Published private(set) var stereo = false
    @Published private(set) var hdAudio = false
    @Published private(set) var hdDetected = false // nrsc5 has synchronized to a digital signal
    @Published private(set) var rds = RDSInfo()
    @Published private(set) var rdsPackets: [String] = []
    @Published private(set) var hd: [String: String] = [:]
    @Published private(set) var hdPackets: [String] = []
    @Published private(set) var hdAlert: String?
    @Published private(set) var spectrum: [Float] = []
    @Published private(set) var spectrumMaxKHz = 124.0
    @Published private(set) var trafficTiles = [[NSImage?]](repeating: [nil, nil, nil], count: 3)
    @Published private(set) var weatherRadar: NSImage?
    @Published private(set) var stationLogo: NSImage?
    @Published private(set) var hdArt: NSImage?
    @Published private(set) var onlineArt: NSImage?

    var artwork: NSImage? { hdArt ?? onlineArt }
    var stationName: String {
        hd["Station name"] ?? (rds.ps.trimmingCharacters(in: .whitespaces).isEmpty ? "" : rds.ps)
    }
    var callSign: String? { rds.pi.flatMap(rbdsCallSign) }
    var nowPlaying: String {
        if let t = hd["Title"] { return [t, hd["Artist"]].compactMap { $0 }.joined(separator: " — ") }
        return rds.rt
    }

    private var procs: [Process] = []
    private var scanTask: Task<Void, Never>?

    private struct Tuning: Equatable {
        var band: Band, freq: Double, wx: Double, rds: Bool, hd: Bool, program: Int, sca: Bool, scaKHz: Double
    }
    private var tuning: Tuning {
        Tuning(band: band, freq: freq, wx: wxChannel, rds: rdsOn, hd: hdOn, program: hdProgram, sca: scaOn, scaKHz: scaKHz)
    }
    private var tunedTo: Tuning?
    var seekTarget: SeekTarget { band == .weather ? .weather : scaOn ? .sca(scaKHz) : .fm }
    private let analogOut = AudioOut(), hdOut = AudioOut()
    private var aasDir: URL?
    private var artQuery = ""
    private var artTask: Task<Void, Never>?

    static func tool(_ name: String) -> String? {
        ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"].map { "\($0)/\(name)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Starts a command-line tool; stdout goes to `onData`, stderr lines to `onLines` (both off the main thread).
    private func launch(_ name: String, _ args: [String], stdin: Pipe? = nil,
                        onData: @escaping @Sendable (Data) -> Void,
                        onLines: @escaping @Sendable ([String]) -> Void,
                        onExit: (@Sendable (Process) -> Void)? = nil) -> Process? {
        guard let path = Self.tool(name) else {
            status = "\(name) not found — install with: brew install \(name == "nrsc5" ? "nrsc5" : "librtlsdr")"
            return nil
        }
        let p = Process(), out = Pipe(), err = Pipe(), reader = LineReader()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = out
        p.standardError = err
        if let stdin { p.standardInput = stdin }
        p.terminationHandler = onExit // set before run() so an instant exit is still seen
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { onData(d) }
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            let lines = reader.feed(d)
            if !lines.isEmpty { onLines(lines) }
        }
        do { try p.run() } catch {
            status = "Failed to launch \(name): \(error.localizedDescription)"
            return nil
        }
        procs.append(p)
        return p
    }

    /// Restart only if a setting that affects the running pipeline changed.
    func retune() { if playing && tuning != tunedTo { play() } }

    func play() {
        stop()
        tunedTo = tuning
        resetDisplay()
        band == .fm ? playFM() : playWeather()
    }

    private func resetDisplay() {
        stereo = false
        hdAudio = false
        hdDetected = false
        rds = RDSInfo()
        rdsPackets = []
        hd = [:]
        hdPackets = []
        hdAlert = nil
        spectrum = []
        trafficTiles = [[NSImage?]](repeating: [nil, nil, nil], count: 3)
        weatherRadar = nil
        stationLogo = nil
        hdArt = nil
        onlineArt = nil
        artQuery = ""
    }

    private func playFM() {
        let demod = FMDemod(inputRate: Self.fmIQRate, decim: 6, cutoff: 110_000, deviation: 75_000)
        let mpxRate = demod.outputRate
        let dec = FMDecoder(sampleRate: mpxRate)
        let sca = scaOn ? SCADecoder(sampleRate: mpxRate, subcarrier: scaKHz * 1000) : nil
        let spec = scaOn ? Spectrum(sampleRate: mpxRate) : nil
        spectrumMaxKHz = mpxRate / 2000
        if rdsOn {
            dec.onRDS = { @Sendable info in DispatchQueue.main.async { self.rds = info; self.lookUpArt() } }
            dec.onRDSGroup = { @Sendable line in DispatchQueue.main.async { self.log(line, to: \.rdsPackets) } }
        }
        do {
            try analogOut.start(rate: sca?.outputRate ?? dec.outputRate)
            if hdOn { try hdOut.start(rate: 44_100) }
        } catch {
            status = "Audio error: \(error.localizedDescription)"
            return
        }
        analogOut.volume = volume
        hdOut.volume = volume

        // HD: nrsc5 decodes the same IQ stream from its stdin and writes 44.1 kHz s16 stereo to stdout.
        let hdLastAudio = OSAllocatedUnfairLock(initialState: Date.distantPast)
        var hdIn: FileHandle?
        if hdOn {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("EnhancedFM-AAS-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            aasDir = dir
            let pipe = Pipe(), hdOut = self.hdOut
            let pcm = PCMReader()
            // -l 1 = debug log, which lists every data packet; data services are saved as files into dir.
            let args = ["-l", "1", "--dump-aas-files", dir.path, "-r", "/dev/stdin", "-o", "-", "-t", "raw", "\(hdProgram)"]
            if launch("nrsc5", args, stdin: pipe, onData: { d in
                let s = pcm.feed(d)
                guard !s.isEmpty else { return }
                hdLastAudio.withLock { $0 = Date() }
                hdOut.write(s.map { Float($0) / 32768 })
            }, onLines: { lines in DispatchQueue.main.async { lines.forEach(self.handleHDLog) } }) != nil {
                hdIn = pipe.fileHandleForWriting
            }
        }

        let analogOut = self.analogOut
        var pendingByte: UInt8?
        var lastPost = Date.distantPast
        let rtl = launch("rtl_sdr", ["-f", "\(Int(freq * 1e6))", "-s", "\(Int(Self.fmIQRate))", "-"], onData: { d in
            if let hdIn { try? hdIn.write(contentsOf: d) } // fails harmlessly if nrsc5 exited
            var bytes = [UInt8](d)
            if let b = pendingByte { bytes.insert(b, at: 0); pendingByte = nil }
            if bytes.count % 2 == 1 { pendingByte = bytes.removeLast() } // keep I/Q pairs aligned
            let mpx = demod.process(bytes)
            let program = dec.process(mpx)
            let hdLive = hdLastAudio.withLock { Date().timeIntervalSince($0) < 1.5 }
            if let sca {
                analogOut.write(sca.process(mpx))
                spec?.update(mpx)
            } else if !hdLive {
                analogOut.write(program)
            }
            if Date().timeIntervalSince(lastPost) > 0.1 { // ~10 UI updates/s
                lastPost = Date()
                let st = dec.stereo, db = spec?.db
                DispatchQueue.main.async {
                    if self.stereo != st { self.stereo = st }
                    if self.hdAudio != hdLive { self.hdAudio = hdLive }
                    if let db { self.spectrum = db }
                }
            }
        }, onLines: { lines in DispatchQueue.main.async { lines.forEach(self.handleSDRLog) } }, onExit: sourceExited)
        started(rtl)
    }

    private func playWeather() {
        let dec = WeatherDecoder()
        do { try analogOut.start(rate: WeatherDecoder.outputRate) } catch {
            status = "Audio error: \(error.localizedDescription)"
            return
        }
        analogOut.volume = volume
        let analogOut = self.analogOut
        var pendingByte: UInt8?
        let rtl = launch("rtl_sdr", ["-f", "\(Int(wxChannel * 1e6))", "-s", "\(Int(WeatherDecoder.iqRate))", "-"], onData: { d in
            var bytes = [UInt8](d)
            if let b = pendingByte { bytes.insert(b, at: 0); pendingByte = nil }
            if bytes.count % 2 == 1 { pendingByte = bytes.removeLast() }
            analogOut.write(dec.process(bytes))
        }, onLines: { lines in DispatchQueue.main.async { lines.forEach(self.handleSDRLog) } }, onExit: sourceExited)
        started(rtl)
    }

    /// rtl_sdr is the pipeline's source: when it exits (unplugged dongle, error) everything stops.
    private nonisolated func sourceExited(_ p: Process) {
        DispatchQueue.main.async {
            guard self.procs.contains(p) else { return }
            let reason = self.status
            self.stop()
            self.status = "Stopped: \(reason)"
        }
    }

    private func started(_ rtl: Process?) {
        guard rtl != nil else { stop(); return }
        playing = true
        status = "Tuning…"
    }

    func stop() {
        artTask?.cancel()
        scanTask?.cancel()
        let running = procs
        procs = []
        for p in running {
            p.terminationHandler = nil
            if p.isRunning { p.terminate() }
        }
        running.forEach { $0.waitUntilExit() } // the dongle must be released before the next tool opens it
        analogOut.stop()
        hdOut.stop()
        playing = false
        scanning = false
        status = "Stopped"
        if let aasDir { try? FileManager.default.removeItem(at: aasDir) }
        aasDir = nil
    }

    // MARK: Tuning

    func step(_ mhz: Double) {
        freq = ((freq + mhz) * 10).rounded() / 10
        if freq > 108 { freq = 87.5 } else if freq < 87.5 { freq = 108 }
        if playing { play() }
    }

    /// Jump to the next station (or weather channel) that has what's selected: plain FM, HD, or SCA at the chosen
    /// subcarrier. The first seek for a target scans for it; later seeks reuse the list.
    func seek(up: Bool) {
        let target = seekTarget
        guard let list = found[target] else { scan { self.seek(up: up) }; return }
        guard !list.isEmpty else { status = "No \(target.label) found — Rescan to try again"; return }
        let current = target == .weather ? wxChannel : freq
        let next = up ? list.first { $0 > current + 0.005 } ?? list.first!
                      : list.last { $0 < current - 0.005 } ?? list.last!
        if target == .weather { wxChannel = next } else { freq = next }
        play()
    }

    /// Scan for the current seek target. For HD and SCA every FM station is tuned briefly and checked.
    func scan(then done: (@MainActor () -> Void)? = nil) {
        let target = seekTarget, wasPlaying = playing
        stop()
        if done == nil, target != .weather { found[.fm] = nil } // an explicit Rescan refreshes the station list too
        scanning = true
        scanTask = Task {
            let list = await stations(for: target)
            guard !Task.isCancelled else { return }
            scanning = false
            guard let list else {
                status = "Scan failed — is the RTL-SDR connected?"
                if wasPlaying { play() }
                return
            }
            found[target] = list
            status = list.isEmpty ? "No \(target.label) found" : "Found \(list.count) \(target.label)"
            if !list.isEmpty, let done { done() } else if wasPlaying { play() }
        }
    }

    /// nil = the scan could not run (no dongle, missing tool, cancelled).
    private func stations(for target: SeekTarget) async -> [Double]? {
        switch target {
        case .weather:
            status = "Scanning weather channels…"
            guard let csv = await capture("rtl_power", ["-f", "162.3M:162.7M:5k", "-i", "2", "-1", "-"]) else { return nil }
            return findChannels(rtlPowerCSV: String(decoding: csv, as: UTF8.self), channels: weatherChannels.sorted(), halfWidthHz: 6_000)
        case .fm:
            status = "Scanning the FM band…"
            guard let csv = await capture("rtl_power", ["-f", "87.5M:108M:50k", "-i", "1", "-c", "20%", "-1", "-"]) else { return nil }
            return findStations(rtlPowerCSV: String(decoding: csv, as: UTF8.self))
        case .sca:
            if found[.fm] == nil { found[.fm] = await stations(for: .fm) }
            guard let fm = found[.fm] else { return nil }
            var hits: [Double] = []
            for (i, f) in fm.enumerated() {
                guard !Task.isCancelled else { return nil }
                status = String(format: "Checking %.1f MHz for %@ (%d/%d, %d found)…", f, target.label, i + 1, fm.count, hits.count)
                // ~0.47 s of IQ; the first 0.07 s is dropped while the tuner settles.
                guard let iq = await capture("rtl_sdr", ["-f", "\(Int(f * 1e6))", "-s", "\(Int(Self.fmIQRate))", "-n", "700000", "-"]) else { return nil }
                let bytes = [UInt8](iq.dropFirst(200_000)), rate = Self.fmIQRate
                if await Task.detached(operation: { probe(bytes, rate: rate, for: target) }).value { hits.append(f) }
            }
            return hits
        }
    }

    /// Run a tool to completion and return its stdout (nil if it couldn't run or produced nothing).
    private func capture(_ name: String, _ args: [String]) async -> Data? {
        guard let path = Self.tool(name) else {
            status = "\(name) not found — install with: brew install librtlsdr"
            return nil
        }
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        procs.append(p)
        let data = await Task.detached { () -> Data in
            let d = (try? out.fileHandleForReading.readToEnd()) ?? Data() // returns at EOF, so nothing is lost
            p.waitUntilExit()
            return d
        }.value
        procs.removeAll { $0 === p }
        return data.isEmpty ? nil : data
    }

    // MARK: Logs

    private func log(_ line: String, to list: ReferenceWritableKeyPath<Radio, [String]>) {
        self[keyPath: list].append(line)
        if self[keyPath: list].count > 300 { self[keyPath: list].removeFirst(self[keyPath: list].count - 300) }
    }

    private func handleSDRLog(_ line: String) {
        if line.contains("No supported devices") || line.contains("Failed") || line.contains("usb_") || line.contains("error") {
            status = line
        } else if line.contains("Reading samples") {
            status = "Playing"
        }
    }

    private func handleHDLog(_ line: String) {
        log(line, to: \.hdPackets)
        if line.contains("Synchronized") && !line.contains("Lost") {
            hdDetected = true
            status = "HD Radio detected — upgrading to HD\(hdProgram + 1)"
        } else if line.contains("Lost synchronization") {
            status = "HD signal lost — playing analog FM"
        }
        for key in ["Station name", "Slogan", "Title", "Artist", "Album", "Genre", "Audio bit rate"] {
            if let r = line.range(of: "\(key): ") {
                hd[key] = String(line[r.upperBound...])
                if key == "Title" || key == "Artist" { lookUpArt() }
            }
        }
        if let r = line.range(of: "Alert: ") { hdAlert = String(line[r.upperBound...]) }
        if line.contains("Alert ended") { hdAlert = nil }
        if line.contains("LOT file:"), let name = field("name", in: line) {
            loadAAS(name, mime: field("mime", in: line) ?? "")
        }
    }

    private func field(_ key: String, in line: String) -> String? {
        guard let r = line.range(of: " \(key)=") else { return nil }
        return String(line[r.upperBound...].prefix { $0 != " " })
    }

    /// Load a data-service file nrsc5 just finished receiving.
    private func loadAAS(_ name: String, mime: String) {
        guard let dir = aasDir else { return }
        let url = dir.appendingPathComponent(name)
        // nrsc5 logs the file as it writes it; give the write a moment to land.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard self.aasDir == dir, let image = NSImage(contentsOf: url) else { return }
            if name.hasPrefix("TMT_") {
                // Traffic map: 3×3 tiles named TMT_<id>_<row>_<col>_<time>.png
                let parts = name.split(separator: "_")
                if parts.count >= 5, let row = Int(parts[parts.count - 3]), let col = Int(parts[parts.count - 2]),
                   (1...3).contains(row), (1...3).contains(col) {
                    self.trafficTiles[row - 1][col - 1] = image
                }
            } else if name.hasPrefix("DWRO_") {
                self.weatherRadar = image
            } else if mime == "D9C72536" {
                self.stationLogo = image
            } else if mime == "BE4B7536" {
                self.hdArt = image
            }
        }
    }

    // MARK: Online artwork

    /// Album art from the iTunes Search API for what's playing (HD tags, else RadioText). Waits for the text to settle.
    private func lookUpArt() {
        guard artLookup, hdArt == nil else { return }
        let query = hd["Title"].map { [hd["Artist"], $0].compactMap { $0 }.joined(separator: " ") } ?? rds.rt
        guard query.count > 3, query != artQuery else { return }
        artQuery = query
        artTask?.cancel()
        artTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            var c = URLComponents(string: "https://itunes.apple.com/search")!
            c.queryItems = [.init(name: "term", value: query), .init(name: "entity", value: "song"), .init(name: "limit", value: "1")]
            struct Result: Decodable { let results: [Song] }
            struct Song: Decodable { let artworkUrl100: String? }
            guard let (data, _) = try? await URLSession.shared.data(from: c.url!),
                  let small = (try? JSONDecoder().decode(Result.self, from: data))?.results.first?.artworkUrl100,
                  let big = URL(string: small.replacingOccurrences(of: "100x100", with: "600x600")),
                  let (img, _) = try? await URLSession.shared.data(from: big),
                  !Task.isCancelled else { return }
            onlineArt = NSImage(data: img)
        }
    }
}

/// Turns a byte stream into s16le samples, carrying an odd trailing byte to the next chunk.
final class PCMReader {
    private var pending = Data()
    func feed(_ d: Data) -> [Int16] {
        pending.append(d)
        let n = pending.count / 2
        var s = [Int16](repeating: 0, count: n)
        _ = s.withUnsafeMutableBytes { pending.copyBytes(to: $0, count: n * 2) }
        pending.removeFirst(n * 2)
        return s
    }
}

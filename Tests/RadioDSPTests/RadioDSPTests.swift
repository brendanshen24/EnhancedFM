import XCTest
@testable import RadioDSP

final class RadioDSPTests: XCTestCase {
    static let iqRate = 1_488_375.0 // nrsc5's rate, which the app uses for FM

    /// Encode RDS groups the way a transmitter would: data + checkword ⊕ offset, MSB first.
    func groupBits(_ blocks: [UInt32]) -> [Bool] {
        let offsets: [UInt32] = [0x0FC, 0x198, 0x168, 0x1B4]
        return zip(blocks, offsets).flatMap { data, off -> [Bool] in
            let word = data << 10 | (rdsCRC(data) ^ off)
            return (0..<26).reversed().map { word >> $0 & 1 == 1 }
        }
    }

    /// RTL-SDR style IQ of a stereo FM station: L = 1 kHz tone, R = silence, pilot, RDS.
    /// `ppm` makes the receiver's sample clock run fast, as a cheap dongle crystal does.
    func makeIQ(seconds: Double, ppm: Double) -> (iq: [UInt8], groups: Int) {
        let pi: UInt32 = 0x796E, ps = Array("TESTFM  ".utf8).map(UInt32.init)
        let rt = Array("HELLO RDS\r".utf8).map(UInt32.init) + [32, 32]
        var bits: [Bool] = [], groups = 0
        while bits.count < Int(seconds * 1187.5) + 104 {
            for seg in 0..<4 {
                bits += groupBits([pi, 0 << 11 | 10 << 5 | UInt32(seg), 0xE0CD, ps[seg * 2] << 8 | ps[seg * 2 + 1]])
            }
            for seg in 0..<3 {
                let r = rt[(seg * 4)...]
                bits += groupBits([pi, 4 << 11 | 10 << 5 | UInt32(seg), r[seg * 4] << 8 | r[seg * 4 + 1], r[seg * 4 + 2] << 8 | r[seg * 4 + 3]])
            }
        }
        var t = false
        let sym = bits.map { d -> Float in t = t != d; return t ? 1 : -1 }
        let trueRate = Self.iqRate * (1 + ppm * 1e-6), n = Int(seconds * Self.iqRate)
        var iq = [UInt8](repeating: 0, count: 2 * n), phase = 0.0
        var rng = SystemRandomNumberGenerator()
        for k in 0..<n {
            let time = Double(k) / trueRate
            let theta = 2 * Double.pi * 19_000 * time
            let left = sin(2 * .pi * 1_000 * time)
            let bitPos = time * 1187.5
            let s = Double(sym[Int(bitPos)]) * (bitPos.truncatingRemainder(dividingBy: 1) < 0.5 ? 1 : -1)
            let mpx = 0.45 * left + 0.09 * sin(theta) + 0.45 * left * sin(2 * theta) + 0.03 * s * sin(3 * theta + 0.3)
            phase += 2 * .pi * 75_000 * mpx / trueRate
            let noise = { Double.random(in: -6...6, using: &rng) }
            iq[2 * k] = UInt8(127.5 + 50 * cos(phase) + noise())
            iq[2 * k + 1] = UInt8(127.5 + 50 * sin(phase) + noise())
        }
        return (iq, Int(seconds * 1187.5) / 104)
    }

    func testFMStereoAndRDSWithClockError() {
        let demod = FMDemod(inputRate: Self.iqRate, decim: 6, cutoff: 110_000, deviation: 75_000)
        let dec = FMDecoder(sampleRate: demod.outputRate)
        var last = RDSInfo(), groups: [String] = []
        dec.onRDS = { last = $0 }
        dec.onRDSGroup = { groups.append($0) }
        let (iq, sent) = makeIQ(seconds: 12, ppm: 100)
        var out: [Float] = []
        for start in stride(from: 0, to: iq.count, by: 65536) {
            out += dec.process(demod.process(Array(iq[start..<min(start + 65536, iq.count)])))
        }
        XCTAssertTrue(dec.stereo)
        XCTAssertEqual(last.pi, 0x796E)
        XCTAssertEqual(last.pty, 10)
        XCTAssertEqual(last.ps, "TESTFM  ")
        XCTAssertEqual(last.rt, "HELLO RDS")
        XCTAssertTrue(groups.contains { $0.hasPrefix(" 0A  796E 0") && $0.hasSuffix("PS name [0]") }, groups.first ?? "no groups")
        let clean = groups.filter { !$0.contains("----") && !$0.hasPrefix("??") }.count
        XCTAssertGreaterThan(Double(clean), 0.9 * Double(sent), "clean groups \(clean) of \(sent)")

        let tail = out.suffix(Int(dec.outputRate) * 2)
        var l: Float = 0, r: Float = 0
        for (i, v) in tail.enumerated() { if i % 2 == 0 { l += v * v } else { r += v * v } }
        XCTAssertGreaterThan(l, r * 100, "expected > 20 dB separation")
    }

    func testCallSign() {
        XCTAssertEqual(rbdsCallSign(0x796E), "WNYC")
        XCTAssertEqual(rbdsCallSign(0x1000), "KAAA")
        XCTAssertEqual(rbdsCallSign(0x54A8), "WAAA")
        XCTAssertNil(rbdsCallSign(0xC000))
    }

    func testSCATone() {
        // 67 kHz subcarrier, ±6 kHz deviation by a 1 kHz tone, in an MPX at 248 kHz.
        let fs = Self.iqRate / 6
        var phase = 0.0
        let mpx = (0..<Int(fs)).map { k -> Float in
            phase += 2 * .pi * (67_000 + 6_000 * sin(2 * .pi * 1_000 * Double(k) / fs)) / fs
            return Float(0.1 * cos(phase))
        }
        let out = SCADecoder(sampleRate: fs, subcarrier: 67_000).process(mpx).suffix(19_000)
        XCTAssertGreaterThan(out.map(abs).max()!, 0.1, "expected recovered audio tone")
    }

    func testWeatherToleratesTuningError() {
        // NBFM ±5 kHz, 1 kHz tone, carrier 7 kHz off-centre (≈ 43 ppm at 162.55 MHz).
        let fs = WeatherDecoder.iqRate
        var phase = 0.0, iq: [UInt8] = []
        for k in 0..<Int(fs) {
            phase += 2 * .pi * (7_000 + 5_000 * sin(2 * .pi * 1_000 * Double(k) / fs)) / fs
            iq += [UInt8(127.5 + 60 * cos(phase)), UInt8(127.5 + 60 * sin(phase))]
        }
        let out = WeatherDecoder().process(iq)
        let left = stride(from: out.count / 2, to: out.count, by: 2).map { out[$0] }
        let rms = sqrt(left.map { $0 * $0 }.reduce(0, +) / Float(left.count))
        XCTAssertEqual(Double(rms), 0.5 / 2.squareRoot(), accuracy: 0.08, "1 kHz tone at full deviation → 0.5 peak")
    }

    func testFindStations() {
        // Two 50 kHz-bin sweeps; stations at 88.5 and 101.1 MHz, floor −40 dB.
        func sweep(_ low: Double) -> String {
            let bins = (0..<40).map { i -> String in
                let f = low + (Double(i) + 0.5) * 50_000
                let station = [88.5e6, 101.1e6].contains { abs($0 - f) < 100_000 }
                return station ? "-5.0" : "-40.0"
            }
            return "2026-10-22, 16:00:00, \(Int(low)), \(Int(low + 2e6)), 50000.00, 100, " + bins.joined(separator: ", ")
        }
        let csv = stride(from: 87.5e6, to: 108e6, by: 2e6).map(sweep).joined(separator: "\n")
        XCTAssertEqual(findStations(rtlPowerCSV: csv), [88.5, 101.1])
    }
}

final class DetectorTests: XCTestCase {
    let fs = RadioDSPTests.iqRate

    /// FM station IQ; `sca` adds a 67 kHz subcarrier to the MPX.
    func station(sca: Bool) -> [UInt8] {
        let n = 400_000
        var rng = SystemRandomNumberGenerator()
        var phase = 0.0, scaPhase = 0.0
        var iq = [UInt8](repeating: 0, count: 2 * n)
        for k in 0..<n {
            let t = Double(k) / fs
            scaPhase += 2 * .pi * (67_000 + 5_000 * sin(2 * .pi * 700 * t)) / fs
            let mpx = 0.8 * sin(2 * .pi * 1_000 * t) + 0.09 * sin(2 * .pi * 19_000 * t) + (sca ? 0.1 * cos(scaPhase) : 0)
            phase += 2 * .pi * 75_000 * mpx / fs
            let i = 50 * cos(phase), q = 50 * sin(phase)
            iq[2 * k] = UInt8(max(0, min(255, 127.5 + i + Double.random(in: -3...3, using: &rng))))
            iq[2 * k + 1] = UInt8(max(0, min(255, 127.5 + q + Double.random(in: -3...3, using: &rng))))
        }
        return iq
    }

    func mpx(_ iq: [UInt8]) -> (mpx: [Float], rate: Double) {
        let d = FMDemod(inputRate: fs, decim: 6, cutoff: 110_000, deviation: 75_000)
        return (d.process(iq), d.outputRate)
    }

    func testSubcarrierDetection() {
        let with = mpx(station(sca: true)), without = mpx(station(sca: false))
        XCTAssertTrue(hasSubcarrier(mpx: with.mpx, sampleRate: with.rate, kHz: 67))
        XCTAssertFalse(hasSubcarrier(mpx: with.mpx, sampleRate: with.rate, kHz: 92))
        XCTAssertFalse(hasSubcarrier(mpx: without.mpx, sampleRate: without.rate, kHz: 67))
    }

    func testFindWeatherChannels() {
        // 5 kHz bins over 162.3–162.7 MHz; only 162.550 is on the air.
        let bins = (0..<80).map { i -> String in
            abs(162.3e6 + (Double(i) + 0.5) * 5_000 - 162.55e6) < 6_000 ? "-10.0" : "-45.0"
        }
        let csv = "2026-10-22, 16:00:00, 162300000, 162700000, 5000.00, 100, " + bins.joined(separator: ", ")
        XCTAssertEqual(findChannels(rtlPowerCSV: csv, channels: [162.400, 162.475, 162.550], halfWidthHz: 6_000), [162.550])
    }
}

final class SpectrumTests: XCTestCase {
    func testPeakAt67kHz() {
        let s = Spectrum(sampleRate: 228_000)
        s.update((0..<8192).map { Float(sin(2 * .pi * 67_000 * Double($0) / 228_000)) })
        let peak = s.db.indices.max { s.db[$0] < s.db[$1] }!
        XCTAssertEqual(Double(peak), 67_000 / 114_000 * Double(Spectrum.bins), accuracy: 2)
    }
}

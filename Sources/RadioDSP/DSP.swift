import Accelerate
import Foundation

/// Windowed-sinc (Hamming) lowpass, unity DC gain.
func lowpassTaps(cutoff: Double, rate: Double, count n: Int) -> [Float] {
    let m = Double(n - 1), fc = cutoff / rate
    let h = (0..<n).map { i -> Double in
        let x = Double(i) - m / 2
        let sinc = x == 0 ? 2 * fc : sin(2 * .pi * fc * x) / (.pi * x)
        return sinc * (0.54 - 0.46 * cos(2 * .pi * Double(i) / m))
    }
    let sum = h.reduce(0, +)
    return h.map { Float($0 / sum) }
}

struct DecimatingFIR {
    let taps: [Float]
    let decim: Int
    var hist: [Float]
    var phase = 0

    init(_ taps: [Float], decim: Int) {
        self.taps = taps
        self.decim = decim
        hist = [Float](repeating: 0, count: taps.count - 1)
    }

    mutating func run(_ x: [Float]) -> [Float] {
        let buf = hist + x, n = vDSP_Length(taps.count)
        var out: [Float] = []
        out.reserveCapacity(x.count / decim + 1)
        var i = phase
        buf.withUnsafeBufferPointer { b in
            while i < x.count {
                var acc: Float = 0
                vDSP_dotpr(b.baseAddress! + i, 1, taps, 1, &acc, n)
                out.append(acc)
                i += decim
            }
        }
        phase = i - x.count
        hist = Array(buf.suffix(taps.count - 1))
        return out
    }
}

/// RTL-SDR IQ (unsigned 8-bit interleaved) → channel filter → FM discriminator.
/// Output is normalized so that `deviation` Hz of frequency swing = 1.0.
public final class FMDemod {
    public let outputRate: Double
    var lpI: DecimatingFIR, lpQ: DecimatingFIR
    var prevI: Float = 0, prevQ: Float = 0, dcI: Float = 127.5, dcQ: Float = 127.5
    let scale: Float

    public init(inputRate: Double, decim: Int, cutoff: Double, deviation: Double, taps: Int = 63) {
        outputRate = inputRate / Double(decim)
        let h = lowpassTaps(cutoff: cutoff, rate: inputRate, count: taps)
        lpI = DecimatingFIR(h, decim: decim)
        lpQ = DecimatingFIR(h, decim: decim)
        scale = Float(outputRate / (2 * .pi * deviation))
    }

    public func process(_ iq: [UInt8]) -> [Float] {
        let n = iq.count / 2
        var i = [Float](repeating: 0, count: n), q = i
        for k in 0..<n {
            i[k] = Float(iq[2 * k])
            q[k] = Float(iq[2 * k + 1])
        }
        // Remove the RTL's DC offset (slowly tracked chunk mean).
        dcI += 0.1 * (vDSP.mean(i) - dcI)
        dcQ += 0.1 * (vDSP.mean(q) - dcQ)
        i = vDSP.add(-dcI, i)
        q = vDSP.add(-dcQ, q)
        let bi = lpI.run(i), bq = lpQ.run(q)
        var out = [Float](repeating: 0, count: bi.count)
        for k in bi.indices {
            let re = bi[k] * prevI + bq[k] * prevQ, im = bq[k] * prevI - bi[k] * prevQ
            out[k] = atan2(im, re) * scale
            prevI = bi[k]
            prevQ = bq[k]
        }
        return out
    }
}

/// Wideband FM multiplex decoder: stereo audio + RDS.
/// Input: MPX normalized to 75 kHz deviation (FMDemod output). Output: interleaved stereo at `outputRate`.
public final class FMDecoder {
    public let sampleRate: Double
    public var outputRate: Double { sampleRate / 5 }
    let w0: Double
    var phi = 0.0, integ = 0.0, pilotLevel = 0.0
    var sumLP: DecimatingFIR, diffLP: DecimatingFIR, rdsI: DecimatingFIR, rdsQ: DecimatingFIR
    let rdsRate: Double
    var rsPos = 0.0, rsPrevI: Float = 0, rsPrevQ: Float = 0
    var deL: Float = 0, deR: Float = 0
    let deA: Float
    let rds = RDSDemod()
    public private(set) var stereo = false
    public var onRDS: ((RDSInfo) -> Void)? {
        get { rds.onUpdate }
        set { rds.onUpdate = newValue }
    }
    public var onRDSGroup: ((String) -> Void)? {
        get { rds.onGroup }
        set { rds.onGroup = newValue }
    }

    public init(sampleRate: Double, deemphasis: Double = 75e-6) {
        self.sampleRate = sampleRate
        w0 = 2 * .pi * 19_000 / sampleRate
        let audio = lowpassTaps(cutoff: 15_000, rate: sampleRate, count: 151)
        let rdsTaps = lowpassTaps(cutoff: 2_600, rate: sampleRate, count: 401)
        let d = Int(sampleRate / 9_500) // keep ≥ 9500 Hz; resampled to exactly 8 samples/bit below
        rdsRate = sampleRate / Double(d)
        sumLP = DecimatingFIR(audio, decim: 5)
        diffLP = DecimatingFIR(audio, decim: 5)
        rdsI = DecimatingFIR(rdsTaps, decim: d)
        rdsQ = DecimatingFIR(rdsTaps, decim: d)
        deA = Float(exp(-1 / (sampleRate / 5 * deemphasis)))
    }

    public func process(_ mpx: [Float]) -> [Float] {
        let count = mpx.count
        var diff = [Float](repeating: 0, count: count), ri = diff, rq = diff
        for k in 0..<count {
            let x = mpx[k]
            // 19 kHz pilot PLL (pilot = A·sin θ; x·cos φ ≈ A/2·sin(θ−φ))
            let s = sin(phi), c = cos(phi)
            let e = Double(x) * c
            pilotLevel += 0.0001 * (2 * Double(x) * s - pilotLevel)
            integ = min(max(integ + 1.5e-5 * e, -0.002), 0.002)
            phi += w0 + 0.026 * e + integ
            if phi > 2 * .pi { phi -= 2 * .pi }
            diff[k] = x * Float(4 * s * c) // 2·sin 2φ
            // RDS carrier is the pilot's 3rd harmonic: mix with e^(−j3φ).
            ri[k] = x * Float(4 * c * c * c - 3 * c)
            rq[k] = -x * Float(3 * s - 4 * s * s * s)
        }
        stereo = pilotLevel > (stereo ? 0.025 : 0.04)
        rds.process(resampleRDS(rdsI.run(ri), rdsQ.run(rq)))

        let sum = sumLP.run(mpx), d = diffLP.run(diff)
        var out = [Float]()
        out.reserveCapacity(sum.count * 2)
        for k in sum.indices {
            let dk = stereo ? d[k] : 0
            deL = (1 - deA) * (sum[k] + dk) + deA * deL
            deR = (1 - deA) * (sum[k] - dk) + deA * deR
            out.append(deL)
            out.append(deR)
        }
        return out
    }

    /// Linear-interpolate RDS baseband to 8 samples per bit. The bit rate is pilot/16, so with a locked
    /// pilot the bit clock follows the transmitter exactly and the receiver's crystal error drops out.
    func resampleRDS(_ i: [Float], _ q: [Float]) -> ([Float], [Float]) {
        let pilotHz = pilotLevel > 0.02 ? 19_000 + integ * sampleRate / (2 * .pi) : 19_000
        let step = rdsRate / (pilotHz / 2)
        let xi = [rsPrevI] + i, xq = [rsPrevQ] + q
        var oi: [Float] = [], oq: [Float] = []
        while rsPos < Double(xi.count - 1) {
            let k = Int(rsPos), f = Float(rsPos - Double(k))
            oi.append(xi[k] + f * (xi[k + 1] - xi[k]))
            oq.append(xq[k] + f * (xq[k + 1] - xq[k]))
            rsPos += step
        }
        rsPos -= Double(xi.count - 1)
        rsPrevI = xi.last!
        rsPrevQ = xq.last!
        return (oi, oq)
    }
}

/// SCA (FM subcarrier, typically 67 or 92 kHz) decoder.
/// Input: MPX (FMDemod output). Output: interleaved stereo (dual mono) at `outputRate`.
public final class SCADecoder {
    public let outputRate: Double
    let w: Double
    var phase = 0.0
    var lpI: DecimatingFIR, lpQ: DecimatingFIR
    var prevI: Float = 0, prevQ: Float = 0, de: Float = 0
    let deA: Float

    public init(sampleRate: Double, subcarrier: Double, deemphasis: Double = 150e-6) {
        outputRate = sampleRate / 6
        w = 2 * .pi * subcarrier / sampleRate
        let taps = lowpassTaps(cutoff: 7_000, rate: sampleRate, count: 255)
        lpI = DecimatingFIR(taps, decim: 6)
        lpQ = DecimatingFIR(taps, decim: 6)
        deA = Float(exp(-1 / (outputRate * deemphasis)))
    }

    public func process(_ mpx: [Float]) -> [Float] {
        var i = [Float](repeating: 0, count: mpx.count), q = i
        for k in mpx.indices {
            i[k] = mpx[k] * Float(cos(phase))
            q[k] = -mpx[k] * Float(sin(phase))
            phase += w
            if phase > 2 * .pi { phase -= 2 * .pi }
        }
        let bi = lpI.run(i), bq = lpQ.run(q)
        var out = [Float]()
        out.reserveCapacity(bi.count * 2)
        for k in bi.indices {
            let re = bi[k] * prevI + bq[k] * prevQ, im = bq[k] * prevI - bi[k] * prevQ
            prevI = bi[k]
            prevQ = bq[k]
            de = (1 - deA) * atan2(im, re) + deA * de
            out.append(de * 0.8)
            out.append(de * 0.8)
        }
        return out
    }
}

/// NOAA Weather Radio (narrowband FM, ±5 kHz). IQ at 1.024 MS/s → stereo audio at 32 kHz.
/// The wide 12 kHz channel filter plus DC removal tolerates the RTL's ~±8 kHz tuning error at 162 MHz.
public final class WeatherDecoder {
    public static let iqRate = 1_024_000.0
    public static let outputRate = 32_000.0
    let demod = FMDemod(inputRate: iqRate, decim: 32, cutoff: 12_000, deviation: 5_000, taps: 255)
    var audioLP = DecimatingFIR(lowpassTaps(cutoff: 4_000, rate: outputRate, count: 63), decim: 1)
    var dc: Float = 0

    public init() {}

    public func process(_ iq: [UInt8]) -> [Float] {
        var x = demod.process(iq)
        for k in x.indices {
            dc += 0.0005 * (x[k] - dc) // frequency offset shows up as DC
            x[k] -= dc
        }
        return audioLP.run(x).flatMap { [$0 * 0.5, $0 * 0.5] }
    }
}

/// Smoothed power spectrum of a real signal, 0 … sampleRate/2 in `bins` bins (dB, arbitrary reference).
public final class Spectrum {
    public static let bins = 512
    public let maxHz: Double
    let n = 4096
    let fft = vDSP.FFT(log2n: 12, radix: .radix2, ofType: DSPSplitComplex.self)!
    let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: 4096, isHalfWindow: false)
    var buf: [Float] = []
    public private(set) var db = [Float](repeating: -200, count: Spectrum.bins)

    public init(sampleRate: Double) { maxHz = sampleRate / 2 }

    public func update(_ x: [Float]) {
        buf = Array((buf + x).suffix(n))
        guard buf.count == n else { return }
        let frame = vDSP.multiply(buf, window)
        var re = [Float](repeating: 0, count: n / 2), im = re, mag = re
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                frame.withUnsafeBytes { vDSP_ctoz($0.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(n / 2)) }
                fft.forward(input: split, output: &split)
                vDSP.squareMagnitudes(split, result: &mag)
            }
        }
        let per = mag.count / Self.bins
        for k in 0..<Self.bins {
            let p = 10 * log10(mag[k * per..<(k + 1) * per].max()! + 1e-20)
            db[k] = db[k] < -150 ? p : 0.7 * db[k] + 0.3 * p
        }
    }
}

/// Stations from one `rtl_power -1` sweep: channels (0.1 MHz grid) that stand `minSNR` dB above the band's median
/// and are a local maximum (an FM signal is ~200 kHz wide, so its neighbours are part of the same station).
public func findStations(rtlPowerCSV csv: String, minSNR: Double = 10) -> [Double] {
    var channels: [Int: [Double]] = [:] // key: frequency in 100 kHz units
    for line in csv.split(separator: "\n") {
        let f = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard f.count > 6, let low = Double(f[2]), let step = Double(f[4]) else { continue }
        for (i, v) in f[6...].enumerated() {
            guard let db = Double(v), db.isFinite else { continue }
            channels[Int(((low + (Double(i) + 0.5) * step) / 100_000).rounded()), default: []].append(db)
        }
    }
    let power = channels.mapValues { $0.reduce(0, +) / Double($0.count) }
    guard !power.isEmpty else { return [] }
    let floor = power.values.sorted()[power.count / 2]
    return power.keys.sorted().filter { k in
        let p = power[k]!
        return p >= floor + minSNR && p >= power[k - 1, default: -.infinity] && p > power[k + 1, default: -.infinity]
    }.map { Double($0) / 10 }
}

extension Spectrum {
    /// Mean power (dB) of the bins between `lo` and `hi` Hz.
    public func power(from lo: Double, to hi: Double) -> Float {
        let a = Int(lo / maxHz * Double(Self.bins)), b = min(Int(hi / maxHz * Double(Self.bins)), Self.bins - 1)
        let linear = db[a...b].map { pow(10, $0 / 10) }
        return 10 * log10(linear.reduce(0, +) / Float(linear.count))
    }
}

/// Does this multiplex carry an SCA subcarrier at `kHz`? Compares the subcarrier band with an empty
/// reference band just above it (FM noise rises with frequency, so this errs towards "no").
public func hasSubcarrier(mpx: [Float], sampleRate: Double, kHz: Double) -> Bool {
    let s = Spectrum(sampleRate: sampleRate)
    for start in stride(from: 0, to: mpx.count - 4096, by: 4096) { s.update(Array(mpx[start..<start + 4096])) }
    let f = kHz * 1000, ref = f < 80_000 ? (77_000.0, 83_000.0) : (102_000.0, 110_000.0)
    return s.power(from: f - 4_000, to: f + 4_000) - s.power(from: ref.0, to: ref.1) > 10
}

/// Which of `channels` (MHz) are on the air in an `rtl_power -1` sweep: at least `minSNR` dB above the sweep's median.
public func findChannels(rtlPowerCSV csv: String, channels: [Double], halfWidthHz: Double, minSNR: Double = 10) -> [Double] {
    var bins: [(hz: Double, db: Double)] = []
    for line in csv.split(separator: "\n") {
        let f = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard f.count > 6, let low = Double(f[2]), let step = Double(f[4]) else { continue }
        for (i, v) in f[6...].enumerated() {
            if let db = Double(v), db.isFinite { bins.append((low + (Double(i) + 0.5) * step, db)) }
        }
    }
    guard !bins.isEmpty else { return [] }
    let floor = bins.map(\.db).sorted()[bins.count / 2]
    return channels.filter { ch in
        let near = bins.filter { abs($0.hz - ch * 1e6) <= halfWidthHz }.map(\.db)
        return !near.isEmpty && near.reduce(0, +) / Double(near.count) >= floor + minSNR
    }
}

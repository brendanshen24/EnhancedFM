import Foundation

public struct RDSInfo: Equatable {
    public var pi: UInt16?
    public var pty = 0
    public var ps = ""
    public var rt = ""
    public init() {}
}

/// North American (RBDS) PI code → 4-letter call sign, e.g. 0x796E → "WNYC". Nil for codes outside that range.
public func rbdsCallSign(_ pi: UInt16) -> String? {
    let p = Int(pi)
    guard (0x1000...0x994F).contains(p) else { return nil }
    let (prefix, n) = p < 0x54A8 ? ("K", p - 0x1000) : ("W", p - 0x54A8)
    let letters = [n / 676, n % 676 / 26, n % 26].map { Character(UnicodeScalar(UInt8(65 + $0))) }
    return prefix + String(letters)
}

/// RDS checkword remainder of a 16-bit block, g(x) = x^10+x^8+x^7+x^5+x^4+x^3+1.
func rdsCRC(_ data: UInt32) -> UInt32 {
    var reg: UInt32 = 0
    for i in (0..<16).reversed() {
        let fb = ((reg >> 9) & 1) ^ ((data >> i) & 1)
        reg = (reg << 1) & 0x3FF
        if fb == 1 { reg ^= 0x1B9 }
    }
    return reg
}

/// Offset words A, B, C, C', D → block slot 0...3.
let rdsOffsets: [(UInt32, Int)] = [(0x0FC, 0), (0x198, 1), (0x168, 2), (0x350, 2), (0x1B4, 3)]

func rdsBlockSlot(_ word: UInt32) -> Int? {
    let syndrome = rdsCRC(word >> 10) ^ (word & 0x3FF)
    return rdsOffsets.first { $0.0 == syndrome }?.1
}

/// BPSK/biphase RDS demodulator + group decoder. Input: complex baseband at 8 samples/bit.
final class RDSDemod {
    var onUpdate: ((RDSInfo) -> Void)?
    var onGroup: ((String) -> Void)?
    // carrier (Costas) + timing
    var psi = 0.0, freq = 0.0, power: Float = 1e-9
    var hist = [Float](repeating: 0, count: 8), energy = [Float](repeating: 0, count: 8)
    var n = 0, best = 0, lastSym = false
    // block sync
    var reg: UInt32 = 0, bitCount = 0, synced = false, bitsInBlock = 0, expect = 0
    var lastHit: (slot: Int, at: Int)?
    var blocks = [UInt32](repeating: 0, count: 4), valid = [Bool](repeating: false, count: 4)
    var total = 0, bad = 0, badRun = 0
    // decoded
    var info = RDSInfo()
    var ps = [Character](repeating: " ", count: 8), rt = [Character](repeating: " ", count: 64)
    var rtAB: UInt32 = 2

    func process(_ z: (i: [Float], q: [Float])) {
        let (i, q) = z
        for k in i.indices {
            let c = Float(cos(psi)), s = Float(sin(psi))
            let re = i[k] * c + q[k] * s, im = q[k] * c - i[k] * s
            power += 0.002 * (re * re + im * im - power)
            let err = Double(re * im / max(power, 1e-20))
            freq = min(max(freq + 0.0005 * err, -0.02), 0.02)
            psi = (psi + freq + 0.03 * err).truncatingRemainder(dividingBy: 2 * .pi)

            // Biphase symbol: + first half, − second half. Pick the sample phase with most energy.
            hist[n & 7] = re
            var b: Float = 0
            for j in 0..<8 { b += j < 4 ? hist[(n + 1 + j) & 7] : -hist[(n + 1 + j) & 7] }
            let ph = n & 7
            energy[ph] = 0.995 * energy[ph] + 0.005 * abs(b)
            if ph == best {
                let sym = b > 0
                bit(sym != lastSym) // differential decoding also removes the 180° Costas ambiguity
                lastSym = sym
            }
            if ph == 7 { best = energy.indices.max { energy[$0] < energy[$1] }! }
            n &+= 1
        }
    }

    func bit(_ d: Bool) {
        reg = ((reg << 1) | (d ? 1 : 0)) & 0x3FF_FFFF
        bitCount += 1
        let data = reg >> 10
        if !synced {
            guard let slot = rdsBlockSlot(reg) else { return }
            // Two valid blocks, a whole number of blocks apart, in the right order → synced.
            if let last = lastHit, (bitCount - last.at) % 26 == 0, bitCount - last.at <= 26 * 8,
               (last.slot + (bitCount - last.at) / 26) % 4 == slot {
                synced = true
                badRun = 0
                bitsInBlock = 0
                total = 0
                bad = 0
                valid = [false, false, false, false]
                blocks[slot] = data
                valid[slot] = true
                expect = (slot + 1) % 4
            }
            lastHit = (slot, bitCount)
            return
        }
        bitsInBlock += 1
        guard bitsInBlock == 26 else { return }
        bitsInBlock = 0
        if rdsBlockSlot(reg) == expect {
            blocks[expect] = data
            valid[expect] = true
            badRun = 0
        } else {
            bad += 1
            badRun += 1
        }
        total += 1
        if expect == 3 {
            decodeGroup()
            valid = [false, false, false, false]
        }
        expect = (expect + 1) % 4
        if badRun >= 6 { synced = false } // a bit slip fails every block after it: resync quickly
        if total == 50 {
            if bad > 20 { synced = false }
            total = 0
            bad = 0
        }
    }

    func decodeGroup() {
        onGroup?(groupLine())
        guard valid[1] else { return }
        let b = blocks[1], c = blocks[2], d = blocks[3]
        var next = info
        if valid[0] { next.pi = UInt16(blocks[0]) }
        next.pty = Int((b >> 5) & 0x1F)
        func ch(_ v: UInt32) -> Character {
            v == 0x0D ? "\r" : (0x20...0x7E).contains(v) ? Character(UnicodeScalar(UInt8(v))) : " "
        }
        switch b >> 11 {
        case 0, 1: // 0A / 0B: programme service name
            if valid[3] {
                let seg = Int(b & 3) * 2
                ps[seg] = ch(d >> 8)
                ps[seg + 1] = ch(d & 0xFF)
            }
        case 4: // 2A: radiotext, 64 chars
            clearRTIfToggled(b)
            let seg = Int(b & 0xF) * 4
            if valid[2] { rt[seg] = ch(c >> 8); rt[seg + 1] = ch(c & 0xFF) }
            if valid[3] { rt[seg + 2] = ch(d >> 8); rt[seg + 3] = ch(d & 0xFF) }
        case 5: // 2B: radiotext, 32 chars
            clearRTIfToggled(b)
            let seg = Int(b & 0xF) * 2
            if valid[3] { rt[seg] = ch(d >> 8); rt[seg + 1] = ch(d & 0xFF) }
        default:
            break
        }
        next.ps = String(ps)
        next.rt = String(rt.prefix { $0 != "\r" }).trimmingCharacters(in: .whitespaces) // CR ends the text
        if next != info {
            info = next
            onUpdate?(info)
        }
    }

    static let groupNames = [0: "PS name", 1: "slow labelling", 2: "RadioText", 3: "ODA id", 4: "clock time",
                             8: "TMC traffic", 10: "PTY name", 14: "other networks"]

    /// One log line per group: type, the four blocks in hex ("----" = failed CRC), and what it carries.
    func groupLine() -> String {
        let hex = (0..<4).map { valid[$0] ? String(format: "%04X", blocks[$0]) : "----" }.joined(separator: " ")
        guard valid[1] else { return "??  \(hex)" }
        let b = blocks[1], type = Int(b >> 12)
        let name = Self.groupNames[type].map { "\($0) [\(type == 2 ? b & 0xF : b & 3)]" } ?? ""
        return String(format: "%2d%@  ", type, (b >> 11) & 1 == 0 ? "A" : "B") + hex + "  " + name
    }

    func clearRTIfToggled(_ b: UInt32) {
        let ab = (b >> 4) & 1
        if ab != rtAB { rt = [Character](repeating: " ", count: 64) }
        rtAB = ab
    }
}

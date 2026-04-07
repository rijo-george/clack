import AVFoundation

class SoundEngine {
    var currentPack: SoundPack = .cherryBlue
    var volume: Float = 0.7 {
        didSet { engine.mainMixerNode.outputVolume = volume }
    }

    private let engine = AVAudioEngine()
    private let format: AVAudioFormat
    private var players: [AVAudioPlayerNode] = []
    private var playerIndex = 0
    private let poolSize = 16

    private var downBuffers: [SoundPack: [AVAudioPCMBuffer]] = [:]
    private var upBuffers: [SoundPack: [AVAudioPCMBuffer]] = [:]
    private var spaceDownBuffers: [SoundPack: [AVAudioPCMBuffer]] = [:]

    private let sr: Double = 44100

    init() {
        format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!

        for _ in 0..<poolSize {
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            players.append(player)
        }

        engine.mainMixerNode.outputVolume = volume
        generateAllSounds()

        do {
            try engine.start()
            for player in players { player.play() }
        } catch {
            print("Clack: failed to start audio engine — \(error)")
        }
    }

    func playKeyDown(keyCode: UInt16) {
        if keyCode == 49, let buffers = spaceDownBuffers[currentPack], !buffers.isEmpty {
            play(buffers[Int.random(in: 0..<buffers.count)])
            return
        }
        guard let buffers = downBuffers[currentPack], !buffers.isEmpty else { return }
        play(buffers[Int.random(in: 0..<buffers.count)])
    }

    func playKeyUp(keyCode: UInt16) {
        guard let buffers = upBuffers[currentPack], !buffers.isEmpty else { return }
        play(buffers[Int.random(in: 0..<buffers.count)])
    }

    private func play(_ buffer: AVAudioPCMBuffer) {
        let player = players[playerIndex]
        playerIndex = (playerIndex + 1) % poolSize
        player.scheduleBuffer(buffer)
    }

    // MARK: - Biquad Filter

    private struct Biquad {
        var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
        var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

        static func bandpass(freq: Double, q: Double, sr: Double) -> Biquad {
            let w0 = 2.0 * .pi * freq / sr
            let alpha = sin(w0) / (2.0 * q)
            let a0 = Float(1.0 + alpha)
            return Biquad(b0: Float(alpha) / a0, b1: 0, b2: Float(-alpha) / a0,
                          a1: Float(-2.0 * cos(w0)) / a0, a2: Float(1.0 - alpha) / a0)
        }

        static func lowpass(freq: Double, q: Double, sr: Double) -> Biquad {
            let w0 = 2.0 * .pi * freq / sr
            let alpha = sin(w0) / (2.0 * q)
            let c = cos(w0)
            let a0 = Float(1.0 + alpha)
            return Biquad(b0: Float((1.0 - c) / 2.0) / a0, b1: Float(1.0 - c) / a0,
                          b2: Float((1.0 - c) / 2.0) / a0,
                          a1: Float(-2.0 * c) / a0, a2: Float(1.0 - alpha) / a0)
        }

        static func highpass(freq: Double, q: Double, sr: Double) -> Biquad {
            let w0 = 2.0 * .pi * freq / sr
            let alpha = sin(w0) / (2.0 * q)
            let c = cos(w0)
            let a0 = Float(1.0 + alpha)
            return Biquad(b0: Float((1.0 + c) / 2.0) / a0, b1: Float(-(1.0 + c)) / a0,
                          b2: Float((1.0 + c) / 2.0) / a0,
                          a1: Float(-2.0 * c) / a0, a2: Float(1.0 - alpha) / a0)
        }

        mutating func process(_ x: Float) -> Float {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            return y
        }

        mutating func process(_ input: [Float]) -> [Float] {
            input.map { process($0) }
        }
    }

    // MARK: - Helpers

    private func noise(_ count: Int) -> [Float] {
        (0..<count).map { _ in Float.random(in: -1...1) }
    }

    private func decay(_ count: Int, rate: Double) -> [Float] {
        (0..<count).map { Float(exp(-Double($0) / sr * rate)) }
    }

    private func shaped(_ sig: [Float], _ env: [Float]) -> [Float] {
        zip(sig, env).map { $0 * $1 }
    }

    private func mix(_ layers: [([Float], Float)]) -> [Float] {
        guard let first = layers.first else { return [] }
        let count = first.0.count
        var out = [Float](repeating: 0, count: count)
        for (samples, gain) in layers {
            for i in 0..<min(count, samples.count) {
                out[i] += samples[i] * gain
            }
        }
        return out
    }

    private func normalize(_ samples: inout [Float], peak: Float = 0.85) {
        let mx = samples.map { abs($0) }.max() ?? 1
        guard mx > 0 else { return }
        let scale = peak / mx
        for i in 0..<samples.count { samples[i] *= scale }
    }

    private func transient(_ count: Int, ms: Double = 1.5, amp: Float = 1.0) -> [Float] {
        let tCount = Int(sr * ms / 1000)
        var out = [Float](repeating: 0, count: count)
        for i in 0..<min(tCount, count) {
            out[i] = Float.random(in: -1...1) * (1.0 - Float(i) / Float(tCount)) * amp
        }
        return out
    }

    private func filteredTransient(_ count: Int, ms: Double = 2.0, freq: Double = 1200, amp: Float = 1.0) -> [Float] {
        let tCount = Int(sr * ms / 1000)
        var filter = Biquad.lowpass(freq: freq, q: 0.7, sr: sr)
        var out = [Float](repeating: 0, count: count)
        for i in 0..<min(tCount, count) {
            let raw = Float.random(in: -1...1) * (1.0 - Float(i) / Float(tCount)) * amp
            out[i] = filter.process(raw)
        }
        return out
    }

    private func toBuffer(_ samples: [Float]) -> AVAudioPCMBuffer {
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buf.frameLength = AVAudioFrameCount(samples.count)
        memcpy(buf.floatChannelData![0], samples, samples.count * MemoryLayout<Float>.size)
        return buf
    }

    // MARK: - Generate All

    private func generateAllSounds() {
        for pack in SoundPack.allCases {
            var downs: [AVAudioPCMBuffer] = []
            var ups: [AVAudioPCMBuffer] = []
            var spaces: [AVAudioPCMBuffer] = []
            for v in 0..<12 {
                downs.append(genDown(pack, v))
                ups.append(genUp(pack, v))
            }
            for v in 0..<6 {
                spaces.append(genSpace(pack, v))
            }
            downBuffers[pack] = downs
            upBuffers[pack] = ups
            spaceDownBuffers[pack] = spaces
        }
    }

    private func genDown(_ p: SoundPack, _ v: Int) -> AVAudioPCMBuffer {
        let f = Double(v)
        switch p {
        case .cherryBlue:    return cherryBlueDown(f)
        case .typewriter:    return typewriterDown(f)
        case .thock:         return thockDown(f)
        case .bucklingSpring: return bucklingSpringDown(f)
        case .topre:         return topreDown(f)
        case .boxNavy:       return boxNavyDown(f)
        case .alpsBlue:      return alpsBlueDown(f)
        case .cherryRed:     return cherryRedDown(f)
        case .membrane:      return membraneDown(f)
        }
    }

    private func genUp(_ p: SoundPack, _ v: Int) -> AVAudioPCMBuffer {
        let f = Double(v)
        switch p {
        case .cherryBlue:    return cherryBlueUp(f)
        case .typewriter:    return typewriterUp(f)
        case .thock:         return thockUp(f)
        case .bucklingSpring: return bucklingSpringUp(f)
        case .topre:         return topreUp(f)
        case .boxNavy:       return boxNavyUp(f)
        case .alpsBlue:      return alpsBlueUp(f)
        case .cherryRed:     return cherryRedUp(f)
        case .membrane:      return membraneUp(f)
        }
    }

    private func genSpace(_ p: SoundPack, _ v: Int) -> AVAudioPCMBuffer {
        let f = Double(v)
        switch p {
        case .cherryBlue:    return cherryBlueSpace(f)
        case .typewriter:    return typewriterSpace(f)
        case .thock:         return thockSpace(f)
        case .bucklingSpring: return bucklingSpringSpace(f)
        case .topre:         return topreSpace(f)
        case .boxNavy:       return boxNavySpace(f)
        case .alpsBlue:      return alpsBlueSpace(f)
        case .cherryRed:     return cherryRedSpace(f)
        case .membrane:      return membraneSpace(f)
        }
    }

    // ━━━━���━━━━━━━���━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Cherry MX Blue — clicky, click-jacket snap
    // ━━━━━━��━━━━━━━━━━━━━━━━━━━━━━��━━━━━━━━���━━━━━━━━━━━━━���━━━━━━━━

    private func cherryBlueDown(_ f: Double) -> AVAudioPCMBuffer {
        let n = Int(sr * 0.12)
        let raw = noise(n)
        var bp1 = Biquad.bandpass(freq: 4500 + f * 130, q: 2.5, sr: sr)
        var bp2 = Biquad.bandpass(freq: 1300 + f * 80,  q: 1.5, sr: sr)
        var lp  = Biquad.lowpass(freq: 350 + f * 40, q: 1.0, sr: sr)
        var bp3 = Biquad.bandpass(freq: 2800 + f * 150, q: 4.0, sr: sr)
        var out = mix([
            (shaped(bp1.process(raw), decay(n, rate: 220 + f * 20)), 0.32),
            (shaped(bp2.process(raw), decay(n, rate: 70 + f * 8)),   0.22),
            (shaped(lp.process(raw),  decay(n, rate: 100 + f * 10)), 0.18),
            (shaped(bp3.process(raw), decay(n, rate: 55 + f * 5)),   0.13),
            (transient(n), 0.15)
        ])
        normalize(&out)
        return toBuffer(out)
    }

    private func cherryBlueUp(_ f: Double) -> AVAudioPCMBuffer {
        let n = Int(sr * 0.06)
        let raw = noise(n)
        var bp1 = Biquad.bandpass(freq: 5200 + f * 120, q: 3.0, sr: sr)
        var bp2 = Biquad.bandpass(freq: 3500 + f * 180, q: 5.0, sr: sr)
        var bp3 = Biquad.bandpass(freq: 1800 + f * 60,  q: 1.8, sr: sr)
        var out = mix([
            (shaped(bp1.process(raw), decay(n, rate: 280 + f * 20)), 0.35),
            (shaped(bp2.process(raw), decay(n, rate: 180 + f * 15)), 0.35),
            (shaped(bp3.process(raw), decay(n, rate: 150 + f * 10)), 0.30)
        ])
        normalize(&out, peak: 0.45)
        return toBuffer(out)
    }

    private func cherryBlueSpace(_ f: Double) -> AVAudioPCMBuffer {
        let n = Int(sr * 0.18)
        let raw = noise(n)
        var lp  = Biquad.lowpass(freq: 250 + f * 25, q: 0.8, sr: sr)
        var bp1 = Biquad.bandpass(freq: 1600 + f * 100, q: 1.2, sr: sr)
        var bp2 = Biquad.bandpass(freq: 3800 + f * 100, q: 2.0, sr: sr)
        var bp3 = Biquad.bandpass(freq: 600 + f * 40,   q: 1.0, sr: sr)
        var out = mix([
            (shaped(lp.process(raw),  decay(n, rate: 40 + f * 5)),  0.28),
            (shaped(bp1.process(raw), decay(n, rate: 30 + f * 4)),  0.25),
            (shaped(bp2.process(raw), decay(n, rate: 160 + f * 12)), 0.17),
            (shaped(bp3.process(raw), decay(n, rate: 35 + f * 3)),  0.30)
        ])
        normalize(&out, peak: 0.9)
        return toBuffer(out)
    }

    // ━━━━━���━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Cherry MX Red — smooth linear, clean bottom-out, minimal noise
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━���━━━━━���━━━━━━���━━━━━━━━━━━━━━━━━━━━

    private func cherryRedDown(_ f: Double) -> AVAudioPCMBuffer {
        let n = Int(sr * 0.09)
        let raw = noise(n)
        // Clean bottom-out — no click, just impact
        var lp  = Biquad.lowpass(freq: 600 + f * 40, q: 1.0, sr: sr)
        var bp1 = Biquad.bandpass(freq: 1500 + f * 70, q: 1.8, sr: sr)
        // Light spring — unlubed red has some spring noise
        var bp2 = Biquad.bandpass(freq: 3200 + f * 120, q: 3.5, sr: sr)
        var out = mix([
            (shaped(lp.process(raw),  decay(n, rate: 90 + f * 8)),   0.35),
            (shaped(bp1.process(raw), decay(n, rate: 110 + f * 10)), 0.30),
            (shaped(bp2.process(raw), decay(n, rate: 160 + f * 12)), 0.15),
            (transient(n, ms: 1.0), 0.20)
        ])
        normalize(&out, peak: 0.75)
        return toBuffer(out)
    }

    private func cherryRedUp(_ f: Double) -> AVAudioPCMBuffer {
        let n = Int(sr * 0.05)
        let raw = noise(n)
        var bp = Biquad.bandpass(freq: 2800 + f * 100, q: 2.5, sr: sr)
        var lp = Biquad.lowpass(freq: 900 + f * 50, q: 0.9, sr: sr)
        var out = mix([
            (shaped(bp.process(raw), decay(n, rate: 200 + f * 15)), 0.45),
            (shaped(lp.process(raw), decay(n, rate: 170 + f * 12)), 0.55)
        ])
        normalize(&out, peak: 0.35)
        return toBuffer(out)
    }

    private func cherryRedSpace(_ f: Double) -> AVAudioPCMBuffer {
        let n = Int(sr * 0.15)
        let raw = noise(n)
        var lp  = Biquad.lowpass(freq: 350 + f * 25, q: 0.9, sr: sr)
        var bp1 = Biquad.bandpass(freq: 800 + f * 50, q: 1.0, sr: sr)
        var bp2 = Biquad.bandpass(freq: 1800 + f * 80, q: 1.5, sr: sr)
        var out = mix([
            (shaped(lp.process(raw),  decay(n, rate: 35 + f * 3)),  0.35),
            (shaped(bp1.process(raw), decay(n, rate: 40 + f * 4)),  0.35),
            (shaped(bp2.process(raw), decay(n, rate: 90 + f * 8)),  0.30)
        ])
        normalize(&out, peak: 0.80)
        return toBuffer(out)
    }

    // ���━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━��━━━━━���━━━━━━━━━━━━━━━━━
    // MARK: - Thock — deep lubed linear, thick PBT keycaps
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━���━━━━���━━━━━━━��━━━━━━━��━━━━

    private func thockDown(_ f: Double) -> AVAudioPCMBuffer {
        let n = Int(sr * 0.14)
        let raw = noise(n)
        var lp  = Biquad.lowpass(freq: 500 + f * 35, q: 1.2, sr: sr)
        var bp1 = Biquad.bandpass(freq: 800 + f * 50, q: 1.0, sr: sr)
        var bp2 = Biquad.bandpass(freq: 1800 + f * 80, q: 2.0, sr: sr)
        var bp3 = Biquad.bandpass(freq: 2200 + f * 100, q: 3.5, sr: sr)
        var out = mix([
            (shaped(lp.process(raw),  decay(n, rate: 50 + f * 4)),   0.35),
            (shaped(bp1.process(raw), decay(n, rate: 65 + f * 5)),   0.25),
            (shaped(bp2.process(raw), decay(n, rate: 140 + f * 12)), 0.10),
            (filteredTransient(n, ms: 3, freq: 1200), 0.18),
            (shaped(bp3.process(noise(n)), decay(n, rate: 90 + f * 8)), 0.12)
        ])
        normalize(&out, peak: 0.85)
        return toBuffer(out)
    }

    private func thockUp(_ f: Double) -> AVAudioPCMBuffer {
        let n = Int(sr * 0.07)
        let raw = noise(n)
        var bp = Biquad.bandpass(freq: 1200 + f * 60, q: 1.5, sr: sr)
        var lp = Biquad.lowpass(freq: 800 + f * 40, q: 0.8, sr: sr)
        var out = mix([
            (shaped(bp.process(raw), decay(n, rate: 110 + f * 10)), 0.50),
            (shaped(lp.process(raw), decay(n, rate: 130 + f * 10)), 0.50)
        ])
        normalize(&out, peak: 0.35)
        return toBuffer(out)
    }

    private func thockSpace(_ f: Double) -> AVAudioPCMBuffer {
        let n = Int(sr * 0.22)
        let raw = noise(n)
        var lp  = Biquad.lowpass(freq: 300 + f * 20, q: 0.9, sr: sr)
        var bp1 = Biquad.bandpass(freq: 700 + f * 40, q: 0.8, sr: sr)
        var bp2 = Biquad.bandpass(freq: 450 + f * 30, q: 1.0, sr: sr)
        var out = mix([
            (shaped(lp.process(raw),  decay(n, rate: 25 + f * 2)), 0.35),
            (shaped(bp1.process(raw), decay(n, rate: 20 + f * 2)), 0.30),
            (shaped(bp2.process(raw), decay(n, rate: 30 + f * 3)), 0.35)
        ])
        normalize(&out, peak: 0.90)
        return toBuffer(out)
    }

    // ━━━━���━━━━━━━��━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Buckling Spring — IBM Model M, heavy spring buckle + metal backplate ping
    // ━━━━━━━��━━━━━━━━━��━━━━━━��━━━━━━━━━━━━━━━━━━━━━���━━━━━━━━━━━━━━

    private func bucklingSpringDown(_ f: Double) -> AVAudioPCMBuffer {
        let n = Int(sr * 0.18)
        let raw = noise(n)
        // Spring buckle — the signature sharp metallic PING, 5-8kHz
        var pingBP = Biquad.bandpass(freq: 6000 + f * 200, q: 6.0, sr: sr)
        let ping = shaped(pingBP.process(raw), decay(n, rate: 45 + f * 4))
        // Metal backplate resonance — large plate rings at lower freq
        var plateBP = Biquad.bandpass(freq: 1800 + f * 120, q: 2.0, sr: sr)
        let plate = shaped(plateBP.process(raw), decay(n, rate: 35 + f * 3))
        // Heavy bottom-out — these switches are HEAVY
        var thudLP = Biquad.lowpass(freq: 400 + f * 30, q: 1.0, sr: sr)
        let thud = shaped(thudLP.process(raw), decay(n, rate: 55 + f * 5))
        // Spring rattle — coiled spring vibrating in housing
        var rattleBP = Biquad.bandpass(freq: 3500 + f * 180, q: 3.5, sr: sr)
        let rattle = shaped(rattleBP.process(raw), decay(n, rate: 40 + f * 4))
        // Hard transient
        let trans = transient(n, ms: 1.5, amp: 1.3)

        var out = mix([
            (ping, 0.25), (plate, 0.22), (thud, 0.20), (rattle, 0.18), (trans, 0.15)
        ])
        normalize(&out, peak: 0.92)
        return toBuffer(out)
    }

    private func bucklingSpringUp(_ f: Double) -> AVAudioPCMBuffer {
        let n = Int(sr * 0.10)
        let raw = noise(n)
        // Spring reset — the buckle snaps back, another ping
        var pingBP = Biquad.bandpass(freq: 5500 + f * 150, q: 5.0, sr: sr)
        let ping = shaped(pingBP.process(raw), decay(n, rate: 80 + f * 8))
        var plateBP = Biquad.bandpass(freq: 2000 + f * 80, q: 1.8, sr: sr)
        let plate = shaped(plateBP.process(raw), decay(n, rate: 60 + f * 5))
        var out = mix([
            (ping, 0.50), (plate, 0.50)
        ])
        normalize(&out, peak: 0.55)
        return toBuffer(out)
    }

    private func bucklingSpringSpace(_ f: Double) -> AVAudioPCMBuffer {
        let n = Int(sr * 0.25)
        let raw = noise(n)
        // Massive stabilizer bar
        var lp  = Biquad.lowpass(freq: 250 + f * 20, q: 0.8, sr: sr)
        var bp1 = Biquad.bandpass(freq: 1200 + f * 80, q: 1.0, sr: sr)
        var bp2 = Biquad.bandpass(freq: 4500 + f * 150, q: 4.0, sr: sr)
        var bp3 = Biquad.bandpass(freq: 700 + f * 40, q: 0.8, sr: sr)
        var out = mix([
            (shaped(lp.process(raw),  decay(n, rate: 20 + f * 2)), 0.30),
            (shaped(bp1.process(raw), decay(n, rate: 18 + f * 2)), 0.25),
            (shaped(bp2.process(raw), decay(n, rate: 35 + f * 3)), 0.20),
            (shaped(bp3.process(raw), decay(n, rate: 22 + f * 2)), 0.25)
        ])
        normalize(&out, peak: 0.95)
        return toBuffer(out)
    }

    // ━━━━━━��━━━━━━━━━━━━━━━━━━���━━━━━━━━━━━━━━━━��━━━━━━━��━━━━━━━━━━
    // MARK: - Topre — electrocapacitive rubber dome, soft "clop", pillowy
    // ━��━━━━━━━━━━━━━━━━━━��━━━━━━━��━━━━━━���━━━━━━━━━━��━━━━━━━━━━━━━━

    private func topreDown(_ f: Double) -> AVAudioPCMBuffer {
        let n = Int(sr * 0.10)
        let raw = noise(n)
        // Rubber dome collapse — soft, dampened, mid-low thud
        var lp  = Biquad.lowpass(freq: 700 + f * 40, q: 1.3, sr: sr)
        let dome = shaped(lp.process(raw), decay(n, rate: 75 + f * 6))
        // Cup rubber "clop" — the signature Topre sound, 800-1500Hz
        var clopBP = Biquad.bandpass(freq: 1100 + f * 60, q: 2.0, sr: sr)
        let clop = shaped(clopBP.process(raw), decay(n, rate: 100 + f * 8))
        // Very soft top — barely any high freq, extremely dampened
        var topBP = Biquad.bandpass(freq: 2200 + f * 80, q: 2.5, sr: sr)
        let top = shaped(topBP.process(raw), decay(n, rate: 180 + f * 15))
        // Soft rounded transient
        let trans = filteredTransient(n, ms: 2.5, freq: 900)

        var out = mix([
            (dome, 0.35), (clop, 0.30), (top, 0.10), (trans, 0.25)
        ])
        normalize(&out, peak: 0.70)
        return toBuffer(out)
    }

    private func topreUp(_ f: Double) -> AVAudioPCMBuffer {
        let n = Int(sr * 0.06)
        let raw = noise(n)
        // Rubber dome pop-back — soft, muted
        var lp = Biquad.lowpass(freq: 1000 + f * 50, q: 1.0, sr: sr)
        let dome = shaped(lp.process(raw), decay(n, rate: 130 + f * 10))
        var bp = Biquad.bandpass(freq: 1600 + f * 60, q: 2.0, sr: sr)
        let mid = shaped(bp.process(raw), decay(n, rate: 160 + f * 12))
        var out = mix([
            (dome, 0.55), (mid, 0.45)
        ])
        normalize(&out, peak: 0.30)
        return toBuffer(out)
    }

    private func topreSpace(_ f: Double) -> AVAudioPCMBuffer {
        let n = Int(sr * 0.16)
        let raw = noise(n)
        var lp  = Biquad.lowpass(freq: 450 + f * 25, q: 1.0, sr: sr)
        var bp1 = Biquad.bandpass(freq: 800 + f * 40, q: 1.2, sr: sr)
        var bp2 = Biquad.bandpass(freq: 1400 + f * 60, q: 1.5, sr: sr)
        var out = mix([
            (shaped(lp.process(raw),  decay(n, rate: 35 + f * 3)), 0.40),
            (shaped(bp1.process(raw), decay(n, rate: 40 + f * 4)), 0.35),
            (shaped(bp2.process(raw), decay(n, rate: 80 + f * 6)), 0.25)
        ])
        normalize(&out, peak: 0.75)
        return toBuffer(out)
    }

    // ━━━━━━━━━━━━━━━��━━━━━━���━━━━━��━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Box Navy — Kailh thick click bar, loud and crunchy
    // ━━━━━��━━━━━━━━━━━━━━━━━━━━━━━━━━━��━━━━━━��━━━━���━━━━━━━━━━━━���━━

    private func boxNavyDown(_ f: Double) -> AVAudioPCMBuffer {
        let n = Int(sr * 0.14)
        let raw = noise(n)
        // Click bar — thicker, louder than Cherry Blue, centered lower ~3-5kHz
        var clickBP = Biquad.bandpass(freq: 3800 + f * 120, q: 2.0, sr: sr)
        let click = shaped(clickBP.process(raw), decay(n, rate: 130 + f * 12))
        // Heavy bottom-out — Box Navy is a heavy switch
        var thudLP = Biquad.lowpass(freq: 400 + f * 35, q: 1.1, sr: sr)
        let thud = shaped(thudLP.process(raw), decay(n, rate: 60 + f * 5))
        // Thick housing resonance — box housing has distinct resonance
        var housingBP = Biquad.bandpass(freq: 1500 + f * 90, q: 1.3, sr: sr)
        let housing = shaped(housingBP.process(raw), decay(n, rate: 55 + f * 5))
        // Crunch — the click bar has a wider, crunchier sound than a click jacket
        var crunchBP = Biquad.bandpass(freq: 5500 + f * 200, q: 1.8, sr: sr)
        let crunch = shaped(crunchBP.process(raw), decay(n, rate: 170 + f * 15))
        // Hard transient
        let trans = transient(n, ms: 1.2, amp: 1.4)

        var out = mix([
            (click, 0.28), (thud, 0.20), (housing, 0.20), (crunch, 0.17), (trans, 0.15)
        ])
        normalize(&out, peak: 0.93)
        return toBuffer(out)
    }

    private func boxNavyUp(_ f: Double) -> AVAudioPCMBuffer {
        let n = Int(sr * 0.08)
        let raw = noise(n)
        // Click bar reset — loud upstroke is a Box signature
        var clickBP = Biquad.bandpass(freq: 4200 + f * 130, q: 2.2, sr: sr)
        let click = shaped(clickBP.process(raw), decay(n, rate: 180 + f * 15))
        var housingBP = Biquad.bandpass(freq: 1800 + f * 70, q: 1.5, sr: sr)
        let housing = shaped(housingBP.process(raw), decay(n, rate: 120 + f * 10))
        var out = mix([
            (click, 0.55), (housing, 0.45)
        ])
        normalize(&out, peak: 0.55)
        return toBuffer(out)
    }

    private func boxNavySpace(_ f: Double) -> AVAudioPCMBuffer {
        let n = Int(sr * 0.20)
        let raw = noise(n)
        var lp  = Biquad.lowpass(freq: 280 + f * 22, q: 0.9, sr: sr)
        var bp1 = Biquad.bandpass(freq: 1400 + f * 80, q: 1.0, sr: sr)
        var bp2 = Biquad.bandpass(freq: 3500 + f * 120, q: 1.8, sr: sr)
        var bp3 = Biquad.bandpass(freq: 700 + f * 40, q: 0.8, sr: sr)
        var out = mix([
            (shaped(lp.process(raw),  decay(n, rate: 30 + f * 3)), 0.28),
            (shaped(bp1.process(raw), decay(n, rate: 25 + f * 2)), 0.25),
            (shaped(bp2.process(raw), decay(n, rate: 80 + f * 7)), 0.22),
            (shaped(bp3.process(raw), decay(n, rate: 28 + f * 3)), 0.25)
        ])
        normalize(&out, peak: 0.95)
        return toBuffer(out)
    }

    // ━━━━��━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━���━━━━��━━━━━━━━━━━━━━━━━━━━
    // MARK: - Alps SKCM Blue — vintage 80s tactile, sharp and dry
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━��━━━━━━━━━━━━━━━━━━���━━━━━━

    private func alpsBlueDown(_ f: Double) -> AVAudioPCMBuffer {
        let n = Int(sr * 0.11)
        let raw = noise(n)
        // Alps tactile leaf — sharp, dry click, different from Cherry
        // Higher, thinner, more "scratch" character
        var leafBP = Biquad.bandpass(freq: 5500 + f * 180, q: 3.5, sr: sr)
        let leaf = shaped(leafBP.process(raw), decay(n, rate: 200 + f * 18))
        // Dry housing — Alps housings are tight, less resonant
        var housingBP = Biquad.bandpass(freq: 2200 + f * 100, q: 2.5, sr: sr)
        let housing = shaped(housingBP.process(raw), decay(n, rate: 120 + f * 10))
        // Light thud — Alps bottom out is lighter, drier
        var thudBP = Biquad.bandpass(freq: 800 + f * 50, q: 1.2, sr: sr)
        let thud = shaped(thudBP.process(raw), decay(n, rate: 90 + f * 8))
        // Sharp transient
        let trans = transient(n, ms: 1.0, amp: 1.1)

        var out = mix([
            (leaf, 0.30), (housing, 0.25), (thud, 0.25), (trans, 0.20)
        ])
        normalize(&out, peak: 0.82)
        return toBuffer(out)
    }

    private func alpsBlueUp(_ f: Double) -> AVAudioPCMBuffer {
        let n = Int(sr * 0.06)
        let raw = noise(n)
        // Leaf reset — crisp, thin
        var bp1 = Biquad.bandpass(freq: 6000 + f * 150, q: 4.0, sr: sr)
        let leaf = shaped(bp1.process(raw), decay(n, rate: 250 + f * 20))
        var bp2 = Biquad.bandpass(freq: 2500 + f * 80, q: 2.0, sr: sr)
        let body = shaped(bp2.process(raw), decay(n, rate: 180 + f * 12))
        var out = mix([
            (leaf, 0.50), (body, 0.50)
        ])
        normalize(&out, peak: 0.42)
        return toBuffer(out)
    }

    private func alpsBlueSpace(_ f: Double) -> AVAudioPCMBuffer {
        let n = Int(sr * 0.16)
        let raw = noise(n)
        var lp  = Biquad.lowpass(freq: 350 + f * 25, q: 0.9, sr: sr)
        var bp1 = Biquad.bandpass(freq: 1200 + f * 60, q: 1.2, sr: sr)
        var bp2 = Biquad.bandpass(freq: 4000 + f * 130, q: 2.5, sr: sr)
        var out = mix([
            (shaped(lp.process(raw),  decay(n, rate: 40 + f * 4)), 0.35),
            (shaped(bp1.process(raw), decay(n, rate: 35 + f * 3)), 0.35),
            (shaped(bp2.process(raw), decay(n, rate: 100 + f * 8)), 0.30)
        ])
        normalize(&out, peak: 0.85)
        return toBuffer(out)
    }

    // ━━━━━���━━━━━━��━━━━━━━━━━━━━━━━���━━━━━━��━━━━━━���━━━━━━━━━━━━━━��━━
    // MARK: - Typewriter — heavy mechanical typebar action
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━���━━━━━━━━━━━━━━━━━━━━━━━���━━

    private func typewriterDown(_ f: Double) -> AVAudioPCMBuffer {
        let n = Int(sr * 0.15)
        let raw = noise(n)
        var bp1 = Biquad.bandpass(freq: 1800 + f * 200, q: 2.0, sr: sr)
        var lp  = Biquad.lowpass(freq: 300 + f * 30, q: 0.9, sr: sr)
        var bp2 = Biquad.bandpass(freq: 3500 + f * 250, q: 3.0, sr: sr)
        var bp3 = Biquad.bandpass(freq: 500 + f * 50, q: 0.8, sr: sr)
        var out = mix([
            (shaped(bp1.process(raw), decay(n, rate: 100 + f * 10)), 0.28),
            (shaped(lp.process(raw),  decay(n, rate: 60 + f * 6)),   0.22),
            (shaped(bp2.process(raw), decay(n, rate: 150 + f * 12)), 0.15),
            (shaped(bp3.process(raw), decay(n, rate: 30 + f * 3)),   0.20),
            (transient(n, ms: 2.0, amp: 1.2), 0.15)
        ])
        normalize(&out, peak: 0.9)
        return toBuffer(out)
    }

    private func typewriterUp(_ f: Double) -> AVAudioPCMBuffer {
        let n = Int(sr * 0.08)
        let raw = noise(n)
        var bp = Biquad.bandpass(freq: 2500 + f * 200, q: 2.5, sr: sr)
        var lp = Biquad.lowpass(freq: 600 + f * 40, q: 1.0, sr: sr)
        var out = mix([
            (shaped(bp.process(raw), decay(n, rate: 120 + f * 10)), 0.50),
            (shaped(lp.process(raw), decay(n, rate: 140 + f * 10)), 0.50)
        ])
        normalize(&out, peak: 0.40)
        return toBuffer(out)
    }

    private func typewriterSpace(_ f: Double) -> AVAudioPCMBuffer {
        let n = Int(sr * 0.20)
        let raw = noise(n)
        var lp  = Biquad.lowpass(freq: 200 + f * 20, q: 0.7, sr: sr)
        var bp1 = Biquad.bandpass(freq: 1200 + f * 100, q: 1.0, sr: sr)
        var bp2 = Biquad.bandpass(freq: 2800 + f * 150, q: 4.0, sr: sr)
        var out = mix([
            (shaped(lp.process(raw),  decay(n, rate: 35 + f * 3)), 0.35),
            (shaped(bp1.process(raw), decay(n, rate: 25 + f * 3)), 0.35),
            (shaped(bp2.process(raw), decay(n, rate: 40 + f * 4)), 0.30)
        ])
        normalize(&out, peak: 0.92)
        return toBuffer(out)
    }

    // ━━━━━��━━━━━━━━━━━━━━━━━━━━━━━���━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━��
    // MARK: - Membrane — classic rubber dome, soft and mushy
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━���━━━━━��━━━━━━━━━━━━━━━━━━━��━━

    private func membraneDown(_ f: Double) -> AVAudioPCMBuffer {
        let n = Int(sr * 0.08)
        let raw = noise(n)
        // Rubber dome squish — very dampened, mostly low-mid
        var lp  = Biquad.lowpass(freq: 800 + f * 45, q: 0.8, sr: sr)
        let squish = shaped(lp.process(raw), decay(n, rate: 80 + f * 7))
        // Plastic keycap tap — thin, hollow
        var bp = Biquad.bandpass(freq: 2500 + f * 100, q: 1.5, sr: sr)
        let tap = shaped(bp.process(raw), decay(n, rate: 160 + f * 12))
        // Mushy bottom — the membrane bottoms out softly
        var mushLP = Biquad.lowpass(freq: 400 + f * 30, q: 0.6, sr: sr)
        let mush = shaped(mushLP.process(raw), decay(n, rate: 100 + f * 8))
        // Soft transient
        let trans = filteredTransient(n, ms: 3.0, freq: 800, amp: 0.8)

        var out = mix([
            (squish, 0.30), (tap, 0.20), (mush, 0.25), (trans, 0.25)
        ])
        normalize(&out, peak: 0.60)
        return toBuffer(out)
    }

    private func membraneUp(_ f: Double) -> AVAudioPCMBuffer {
        let n = Int(sr * 0.05)
        let raw = noise(n)
        // Soft rubber pop-back
        var lp = Biquad.lowpass(freq: 1200 + f * 50, q: 0.7, sr: sr)
        let pop = shaped(lp.process(raw), decay(n, rate: 140 + f * 12))
        var out = mix([(pop, 1.0)])
        normalize(&out, peak: 0.25)
        return toBuffer(out)
    }

    private func membraneSpace(_ f: Double) -> AVAudioPCMBuffer {
        let n = Int(sr * 0.12)
        let raw = noise(n)
        // Big mushy spacebar
        var lp  = Biquad.lowpass(freq: 500 + f * 30, q: 0.7, sr: sr)
        var bp  = Biquad.bandpass(freq: 1000 + f * 50, q: 0.8, sr: sr)
        var out = mix([
            (shaped(lp.process(raw), decay(n, rate: 45 + f * 4)), 0.55),
            (shaped(bp.process(raw), decay(n, rate: 60 + f * 5)), 0.45)
        ])
        normalize(&out, peak: 0.65)
        return toBuffer(out)
    }
}

import AVFoundation
import Foundation

// One owner for the phone's audio session, which every feature shares.
//   idle       mixes with other apps; plays the silent loop that keeps the app alive in your pocket
//   talking    the glasses mic over Bluetooth HFP (call quality both ways) for a Desk Pal conversation
//   announcing ducks your music while the pager or posture nudge speaks
//   reading    ezRead: takes over Now Playing, so the glasses' tap and swipe control it
@MainActor final class AudioRoute {
  static let shared = AudioRoute()
  enum Mode: Equatable { case idle, talking, announcing, reading }

  private(set) var mode: Mode = .idle
  private var keepAlivePlayer: AVAudioPlayer?
  private let session = AVAudioSession.sharedInstance()

  func use(_ next: Mode) {
    let leaving = mode
    mode = next
    do {
      // Coming back from a mode that paused or ducked other apps lets them resume.
      if leaving != .idle && next == .idle { try? session.setActive(false, options: .notifyOthersOnDeactivation) }
      switch next {
      case .idle: try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
      case .talking: try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP])
      case .announcing: try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
      case .reading: try session.setCategory(.playback, mode: .spokenAudio, options: [])
      }
      try session.setActive(true)
      if next == .talking, let glasses = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
        try session.setPreferredInput(glasses)
      }
    } catch {
      log("Audio session (\(next)): \(error.localizedDescription)")
    }
    updateKeepAlive()
  }

  // The glasses mic needs a moment after switching to HFP (Meta's docs say about 2 s).
  func glassesMicReady(timeout: Double = 3) async -> Bool {
    let start = Date()
    while Date().timeIntervalSince(start) < timeout {
      if session.currentRoute.inputs.contains(where: { $0.portType == .bluetoothHFP }) { return true }
      if let glasses = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
        try? session.setPreferredInput(glasses)
      }
      try? await Task.sleep(for: .milliseconds(150))
    }
    return false
  }

  var routeDescription: String {
    let r = session.currentRoute
    return (r.inputs.map { "in: \($0.portName) (\($0.portType.rawValue))" } +
            r.outputs.map { "out: \($0.portName) (\($0.portType.rawValue))" }).joined(separator: ", ")
  }

  // Always on: the wake word, pager and posture nudge only work while the app stays alive in your pocket.
  private func updateKeepAlive() {
    if keepAlivePlayer == nil {
      keepAlivePlayer = try? AVAudioPlayer(data: Sounds.silence)
      keepAlivePlayer?.numberOfLoops = -1
      keepAlivePlayer?.volume = 0
    }
    if keepAlivePlayer?.isPlaying == false { keepAlivePlayer?.play() }
  }
}

// Records one utterance from the glasses mic: waits for speech, stops after a short silence.
// Returns 16 kHz 16-bit mono PCM, or nil when nobody spoke.
final class Mic: @unchecked Sendable {
  private let engine = AVAudioEngine()
  private let lock = NSLock()
  private var samples: [Int16] = []
  private var elapsed = 0.0, silentFor = 0.0, noise: Float = 0, noiseSeconds = 0.0, peak: Float = 0
  private var heardSpeech = false, finished = true
  private var waitForSpeech = 7.0, maxSeconds = 25.0, endSilence = 1.2
  private var done: CheckedContinuation<[Int16]?, Never>?

  static let rate = 16000.0

  @MainActor
  func record(waitForSpeech: Double, maxSeconds: Double = 25, endSilence: Double = 1.2) async -> [Int16]? {
    let input = engine.inputNode
    let inFormat = input.inputFormat(forBus: 0)
    guard inFormat.sampleRate > 0, inFormat.channelCount > 0,
          let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Self.rate, channels: 1, interleaved: true),
          let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
      log("No usable microphone input")
      return nil
    }
    lock.withLock {
      samples = []; elapsed = 0; silentFor = 0; noise = 0; noiseSeconds = 0; peak = 0
      heardSpeech = false; finished = false
      self.waitForSpeech = waitForSpeech; self.maxSeconds = maxSeconds; self.endSilence = endSilence
    }
    return await withCheckedContinuation { c in
      lock.withLock { done = c }
      input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buffer, _ in
        self?.take(buffer, converter: converter, outFormat: outFormat)
      }
      do {
        engine.prepare()
        try engine.start()
      } catch {
        log("Mic start failed: \(error.localizedDescription)")
        finish(spoke: false)
      }
    }
  }

  @MainActor func cancel() { finish(spoke: false) }

  private func take(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, outFormat: AVAudioFormat) {
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * Self.rate / buffer.format.sampleRate) + 32
    guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
    var fed = false
    var error: NSError?
    converter.convert(to: out, error: &error) { _, status in
      if fed { status.pointee = .noDataNow; return nil }
      fed = true
      status.pointee = .haveData
      return buffer
    }
    guard error == nil, let data = out.int16ChannelData?[0], out.frameLength > 0 else { return }
    let chunk = Array(UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
    var sum: Float = 0
    for s in chunk { let f = Float(s) / 32768; sum += f * f }
    let rms = (sum / Float(chunk.count)).squareRoot()
    let seconds = Double(chunk.count) / Self.rate

    let end: Bool? = lock.withLock {
      guard !finished else { return nil }
      samples += chunk
      elapsed += seconds
      peak = max(peak, rms)
      // The first quarter second is the room (the chime has ended by then): what counts as speech is
      // well above it.
      if noiseSeconds < 0.25 {
        noise = (noise * Float(noiseSeconds) + rms * Float(seconds)) / Float(noiseSeconds + seconds)
        noiseSeconds += seconds
        return elapsed >= maxSeconds ? heardSpeech : nil
      }
      if rms > max(0.02, noise * 3) {
        heardSpeech = true
        silentFor = 0
      } else if heardSpeech {
        silentFor += seconds
      }
      if heardSpeech && silentFor >= endSilence { return true }
      if !heardSpeech && elapsed >= waitForSpeech { return false }
      if elapsed >= maxSeconds { return heardSpeech }
      return nil
    }
    if let spoke = end {
      Task { @MainActor in self.finish(spoke: spoke) }
    }
  }

  @MainActor private func finish(spoke: Bool) {
    let (c, pcm, stats): (CheckedContinuation<[Int16]?, Never>?, [Int16], String) = lock.withLock {
      finished = true
      let c = done
      done = nil
      return (c, samples, String(format: "%.1f s, room %.3f, loudest %.3f", elapsed, noise, peak))
    }
    if c != nil { log("Mic: \(spoke ? "speech" : "nothing"), \(stats)") }
    if engine.isRunning { engine.stop() }
    engine.inputNode.removeTap(onBus: 0)
    c?.resume(returning: spoke ? pcm : nil)
  }
}

import AVFoundation
import Foundation
import Observation

// Where the app talks to, and its keys (from Config/Secrets.xcconfig via Info.plist).
enum Config {
  static let glassesURL = URL(string: "https://\(info("DeskPalVoiceHost"))/api/glasses")!
  static let agentURL = URL(string: "https://\(info("DeskPalVoiceHost"))/api/agent")!
  static let readerURL = URL(string: "https://\(info("DeskPalReaderHost"))")!
  static let macURL = URL(string: "http://\(info("DeskPalMacHost")):8765")!   // Head Spaces (mac/HeadSpaces.swift), same Wi-Fi
  static let macHelperURL = URL(string: "http://\(info("DeskPalMacHost")):8737")!   // desk-voice's mac/deskpal-mac.py (dictation)
  static let voiceKey = info("DeskPalVoiceKey")
  static let readerKey = info("DeskPalReaderKey")

  private static func info(_ key: String) -> String {
    Bundle.main.object(forInfoDictionaryKey: key) as? String ?? ""
  }

  static func url(_ base: URL, _ query: [String: String]) -> URL {
    var c = URLComponents(url: base, resolvingAgainstBaseURL: false)!
    c.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
    return c.url!
  }
}

// The last lines of what the app did, shown at the bottom of the screen.
@MainActor @Observable final class Log {
  static let shared = Log()
  private(set) var lines: [String] = []
  private let clock: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
  }()

  func add(_ line: String) {
    lines.append("\(clock.string(from: Date())) \(line)")
    if lines.count > 80 { lines.removeFirst(lines.count - 80) }
    print("[DeskPal] \(line)")
  }
}

func log(_ line: String) {
  Task { @MainActor in Log.shared.add(line) }
}

// Short sounds, made in code: a chime before listening and before the pager speaks, and the
// silent loop that keeps the app running in your pocket.
enum Sounds {
  static func wav(rate: Int = 16000, seconds: Double, _ sample: (Double) -> Double) -> Data {
    let n = Int(Double(rate) * seconds)
    var pcm = Data(capacity: n * 2)
    for i in 0..<n {
      let v = Int16(max(-1, min(1, sample(Double(i) / Double(rate)))) * 32767)
      withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
    }
    var h = Data()
    func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { h.append(contentsOf: $0) } }
    func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { h.append(contentsOf: $0) } }
    h.append(contentsOf: Array("RIFF".utf8)); u32(36 + pcm.count); h.append(contentsOf: Array("WAVE".utf8))
    h.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
    h.append(contentsOf: Array("data".utf8)); u32(pcm.count)
    return h + pcm
  }

  // Two rising notes, 0.25 s.
  static let listen = wav(seconds: 0.25) { t in
    let f = t < 0.12 ? 660.0 : 990.0
    let local = t < 0.12 ? t : t - 0.12
    return 0.35 * sin(2 * .pi * f * t) * min(1, local * 80) * max(0, 1 - local * 7)
  }
  // One soft note, 0.3 s.
  static let notice = wav(seconds: 0.3) { t in 0.3 * sin(2 * .pi * 784 * t) * min(1, t * 80) * max(0, 1 - t * 3.3) }
  static let silence = wav(rate: 8000, seconds: 1) { _ in 0 }
}

// Plays one WAV and waits for it to end.
@MainActor final class Player: NSObject, AVAudioPlayerDelegate {
  private var player: AVAudioPlayer?
  private var done: CheckedContinuation<Void, Never>?

  func play(_ data: Data) async {
    stop()
    let p: AVAudioPlayer
    do { p = try AVAudioPlayer(data: data) } catch {
      log("Player: \(error.localizedDescription)")
      return
    }
    player = p
    p.delegate = self
    await withCheckedContinuation { c in
      done = c
      if !p.play() {
        log("Player: play() refused")
        finish()
      }
    }
  }

  func stop() {
    player?.stop()
    finish()
  }

  private func finish() {
    done?.resume()
    done = nil
  }

  nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    Task { @MainActor in self.finish() }
  }

  nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
    Task { @MainActor in self.finish() }
  }
}

// On-device speech (the pager, posture nudges and ezRead): free, instant, and works offline.
@MainActor final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
  private let synth = AVSpeechSynthesizer()
  private var waiting: [ObjectIdentifier: CheckedContinuation<Bool, Never>] = [:]
  // The best English voice installed (Settings > Accessibility > Spoken Content > Voices adds better ones).
  static let voice: AVSpeechSynthesisVoice? = AVSpeechSynthesisVoice.speechVoices()
    .filter { $0.language.hasPrefix("en") }
    .max { a, b in (a.quality.rawValue, a.language == "en-US" ? 1 : 0) < (b.quality.rawValue, b.language == "en-US" ? 1 : 0) }
  // Every English voice installed, best first, for the pager's voice picker.
  static var englishVoices: [AVSpeechSynthesisVoice] {
    AVSpeechSynthesisVoice.speechVoices()
      .filter { $0.language.hasPrefix("en") && !$0.voiceTraits.contains(.isNoveltyVoice) }
      .sorted { ($0.quality.rawValue, $1.name) > ($1.quality.rawValue, $0.name) }
  }
  var voice = Speaker.voice

  override init() {
    super.init()
    synth.delegate = self
  }

  var isPaused: Bool { synth.isPaused }

  // True when it finished, false when it was cut off.
  @discardableResult
  func say(_ text: String, rate: Float = AVSpeechUtteranceDefaultSpeechRate) async -> Bool {
    let u = AVSpeechUtterance(string: text)
    u.voice = voice
    u.rate = rate
    return await withCheckedContinuation { c in
      waiting[ObjectIdentifier(u)] = c
      synth.speak(u)
    }
  }

  func pause() { synth.pauseSpeaking(at: .word) }
  func resume() { synth.continueSpeaking() }
  func stop() { synth.stopSpeaking(at: .immediate) }

  private func ended(_ u: AVSpeechUtterance, finished: Bool) {
    waiting.removeValue(forKey: ObjectIdentifier(u))?.resume(returning: finished)
  }

  nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
    Task { @MainActor in self.ended(u, finished: true) }
  }

  nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
    Task { @MainActor in self.ended(u, finished: false) }
  }
}

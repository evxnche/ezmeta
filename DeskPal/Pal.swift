import Foundation
import Observation

// Desk Pal through the glasses: chime, listen, send to desk-voice /api/glasses, play the answer, then
// listen a few seconds for a reply without being asked again (like the desk board).
@MainActor @Observable final class Pal {
  enum Status: String { case ready = "Ready", listening = "Listening", replying = "Listening for a reply",
                             thinking = "Thinking", speaking = "Speaking" }

  private(set) var status: Status = .ready
  private(set) var heard = ""
  private(set) var reply = ""
  var busy: Bool { status != .ready }
  var onReadArticles: (() -> Void)?

  private let mic = Mic()
  private let player = Player()
  // [question, answer, when]: the last few minutes of conversation, sent as X-History.
  private var history: [(String, String, Date)] = []
  private var practicing = false
  private var cancelled = false

  func talk() async {
    guard !busy else { return }
    cancelled = false
    AudioRoute.shared.use(.talking)
    defer {
      status = .ready
      AudioRoute.shared.use(.idle)
    }
    guard await AudioRoute.shared.glassesMicReady() else {
      log("Glasses mic not found (\(AudioRoute.shared.routeDescription))")
      return
    }
    var followUp = false
    for _ in 0..<6 where !cancelled {
      if !followUp { await player.play(Sounds.listen) }
      status = followUp ? .replying : .listening
      warmUp()
      guard let pcm = await mic.record(waitForSpeech: followUp ? 5 : 7), !cancelled else { return }
      status = .thinking
      guard let answer = await ask(pcm, followUp: followUp), !cancelled else { return }
      if answer.ignored { return }
      heard = answer.heard
      reply = answer.reply
      if answer.forget { history = [] }
      if let p = answer.practice { practicing = p }
      if !answer.heard.isEmpty && answer.forget == false { history.append((answer.heard, answer.reply, Date())) }
      status = .speaking
      log("Playing \(answer.audio.count / 1000) KB, \(AudioRoute.shared.routeDescription)")
      await player.play(answer.audio)
      if answer.action == "read_articles" {
        onReadArticles?()
        return
      }
      followUp = true
    }
  }

  func stop() {
    cancelled = true
    mic.cancel()
    player.stop()
  }

  private struct Answer {
    var heard = "", reply = "", action: String?, forget = false, practice: Bool?, ignored = false
    var audio = Data()
  }

  private func ask(_ pcm: [Int16], followUp: Bool) async -> Answer? {
    var req = URLRequest(url: Config.url(Config.glassesURL, ["k": Config.voiceKey]))
    req.httpMethod = "POST"
    req.timeoutInterval = 90
    req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
    let recent = history.filter { Date().timeIntervalSince($0.2) < 600 }.suffix(6).map { [$0.0, $0.1] }
    if !recent.isEmpty, let json = try? JSONSerialization.data(withJSONObject: recent) {
      req.setValue(json.base64EncodedString(), forHTTPHeaderField: "X-History")
    }
    if practicing { req.setValue("es", forHTTPHeaderField: "X-Practice") }
    if followUp { req.setValue("1", forHTTPHeaderField: "X-Followup") }
    let body = pcm.withUnsafeBufferPointer { Data(buffer: $0) }
    do {
      let (data, res) = try await URLSession.shared.upload(for: req, from: body)
      guard (res as? HTTPURLResponse)?.statusCode == 200, let nl = data.firstIndex(of: 0x0A),
            let head = try JSONSerialization.jsonObject(with: data[..<nl]) as? [String: Any] else {
        log("Desk Pal server: HTTP \((res as? HTTPURLResponse)?.statusCode ?? 0)")
        return nil
      }
      var a = Answer()
      a.heard = head["heard"] as? String ?? ""
      a.reply = head["reply"] as? String ?? ""
      a.action = head["action"] as? String
      a.forget = head["forget"] as? Bool ?? false
      a.practice = head["practice"] as? Bool
      a.ignored = head["ignored"] as? Bool ?? false
      a.audio = data[data.index(after: nl)...]
      log(a.ignored ? "Heard \"\(a.heard)\": no reply needed" : "Heard \"\(a.heard)\"")
      return a
    } catch {
      log("Desk Pal server: \(error.localizedDescription)")
      return nil
    }
  }

  // Wakes the server function while you talk, so it isn't cold when the question arrives.
  private func warmUp() {
    let url = Config.url(Config.glassesURL, ["k": Config.voiceKey])
    Task.detached { _ = try? await URLSession.shared.data(from: url) }
  }
}

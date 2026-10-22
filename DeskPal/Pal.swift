import Foundation
import Observation

// Desk Pal through the glasses: chime, listen, send to desk-voice /api/glasses, play the answer, then
// listen a few seconds for a reply without being asked again (like the desk board).
@MainActor @Observable final class Pal {
  enum Status: String { case ready = "Ready", listening = "Listening", replying = "Listening for a reply",
                             thinking = "Thinking", speaking = "Speaking", dictating = "Dictating" }

  private(set) var status: Status = .ready
  private(set) var heard = ""
  private(set) var reply = ""
  var busy: Bool { status != .ready }
  var onReadArticles: (() -> Void)?
  var onAnswered: (() -> Void)?   // Claude's permission question was answered

  private let mic = Mic()
  private let player = Player()
  private let speaker = Speaker()
  private var dictationOver = false
  private var typedBefore = false     // a space goes before every sentence after the first
  // [question, answer, when]: the last few minutes of conversation, sent as X-History.
  private var history: [(String, String, Date)] = []
  private var practicing = false
  private var cancelled = false

  // replyTo: the id of Claude's permission question just asked, so what's said answers it.
  func talk(replyTo: String? = nil) async {
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
    var agentAsk = replyTo
    for _ in 0..<6 where !cancelled {
      if !followUp { await player.play(Sounds.listen) }
      status = followUp ? .replying : .listening
      warmUp()
      guard let pcm = await mic.record(waitForSpeech: followUp ? 5 : 7), !cancelled else { return }
      status = .thinking
      guard let answer = await ask(pcm, followUp: followUp, agentAsk: agentAsk), !cancelled else { return }
      agentAsk = answer.agentAsk   // "what did Claude say?" asks its question again
      if answer.answered { onAnswered?() }
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
      if answer.dictate == true {
        await dictate()
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

  // Dictation mode: each sentence is transcribed by desk-voice and typed wherever the Mac's cursor is, until
  // "stop dictation", a tap on the glasses, or ten quiet minutes. The next sentence is recorded while the last
  // is still being transcribed, so nothing said in between is lost, and they're typed in order.
  private func dictate() async {
    status = .dictating
    dictationOver = false
    typedBefore = false
    var last: Task<Void, Never>?
    var spoke = Date()
    while !cancelled, !dictationOver, Date().timeIntervalSince(spoke) < 600 {
      let started = Date()
      guard let pcm = await mic.record(waitForSpeech: 25) else {
        if Date().timeIntervalSince(started) < 1 { break }   // the mic didn't start: don't spin
        continue
      }
      spoke = Date()
      let before = last
      last = Task {
        let answer = await ask(pcm, dictating: true)
        await before?.value
        guard !cancelled, !dictationOver, let answer, !answer.ignored else { return }
        if let text = answer.type {
          guard await typeOnMac((typedBefore ? " " : "") + text) else {
            dictationOver = true
            mic.cancel()
            await speaker.say("I can't reach your Mac, so dictation is off.")
            return
          }
          typedBefore = true
        } else if answer.dictate == false {   // "stop dictation"
          dictationOver = true
          mic.cancel()
          await player.play(answer.audio)
        }
      }
    }
    await last?.value
  }

  // Types through the Desk Pal helper on the Mac (its "type" action pastes at the cursor), same Wi-Fi.
  private func typeOnMac(_ text: String) async -> Bool {
    var req = URLRequest(url: Config.url(Config.macHelperURL.appending(path: "do"), ["k": Config.voiceKey]))
    req.httpMethod = "POST"
    req.timeoutInterval = 5
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try? JSONSerialization.data(withJSONObject: ["action": "type", "target": text])
    do {
      let (_, res) = try await URLSession.shared.data(for: req)
      let status = (res as? HTTPURLResponse)?.statusCode ?? 0
      if status != 200 { log("Dictation: Mac said \(status)") }
      return status == 200
    } catch {
      log("Dictation: \(error.localizedDescription)")
      return false
    }
  }

  private struct Answer {
    var heard = "", reply = "", action: String?, forget = false, practice: Bool?, ignored = false
    var agentAsk: String?, answered = false, dictate: Bool?, type: String?
    var audio = Data()
  }

  private func ask(_ pcm: [Int16], followUp: Bool = false, agentAsk: String? = nil, dictating: Bool = false) async -> Answer? {
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
    if let agentAsk { req.setValue(agentAsk, forHTTPHeaderField: "X-Agent-Reply") }
    if dictating { req.setValue("1", forHTTPHeaderField: "X-Dictate") }
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
      a.agentAsk = head["agent_ask"] as? String
      a.answered = head["answered"] as? Bool ?? false
      a.dictate = head["dictate"] as? Bool
      a.type = head["type"] as? String
      a.audio = data[data.index(after: nl)...]
      log(a.type != nil ? "Dictated \(a.heard.count) characters"
          : a.ignored ? "Heard \"\(a.heard)\": no reply needed" : "Heard \"\(a.heard)\"")
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

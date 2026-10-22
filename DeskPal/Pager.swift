import AVFoundation
import Foundation
import Observation

// Agent pager: polls desk-voice /api/agent (filled by the Mac's Claude Code / Codex hooks) and says
// new events in your ear. Only events after the app started are spoken. Claude's permission questions
// (events with an id) end with "Allow, deny, or always allow?" and hand the glasses' mic to Desk Pal
// for the answer, which goes back to the Mac.
@MainActor @Observable final class Pager {
  var enabled = UserDefaults.standard.object(forKey: "pager") as? Bool ?? true {
    didSet { UserDefaults.standard.set(enabled, forKey: "pager") }
  }
  var replies = UserDefaults.standard.object(forKey: "pagerReplies") as? Bool ?? true {
    didSet { UserDefaults.standard.set(replies, forKey: "pagerReplies") }
  }
  // The voice alerts are spoken in; empty is the best English voice installed.
  var voiceID = UserDefaults.standard.string(forKey: "pagerVoice") ?? "" {
    didSet {
      UserDefaults.standard.set(voiceID, forKey: "pagerVoice")
      speaker.voice = Self.voice(voiceID)
    }
  }
  private(set) var last = "Nothing yet"
  var isBusy: () -> Bool = { false }   // Desk Pal mid-conversation: wait for it
  var isLive: () -> Bool = { false }   // glasses on: check often, and tell the Mac it can ask through them
  var willSpeak: () -> Void = {}       // ezRead pauses for an alert...
  var didSpeak: () -> Void = {}        // ...and carries on after it
  var onAsk: (String) -> Void = { _ in }   // listen for the answer to permission question <id>

  private var since = Int64(Date().timeIntervalSince1970 * 1000)
  private var queue: [(line: String, ask: String?)] = []
  private var lastAsk: String?
  private var loop: Task<Void, Never>?
  private var markedLive = Date.distantPast
  private let player = Player()
  private let speaker = Speaker()
  private static let ask = "Allow, deny, or always allow?"

  init() {
    speaker.voice = Self.voice(voiceID)
  }

  private static func voice(_ id: String) -> AVSpeechSynthesisVoice? {
    id.isEmpty ? Speaker.voice : AVSpeechSynthesisVoice(identifier: id) ?? Speaker.voice
  }

  func start() {
    guard loop == nil else { return }
    loop = Task { [weak self] in
      while !Task.isCancelled {
        await self?.poll()
        await self?.announce()
        // Every 5 s with the glasses on, 20 s otherwise: keeps the mailbox within Upstash's free tier.
        try? await Task.sleep(for: self?.isLive() == true ? .seconds(5) : .seconds(20))
      }
    }
  }

  private func poll() async {
    guard enabled else { return }
    var query = ["k": Config.voiceKey, "since": String(since)]
    if replies, isLive(), Date().timeIntervalSince(markedLive) > 25 {   // the server forgets after 60 s
      query["live"] = "1"
      markedLive = Date()
    }
    guard let (data, res) = try? await URLSession.shared.data(from: Config.url(Config.agentURL, query)),
          (res as? HTTPURLResponse)?.statusCode == 200,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let events = json["events"] as? [[String: Any]] else { return }
    for e in events {
      if let at = e["at"] as? NSNumber { since = max(since, at.int64Value) }
      queue.append((Self.sentence(e), e["id"] as? String))
    }
  }

  // "Claude needs you in ezmeta: Allow this command?" / "Codex finished in desk-voice."
  static func sentence(_ e: [String: Any]) -> String {
    let agent = e["agent"] as? String ?? "An agent"
    let project = (e["project"] as? String).map { $0.isEmpty ? "" : " in \($0)" } ?? ""
    var message = (e["message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if let end = message.firstIndex(where: { ".!?".contains($0) }), message.distance(from: message.startIndex, to: end) > 20 {
      message = String(message[...end])
    }
    if message.count > 160 { message = String(message.prefix(160)) + "…" }
    let needs = e["kind"] as? String == "needs"
    return needs ? "\(agent) needs you\(project). \(message)" : "\(agent) finished\(project)." + (message.isEmpty ? "" : " \(message)")
  }

  private func announce() async {
    guard !queue.isEmpty, !isBusy() else { return }
    let events = queue
    queue = []
    // Only the newest question is asked: the Mac stops waiting on older ones by itself.
    let ask = replies ? events.last(where: { $0.ask != nil })?.ask : nil
    last = events.last?.line ?? last
    lastAsk = ask
    log("Pager: \(events.map(\.line).joined(separator: " | "))")
    await say(events.map(\.line) + (ask == nil ? [] : [Self.ask]), thenAsk: ask)
  }

  // The last alert again (the Repeat button); its question too, if the Mac may still be waiting.
  func repeatLast() async {
    guard last != "Nothing yet", !isBusy() else { return }
    await say([last] + (lastAsk == nil ? [] : [Self.ask]), thenAsk: lastAsk)
  }

  func answered() { lastAsk = nil }

  func preview() async {
    speaker.stop()
    await say(["Claude finished in ezmeta. Finished after 3 min."])
  }

  // With a question, ezRead stays paused: the conversation that takes the answer carries it on after.
  private func say(_ lines: [String], thenAsk ask: String? = nil) async {
    willSpeak()
    AudioRoute.shared.use(.announcing)
    await player.play(Sounds.notice)
    for line in lines { await speaker.say(line) }
    AudioRoute.shared.use(.idle)
    if let ask { onAsk(ask) } else { didSpeak() }
  }
}

import Foundation
import Observation

// Agent pager: polls desk-voice /api/agent (filled by the Mac's Claude Code / Codex hooks) and says
// new events in your ear. Only events after the app started are spoken.
@MainActor @Observable final class Pager {
  var enabled = UserDefaults.standard.object(forKey: "pager") as? Bool ?? true {
    didSet { UserDefaults.standard.set(enabled, forKey: "pager") }
  }
  private(set) var last = "Nothing yet"
  var isBusy: () -> Bool = { false }   // Desk Pal mid-conversation: wait for it
  var willSpeak: () -> Void = {}       // ezRead pauses for an alert...
  var didSpeak: () -> Void = {}        // ...and carries on after it

  private var since = Int64(Date().timeIntervalSince1970 * 1000)
  private var queue: [String] = []
  private var loop: Task<Void, Never>?
  private let player = Player()
  private let speaker = Speaker()
  private static let every: Duration = .seconds(20)

  func start() {
    guard loop == nil else { return }
    loop = Task { [weak self] in
      while !Task.isCancelled {
        await self?.poll()
        await self?.announce()
        try? await Task.sleep(for: Self.every)
      }
    }
  }

  private func poll() async {
    guard enabled else { return }
    let url = Config.url(Config.agentURL, ["k": Config.voiceKey, "since": String(since)])
    guard let (data, res) = try? await URLSession.shared.data(from: url),
          (res as? HTTPURLResponse)?.statusCode == 200,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let events = json["events"] as? [[String: Any]] else { return }
    for e in events {
      if let at = e["at"] as? NSNumber { since = max(since, at.int64Value) }
      queue.append(Self.sentence(e))
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
    let lines = queue
    queue = []
    last = lines.last ?? last
    log("Pager: \(lines.joined(separator: " | "))")
    willSpeak()
    AudioRoute.shared.use(.announcing)
    await player.play(Sounds.notice)
    for line in lines { await speaker.say(line) }
    AudioRoute.shared.use(.idle)
    didSpeak()
  }
}

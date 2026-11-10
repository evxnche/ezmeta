import MWDATCore
import MWDATInputs
import SwiftUI

@main
struct DeskPalApp: App {
  @State private var app: AppModel

  init() {
    do { try Wearables.configure() } catch { print("[DeskPal] Wearables.configure failed: \(error)") }
    _app = State(initialValue: AppModel())
  }

  var body: some Scene {
    WindowGroup {
      ContentView(app: app)
        .onOpenURL { app.glasses.handle($0) }
    }
  }
}

// Wires the features together: what triggers a conversation, and who waits for whom.
@MainActor @Observable final class AppModel {
  let glasses = Glasses()
  let pal = Pal()
  let pager = Pager()
  let reader = Reader()
  let posture = Posture()
  let headSwitch = HeadSwitch()
  let headScroll = HeadScroll()
  var wakeWord = UserDefaults.standard.object(forKey: "wakeWord") as? Bool ?? true {
    didSet {
      UserDefaults.standard.set(wakeWord, forKey: "wakeWord")
      glasses.wantsSpeech = wakeWord
    }
  }

  init() {
    AudioRoute.shared.use(.idle)
    glasses.onInput = { [weak self] in self?.input($0) }
    glasses.onMotion = { [weak self] a, w, t in
      self?.posture.feed(accelerometer: a, timestampNs: t)
      self?.headSwitch.feed(accelerometer: a, gyroscope: w, timestampNs: t)
      self?.headScroll.feed(accelerometer: a, timestampNs: t)
    }
    glasses.onWorn = { [weak self] in
      self?.posture.worn = $0
      self?.headSwitch.worn = $0
      self?.headScroll.worn = $0
    }
    updateMotion()
    glasses.onHeard = { [weak self] in self?.heard($0) }
    glasses.wantsSpeech = wakeWord
    pal.onReadArticles = { [weak self] in self?.startReading() }
    pager.isBusy = { [weak self] in self?.pal.busy ?? false }
    pager.isLive = { [weak self] in self?.glasses.linkState == .connected && self?.glasses.worn != false }
    pager.onAsk = { [weak self] in self?.talk(replyTo: $0) }
    pal.onAnswered = { [weak self] in self?.pager.answered() }
    pager.willSpeak = { [weak self] in self?.holdReading() }
    pager.didSpeak = { [weak self] in self?.releaseReading() }
    posture.isBusy = { [weak self] in (self?.pal.busy ?? false) || (self?.reader.reading ?? false) }
    glasses.boot()
    pager.start()
  }

  func setPosture(_ on: Bool) {
    posture.enabled = on
    updateMotion()
    if on && !posture.calibrated { Task { await posture.calibrate() } }
  }

  func setHeadSwitch(_ on: Bool) {
    headSwitch.enabled = on
    updateMotion()
  }

  func setHeadScroll(_ on: Bool) {
    headScroll.enabled = on
    updateMotion()
    if on && !headScroll.calibrated { Task { await headScroll.calibrate() } }
  }

  // Head switching needs 30 samples a second to catch a quick turn, and scrolling to follow the head
  // smoothly; posture alone is fine with 5.
  private func updateMotion() {
    glasses.motionHz = headSwitch.enabled || headScroll.enabled ? 30 : posture.enabled ? 5 : nil
  }

  // "Gigi", a double tap on the glasses, or the Talk button. Again while talking stops it.
  // replyTo: the pager just asked Claude's permission question <id>, and this conversation answers it.
  func talk(replyTo: String? = nil) {
    if pal.busy {
      if replyTo == nil { pal.stop() }
      return
    }
    holdReading()
    glasses.wantsSpeech = false   // the glasses' mic is the conversation's now, and the answer can't wake it
    Task {
      await pal.talk(replyTo: replyTo)
      releaseReading()
      await AudioRoute.shared.glassesMicReleased()
      if !pal.busy { glasses.wantsSpeech = wakeWord }
    }
  }

  // Anything the glasses hear with "Gigi" in it starts a conversation: the desk board's wake word.
  // Meta's recognizer can't be told the word and writes it many ways ("didi", "giju", "jiji",
  // "gee gee", "juju", "jiggy", "kiki", "gigis"), so match the sound: g/j/d/z/k (maybe doubled), an "ee",
  // g/j/d/z/k (maybe doubled), any vowel, maybe an "s"; or g/j "oo" g/j "oo".
  // Whole words only (a short pair counts as one, for "gee gee"), so "eggs", "dad" and "dude" don't count.
  private static let wakeWords = ["gg", "g g"]
  private static let wakeSound = #/[gjdzk]{1,2}[iey]{1,2}[gjdzk]{1,2}[aeiouy]{1,2}s?|[gj]u[gj]u/#
  private var lastWake = Date.distantPast
  private func heard(_ text: String) {
    let split = text.lowercased().map { $0.isLetter ? $0 : " " }.split(separator: " ").map { String($0) }
    let words = " " + split.joined(separator: " ") + " "
    let pairs = zip(split, split.dropFirst()).filter { $0.count <= 3 && $1.count <= 3 }.map { $0 + $1 }
    let sounds = (split + pairs).contains { $0.wholeMatch(of: Self.wakeSound) != nil }
    guard sounds || Self.wakeWords.contains(where: { words.contains(" \($0) ") }), !pal.busy,
          Date().timeIntervalSince(lastWake) > 3 else { return }
    lastWake = Date()
    log("Heard: \(text)")
    talk()
  }

  func startReading() {
    if reader.reading {
      if reader.paused { reader.togglePause() }
    } else {
      reader.start()
    }
  }

  // ezRead pauses while something else talks in your ear, then carries on.
  private var readingHeld = false
  private func holdReading() {
    guard reader.reading, !reader.paused else { return }
    readingHeld = true
    reader.togglePause()
  }

  private func releaseReading() {
    guard readingHeld else { return }
    readingHeld = false
    if reader.reading {
      AudioRoute.shared.use(.reading)
      if reader.paused { reader.togglePause() }
    }
  }

  // The glasses' own buttons (Meta's Inputs capability), when the glasses send them to the app.
  private func input(_ event: InputEvent) {
    switch event {
    case .select, .button:
      talk()
    case .nav(let direction, _, _) where reader.reading:
      if direction == .right || direction == .down { reader.nextArticle() } else { reader.repeatParagraph() }
    case .back:
      if pal.busy { pal.stop() } else if reader.reading { reader.stop() }
    default:
      break
    }
  }
}

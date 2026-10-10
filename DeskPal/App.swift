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

  init() {
    AudioRoute.shared.use(.idle)
    glasses.onTalk = { [weak self] in self?.talk() }
    glasses.onInput = { [weak self] in self?.input($0) }
    glasses.onMotion = { [weak self] a, t in self?.posture.feed(accelerometer: a, timestampNs: t) }
    glasses.onWorn = { [weak self] in self?.posture.worn = $0 }
    glasses.wantsMotion = posture.enabled
    pal.onReadArticles = { [weak self] in self?.startReading() }
    pager.isBusy = { [weak self] in self?.pal.busy ?? false }
    pager.willSpeak = { [weak self] in self?.holdReading() }
    pager.didSpeak = { [weak self] in self?.releaseReading() }
    posture.isBusy = { [weak self] in (self?.pal.busy ?? false) || (self?.reader.reading ?? false) }
    glasses.boot()
    pager.start()
  }

  func setPosture(_ on: Bool) {
    posture.enabled = on
    glasses.wantsMotion = on
    if on && !posture.calibrated { Task { await posture.calibrate() } }
  }

  // "Hey Meta, start Desk Pal", a tap on the glasses, or the Talk button. Again while talking stops it.
  func talk() {
    if pal.busy {
      pal.stop()
      return
    }
    holdReading()
    Task {
      await pal.talk()
      releaseReading()
    }
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

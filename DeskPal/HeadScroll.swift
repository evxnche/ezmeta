import Foundation
import Observation
import simd

// Head tilt → scroll on the Mac. Calibrate once (look at the screen, then tilt down a little) so it knows
// which way is down on your glasses. Tilting past `deadZone` either way scrolls that way, faster the
// further you tilt, up to `maxSpeed` at `fullTilt`. Past `keyboard` degrees down it stops, so looking at
// the keyboard doesn't scroll. The phone sends Head Spaces (mac/HeadSpaces.swift) the speed when it
// changes, and again every half second while scrolling; the Mac stops by itself after a second of quiet.
@MainActor @Observable final class HeadScroll {
  var enabled = UserDefaults.standard.bool(forKey: "headScroll") {
    didSet { UserDefaults.standard.set(enabled, forKey: "headScroll"); stop() }
  }
  private(set) var pitch: Double?         // degrees from looking at the screen, + = down, live
  private(set) var speed = 0              // pixels a second, + = down
  private(set) var calibrated = false
  private(set) var last = "Nothing yet"
  var worn = true {
    didSet { if !worn { stop() } }
  }

  static let deadZone = 6.0               // degrees
  static let fullTilt = 15.0
  static let keyboard = 25.0
  static let maxSpeed = 1200.0            // pixels a second
  private static let step = 50            // speeds round to this, so a wobble doesn't send anything

  // Gravity while looking at the screen, and the way it moves when you look down.
  private var ahead: SIMD3<Float>?
  private var down: SIMD3<Float>?
  private var smoothed: SIMD3<Float>?
  private var calibrating: [SIMD3<Float>]?
  private var sentAt: Int64 = 0
  private let player = Player()
  private let speaker = Speaker()

  init() {
    if let a = UserDefaults.standard.array(forKey: "scrollAxes") as? [Float], a.count == 6 {
      ahead = SIMD3(a[0], a[1], a[2])
      down = SIMD3(a[3], a[4], a[5])
      calibrated = true
    }
  }

  // Called for every motion sample.
  func feed(accelerometer a: SIMD3<Float>, timestampNs: Int64) {
    guard simd_length(a) > 4 else { return }   // free fall / garbage
    smoothed = smoothed.map { $0 * 0.7 + a * 0.3 } ?? a
    let g = simd_normalize(smoothed!)
    if calibrating != nil {
      calibrating!.append(g)
      return
    }
    guard let ahead, let down else { return }
    let p = Double(atan2(simd_dot(g, down), simd_dot(g, ahead))) * 180 / .pi
    pitch = p
    guard enabled, worn else { return }
    var v = 0.0
    if abs(p) > Self.deadZone && p < Self.keyboard {
      let x = min(1, (abs(p) - Self.deadZone) / (Self.fullTilt - Self.deadZone))
      v = x * x * Self.maxSpeed * (p > 0 ? 1 : -1)   // squared: slow and fine near the dead zone
    }
    let rounded = Int((v / Double(Self.step)).rounded()) * Self.step
    if rounded != speed || (rounded != 0 && timestampNs - sentAt > 500_000_000) {
      sentAt = timestampNs
      send(rounded)
    }
  }

  // Two held positions: looking at the screen, then tilted down a little.
  func calibrate() async {
    stop()
    guard let ahead = await hold("Look at your screen and hold still."),
          let low = await hold("Now tilt your head down a little, and hold.") else {
      log("Scroll: no motion data from the glasses to calibrate with")
      return
    }
    let d = low - simd_dot(low, ahead) * ahead
    guard simd_length(d) > 0.1 else {   // about 6 degrees
      AudioRoute.shared.use(.announcing)
      await speaker.say("That wasn't enough tilt. Try calibrating again.")
      AudioRoute.shared.use(.idle)
      return
    }
    let down = simd_normalize(d)
    self.ahead = ahead
    self.down = down
    calibrated = true
    UserDefaults.standard.set([ahead.x, ahead.y, ahead.z, down.x, down.y, down.z], forKey: "scrollAxes")
    log("Scroll: calibrated")
    AudioRoute.shared.use(.announcing)
    await player.play(Sounds.notice)
    AudioRoute.shared.use(.idle)
  }

  private func hold(_ prompt: String) async -> SIMD3<Float>? {
    AudioRoute.shared.use(.announcing)
    await speaker.say(prompt)
    AudioRoute.shared.use(.idle)
    calibrating = []
    try? await Task.sleep(for: .seconds(2))
    let got = calibrating ?? []
    calibrating = nil
    guard got.count >= 5 else { return nil }
    return simd_normalize(got.reduce(SIMD3<Float>(), +) / Float(got.count))
  }

  private func stop() {
    if speed != 0 { send(0) }
  }

  private func send(_ v: Int) {
    speed = v
    let url = Config.url(Config.macURL.appending(path: "scroll"), ["v": String(v), "k": Config.voiceKey])
    Task {
      do {
        let (_, res) = try await URLSession.shared.data(from: url)
        switch (res as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: last = v == 0 ? "Stopped" : "Scrolling \(v > 0 ? "down" : "up")"
        case 503: last = "Mac needs Accessibility for Head Spaces"
        case let status: last = "Mac said \(status)"
        }
      } catch {
        last = "Mac not reachable"
      }
    }
  }
}

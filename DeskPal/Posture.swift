import Foundation
import Observation
import simd

// Posture nudge from the glasses' accelerometer (Meta's Motion capability, 5 samples a second).
// Gravity's direction in the glasses says how far your head is tilted from "looking straight ahead",
// which you set once with Calibrate. Looking down more than `downAngle` adds up; a minute of looking
// up again clears it; `nudgeAfter` minutes of looking down gets a chime and a reminder in your ear.
// Only counts while the glasses are on your face.
@MainActor @Observable final class Posture {
  var enabled = UserDefaults.standard.bool(forKey: "posture") {
    didSet { UserDefaults.standard.set(enabled, forKey: "posture"); reset() }
  }
  private(set) var tilt: Double?          // degrees from straight ahead, live
  private(set) var downMinutes = 0.0
  private(set) var calibrated = UserDefaults.standard.array(forKey: "postureNeutral") != nil
  var worn = true
  var isBusy: () -> Bool = { false }

  static let downAngle = 25.0
  static let nudgeAfter = 20.0            // minutes
  private static let clearAfter = 60.0    // seconds of looking up

  private var neutral: SIMD3<Float>? = (UserDefaults.standard.array(forKey: "postureNeutral") as? [Float]).map { SIMD3($0[0], $0[1], $0[2]) }
  private var smoothed: SIMD3<Float>?
  private var upFor = 0.0
  private var lastSample: Int64?
  private var calibrating: [SIMD3<Float>]?
  private let player = Player()
  private let speaker = Speaker()

  // Called for every motion sample (any thread hops here first).
  func feed(accelerometer a: SIMD3<Float>, timestampNs: Int64) {
    let dt = lastSample.map { Double(timestampNs - $0) / 1e9 } ?? 0
    lastSample = timestampNs
    guard simd_length(a) > 4 else { return }   // free fall / garbage
    smoothed = smoothed.map { $0 * 0.7 + a * 0.3 } ?? a
    let g = simd_normalize(smoothed!)
    if calibrating != nil {
      calibrating!.append(g)
      return
    }
    guard let n = neutral else { return }
    let angle = Double(acos(max(-1, min(1, simd_dot(g, n))))) * 180 / .pi
    tilt = angle
    guard enabled, worn, dt > 0, dt < 2 else { return }
    if angle > Self.downAngle {
      downMinutes += dt / 60
      upFor = 0
    } else {
      upFor += dt
      if upFor >= Self.clearAfter { downMinutes = 0 }
    }
    if downMinutes >= Self.nudgeAfter && !isBusy() {
      downMinutes = 0
      Task { await nudge() }
    }
  }

  // "Look straight ahead": averages three seconds of gravity as the neutral position.
  func calibrate() async {
    AudioRoute.shared.use(.announcing)
    await speaker.say("Look straight ahead, and hold still for three seconds.")
    AudioRoute.shared.use(.idle)
    calibrating = []
    try? await Task.sleep(for: .seconds(3))
    let got = calibrating ?? []
    calibrating = nil
    guard got.count >= 5 else {
      log("Posture: no motion data from the glasses to calibrate with")
      return
    }
    let n = simd_normalize(got.reduce(SIMD3<Float>(), +) / Float(got.count))
    neutral = n
    calibrated = true
    UserDefaults.standard.set([n.x, n.y, n.z], forKey: "postureNeutral")
    reset()
    log("Posture: calibrated")
    AudioRoute.shared.use(.announcing)
    await player.play(Sounds.notice)
    AudioRoute.shared.use(.idle)
  }

  private func reset() {
    downMinutes = 0
    upFor = 0
  }

  private func nudge() async {
    log("Posture: nudge")
    AudioRoute.shared.use(.announcing)
    await player.play(Sounds.notice)
    await speaker.say("You've been looking down for \(Int(Self.nudgeAfter)) minutes. Sit up and look up for a bit.")
    AudioRoute.shared.use(.idle)
  }
}

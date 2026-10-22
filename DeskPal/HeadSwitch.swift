import Foundation
import Observation
import simd

// Head flick → switch Mac Spaces, like a four-finger swipe. The glasses' gyroscope (Motion, 30 Hz) gives
// how fast your head turns; the part around gravity is the left/right turn. A quick turn past `flick`
// sends one switch to Head Spaces on the Mac (mac/HeadSpaces.swift), then ignores motion for `lockout`
// so turning back to the screen doesn't switch again. Turning left slides the current window left,
// bringing in the Space to its right — the same as a four-finger swipe left.
@MainActor @Observable final class HeadSwitch {
  var enabled = UserDefaults.standard.bool(forKey: "headSwitch") {
    didSet { UserDefaults.standard.set(enabled, forKey: "headSwitch") }
  }
  private(set) var turnRate: Double?      // degrees a second, + = turning left, live
  private(set) var noGyroscope = false
  private(set) var last = "Nothing yet"
  var worn = true

  static let flick = 150.0                // degrees a second
  private static let lockoutNs: Int64 = 800_000_000

  private var gravity: SIMD3<Float>?
  private var lockedUntil: Int64 = 0

  // Called for every motion sample.
  func feed(accelerometer a: SIMD3<Float>, gyroscope w: SIMD3<Float>?, timestampNs: Int64) {
    guard simd_length(a) > 4 else { return }   // free fall / garbage
    gravity = gravity.map { $0 * 0.9 + a * 0.1 } ?? a
    guard let w else {
      noGyroscope = true
      return
    }
    noGyroscope = false
    // The accelerometer reads "up", so spin around it (right-hand rule) is a turn to the left.
    let rate = Double(simd_dot(w, simd_normalize(gravity!))) * 180 / .pi
    turnRate = rate
    guard enabled, worn, timestampNs >= lockedUntil, abs(rate) > Self.flick else { return }
    lockedUntil = timestampNs + Self.lockoutNs
    send(rate > 0 ? "right" : "left")
  }

  private func send(_ direction: String) {
    last = "Space \(direction)"
    log("Head: Space \(direction)")
    let url = Config.url(Config.macURL.appending(path: "space/\(direction)"), ["k": Config.voiceKey])
    Task {
      do {
        let (_, res) = try await URLSession.shared.data(from: url)
        let status = (res as? HTTPURLResponse)?.statusCode ?? 0
        if status == 503 { last = "Mac needs Accessibility for Head Spaces" }
        if status != 200 { log("Head: Mac said \(status)") }
      } catch {
        last = "Mac not reachable"
        log("Head: \(error.localizedDescription)")
      }
    }
  }
}

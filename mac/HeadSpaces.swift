// Head Spaces: the Mac end of Desk Pal's head gestures. Listens on the LAN for
//   GET /space/left?k=KEY   or   GET /space/right?k=KEY
// from the phone and presses Ctrl+← / Ctrl+→ (Mission Control's "Move left/right a space"),
// the same switch a four-finger swipe does; and for
//   GET /scroll?v=SPEED&k=KEY
// (pixels a second, + = down, 0 = stop) and scrolls the window under the pointer at that speed.
// KEY is desk-voice's key in ~/.claude/deskpal/key.
//
// Build:  swiftc -O mac/HeadSpaces.swift -o ~/.claude/deskpal/headspaces
//         codesign -f -s "Apple Development" -i com.evan.headspaces ~/.claude/deskpal/headspaces
// Then allow ~/.claude/deskpal/headspaces in System Settings → Privacy & Security → Accessibility
// (needed to press keys; signing with your certificate keeps that across rebuilds).
// Runs as the launch agent com.evan.headspaces.
import ApplicationServices
import Foundation
import Network

let port: NWEndpoint.Port = 8765
let key = (try? String(contentsOfFile: NSHomeDirectory() + "/.claude/deskpal/key", encoding: .utf8))?
  .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

func log(_ s: String) { print("[headspaces] \(s)"); fflush(stdout) }

// Arrow keys need the fn and keypad flags, or Mission Control ignores the synthetic press.
func press(_ arrow: CGKeyCode) {
  let source = CGEventSource(stateID: .hidSystemState)
  for down in [true, false] {
    let e = CGEvent(keyboardEventSource: source, virtualKey: arrow, keyDown: down)!
    e.flags = [.maskControl, .maskSecondaryFn, .maskNumericPad]
    e.post(tap: .cghidEventTap)
  }
}

// The phone sends the scroll speed when it changes and every half second while it isn't 0; a 60 Hz
// timer scrolls at that speed, and stops by itself after a second without hearing from the phone.
var scrollSpeed = 0.0
var scrollHeard = Date.distantPast
var scrollCarry = 0.0                   // pixels owed, less than one
var scrolling = false
let scrollTimer = DispatchSource.makeTimerSource(queue: .main)
scrollTimer.schedule(deadline: .now(), repeating: 1.0 / 60)
scrollTimer.setEventHandler {
  guard scrollSpeed != 0, Date().timeIntervalSince(scrollHeard) < 1 else {
    if scrollSpeed != 0 { log("scroll: phone went quiet, stopped") }
    scrollSpeed = 0
    scrollCarry = 0
    scrolling = false
    scrollTimer.suspend()
    return
  }
  scrollCarry += scrollSpeed / 60
  let px = Int32(scrollCarry.rounded(.towardZero))
  guard px != 0 else { return }
  scrollCarry -= Double(px)
  // A positive wheel delta scrolls up, so down is negative.
  CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -px, wheel2: 0, wheel3: 0)?
    .post(tap: .cghidEventTap)
}

func scroll(_ speed: Double) {
  if (speed == 0) != (scrollSpeed == 0) { log(speed == 0 ? "scroll: stop" : "scroll: start") }
  scrollSpeed = max(-3000, min(3000, speed))
  scrollHeard = Date()
  if scrollSpeed != 0 && !scrolling {
    scrolling = true
    scrollTimer.resume()
  }
}

func handle(_ requestLine: String) -> String {
  // "GET /space/left?k=… HTTP/1.1"
  let parts = requestLine.split(separator: " ")
  guard parts.count >= 2, let c = URLComponents(string: String(parts[1])) else { return "400 Bad Request" }
  guard !key.isEmpty, c.queryItems?.first(where: { $0.name == "k" })?.value == key else { return "403 Forbidden" }
  switch c.path {
  case "/space/left": press(123)
  case "/space/right": press(124)
  case "/scroll":
    guard let v = c.queryItems?.first(where: { $0.name == "v" })?.value.flatMap(Double.init) else {
      return "400 Bad Request"
    }
    scroll(v)
    return AXIsProcessTrusted() ? "200 OK" : "503 Service Unavailable"
  default: return "404 Not Found"
  }
  log(c.path)
  return AXIsProcessTrusted() ? "200 OK" : "503 Service Unavailable"   // pressed nothing without Accessibility
}

let listener = try! NWListener(using: .tcp, on: port)
listener.newConnectionHandler = { conn in
  conn.start(queue: .main)
  conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
    let line = data.flatMap { String(data: $0, encoding: .utf8) }?.components(separatedBy: "\r\n").first ?? ""
    let status = handle(line)
    let reply = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    conn.send(content: reply.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
  }
}
listener.start(queue: .main)
if !AXIsProcessTrusted() {
  log("not allowed to press keys: add this binary in System Settings → Privacy & Security → Accessibility")
}
log("listening on :\(port)")
dispatchMain()

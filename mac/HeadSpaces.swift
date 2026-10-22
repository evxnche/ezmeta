// Head Spaces: the Mac end of Desk Pal's head-flick gesture. Listens on the LAN for
//   GET /space/left?k=KEY   or   GET /space/right?k=KEY
// from the phone and presses Ctrl+← / Ctrl+→ (Mission Control's "Move left/right a space"),
// the same switch a four-finger swipe does. KEY is desk-voice's key in ~/.claude/deskpal/key.
//
// Build:  swiftc -O mac/HeadSpaces.swift -o ~/.claude/deskpal/headspaces
// Then allow ~/.claude/deskpal/headspaces in System Settings → Privacy & Security → Accessibility
// (needed to press keys; rebuilding asks again). Runs as the launch agent com.evan.headspaces.
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

func handle(_ requestLine: String) -> String {
  // "GET /space/left?k=… HTTP/1.1"
  let parts = requestLine.split(separator: " ")
  guard parts.count >= 2, let c = URLComponents(string: String(parts[1])) else { return "400 Bad Request" }
  guard !key.isEmpty, c.queryItems?.first(where: { $0.name == "k" })?.value == key else { return "403 Forbidden" }
  switch c.path {
  case "/space/left": press(123)
  case "/space/right": press(124)
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

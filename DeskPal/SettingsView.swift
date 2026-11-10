import AVFoundation
import MWDATCore
import SwiftUI

struct SettingsView: View {
  let app: AppModel

  var body: some View {
    NavigationStack {
      Form {
        Section("Glasses") {
          if app.glasses.registration == .registered {
            LabeledContent("Name", value: app.glasses.deviceName ?? "Ray-Ban Meta")
            if let battery = app.glasses.battery { LabeledContent("Battery", value: "\(battery)%") }
          } else {
            Button("Connect Glasses") { app.glasses.register() }
              .disabled(app.glasses.registration == .registering)
          }
        }

        Section {
          Toggle("Start When I Say \u{201C}Gigi\u{201D}", isOn: Bindable(app).wakeWord)
        } footer: {
          Text("Your glasses listen for \u{201C}Gigi\u{201D} themselves. You can always double tap the glasses or press Talk instead.")
        }

        Section {
          NavigationLink {
            AgentAlertsView(app: app)
          } label: {
            Label("Agent Alerts", systemImage: "bell.badge")
          }
        } footer: {
          Text("The voice Claude Code and Codex alerts use, and answering Claude from your glasses.")
        }

        Section {
          NavigationLink {
            DiagnosticsView(app: app)
          } label: {
            Label("Diagnostics", systemImage: "stethoscope")
          }
        } footer: {
          Text("Connection details, what the glasses last heard, and the app's log, for when something isn't working.")
        }

        Section {
          LabeledContent("Version", value: Self.version)
        }
      }
      .navigationTitle("Settings")
    }
  }

  private static let version: String = {
    let info = Bundle.main.infoDictionary
    return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
  }()
}

// The pager's voice (tap one to hear it), answering Claude's permission questions by voice, and
// hearing the last alert again.
struct AgentAlertsView: View {
  let app: AppModel
  private let voices = Speaker.englishVoices

  var body: some View {
    let pager = app.pager
    List {
      Section {
        Button("Repeat Last Alert") { Task { await pager.repeatLast() } }
          .disabled(pager.last == "Nothing yet")
      } footer: {
        Text("Or say \u{201C}Gigi, what did Claude say?\u{201D}")
      }

      Section {
        Toggle("Answer Claude by Voice", isOn: Bindable(pager).replies)
      } footer: {
        Text("While your glasses are on, Claude's permission questions are read out: say \u{201C}allow\u{201D}, \u{201C}deny\u{201D} or \u{201C}always allow\u{201D}. Anything unclear leaves the question waiting on your Mac.")
      }

      Section {
        voiceRow("Automatic", detail: "Best voice installed", id: "")
        ForEach(voices, id: \.identifier) { v in
          voiceRow(v.name, detail: Self.detail(v), id: v.identifier)
        }
      } header: {
        Text("Voice")
      } footer: {
        Text("Tap a voice to hear it. Add better ones in iOS Settings → Accessibility → Spoken Content → Voices → English: Premium voices sound most natural.")
      }
    }
    .navigationTitle("Agent Alerts")
    .navigationBarTitleDisplayMode(.inline)
  }

  private func voiceRow(_ name: String, detail: String, id: String) -> some View {
    Button {
      app.pager.voiceID = id
      Task { await app.pager.preview() }
    } label: {
      HStack {
        VStack(alignment: .leading) {
          Text(name).foregroundStyle(.primary)
          Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        if app.pager.voiceID == id { Image(systemName: "checkmark").foregroundStyle(.tint) }
      }
    }
  }

  private static func detail(_ v: AVSpeechSynthesisVoice) -> String {
    let quality = v.quality == .premium ? "Premium" : v.quality == .enhanced ? "Enhanced" : "Standard"
    let region = Locale.current.localizedString(forIdentifier: v.language) ?? v.language
    return "\(quality) · \(region)"
  }
}

// Everything that's only interesting when something is broken.
struct DiagnosticsView: View {
  let app: AppModel
  private var log: Log { Log.shared }

  var body: some View {
    List {
      Section("Glasses") {
        row("Registration", app.glasses.registration.description)
        row("Link", app.glasses.link ?? "No glasses seen")
        row("Session", app.glasses.session)
        row("Touch input", app.glasses.inputs)
        row("Motion", app.glasses.motion)
        row("Speech", app.glasses.speech)
      }

      Section {
        Text(app.glasses.lastHeard.isEmpty ? "Nothing yet" : app.glasses.lastHeard)
          .foregroundStyle(app.glasses.lastHeard.isEmpty ? .secondary : .primary)
          .textSelection(.enabled)
      } header: {
        Text("Last heard")
      } footer: {
        Text("The glasses' own speech recognition. If \u{201C}Gigi\u{201D} doesn't start Desk Pal, check how it was written here.")
      }

      if app.posture.enabled || app.headSwitch.enabled || app.headScroll.enabled {
        Section("Motion") {
          if app.posture.enabled {
            row("Head tilt", app.posture.tilt.map { "\(Int($0))°" } ?? "Waiting for glasses")
            row("Looking down", String(format: "%.1f min", app.posture.downMinutes))
          }
          if app.headSwitch.enabled {
            row("Turn speed", app.headSwitch.noGyroscope ? "No gyroscope from glasses"
                : app.headSwitch.turnRate.map { "\(Int($0))°/s (switches past \(Int(HeadSwitch.flick)))" } ?? "Waiting for glasses")
            row("Last switch", app.headSwitch.last)
          }
          if app.headScroll.enabled {
            row("Scroll tilt", !app.headScroll.calibrated ? "Not calibrated"
                : app.headScroll.pitch.map { "\(Int($0))° (scrolls past \(Int(HeadScroll.deadZone)))" } ?? "Waiting for glasses")
            row("Scroll", app.headScroll.speed == 0 ? app.headScroll.last : "\(abs(app.headScroll.speed)) px/s \(app.headScroll.speed > 0 ? "down" : "up")")
          }
        }
      }

      Section("Agent alerts") {
        row("Last", app.pager.last)
      }

      Section("Log") {
        if log.lines.isEmpty {
          Text("Nothing logged yet").foregroundStyle(.secondary)
        }
        ForEach(Array(log.lines.reversed().enumerated()), id: \.offset) { _, line in
          Text(line)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
      }
    }
    .navigationTitle("Diagnostics")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ShareLink(item: log.lines.joined(separator: "\n")) {
        Label("Share Log", systemImage: "square.and.arrow.up")
      }
      .disabled(log.lines.isEmpty)
    }
  }

  private func row(_ label: String, _ value: String) -> some View {
    LabeledContent(label) {
      Text(value.isEmpty ? "—" : value).multilineTextAlignment(.trailing)
    }
  }
}

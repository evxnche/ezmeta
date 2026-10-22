import SwiftUI

// Everything Desk Pal can do. Spoken skills start with "Gigi" (or a double tap, or Talk); hands-free
// ones run on their own and have their switch here.
struct Skill: Identifiable {
  enum Switch { case pager, posture, headSwitch }

  let title: String
  let symbol: String
  let summary: String
  var examples: [String] = []
  var toggle: Switch?
  var id: String { title }

  static let spoken: [Skill] = [
    Skill(title: "Ask anything", symbol: "magnifyingglass",
          summary: "Searches the web, checks your calendar and your AI usage limits.",
          examples: ["What's on my calendar today?", "How are my Claude limits?"]),
    Skill(title: "Weather", symbol: "cloud.sun.fill",
          summary: "Now, later today and tomorrow, for home or anywhere.",
          examples: ["What's the weather?", "Will it rain in Lisbon tomorrow?"]),
    Skill(title: "Voice notes", symbol: "note.text",
          summary: "Adds a line to your Inbox note in Noty.",
          examples: ["Note: buy solder"]),
    Skill(title: "Tasks and notes", symbol: "checklist",
          summary: "Adds to-dos and reads or searches any Noty note.",
          examples: ["Add call the bank to my tasks", "What's on my plan?"]),
    Skill(title: "Read my articles", symbol: "book.fill",
          summary: "Reads your ezRead inbox aloud, newest first, and remembers where you stopped.",
          examples: ["Read my articles"]),
    Skill(title: "Dictation", symbol: "keyboard",
          summary: "Types what you say wherever the cursor is on your Mac, until you say stop. Same Wi-Fi as the Mac.",
          examples: ["Dictation mode", "Stop dictation"]),
    Skill(title: "Spanish practice", symbol: "character.bubble.fill",
          summary: "A beginner Spanish tutor until you say stop.",
          examples: ["Let's practice Spanish", "Stop practicing"]),
  ]

  static let handsFree: [Skill] = [
    Skill(title: "Agent alerts", symbol: "bell.badge.fill",
          summary: "Says when Claude Code or Codex finishes or needs you.", toggle: .pager),
    Skill(title: "Posture nudge", symbol: "figure.stand",
          summary: "A chime and a reminder after \(Int(Posture.nudgeAfter)) minutes of looking down.", toggle: .posture),
    Skill(title: "Mac Spaces", symbol: "rectangle.split.3x1.fill",
          summary: "Flick your head left or right to switch Spaces on your Mac.", toggle: .headSwitch),
  ]

  static let all = spoken + handsFree
}

struct SkillsView: View {
  let app: AppModel

  var body: some View {
    NavigationStack {
      List {
        Section {
          ForEach(Skill.spoken) { SkillRow(skill: $0) }
        } header: {
          Text("Say \u{201C}Gigi\u{201D}, then\u{2026}")
        } footer: {
          Text("Wait for the chime, then talk. Desk Pal listens a few more seconds after it answers, so you can reply without saying \u{201C}Gigi\u{201D} again.")
        }

        Section {
          ForEach(Skill.handsFree) { skill in
            Toggle(isOn: binding(skill.toggle!)) { SkillRow(skill: skill) }
            if skill.toggle == .posture && app.posture.enabled {
              Button("Calibrate Posture") { Task { await app.posture.calibrate() } }
            }
          }
        } header: {
          Text("Hands-free")
        } footer: {
          Text("Calibrate while looking straight ahead. Mac Spaces needs Head Spaces running on your Mac, on the same Wi-Fi.")
        }

        Section("Glasses controls") {
          GestureRow(symbol: "hand.tap.fill", gesture: "Double tap", action: "Talk, or stop talking")
          GestureRow(symbol: "playpause.fill", gesture: "Tap while reading", action: "Pause or resume")
          GestureRow(symbol: "forward.end.fill", gesture: "Swipe forward", action: "Next article")
          GestureRow(symbol: "backward.end.fill", gesture: "Swipe back", action: "Repeat the paragraph")
        }
      }
      .navigationTitle("Skills")
    }
  }

  private func binding(_ which: Skill.Switch) -> Binding<Bool> {
    switch which {
    case .pager: Bindable(app.pager).enabled
    case .posture: Binding(get: { app.posture.enabled }, set: { app.setPosture($0) })
    case .headSwitch: Binding(get: { app.headSwitch.enabled }, set: { app.setHeadSwitch($0) })
    }
  }
}

struct SkillRow: View {
  let skill: Skill

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      IconTile(symbol: skill.symbol)
      VStack(alignment: .leading, spacing: 4) {
        Text(skill.title).font(.body.weight(.semibold))
        Text(skill.summary).font(.subheadline).foregroundStyle(.secondary)
        ForEach(skill.examples, id: \.self) { example in
          Text("\u{201C}\(example)\u{201D}")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Color.pal)
        }
      }
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
  }
}

private struct GestureRow: View {
  let symbol: String
  let gesture: String
  let action: String

  var body: some View {
    LabeledContent {
      Text(action)
    } label: {
      Label {
        Text(gesture).foregroundStyle(.primary)
      } icon: {
        Image(systemName: symbol).foregroundStyle(Color.pal)
      }
    }
  }
}

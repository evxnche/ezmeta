import Foundation
import MediaPlayer
import Observation

// ezRead: reads the Xteink article inbox (reader-inbox) aloud, newest first, paragraph by paragraph.
// It takes over Now Playing, so the glasses' touchpad works like for music: tap pauses or resumes,
// swipe forward skips to the next article, swipe back starts the paragraph again.
// Where you stopped in each article is remembered, and finished articles are skipped next time.
@MainActor @Observable final class Reader {
  struct Article: Decodable { let id: String; let title: String; let site: String? }
  struct Paragraph: Decodable { let heading: Bool; let text: String }
  private struct Text: Decodable { let paragraphs: [Paragraph] }

  private(set) var reading = false
  private(set) var paused = false
  private(set) var title = ""
  private(set) var progress = ""

  private var articles: [Article] = []
  private var index = 0
  private var paragraphs: [Paragraph] = []
  private var position = 0
  private var skip = 0   // +1 next article, -1 repeat paragraph
  private var run: Task<Void, Never>?
  private let speaker = Speaker()
  private let defaults = UserDefaults.standard

  init() {
    let c = MPRemoteCommandCenter.shared()
    c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.togglePause(); return .success }
    c.playCommand.addTarget { [weak self] _ in if self?.paused == true { self?.togglePause() }; return .success }
    c.pauseCommand.addTarget { [weak self] _ in if self?.paused == false { self?.togglePause() }; return .success }
    c.nextTrackCommand.addTarget { [weak self] _ in self?.nextArticle(); return .success }
    c.previousTrackCommand.addTarget { [weak self] _ in self?.repeatParagraph(); return .success }
  }

  func start() {
    guard !reading else { return }
    reading = true
    paused = false
    run = Task { await readAll() }
  }

  func stop() {
    run?.cancel()
    speaker.stop()
    finish()
  }

  func togglePause() {
    guard reading else { return }
    paused.toggle()
    paused ? speaker.pause() : speaker.resume()
    updateNowPlaying()
  }

  func nextArticle() {
    guard reading else { return }
    skip = 1
    if paused { togglePause() }
    speaker.stop()
  }

  func repeatParagraph() {
    guard reading else { return }
    skip = -1
    if paused { togglePause() }
    speaker.stop()
  }

  private func readAll() async {
    AudioRoute.shared.use(.reading)
    defer { finish() }
    guard let list: [String: [Article]] = await get("/api/articles", [:]), let all = list["articles"] else {
      await speaker.say("I couldn't reach your reading list.")
      return
    }
    articles = all.filter { !finished($0.id) }
    guard !articles.isEmpty else {
      await speaker.say("You've read everything in your reading list.")
      return
    }
    log("ezRead: \(articles.count) unread")
    index = 0
    while index < articles.count, !Task.isCancelled {
      let a = articles[index]
      title = a.title
      guard let text: Text = await get("/api/text", ["id": a.id]) else {
        index += 1
        continue
      }
      paragraphs = text.paragraphs
      position = min(defaults.integer(forKey: "pos.\(a.id)"), max(0, paragraphs.count - 1))
      if position == 0, let site = a.site, !site.isEmpty { await speaker.say("From \(site).") }
      while position < paragraphs.count, !Task.isCancelled {
        updateNowPlaying()
        let p = paragraphs[position]
        let done = await speaker.say(p.text, rate: p.heading ? 0.47 : 0.5)
        if Task.isCancelled { return }
        if skip == 1 {   // skipped articles count as read
          skip = 0
          position = paragraphs.count
          break
        }
        if skip == -1 { skip = 0; continue }
        if done { position += 1 }
        defaults.set(position, forKey: "pos.\(a.id)")
      }
      if position >= paragraphs.count { defaults.set(true, forKey: "done.\(a.id)") }
      index += 1
      if index < articles.count, !Task.isCancelled { await speaker.say("Next article.") }
    }
    if !Task.isCancelled { await speaker.say("That's the end of your reading list.") }
  }

  private func finished(_ id: String) -> Bool { defaults.bool(forKey: "done.\(id)") }

  private func finish() {
    reading = false
    paused = false
    title = ""
    progress = ""
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    if AudioRoute.shared.mode == .reading { AudioRoute.shared.use(.idle) }
  }

  private func updateNowPlaying() {
    progress = paragraphs.isEmpty ? "" : "Paragraph \(position + 1) of \(paragraphs.count) · article \(index + 1) of \(articles.count)"
    MPNowPlayingInfoCenter.default().nowPlayingInfo = [
      MPMediaItemPropertyTitle: title,
      MPMediaItemPropertyArtist: "ezRead",
      MPNowPlayingInfoPropertyPlaybackRate: paused ? 0.0 : 1.0,
    ]
  }

  private func get<T: Decodable>(_ path: String, _ query: [String: String]) async -> T? {
    var q = query
    q["k"] = Config.readerKey
    let url = Config.url(Config.readerURL.appending(path: path), q)
    do {
      let (data, res) = try await URLSession.shared.data(from: url)
      guard (res as? HTTPURLResponse)?.statusCode == 200 else {
        log("ezRead \(path): HTTP \((res as? HTTPURLResponse)?.statusCode ?? 0)")
        return nil
      }
      return try JSONDecoder().decode(T.self, from: data)
    } catch {
      log("ezRead \(path): \(error.localizedDescription)")
      return nil
    }
  }
}

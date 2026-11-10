import Foundation
import MWDATCore
import MWDATInputs
import MWDATMotion
import MWDATSpeech
import Observation

// The Ray-Ban Meta connection through Meta's Wearables Device Access Toolkit:
//   registration   one-time approval in the Meta AI app (Developer Mode on)
//   session        a device session carrying Inputs (touchpad / capture button -> onInput) and,
//                  when posture or head switching is on, Motion (accelerometer, gyroscope -> onMotion),
//                  and when listening for "Gigi", Speech (the glasses' own recognizer -> onHeard)
// Folding the glasses ends the session; it's started again when they come back.
@MainActor @Observable final class Glasses {
  private(set) var registration: RegistrationState = .unavailable
  private(set) var deviceName: String?
  private(set) var battery: Int?
  private(set) var worn: Bool?
  private(set) var link: String?          // Bluetooth link and version check, e.g. "connected · Compatible"
  private(set) var linkState: LinkState?
  private(set) var session = "Not started"
  private(set) var inputs = "Off"
  private(set) var motion = "Off"
  private(set) var speech = "Off"
  private(set) var lastHeard = ""

  var onInput: (InputEvent) -> Void = { _ in }
  var onMotion: (SIMD3<Float>, SIMD3<Float>?, Int64) -> Void = { _, _, _ in }
  var onWorn: (Bool) -> Void = { _ in }
  var onHeard: (String) -> Void = { _ in }

  var wantsSpeech = false {
    didSet {
      guard wantsSpeech != oldValue else { return }
      if wantsSpeech { speechResumed = Date() }
      Task { await updateSpeech() }
    }
  }

  var motionHz: Int? {                    // 5 or 30 samples a second; nil = off
    didSet { if motionHz != oldValue { Task { await updateMotion() } } }
  }

  private let wearables = Wearables.shared
  private var deviceSession: DeviceSession?
  private var inputsCapability: Inputs?
  private var motionCapability: Motion?
  private var speechCapability: Speech?
  private var speechErrors = 0              // since it last started listening
  private var speechWatchdog: Task<Void, Never>?
  private var lastTranscript = Date()
  private var speechResumed = Date.distantPast   // wanted again after a conversation
  private var refreshingSpeech = false
  private var motionCapabilityHz: Int?
  private var tokens: [any AnyListenerToken] = []
  private var sessionTokens: [any AnyListenerToken] = []
  private var deviceTokens: [any AnyListenerToken] = []
  private var tasks: [Task<Void, Never>] = []
  private var inputsTask: Task<Void, Never>?
  private var motionTask: Task<Void, Never>?
  private var restarting = false

  func boot() {
    registration = wearables.registrationState
    tasks.append(Task {
      for await state in wearables.registrationStateStream() {
        registration = state
        log("Glasses: registration \(state.description)")
        connect()
      }
    })
    tasks.append(Task {
      for await devices in wearables.devicesStream() {
        log("Glasses: \(devices.count) device(s)")
        connect()
      }
    })
    connect()
  }

  func register() {
    Task {
      do { try await wearables.startRegistration() } catch { log("Register: \(error)") }
    }
  }

  func handle(_ url: URL) {
    guard URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true
    else { return }
    Task {
      do { _ = try await wearables.handleUrl(url) } catch { log("Meta AI callback: \(error)") }
    }
  }

  // Starts whatever isn't running yet, once registered with a device around.
  private func connect() {
    guard registration == .registered, let id = wearables.devices.first else { return }
    watchDevice(id)
    guard wearables.deviceForIdentifier(id)?.linkState == .connected else { return }   // setLink calls back
    startSession(id)
  }

  private func watchDevice(_ id: DeviceIdentifier) {
    guard let device = wearables.deviceForIdentifier(id), deviceName != device.nameOrId() || deviceTokens.isEmpty else { return }
    deviceName = device.nameOrId()
    battery = device.batteryLevel
    setWorn(device.donState)
    setLink(device.linkState, device.compatibility())
    deviceTokens = [device.addDeviceStateListener { [weak self] state in
      Task { @MainActor in
        self?.battery = state.batteryLevel
        self?.setWorn(state.donState)
        self?.setLink(state.linkState, state.compatibility)
      }
    }]
  }

  // A session only starts on glasses that are linked and compatible ("no eligible device" otherwise).
  private func setLink(_ state: LinkState, _ compatibility: Compatibility) {
    let now = "\(state) · \(compatibility.displayString)"
    linkState = state
    guard now != link else { return }
    link = now
    log("Glasses link: \(now)")
    if state == .connected { connect() }
  }

  private func setWorn(_ don: DonState) {
    let now: Bool? = don == .donned ? true : don == .doffed ? false : nil
    guard now != worn else { return }
    worn = now
    if let now { onWorn(now) }
  }

  // Names the glasses outright: a new AutoDeviceSelector hasn't picked a device yet when the session
  // is created, so it fails with "no eligible device" (Meta's samples do the same).
  private func startSession(_ id: DeviceIdentifier) {
    guard deviceSession == nil else { return }
    do {
      let s = try wearables.createSession(deviceSelector: SpecificDeviceSelector(device: id))
      deviceSession = s
      sessionTokens = [
        s.statePublisher.listen { [weak self] state in Task { @MainActor in self?.sessionChanged(state) } },
        s.errorPublisher.listen { error in log("Session error: \(error)") },
      ]
      try s.start()
      session = "Starting"
    } catch {
      session = "Failed: \(error.description)"
      log("Session start: \(error.description)")
      deviceSession = nil
      retrySoon()
    }
  }

  private func sessionChanged(_ state: DeviceSessionState) {
    session = state.description
    log("Session \(state.description)")
    switch state {
    case .started:
      addInputs()
      Task { await updateMotion() }
      Task { await updateSpeech() }
    case .stopped:
      inputsTask?.cancel()
      motionTask?.cancel()
      inputsCapability = nil
      motionCapability = nil
      speechCapability = nil
      inputs = "Off"
      motion = "Off"
      speech = "Off"
      deviceSession = nil
      sessionTokens = []
      retrySoon()
    default:
      break
    }
  }

  private func retrySoon() {
    guard !restarting else { return }
    restarting = true
    Task {
      try? await Task.sleep(for: .seconds(5))
      restarting = false
      connect()
    }
  }

  private func addInputs() {
    guard inputsCapability == nil, let s = deviceSession else { return }
    do {
      guard let i = try s.addInputs(configuration: InputsConfiguration(consumeBack: false)) else { return }
      inputsCapability = i
      inputs = "On"
      inputsTask?.cancel()
      inputsTask = Task { [weak self] in
        for await event in i.events {
          log("Input: \(event)")
          self?.onInput(event)
        }
      }
      sessionTokens.append(i.errorPublisher.listen { [weak self] error in
        Task { @MainActor in
          self?.inputs = "Error: \(error.description)"
          log("Inputs: \(error.description)")
        }
      })
    } catch {
      inputs = "Failed: \(error.description)"
      log("Inputs: \(error.description)")
    }
  }

  private func updateMotion() async {
    guard let s = deviceSession, s.state == .started else { return }
    if let m = motionCapability, motionCapabilityHz != motionHz {
      m.stop()
      motionTask?.cancel()
      motionTask = nil
      try? s.removeMotion()
      motionCapability = nil
      motion = "Off"
    }
    if let hz = motionHz, motionCapability == nil {
      do {
        guard let m = try s.addMotion(configuration: MotionConfiguration(samplingRate: hz >= 30 ? .hz30 : .hz5)) else { return }
        motionCapability = m
        motionCapabilityHz = hz
        sessionTokens.append(m.errorPublisher.listen { [weak self] error in
          Task { @MainActor in
            self?.motion = "Error: \(error.description)"
            log("Motion: \(error.description)")
          }
        })
        motionTask?.cancel()
        motionTask = Task { [weak self] in
          for await sample in m.samples {
            guard let a = sample.accelerometer else { continue }
            self?.onMotion(a.simd, sample.gyroscope?.simd, sample.timestampNs)
          }
        }
        m.start()
        motion = "On (\(hz) Hz)"
      } catch {
        motion = "Failed: \(error.description)"
        log("Motion: \(error.description)")
      }
    }
  }

  // Speech recognition runs on the glasses (Meta's Speech capability, beta) and sends text, so
  // listening for "Gigi" keeps the Bluetooth audio as it is. Needs the glasses' microphone
  // permission, asked for once through Meta AI.
  private func updateSpeech() async {
    guard let s = deviceSession, s.state == .started else { return }
    guard wantsSpeech else {
      speechCapability?.stop()
      return
    }
    if speechCapability == nil {
      guard await microphoneAllowed() else { return }
      do {
        guard let sp = try s.addSpeech() else { return }
        speechCapability = sp
        sessionTokens.append(sp.transcriptionPublisher.listen { [weak self] result in
          Task { @MainActor in
            self?.lastHeard = result.text
            self?.lastTranscript = Date()
            if result.isFinal { log("Glasses heard: \(result.text)") }
            self?.onHeard(result.text)
          }
        })
        sessionTokens.append(sp.statePublisher.listen { [weak self] state in
          Task { @MainActor in self?.speechChanged(state) }
        })
        sessionTokens.append(sp.errorPublisher.listen { [weak self] error in
          Task { @MainActor in
            self?.speechErrors += 1
            self?.speech = "Error: \(error.description)"
            log("Speech: \(error.description)")
          }
        })
      } catch {
        speech = "Failed: \(error.description)"
        log("Speech: \(error.description)")
        return
      }
    }
    if speechWatchdog == nil {
      speechWatchdog = Task { [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(5))
          await self?.checkSpeech()
        }
      }
    }
    speechCapability?.start()
  }

  // Every 5 s while it's wanted: the glasses stop listening on their own (silence, timeouts, errors),
  // so start it again, and after three failures in a row attach a fresh recognizer.
  private func checkSpeech() async {
    guard wantsSpeech, let s = deviceSession, s.state == .started else { return }
    guard let sp = speechCapability else { return await updateSpeech() }
    // It can say it's listening while no text comes through any more: after a quiet minute, restart it
    // (speechChanged starts it again once it has stopped). In the minute after a conversation, when it
    // most often comes back deaf, 15 quiet seconds is enough.
    let quiet: Double = Date().timeIntervalSince(speechResumed) < 60 ? 15 : 60
    if sp.state == .started, Date().timeIntervalSince(lastTranscript) > quiet {
      refreshingSpeech = true
      lastTranscript = Date()
      sp.stop()
      return
    }
    guard sp.state == .stopped else { return }
    if speechErrors >= 3 {
      log("Speech: reattaching")
      try? s.removeSpeech()
      speechCapability = nil
      speechErrors = 0
      await updateSpeech()
    } else {
      sp.start()
    }
  }

  // A quiet stop gets a restart a second later; one after errors waits for checkSpeech.
  private func speechChanged(_ state: SpeechState) {
    if !refreshingSpeech { log("Speech: \(state)") }
    if state == .started {
      speechErrors = 0
      refreshingSpeech = false
      lastTranscript = Date()
    }
    if speechErrors == 0 { speech = state == .started ? "Listening for \"Gigi\"" : state.description }
    guard state == .stopped, wantsSpeech, speechErrors == 0, let sp = speechCapability else { return }
    Task {
      try? await Task.sleep(for: .seconds(1))
      if wantsSpeech, speechCapability === sp, sp.state == .stopped { sp.start() }
    }
  }

  private func microphoneAllowed() async -> Bool {
    do {
      if try await wearables.checkPermissionStatus(.microphone) == .granted { return true }
      speech = "Asking Meta AI for the microphone"
      let granted = try await wearables.requestPermission(.microphone) == .granted
      if !granted { speech = "Microphone not allowed in Meta AI" }
      return granted
    } catch {
      speech = "Microphone permission: \(error.description)"
      log("Microphone permission: \(error.description)")
      return false
    }
  }
}

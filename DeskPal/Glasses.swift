import Foundation
import MWDATCore
import MWDATInputs
import MWDATMotion
import Observation

// The Ray-Ban Meta connection through Meta's Wearables Device Access Toolkit:
//   registration   one-time approval in the Meta AI app (Developer Mode on)
//   voice          "Hey Meta, start Desk Pal" launches or wakes the app -> onTalk
//   session        a device session carrying Inputs (touchpad / capture button -> onInput) and,
//                  when posture is on, Motion (accelerometer -> onMotion)
// Folding the glasses ends the session; it's started again when they come back.
@MainActor @Observable final class Glasses {
  private(set) var registration: RegistrationState = .unavailable
  private(set) var deviceName: String?
  private(set) var battery: Int?
  private(set) var worn: Bool?
  private(set) var session = "Not started"
  private(set) var inputs = "Off"
  private(set) var motion = "Off"
  private(set) var voice = "Off"

  var onTalk: () -> Void = {}
  var onInput: (InputEvent) -> Void = { _ in }
  var onMotion: (SIMD3<Float>, Int64) -> Void = { _, _ in }
  var onWorn: (Bool) -> Void = { _ in }

  var wantsMotion = false {
    didSet { if wantsMotion != oldValue { Task { await updateMotion() } } }
  }

  private let wearables = Wearables.shared
  private var deviceSession: DeviceSession?
  private var inputsCapability: Inputs?
  private var motionCapability: Motion?
  private var voiceStream: VoiceInvocationsStream?
  private var voiceDevice: DeviceIdentifier?
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
    startVoice(id)
    startSession()
  }

  private func watchDevice(_ id: DeviceIdentifier) {
    guard let device = wearables.deviceForIdentifier(id), deviceName != device.nameOrId() || deviceTokens.isEmpty else { return }
    deviceName = device.nameOrId()
    battery = device.batteryLevel
    setWorn(device.donState)
    deviceTokens = [device.addDeviceStateListener { [weak self] state in
      Task { @MainActor in
        self?.battery = state.batteryLevel
        self?.setWorn(state.donState)
      }
    }]
  }

  private func setWorn(_ don: DonState) {
    let now: Bool? = don == .donned ? true : don == .doffed ? false : nil
    guard now != worn else { return }
    worn = now
    if let now { onWorn(now) }
  }

  private func startVoice(_ id: DeviceIdentifier) {
    guard voiceDevice != id else { return }
    do {
      let stream = try voiceStream ?? VoiceInvocationsStream(wearables: wearables)
      if voiceStream == nil {
        voiceStream = stream
        tokens.append(stream.invocationsPublisher.listen { [weak self] invocation in
          guard let launch = invocation as? LaunchApp else { return }
          Task { _ = await launch.responseHandle.sendSuccess(actionOutput: nil) }
          Task { @MainActor in
            log("Hey Meta: start Desk Pal")
            self?.onTalk()
          }
        })
        tokens.append(stream.errorPublisher.listen { [weak self] error in
          Task { @MainActor in
            self?.voice = "Error: \(error.description)"
            log("Voice invocation: \(error.description)")
          }
        })
      }
      try stream.start(deviceIdentifier: id)
      voiceDevice = id
      voice = "Listening for \"Hey Meta, start Desk Pal\""
    } catch {
      voice = "Off: \(error.localizedDescription)"
      log("Voice invocation start: \(error.localizedDescription)")
    }
  }

  private func startSession() {
    guard deviceSession == nil else { return }
    do {
      let s = try wearables.createSession(deviceSelector: AutoDeviceSelector(wearables: wearables))
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
    case .stopped:
      inputsTask?.cancel()
      motionTask?.cancel()
      inputsCapability = nil
      motionCapability = nil
      inputs = "Off"
      motion = "Off"
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
    if wantsMotion, motionCapability == nil {
      do {
        guard let m = try s.addMotion(configuration: MotionConfiguration(samplingRate: .hz5)) else { return }
        motionCapability = m
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
            self?.onMotion(a.simd, sample.timestampNs)
          }
        }
        m.start()
        motion = "On (5 Hz)"
      } catch {
        motion = "Failed: \(error.description)"
        log("Motion: \(error.description)")
      }
    } else if !wantsMotion, let m = motionCapability {
      m.stop()
      motionTask?.cancel()
      motionTask = nil
      try? s.removeMotion()
      motionCapability = nil
      motion = "Off"
    }
  }
}

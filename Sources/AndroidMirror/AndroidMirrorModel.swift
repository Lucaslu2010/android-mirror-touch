import AppKit
import AOATouch
import Foundation

@MainActor
final class AndroidMirrorModel: ObservableObject {
    @Published private(set) var devices: [AndroidDevice] = []
    @Published var selectedSerial: String?
    @Published private(set) var frame: NSImage?
    @Published private(set) var status = "Looking for Android devices"
    @Published private(set) var isStreaming = false
    @Published var isVideoMaximized = false
    @Published var isMappingEditorPresented = false
    @Published var selectedBindingID: UUID?
    @Published private(set) var bindings: [TouchBinding]
    @Published var placementKind: TouchBindingKind?
    @Published private(set) var isOptionDragLocked = false
    @Published var mouseSensitivity: Double {
        didSet {
            UserDefaults.standard.set(mouseSensitivity, forKey: mouseSensitivityStorageKey)
        }
    }
    @Published var audioVolume: Double {
        didSet {
            let clamped = min(max(audioVolume, 0), 1)
            if clamped != audioVolume {
                audioVolume = clamped
                return
            }
            UserDefaults.standard.set(audioVolume, forKey: audioVolumeStorageKey)
            embeddedSession?.setAudioVolume(audioVolume)
        }
    }

    private let adb = ADBClient()
    private let bindingsStorageKey = "androidMirror.touchBindings"
    private let mouseSensitivityStorageKey = "androidMirror.mouseSensitivity"
    private let audioVolumeStorageKey = "androidMirror.audioVolume"
    private var deviceTask: Task<Void, Never>?
    private var embeddedSession: EmbeddedScrcpySession?
    private let touchInput = AOATouchInputService()
    private var inputEventMonitor: Any?
    private var isStartingAOATouch = false
    private var isAOATouchReady = false
    private var hasReceivedVideoFrame = false
    private var displayRotation: AndroidDisplayRotation?
    private var displayRotationTask: Task<Void, Never>?
    private var displayRotationPollTask: Task<Void, Never>?
    private var rawHIDTraceProcess: Process?
    private var rawHIDTracePipe: Pipe?
    private var optionKeyIsDown = false
    /// Physical Shift state, used so Shift-held W taps always begin sprinting.
    private var shiftKeyIsDown = false
    /// Shift press toggles this while W is held. Releasing W clears it.
    private var joystickSprintModeEnabled = false
    private var activeDragBindingID: UUID?
    private var activeDragPoint: CGPoint?
    private var activeHeldBindings: [String: UUID] = [:]   // key → binding ID
    private var activeHeldContactIDs: [String: UInt8] = [:] // key → AOA contact ID
    private var activeJoysticks: [UUID: ActiveJoystickState] = [:]
    private var joystickMovementTasks: [UUID: Task<Void, Never>] = [:]
    private var directMouseContactID: UInt8?
    private var directMouseTargetPoint: CGPoint?
    private var directMousePoint: CGPoint?

    init() {
        MirrorLogger.reset()
        TouchTraceLogger.reset()
        if TouchTraceLogger.isEnabled {
            touchInput.traceHandler = { report in
                TouchTraceLogger.log("AOA \(report)")
            }
        }
        bindings = Self.loadBindings()
        let storedSensitivity = UserDefaults.standard.double(forKey: "androidMirror.mouseSensitivity")
        mouseSensitivity = storedSensitivity > 0 ? min(max(storedSensitivity, 0.25), 3.0) : 1.0
        let storedAudioVolume = UserDefaults.standard.object(forKey: "androidMirror.audioVolume") as? Double
        audioVolume = min(max(storedAudioVolume ?? 0.8, 0), 1)
        selectedBindingID = bindings.first?.id
        installInputMonitor()
        refreshDevices()
        deviceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.refreshDevices()
            }
        }
    }

    deinit {
        deviceTask?.cancel()
        displayRotationTask?.cancel()
        displayRotationPollTask?.cancel()
        rawHIDTracePipe?.fileHandleForReading.readabilityHandler = nil
        rawHIDTraceProcess?.terminate()
        embeddedSession?.stop()
        joystickMovementTasks.values.forEach { $0.cancel() }
        if let inputEventMonitor {
            NSEvent.removeMonitor(inputEventMonitor)
        }
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
        touchInput.disconnect()
    }

    /// Whether a mouse button binding exists for the given button name
    /// ("mouse1", "mouse2", etc.).  The NSView uses this to skip direct
    /// touch when a binding will handle the click instead.
    func hasBindingForMouseButton(_ button: String) -> Bool {
        bindings.contains { $0.kind == .tap && $0.key.lowercased() == button }
    }

    func refreshDevices() {
        Task { [adb] in
            let result = await Task.detached { Result { try adb.devices() } }.value
            guard !Task.isCancelled else { return }

            switch result {
            case let .success(devices):
                self.devices = devices
                let readyDevices = devices.filter(\.isReady)
                if selectedSerial == nil || !readyDevices.contains(where: { $0.serial == selectedSerial }) {
                    selectedSerial = readyDevices.first?.serial
                }
                if let selectedSerial, readyDevices.contains(where: { $0.serial == selectedSerial }) {
                    if !isStreaming { startStreaming() }
                    refreshDisplayRotation(for: selectedSerial)
                } else {
                    stopStreaming()
                    frame = nil
                    status = devices.isEmpty ? "No Android device connected" : "Authorize the device in its USB debugging prompt"
                }
            case let .failure(error):
                stopStreaming()
                status = error.localizedDescription
            }
        }
    }

    func selectDevice(_ serial: String) {
        guard selectedSerial != serial else { return }
        selectedSerial = serial
        displayRotationTask?.cancel()
        displayRotationTask = nil
        displayRotation = nil
        stopStreaming()
        startStreaming()
    }

    func startStreaming() {
        guard let serial = selectedSerial, !isStreaming else { return }
        isStreaming = true
        hasReceivedVideoFrame = false
        status = "Starting embedded H.264 renderer"
        MirrorLogger.log("Starting embedded renderer for \(serial)")

        let session = EmbeddedScrcpySession(serial: serial, audioVolume: audioVolume)
        session.onFrame = { [weak self] image in
            guard let self, self.embeddedSession === session else { return }
            self.hasReceivedVideoFrame = true
            self.frame = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            self.isStreaming = true
        }
        session.onStatus = { [weak self] message in
            DispatchQueue.main.async {
                guard let self, self.embeddedSession === session else { return }
                self.status = message
                MirrorLogger.log("Session status: \(message)")
            }
        }
        session.onAudioStatus = { [weak self] message in
            DispatchQueue.main.async {
                guard let self, self.embeddedSession === session else { return }
                MirrorLogger.log("Audio status: \(message)")
                // Keep video streaming state clear while surfacing audio setup
                // errors and successful handshakes in the existing status row.
                self.status = message
            }
        }
        session.onVideoSize = { [weak self, weak session] _ in
            DispatchQueue.main.async {
                guard let self, let session, self.embeddedSession === session,
                      let serial = self.selectedSerial else { return }
                self.refreshDisplayRotation(for: serial)
            }
        }
        embeddedSession = session
        startDisplayRotationPolling(for: serial)
        session.start()
    }

    func stopStreaming() {
        displayRotationPollTask?.cancel()
        displayRotationPollTask = nil
        displayRotationTask?.cancel()
        displayRotationTask = nil
        embeddedSession?.stop()
        embeddedSession = nil
        isStreaming = false
        hasReceivedVideoFrame = false
    }

    func toggleStreaming() {
        isStreaming ? stopStreaming() : startStreaming()
    }

    func toggleVideoMaximized() {
        guard !isMappingEditorPresented else { return }
        isVideoMaximized.toggle()
    }

    func toggleMappingEditor() {
        if !isMappingEditorPresented {
            endOptionDrag()
            endDirectMouseTouch()
            endHeldKeyTouch()
            endAllJoystickTouches()
            shiftKeyIsDown = false
            joystickSprintModeEnabled = false
        }
        placementKind = nil
        isMappingEditorPresented.toggle()
    }

    /// `swift run` starts the app from a Terminal process. Explicitly making
    /// this window key prevents that Terminal from retaining keyboard focus.
    func claimInputFocus() {
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            guard let window = NSApp.windows.first(where: { $0.isVisible }) else { return }
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(window.contentView)
        }
    }

    func autoStartAOADevice() {
        guard hasReceivedVideoFrame, !isStartingAOATouch, !isAOATouchReady else { return }
        isStartingAOATouch = true
        status = "Starting AOA touch input"
        let touchInput = touchInput

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<AOAAccessoryMode, Error> = Result { try touchInput.start() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isStartingAOATouch = false
                switch result {
                case let .success(mode):
                    self.isAOATouchReady = true
                    self.status = mode.preservesADB
                        ? "AOA touch input ready"
                        : "AOA ready, but this USB mode does not retain ADB video"
                case let .failure(error):
                    self.status = "AOA touch input: \(error.localizedDescription)"
                }
            }
        }
    }

    func beginPlacement(kind: TouchBindingKind) {
        placementKind = kind
        status = "Click the screen to place a \(kind.rawValue.lowercased()) area"
    }

    func cancelPlacement() {
        placementKind = nil
    }

    func placeBinding(x: Double, y: Double) {
        guard let kind = placementKind else { return }
        addBinding(kind: kind, x: x, y: y)
        placementKind = nil
    }

    func addBinding(kind: TouchBindingKind, x: Double? = nil, y: Double? = nil) {
        let centerX = x ?? (kind == .tap ? 0.7 : 0.3)
        let centerY = y ?? 0.65
        let binding = TouchBinding(
            key: kind == .tap ? "F" : (kind == .drag ? "Option" : "WASD"),
            kind: kind,
            x: centerX,
            y: centerY,
            radius: kind == .tap ? 0.08 : 0.15,
            joystickKeys: kind == .joystick ? .wasd : nil,
            joystickSprintPoint: kind == .joystick
                ? JoystickSprintPoint(x: centerX, y: max(centerY - 0.25, 0.08))
                : nil
        )
        bindings.append(binding)
        selectedBindingID = binding.id
        saveBindings()
    }

    func removeSelectedBinding() {
        guard let selectedBindingID else { return }
        if selectedBindingID == activeDragBindingID {
            endOptionDrag()
        }
        if activeHeldBindings.values.contains(selectedBindingID) {
            // Find and end the key associated with this binding.
            if let key = activeHeldBindings.first(where: { $0.value == selectedBindingID })?.key {
                endOneHeldKeyTouch(key)
            }
        }
        endJoystick(bindingID: selectedBindingID)
        bindings.removeAll { $0.id == selectedBindingID }
        self.selectedBindingID = bindings.first?.id
        saveBindings()
    }

    func updateBinding(_ binding: TouchBinding) {
        guard let index = bindings.firstIndex(where: { $0.id == binding.id }) else { return }
        var updated = binding
        // The inspector edits keys/radius from local SwiftUI state while the
        // canvas edits positions directly. Preserve live canvas geometry so a
        // later text-field or slider change cannot move either marker back.
        updated.x = bindings[index].x
        updated.y = bindings[index].y
        updated.joystickSprintPoint = bindings[index].joystickSprintPoint
        updated.joystickSprintLeftPoint = bindings[index].joystickSprintLeftPoint
        updated.joystickSprintRightPoint = bindings[index].joystickSprintRightPoint
        bindings[index] = updated
        saveBindings()
    }

    func moveBinding(id: UUID, x: Double, y: Double) {
        guard let index = bindings.firstIndex(where: { $0.id == id }) else { return }
        bindings[index].x = min(max(x, 0), 1)
        bindings[index].y = min(max(y, 0), 1)
        saveBindings()
    }

    func resizeBinding(id: UUID, radius: Double) {
        guard let index = bindings.firstIndex(where: { $0.id == id }) else { return }
        bindings[index].radius = min(max(radius, 0.03), 0.45)
        saveBindings()
    }

    func moveJoystickSprint(bindingID: UUID, x: Double, y: Double) {
        guard let index = bindings.firstIndex(where: { $0.id == bindingID && $0.kind == .joystick }) else { return }
        bindings[index].joystickSprintPoint = JoystickSprintPoint(
            x: min(max(x, 0), 1),
            y: min(max(y, 0), 1)
        )
        selectedBindingID = bindingID
        saveBindings()
    }

    func moveJoystickSprintDirection(bindingID: UUID, direction: JoystickDirection, x: Double, y: Double) {
        guard direction == .left || direction == .right,
              let index = bindings.firstIndex(where: { $0.id == bindingID && $0.kind == .joystick }) else { return }
        let point = JoystickSprintPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
        if direction == .left {
            bindings[index].joystickSprintLeftPoint = point
        } else {
            bindings[index].joystickSprintRightPoint = point
        }
        selectedBindingID = bindingID
        saveBindings()
    }

    /// Start a brand-new direct touch. A mouseDown must never continue a stale
    /// drag from an earlier press whose mouseUp was lost by the window.
    func beginDirectMouseTouch(x: Double, y: Double) {
        guard !isMappingEditorPresented else { return }
        guard hasReceivedVideoFrame else {
            status = "Waiting for the phone stream before enabling touch input"
            return
        }
        guard !isStartingAOATouch else {
            status = "Waiting for AOA touch input to start"
            return
        }

        if isOptionDragLocked {
            endOptionDrag()
        }

        if directMouseContactID != nil {
            TouchTraceLogger.log("HID stale direct contact closed before new MOUSE DOWN")
            endDirectMouseTouch()
        }

        let point = CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
        directMousePoint = point
        do {
            let rotation = displayRotation ?? fallbackDisplayRotation
            let touchPoint = correctedTouchPoint(x: point.x, y: point.y, rotation: rotation)
            MirrorLogger.log(
                "DIRECT TOUCH mapper=inverse-surface-orientation preview=(\(point.x),\(point.y)) rotation=\(rotation.rawValue) rawHID=(\(touchPoint.x),\(touchPoint.y))"
            )
            TouchTraceLogger.log("HID DOWN preview=(\(point.x),\(point.y)) output=(\(touchPoint.x),\(touchPoint.y)) rotation=\(rotation)")
            directMouseContactID = try touchInput.beginContact(x: touchPoint.x, y: touchPoint.y)
            startRawHIDTraceIfNeeded()
            directMouseTargetPoint = touchPoint
            status = "Touching screen through AOA HID"
        } catch {
            directMouseContactID = nil
            directMouseTargetPoint = nil
            directMousePoint = nil
            reportTouchError(error)
        }
    }

    /// Move only an existing contact. A drag event is never allowed to create
    /// a new Android touch implicitly.
    func moveDirectMouseTouch(x: Double, y: Double) {
        guard directMouseContactID != nil, !isMappingEditorPresented else { return }
        let point = CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
        // A physical HID touchscreen uses the panel's natural axes. Unlike a
        // window-coordinate snapshot, this transform must follow the phone's
        // *current* rotation while a mouse drag is in progress.
        let rotation = displayRotation ?? fallbackDisplayRotation
        let touchPoint = correctedTouchPoint(x: point.x, y: point.y, rotation: rotation)
        directMousePoint = point
        directMouseTargetPoint = touchPoint
        TouchTraceLogger.log("HID MOVE preview=(\(point.x),\(point.y)) output=(\(touchPoint.x),\(touchPoint.y)) rotation=\(rotation)")
        sendDirectMouseMove(to: touchPoint)
    }

    func endDirectMouseTouch() {
        guard let contactID = directMouseContactID else { return }
        do {
            TouchTraceLogger.log("HID UP output=(\(String(describing: directMouseTargetPoint)))")
            try touchInput.endContact(contactID)
        } catch {
            reportTouchError(error)
        }
        directMouseContactID = nil
        directMouseTargetPoint = nil
        directMousePoint = nil
        status = "Touch released"
    }

    private func sendDirectMouseMove(to point: CGPoint) {
        guard let contactID = directMouseContactID else { return }
        do {
            let t0 = ProcessInfo.processInfo.systemUptime
            try touchInput.moveContact(contactID, x: point.x, y: point.y)
            let ms = (ProcessInfo.processInfo.systemUptime - t0) * 1000
            TouchTraceLogger.log("HID MOVE output=(\(point.x),\(point.y)) usbMs=\(String(format: "%.2f", ms))")
        } catch {
            directMouseContactID = nil
            reportTouchError(error)
        }
    }

    private func installInputMonitor() {
        inputEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [
                .keyDown, .keyUp, .flagsChanged,
                .mouseMoved, .leftMouseDragged, .rightMouseDragged,
                .leftMouseDown, .leftMouseUp,
                .rightMouseDown, .rightMouseUp,
                .otherMouseDown, .otherMouseUp
            ]
        ) { [weak self] event in
            // Local monitors run on the main event thread. Handle the event
            // before returning it so down/up ordering cannot be rearranged by
            // separately scheduled MainActor tasks while mouse lock is active.
            self?.handleInputEvent(event)
            return event
        }
    }

    private func handleInputEvent(_ event: NSEvent) {
        if isMappingEditorPresented {
            if event.type == .keyDown, event.keyCode == 53 {
                cancelPlacement()
            }
            return
        }

        switch event.type {
        case .keyDown:
            beginHeldKeyTouch(for: event)
        case .keyUp:
            endHeldKeyTouch(for: event)
        case .flagsChanged:
            handleOptionKey(event)
            handleShiftKey(event)
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
            guard isOptionDragLocked else { return }
            moveOptionDrag(deltaX: Double(event.deltaX), deltaY: Double(event.deltaY))
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            guard isOptionDragLocked else { return }
            beginMouseButtonTouch(button: normalizedKey(event))
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            endMouseButtonTouch(button: normalizedKey(event))
        default:
            break
        }
    }

    private func handleOptionKey(_ event: NSEvent) {
        // flagsChanged is sent for both pressing and releasing Option. Toggle
        // only on its key-down transition, so releasing Option does nothing.
        guard event.keyCode == 58 || event.keyCode == 61 else { return }
        let optionIsDown = event.modifierFlags.contains(.option)
        defer { optionKeyIsDown = optionIsDown }
        guard optionIsDown, !optionKeyIsDown else { return }

        isOptionDragLocked ? endOptionDrag() : beginOptionDrag()
    }

    private func handleShiftKey(_ event: NSEvent) {
        guard event.keyCode == 56 || event.keyCode == 60 else { return }
        let isDown = event.modifierFlags.contains(.shift)
        guard isDown != shiftKeyIsDown else { return }
        shiftKeyIsDown = isDown

        // Shift is a toggle on its press transition only. Its release does
        // not undo sprint; pressing Shift again does. Holding Shift before a
        // short W tap is separately supported by joystickTarget(for:).
        guard isDown else { return }
        let hasActiveUpDirection = activeJoysticks.values.contains { $0.pressedDirections.contains(.up) }
        guard hasActiveUpDirection else { return }
        joystickSprintModeEnabled.toggle()

        // Keep the same HID contact alive and move it through the usual route
        // between W and the independently positioned sprint target.
        for binding in bindings where binding.kind == .joystick {
            guard var state = activeJoysticks[binding.id],
                  state.pressedDirections.contains(.up),
                  state.contactID != nil else { continue }

            let target = joystickTarget(for: binding, directions: state.pressedDirections)
            let token = UUID()
            state.transitionToken = token
            activeJoysticks[binding.id] = state
            scheduleJoystickDrag(binding: binding, to: target, token: token)
            TouchTraceLogger.log(
                "JOYSTICK SPRINT toggle=\(joystickSprintModeEnabled) directions=\(state.pressedDirections.map(\.rawValue).sorted()) target=\(target)"
            )
        }
    }

    private func beginHeldKeyTouch(for event: NSEvent) {
        guard !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control) else { return }
        guard hasReceivedVideoFrame else { return }
        guard !isStartingAOATouch else { return }
        guard !event.isARepeat else { return }
        let key = normalizedKey(event)
        guard !key.isEmpty else { return }

        // If focus moved to this app while Shift was already held, AppKit may
        // not have delivered the earlier flagsChanged event. The key event is
        // still authoritative for a Shift-held W sprint tap.
        if event.modifierFlags.contains(.shift) {
            shiftKeyIsDown = true
        }

        // Joystick directions take priority over ordinary tap bindings. A
        // direction change moves one persistent contact instead of creating
        // separate cardinal and diagonal touches.
        if handleJoystickKeyDown(key) { return }

        guard let binding = bindings.first(where: { $0.kind == .tap && $0.key.lowercased() == key }) else { return }
        guard activeHeldBindings[key] == nil else { return }   // already held

        // Don't end option-drag lock — only pressing Option should release it.
        // Don't end direct touch while locked either.
        if !isOptionDragLocked {
            endDirectMouseTouch()
        }
        do {
            let previewPoint = randomPoint(in: binding)
            let touchPoint = correctedTouchPoint(x: previewPoint.x, y: previewPoint.y)
            TouchTraceLogger.log("KEY DOWN \(key) randomPreview=\(previewPoint) HID output=(\(touchPoint.x),\(touchPoint.y))")
            let contactID = try touchInput.beginContact(x: touchPoint.x, y: touchPoint.y)
            startRawHIDTraceIfNeeded()
            activeHeldBindings[key] = binding.id
            activeHeldContactIDs[key] = contactID
            status = "Holding \(activeHeldBindings.keys.joined(separator: "+"))"
        } catch {
            reportTouchError(error)
        }
    }

    private func endHeldKeyTouch(for event: NSEvent) {
        let key = normalizedKey(event)
        if handleJoystickKeyUp(key) { return }
        guard activeHeldBindings[key] != nil else { return }
        endOneHeldKeyTouch(key)
    }

    // MARK: - Joystick bindings

    @discardableResult
    private func handleJoystickKeyDown(_ key: String) -> Bool {
        let matches = bindings.compactMap { binding -> (TouchBinding, JoystickDirection)? in
            guard binding.kind == .joystick,
                  let direction = (binding.joystickKeys ?? .wasd).direction(for: key) else { return nil }
            return (binding, direction)
        }
        guard !matches.isEmpty else { return false }
        guard hasReceivedVideoFrame, !isStartingAOATouch else { return true }

        if !isOptionDragLocked {
            endDirectMouseTouch()
        }

        for (binding, direction) in matches {
            var state = activeJoysticks[binding.id] ?? ActiveJoystickState()
            let inserted = state.pressedDirections.insert(direction).inserted
            guard inserted else { continue }

            do {
                if state.contactID == nil {
                    // R1 begins near the neutral center, never directly at the
                    // requested direction. R1→R2 is always a real drag.
                    let r1 = randomPoint(in: binding, radiusFraction: 0.10)
                    let touchPoint = correctedTouchPoint(x: r1.x, y: r1.y)
                    state.contactID = try touchInput.beginContact(x: touchPoint.x, y: touchPoint.y)
                    state.currentPoint = r1
                    startRawHIDTraceIfNeeded()
                }

                let r2 = joystickTarget(for: binding, directions: state.pressedDirections)
                let token = UUID()
                state.transitionToken = token
                activeJoysticks[binding.id] = state
                scheduleJoystickDrag(binding: binding, to: r2, token: token)
                TouchTraceLogger.log("JOYSTICK DOWN key=\(key) directions=\(state.pressedDirections.map(\.rawValue).sorted()) R1=\(String(describing: state.currentPoint)) R2=\(r2)")
            } catch {
                reportTouchError(error)
            }
        }
        status = joystickStatus
        return true
    }

    @discardableResult
    private func handleJoystickKeyUp(_ key: String) -> Bool {
        let matches = bindings.compactMap { binding -> (TouchBinding, JoystickDirection)? in
            guard binding.kind == .joystick,
                  let direction = (binding.joystickKeys ?? .wasd).direction(for: key) else { return nil }
            return (binding, direction)
        }
        guard !matches.isEmpty else { return false }

        for (binding, direction) in matches {
            // Releasing W always clears the persistent sprint toggle. If
            // Shift is still physically held, the next W press still starts
            // at the sprint target through shiftKeyIsDown.
            if direction == .up {
                joystickSprintModeEnabled = false
            }
            guard var state = activeJoysticks[binding.id],
                  state.pressedDirections.remove(direction) != nil else { continue }

            joystickMovementTasks.removeValue(forKey: binding.id)?.cancel()
            do {
                if state.pressedDirections.isEmpty {
                    if let contactID = state.contactID {
                        try touchInput.endContact(contactID)
                    }
                    activeJoysticks.removeValue(forKey: binding.id)
                    TouchTraceLogger.log("JOYSTICK UP key=\(key) released contact")
                } else {
                    let r2 = joystickTarget(for: binding, directions: state.pressedDirections)
                    let token = UUID()
                    state.transitionToken = token
                    activeJoysticks[binding.id] = state
                    scheduleJoystickDrag(binding: binding, to: r2, token: token)
                    TouchTraceLogger.log("JOYSTICK UP key=\(key) remaining=\(state.pressedDirections.map(\.rawValue).sorted()) R1=\(String(describing: state.currentPoint)) R2=\(r2)")
                }
            } catch {
                reportTouchError(error)
            }
        }
        status = activeJoysticks.isEmpty ? "Touch released" : joystickStatus
        return true
    }

    private func randomJoystickPoint(for binding: TouchBinding, directions: Set<JoystickDirection>) -> CGPoint {
        let horizontal = (directions.contains(.right) ? 1.0 : 0.0)
            - (directions.contains(.left) ? 1.0 : 0.0)
        let vertical = (directions.contains(.down) ? 1.0 : 0.0)
            - (directions.contains(.up) ? 1.0 : 0.0)
        let magnitude = hypot(horizontal, vertical)
        guard magnitude > 0 else { return randomPoint(in: binding, radiusFraction: 0.10) }

        // R2 stays near its requested direction but is randomized radially and
        // angularly on every transition. Keeping it below 94% leaves room for
        // the outward curve and stutters without crossing the circle edge.
        let unit = CGPoint(x: horizontal / magnitude, y: vertical / magnitude)
        let angularJitter = Double.random(in: -0.09...0.09)
        let jittered = normalizedPhysicalVector(CGPoint(
            x: unit.x - unit.y * angularJitter,
            y: unit.y + unit.x * angularJitter
        ))
        let radialDistance = binding.radius * Double.random(in: 0.82...0.94)
        return previewPoint(
            center: CGPoint(x: binding.x, y: binding.y),
            physicalOffset: CGPoint(x: jittered.x * radialDistance, y: jittered.y * radialDistance)
        )
    }

    private func joystickTarget(for binding: TouchBinding, directions: Set<JoystickDirection>) -> CGPoint {
        if directions.contains(.up), (joystickSprintModeEnabled || shiftKeyIsDown) {
            return sprintPoint(for: binding, directions: directions)
        }
        return randomJoystickPoint(for: binding, directions: directions)
    }

    private func sprintPoint(for binding: TouchBinding, directions: Set<JoystickDirection>) -> CGPoint {
        let hasLeft = directions.contains(.left)
        let hasRight = directions.contains(.right)
        let point: JoystickSprintPoint
        if hasLeft != hasRight {
            point = hasLeft
                ? (binding.joystickSprintLeftPoint ?? defaultDiagonalSprintPoint(for: binding, direction: .left))
                : (binding.joystickSprintRightPoint ?? defaultDiagonalSprintPoint(for: binding, direction: .right))
        } else {
            point = binding.joystickSprintPoint
                ?? JoystickSprintPoint(x: binding.x, y: max(binding.y - 0.25, 0.08))
        }
        return CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
    }

    private func defaultDiagonalSprintPoint(for binding: TouchBinding, direction: JoystickDirection) -> JoystickSprintPoint {
        let horizontal = direction == .left ? -1.0 : 1.0
        return JoystickSprintPoint(
            x: min(max(binding.x + horizontal * binding.radius * 0.8, 0), 1),
            y: min(max(binding.y - binding.radius * 0.8, 0), 1)
        )
    }

    private func scheduleJoystickDrag(binding: TouchBinding, to target: CGPoint, token: UUID) {
        joystickMovementTasks.removeValue(forKey: binding.id)?.cancel()
        guard let state = activeJoysticks[binding.id],
              let start = state.currentPoint,
              let contactID = state.contactID else { return }

        let route = makeJoystickRoute(binding: binding, from: start, to: target)
        joystickMovementTasks[binding.id] = Task { [weak self] in
            guard let self else { return }
            for sample in route {
                do {
                    try await Task.sleep(for: .milliseconds(sample.delayMilliseconds))
                } catch {
                    return
                }
                guard !Task.isCancelled,
                      var latest = self.activeJoysticks[binding.id],
                      latest.transitionToken == token,
                      latest.contactID == contactID else { return }

                let touchPoint = self.correctedTouchPoint(x: sample.point.x, y: sample.point.y)
                do {
                    try self.touchInput.moveContact(contactID, x: touchPoint.x, y: touchPoint.y)
                    latest.currentPoint = sample.point
                    self.activeJoysticks[binding.id] = latest
                    TouchTraceLogger.log("JOYSTICK DRAG preset=\(sample.preset.rawValue) preview=\(sample.point) HID=\(touchPoint)")
                } catch {
                    self.reportTouchError(error)
                    return
                }
            }
        }
    }

    private func makeJoystickRoute(binding: TouchBinding, from start: CGPoint, to target: CGPoint) -> [JoystickRouteSample] {
        let center = CGPoint(x: binding.x, y: binding.y)
        let p0 = physicalOffset(from: center, to: start)
        let p2 = physicalOffset(from: center, to: target)
        let midpoint = CGPoint(x: (p0.x + p2.x) * 0.5, y: (p0.y + p2.y) * 0.5)
        let chord = CGPoint(x: p2.x - p0.x, y: p2.y - p0.y)

        // The Bézier control point is pushed away from the joystick center.
        // For a diametric transition whose midpoint is exactly centered, pick
        // one of the two outward sides at random.
        var outward = normalizedPhysicalVector(midpoint)
        if hypot(outward.x, outward.y) < 0.001 {
            let side = Bool.random() ? 1.0 : -1.0
            outward = normalizedPhysicalVector(CGPoint(x: -chord.y * side, y: chord.x * side))
        }
        let curveAmount = binding.radius * Double.random(in: 0.10...0.24)
        let endpointRadius = max(hypot(p0.x, p0.y), hypot(p2.x, p2.y)) * 1.04
        let routeRadius = max(binding.radius * 0.985, endpointRadius)
        var control = CGPoint(x: midpoint.x + outward.x * curveAmount, y: midpoint.y + outward.y * curveAmount)
        control = clampedPhysicalOffset(control, radius: routeRadius)

        let preset = JoystickStutterPreset.allCases.randomElement() ?? .hesitation
        let occurrence = Double.random(in: 0.22...0.78)
        let occurrenceCoefficient = Double.random(in: 0.18...0.48)
        let sizeCoefficient = Double.random(in: 0.010...0.040)
        let steps = Int.random(in: 12...18)
        TouchTraceLogger.log(
            "JOYSTICK ROUTE preset=\(preset.rawValue) curve=\(curveAmount) occurrence=\(occurrence) occurrenceCoefficient=\(occurrenceCoefficient) sizeCoefficient=\(sizeCoefficient) steps=\(steps)"
        )

        var samples: [JoystickRouteSample] = []
        samples.reserveCapacity(steps)
        for step in 1...steps {
            let rawT = Double(step) / Double(steps)
            let easedT = rawT * rawT * (3 - 2 * rawT)
            let stutter = preset.offsets(
                progress: easedT,
                occurrence: occurrence,
                occurrenceCoefficient: occurrenceCoefficient,
                sizeCoefficient: sizeCoefficient
            )
            let t = min(max(easedT + stutter.progress, 0), 1)
            let oneMinusT = 1 - t
            let p0Weight = oneMinusT * oneMinusT
            let controlWeight = 2 * oneMinusT * t
            let p2Weight = t * t
            var physical = CGPoint(
                x: p0Weight * p0.x + controlWeight * control.x + p2Weight * p2.x,
                y: p0Weight * p0.y + controlWeight * control.y + p2Weight * p2.y
            )

            let tangentX = 2 * oneMinusT * (control.x - p0.x) + 2 * t * (p2.x - control.x)
            let tangentY = 2 * oneMinusT * (control.y - p0.y) + 2 * t * (p2.y - control.y)
            let tangent = normalizedPhysicalVector(CGPoint(x: tangentX, y: tangentY))
            let lateralMagnitude = binding.radius * stutter.lateral
            physical.x += -tangent.y * lateralMagnitude
            physical.y += tangent.x * lateralMagnitude
            // Ordinary directions remain inside the joystick circle. Sprint
            // routes may extend to a target anywhere on the preview, so their
            // limit expands just enough to contain both endpoints.
            physical = clampedPhysicalOffset(physical, radius: routeRadius)

            samples.append(JoystickRouteSample(
                point: previewPoint(center: center, physicalOffset: physical),
                delayMilliseconds: Int.random(in: 5...11),
                preset: preset
            ))
        }
        return samples
    }

    private func randomPoint(in binding: TouchBinding, radiusFraction: Double = 1.0) -> CGPoint {
        // sqrt(U) distributes points uniformly by area instead of clustering
        // them around the center.
        let radius = binding.radius * min(max(radiusFraction, 0), 1) * sqrt(Double.random(in: 0...1))
        let angle = Double.random(in: 0..<(2 * Double.pi))
        return previewPoint(
            center: CGPoint(x: binding.x, y: binding.y),
            physicalOffset: CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
        )
    }

    private func previewPoint(center: CGPoint, physicalOffset: CGPoint) -> CGPoint {
        let aspect = screenAspect
        let xScale = aspect >= 1 ? 1 / aspect : 1
        let yScale = aspect >= 1 ? 1 : aspect
        return CGPoint(
            x: min(max(center.x + physicalOffset.x * xScale, 0), 1),
            y: min(max(center.y + physicalOffset.y * yScale, 0), 1)
        )
    }

    private func physicalOffset(from center: CGPoint, to point: CGPoint) -> CGPoint {
        let aspect = screenAspect
        let xScale = aspect >= 1 ? 1 / aspect : 1
        let yScale = aspect >= 1 ? 1 : aspect
        return CGPoint(x: (point.x - center.x) / xScale, y: (point.y - center.y) / yScale)
    }

    private func normalizedPhysicalVector(_ vector: CGPoint) -> CGPoint {
        let length = hypot(vector.x, vector.y)
        guard length > 0.000_001 else { return .zero }
        return CGPoint(x: vector.x / length, y: vector.y / length)
    }

    private func clampedPhysicalOffset(_ point: CGPoint, radius: Double) -> CGPoint {
        let length = hypot(point.x, point.y)
        guard length > radius, length > 0 else { return point }
        return CGPoint(x: point.x / length * radius, y: point.y / length * radius)
    }

    private func endJoystick(bindingID: UUID) {
        joystickMovementTasks.removeValue(forKey: bindingID)?.cancel()
        guard let state = activeJoysticks.removeValue(forKey: bindingID),
              let contactID = state.contactID else { return }
        do {
            try touchInput.endContact(contactID)
        } catch {
            reportTouchError(error)
        }
    }

    private func endAllJoystickTouches() {
        for bindingID in Array(activeJoysticks.keys) {
            endJoystick(bindingID: bindingID)
        }
        joystickSprintModeEnabled = false
    }

    private var joystickStatus: String {
        let directions = activeJoysticks.values
            .flatMap(\.pressedDirections)
            .map(\.rawValue)
            .sorted()
            .joined(separator: "+")
        return directions.isEmpty ? "Touch released" : "Joystick \(directions)"
    }

    /// End one specific held key touch.
    private func endOneHeldKeyTouch(_ key: String) {
        guard activeHeldBindings.removeValue(forKey: key) != nil else { return }
        if let contactID = activeHeldContactIDs.removeValue(forKey: key) {
            do {
                TouchTraceLogger.log("KEY UP \(key) contactID=\(contactID)")
                try touchInput.endContact(contactID)
            } catch {
                reportTouchError(error)
            }
        }
        status = activeHeldBindings.isEmpty ? "Touch released" : "Holding \(activeHeldBindings.keys.joined(separator: "+"))"
    }

    /// End all held key touches.
    private func endHeldKeyTouch() {
        for key in activeHeldBindings.keys {
            endOneHeldKeyTouch(key)
        }
    }

    // MARK: - Mouse button bindings (called by PreviewMouseCaptureNSView)

    func beginMouseButtonTouch(button: String) {
        guard hasReceivedVideoFrame else { return }
        guard !isStartingAOATouch else { return }
        guard !button.isEmpty else { return }

        guard let binding = bindings.first(where: { $0.kind == .tap && $0.key.lowercased() == button }) else { return }
        guard activeHeldBindings[button] == nil else { return }

        do {
            let previewPoint = randomPoint(in: binding)
            let touchPoint = correctedTouchPoint(x: previewPoint.x, y: previewPoint.y)
            TouchTraceLogger.log("MOUSE BUTTON DOWN \(button) randomPreview=\(previewPoint) HID output=(\(touchPoint.x),\(touchPoint.y))")
            let contactID = try touchInput.beginContact(x: touchPoint.x, y: touchPoint.y)
            startRawHIDTraceIfNeeded()
            activeHeldBindings[button] = binding.id
            activeHeldContactIDs[button] = contactID
            status = "Holding \(activeHeldBindings.keys.joined(separator: "+"))"
        } catch {
            reportTouchError(error)
        }
    }

    func endMouseButtonTouch(button: String) {
        guard activeHeldBindings[button] != nil else { return }
        endOneHeldKeyTouch(button)
    }

    private func beginOptionDrag() {
        guard hasReceivedVideoFrame else {
            status = "Waiting for the phone stream before enabling touch input"
            return
        }
        guard !isStartingAOATouch else {
            status = "Waiting for AOA touch input to start"
            return
        }
        endDirectMouseTouch()
        let selectedDrag = bindings.first { $0.id == selectedBindingID && $0.kind == .drag }
        guard let binding = selectedDrag ?? bindings.first(where: { $0.kind == .drag }) else {
            status = "Add a Drag area before using Option mouse lock"
            return
        }

        do {
            let startPoint = randomPoint(in: binding, radiusFraction: 0.30)
            let touchPoint = correctedTouchPoint(x: startPoint.x, y: startPoint.y)
            try touchInput.beginDrag(x: touchPoint.x, y: touchPoint.y)
            activeDragBindingID = binding.id
            activeDragPoint = startPoint
            isOptionDragLocked = true
            CGAssociateMouseAndMouseCursorPosition(0)
            NSCursor.hide()
            TouchTraceLogger.log("OPTION-DRAG BEGIN randomPreview=\(startPoint) HID=\(touchPoint)")
            status = "Mouse locked to Drag area — press Option again to stop"
        } catch {
            reportTouchError(error)
        }
    }

    private func moveOptionDrag(deltaX: Double, deltaY: Double) {
        guard let binding = activeDragBinding,
              var point = activeDragPoint else { return }

        // Preview coordinates are down-positive, matching NSEvent mouse
        // deltas. Rotation is applied later by correctedTouchPoint. Keeping
        // the sign here fixes inverted vertical look in landscape.
        let scale = 0.0018 * mouseSensitivity
        var remaining = CGPoint(x: deltaX * scale, y: deltaY * scale)
        let aspect = screenAspect
        let center = CGPoint(x: binding.x, y: binding.y)
        let radius = binding.radius
        let rot = displayRotation ?? fallbackDisplayRotation
        TouchTraceLogger.log("OPTION-DRAG delta=(\(deltaX),\(deltaY)) remaining=(\(remaining.x),\(remaining.y)) rotation=\(rot) point=(\(point.x),\(point.y))")

        while physicalLength(remaining, aspect: aspect) > 0.000_01 {
            let length = physicalLength(remaining, aspect: aspect)
            let unit = CGPoint(
                x: remaining.x / length,
                y: remaining.y / aspect / length
            )
            let boundaryDistance = distanceToCircleEdge(
                from: point,
                center: center,
                radius: radius,
                direction: unit,
                aspect: aspect
            )

            if length <= boundaryDistance {
                point.x += remaining.x
                point.y += remaining.y
                sendDragMove(to: point)
                remaining = .zero
            } else {
                point.x += unit.x * boundaryDistance
                point.y += unit.y * aspect * boundaryDistance
                sendDragMove(to: point)
                do {
                    try touchInput.endDrag()
                    // Every new drag contact starts at a fresh random point
                    // inside the circle's inner 30%, including edge restarts.
                    point = randomPoint(in: binding, radiusFraction: 0.30)
                    let touchPoint = correctedTouchPoint(x: point.x, y: point.y)
                    try touchInput.beginDrag(x: touchPoint.x, y: touchPoint.y)
                    TouchTraceLogger.log("OPTION-DRAG RESTART randomPreview=\(point) HID=\(touchPoint)")
                } catch {
                    reportTouchError(error)
                    endOptionDrag()
                    return
                }
                remaining.x -= unit.x * boundaryDistance
                remaining.y -= unit.y * aspect * boundaryDistance
            }
        }
        activeDragPoint = point
    }

    private func sendDragMove(to point: CGPoint) {
        do {
            let touchPoint = correctedTouchPoint(x: point.x, y: point.y)
            TouchTraceLogger.log("OPTION-DRAG SEND preview=(\(point.x),\(point.y)) → HID=(\(touchPoint.x),\(touchPoint.y)) rot=\(String(describing: displayRotation))")
            try touchInput.moveDrag(x: touchPoint.x, y: touchPoint.y)
        } catch {
            reportTouchError(error)
            endOptionDrag()
        }
    }

    private func endOptionDrag() {
        guard isOptionDragLocked || activeDragBindingID != nil else { return }
        do {
            try touchInput.endDrag()
        } catch {
            reportTouchError(error)
        }
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
        activeDragBindingID = nil
        activeDragPoint = nil
        isOptionDragLocked = false
    }

    private func reportTouchError(_ error: Error) {
        let message = error.localizedDescription
        guard message.contains("LIBUSB_ERROR_NO_DEVICE") else {
            status = "Touch input: \(message)"
            return
        }

        // The phone was unplugged or re-enumerated after an AOA switch. Drop
        // the invalid libusb handle and reconnect once the video path is back.
        touchInput.disconnect()
        isAOATouchReady = false
        status = "AOA USB reconnected; restoring touch input"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.autoStartAOADevice()
        }
    }

    private var activeDragBinding: TouchBinding? {
        bindings.first { $0.id == activeDragBindingID }
    }

    private var screenAspect: Double {
        guard let frame, frame.size.height > 0 else { return 9.0 / 16.0 }
        return max(Double(frame.size.width / frame.size.height), 0.01)
    }

    private func refreshDisplayRotation(for serial: String) {
        guard displayRotationTask == nil else { return }
        let adb = adb
        displayRotationTask = Task { [weak self] in
            let result = await Task.detached {
                Result { try adb.displayRotation(serial: serial) }
            }.value
            guard !Task.isCancelled else { return }
            if case let .success(rotation) = result, let rotation {
                guard let self else { return }
                if self.displayRotation != rotation {
                    MirrorLogger.log("Input SurfaceOrientation changed: \(String(describing: self.displayRotation?.rawValue)) -> \(rotation.rawValue)")
                    TouchTraceLogger.log("DISPLAY ROTATION \(String(describing: self.displayRotation)) → \(rotation)")
                    self.displayRotation = rotation
                }
            }
            self?.displayRotationTask = nil
        }
    }

    private func startDisplayRotationPolling(for serial: String) {
        displayRotationPollTask?.cancel()
        refreshDisplayRotation(for: serial)
        displayRotationPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self,
                      self.isStreaming,
                      self.selectedSerial == serial else { return }
                self.refreshDisplayRotation(for: serial)
            }
        }
    }

    private func startRawHIDTraceIfNeeded() {
        guard TouchTraceLogger.isEnabled,
              rawHIDTraceProcess == nil,
              let serial = selectedSerial else { return }
        let adb = adb
        Task { [weak self] in
            let result = await Task.detached {
                Result { try adb.accessoryTouchEventPath(serial: serial) }
            }.value
            guard let self, case let .success(eventPath?) = result, rawHIDTraceProcess == nil else { return }

            let pipe = Pipe()
            do {
                let process = try adb.start(["-s", serial, "shell", "getevent", "-lt", eventPath], output: pipe)
                rawHIDTraceProcess = process
                rawHIDTracePipe = pipe
                TouchTraceLogger.log("ANDROID RAW trace started at \(eventPath)")
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty else { return }
                    let events = String(decoding: data, as: UTF8.self)
                        .split(separator: "\n")
                        .filter {
                            $0.contains("ABS_MT_SLOT")
                                || $0.contains("ABS_MT_POSITION")
                                || $0.contains("ABS_X")
                                || $0.contains("ABS_Y")
                                || $0.contains("ABS_MT_TRACKING_ID")
                                || $0.contains("BTN_TOUCH")
                                || $0.contains("SYN_REPORT")
                        }
                    for event in events {
                        TouchTraceLogger.log("ANDROID RAW \(event)")
                    }
                }
            } catch {
                TouchTraceLogger.log("ANDROID RAW trace unavailable: \(error.localizedDescription)")
            }
        }
    }

    /// Android InputReader rotates raw HID coordinates into the active display
    /// using SurfaceOrientation. Send its inverse so the final Android point
    /// matches the already-rotated scrcpy preview.
    private func correctedTouchPoint(
        x: Double,
        y: Double,
        rotation explicitRotation: AndroidDisplayRotation? = nil
    ) -> CGPoint {
        let rotation = explicitRotation ?? displayRotation ?? fallbackDisplayRotation
        return rotation.rawHIDPoint(forPreviewX: x, y: y)
    }

    private var fallbackDisplayRotation: AndroidDisplayRotation {
        guard let frame else { return .portrait }
        return frame.size.width > frame.size.height ? .landscapeRight : .portrait
    }

    private func physicalLength(_ point: CGPoint, aspect: Double) -> Double {
        hypot(point.x, point.y / aspect)
    }

    private func distanceToCircleEdge(
        from point: CGPoint,
        center: CGPoint,
        radius: Double,
        direction: CGPoint,
        aspect: Double
    ) -> Double {
        let origin = CGPoint(x: point.x - center.x, y: (point.y - center.y) / aspect)
        let projection = origin.x * direction.x + origin.y * direction.y
        let discriminant = max(0, projection * projection + radius * radius - origin.x * origin.x - origin.y * origin.y)
        return max(0, -projection + sqrt(discriminant))
    }

    private func normalizedKey(_ event: NSEvent) -> String {
        // Mouse buttons are identified by buttonNumber, not keyCode.
        switch event.type {
        case .leftMouseDown, .leftMouseUp:
            return "mouse1"
        case .rightMouseDown, .rightMouseUp:
            return "mouse2"
        case .otherMouseDown, .otherMouseUp:
            return "mouse3"
        default:
            break
        }
        switch event.keyCode {
        case 49: return "space"
        case 123: return "left"
        case 124: return "right"
        case 125: return "down"
        case 126: return "up"
        default: return event.charactersIgnoringModifiers?.lowercased() ?? ""
        }
    }

    private static func loadBindings() -> [TouchBinding] {
        guard let data = UserDefaults.standard.data(forKey: "androidMirror.touchBindings"),
              let bindings = try? JSONDecoder().decode([TouchBinding].self, from: data),
              !bindings.isEmpty else {
            return TouchBinding.defaults
        }
        return bindings
    }

    private func saveBindings() {
        guard let data = try? JSONEncoder().encode(bindings) else { return }
        UserDefaults.standard.set(data, forKey: bindingsStorageKey)
    }
}

private struct ActiveJoystickState {
    var pressedDirections: Set<JoystickDirection> = []
    var contactID: UInt8?
    var currentPoint: CGPoint?
    var transitionToken: UUID?
}

private struct JoystickRouteSample {
    let point: CGPoint
    let delayMilliseconds: Int
    let preset: JoystickStutterPreset
}

private enum JoystickStutterPreset: String, CaseIterable {
    case hesitation
    case microBacktrack
    case sideWobble

    /// Returns a small progress and lateral deviation. The location,
    /// probability and magnitude coefficients are regenerated for every
    /// joystick transition by `makeJoystickRoute`.
    func offsets(
        progress: Double,
        occurrence: Double,
        occurrenceCoefficient: Double,
        sizeCoefficient: Double
    ) -> (progress: Double, lateral: Double) {
        guard progress < 0.999 else { return (0, 0) }
        let distance = progress - occurrence
        let width = 0.035 + occurrenceCoefficient * 0.10
        let envelope = exp(-(distance * distance) / max(2 * width * width, 0.000_001))
        let randomKick = Double.random(in: 0...1) < occurrenceCoefficient
            ? Double.random(in: -sizeCoefficient...sizeCoefficient) * envelope
            : 0

        switch self {
        case .hesitation:
            return (
                progress: -sizeCoefficient * 1.8 * envelope,
                lateral: randomKick * 0.35
            )
        case .microBacktrack:
            let backtrack = distance >= 0 ? -sizeCoefficient * 2.4 * envelope : 0
            return (
                progress: backtrack + randomKick * 0.25,
                lateral: randomKick * 0.45
            )
        case .sideWobble:
            let wave = sin((progress - occurrence) * Double.pi * (8 + occurrenceCoefficient * 10))
            return (
                progress: randomKick * 0.2,
                lateral: wave * sizeCoefficient * envelope + randomKick
            )
        }
    }
}

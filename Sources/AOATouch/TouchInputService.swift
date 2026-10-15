import Foundation

public enum AOAAccessoryMode: Sendable, Equatable {
    case accessoryOnly
    case accessoryAndADB

    public var preservesADB: Bool {
        self == .accessoryAndADB
    }
}

/// Keeps the already-proven AOA HID touch transport open for low-latency taps
/// and streamed drag updates from the macOS mapping UI.
///
/// Supports up to `HID.maxFingers` simultaneous contacts.  Each contact is
/// assigned a finger-slot index (0..<maxFingers) and an incrementing contact
/// ID.  A single multitouch report is sent for every state change.
public final class AOATouchInputService: @unchecked Sendable {
    private var context: USBContext?
    private var handle: USBHandle?
    private var accessoryMode: AOAAccessoryMode?

    /// Currently active contacts keyed by contact ID.
    private var activeContacts: [UInt8: ActiveContact] = [:]
    private var usedFingerIndices: Set<Int> = []
    private var dragContactID: UInt8?
    private let lock = NSRecursiveLock()
    private var transferSampleCount = 0
    private var transferTotalMilliseconds = 0.0
    private var transferMaximumMilliseconds = 0.0
    private var lastTransferSummaryUptime = ProcessInfo.processInfo.systemUptime

    /// Optional diagnostics hook for the host UI. It reports the exact contact
    /// records handed to the AOA transport, not merely UI-level intent.
    public var traceHandler: ((String) -> Void)?

    public init() {}

    /// Makes the first available AOA-capable Android device enter accessory
    /// mode when it is not already there, then waits for its USB reconnect.
    public func start() throws -> AOAAccessoryMode {
        lock.lock()
        defer { lock.unlock() }
        try activateIfNeeded()
        return accessoryMode ?? .accessoryOnly
    }

    deinit {
        lock.lock()
        defer { lock.unlock() }
        endAllContactsSilently()
        try? handle?.unregisterHID()
    }

    // MARK: - Single-contact convenience API (used by the host app)

    public func tap(x: Double, y: Double) throws {
        lock.lock()
        defer { lock.unlock() }
        try activateIfNeeded()
        guard let handle else { return }
        let point = encodedPoint(x: x, y: y)
        let contact = try allocateContact(x: point.x, y: point.y)
        activeContacts[contact.id] = contact
        do {
            try sendActiveFrame(handle: handle)
        } catch {
            freeContact(contact)
            throw error
        }
        trace("DOWN id=\(contact.id) slot=\(contact.fingerIndex) raw=(\(point.x),\(point.y)) count=\(activeContacts.count)")
        Thread.sleep(forTimeInterval: 0.045)
        try releaseContact(contact, handle: handle)
        freeContact(contact)
    }

    public func beginDrag(x: Double, y: Double) throws {
        lock.lock()
        defer { lock.unlock() }
        try activateIfNeeded()
        if let dragContactID {
            try endContactLocked(dragContactID)
        }
        guard let handle else { return }
        let point = encodedPoint(x: x, y: y)
        let contact = try allocateContact(x: point.x, y: point.y)
        activeContacts[contact.id] = contact
        dragContactID = contact.id
        do {
            try sendActiveFrame(handle: handle)
        } catch {
            freeContact(contact)
            dragContactID = nil
            throw error
        }
        trace("DOWN id=\(contact.id) slot=\(contact.fingerIndex) raw=(\(point.x),\(point.y)) count=\(activeContacts.count)")
    }

    public func moveDrag(x: Double, y: Double) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let dragContactID, let contact = activeContacts[dragContactID], let handle else { return }
        let point = encodedPoint(x: x, y: y)
        contact.x = point.x
        contact.y = point.y
        try sendActiveFrame(handle: handle)
        trace("MOVE id=\(contact.id) slot=\(contact.fingerIndex) raw=(\(point.x),\(point.y)) count=\(activeContacts.count)")
    }

    public func endDrag() throws {
        lock.lock()
        defer { lock.unlock() }
        guard let dragContactID, let contact = activeContacts[dragContactID], let handle else { return }
        let t0 = ProcessInfo.processInfo.systemUptime
        try releaseContact(contact, handle: handle)
        let ms = (ProcessInfo.processInfo.systemUptime - t0) * 1000
        trace("UP id=\(contact.id) slot=\(contact.fingerIndex) raw=(\(contact.x),\(contact.y)) releaseMs=\(String(format: "%.1f", ms))")
        freeContact(contact)
        self.dragContactID = nil
    }

    public func disconnect() {
        lock.lock()
        defer { lock.unlock() }
        endAllContactsSilently()
        try? handle?.unregisterHID()
        handle = nil
        context = nil
        accessoryMode = nil
    }

    // MARK: - Multi-contact API

    /// Begin a new contact, returning its ID for subsequent move/end calls.
    @discardableResult
    public func beginContact(x: Double, y: Double) throws -> UInt8 {
        lock.lock()
        defer { lock.unlock() }
        try activateIfNeeded()
        guard let handle else { return 0 }
        let point = encodedPoint(x: x, y: y)
        let contact = try allocateContact(x: point.x, y: point.y)
        activeContacts[contact.id] = contact
        do {
            try sendActiveFrame(handle: handle)
        } catch {
            freeContact(contact)
            throw error
        }
        trace("DOWN id=\(contact.id) slot=\(contact.fingerIndex) raw=(\(point.x),\(point.y)) count=\(activeContacts.count)")
        return contact.id
    }

    public func moveContact(_ contactID: UInt8, x: Double, y: Double) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let contact = activeContacts[contactID], let handle else { return }
        let point = encodedPoint(x: x, y: y)
        contact.x = point.x
        contact.y = point.y
        try sendActiveFrame(handle: handle)
        trace("MOVE id=\(contact.id) slot=\(contact.fingerIndex) raw=(\(point.x),\(point.y)) count=\(activeContacts.count)")
    }

    public func endContact(_ contactID: UInt8) throws {
        lock.lock()
        defer { lock.unlock() }
        guard activeContacts[contactID] != nil, handle != nil else { return }
        try endContactLocked(contactID)
    }

    // MARK: - Internals

    private func activateIfNeeded() throws {
        guard handle == nil else { return }
        let context = try USBContext()
        let handle: USBHandle

        if let accessory = try? context.openFirstAccessory() {
            handle = accessory
        } else {
            let (normalHandle, info, version) = try context.openFirstAOACapable()
            guard version >= 2 else { throw AOAError.unsupportedProtocol(version) }
            try normalHandle.startAccessoryMode()

            let deadline = ProcessInfo.processInfo.systemUptime + 8
            var reconnectedHandle: USBHandle?
            while ProcessInfo.processInfo.systemUptime < deadline {
                if let accessory = try? context.openFirstAccessory() {
                    reconnectedHandle = accessory
                    break
                }
                Thread.sleep(forTimeInterval: 0.2)
            }
            guard let reconnectedHandle else {
                throw AOAError.noDevice("\(info.identifier) did not reconnect in AOA accessory mode within 8 seconds.")
            }
            handle = reconnectedHandle
        }
        try handle.registerHID(descriptor: HID.touchDescriptor)
        Thread.sleep(forTimeInterval: 0.35)
        self.context = context
        self.handle = handle
        accessoryMode = [0x2d01, 0x2d03, 0x2d05].contains(handle.info.productID)
            ? .accessoryAndADB
            : .accessoryOnly
    }

    private func encodedPoint(x: Double, y: Double) -> (x: UInt16, y: UInt16) {
        let normalizedX = min(max(x, 0), 1)
        let normalizedY = min(max(y, 0), 1)
        return (
            UInt16((normalizedX * 32_767).rounded()),
            UInt16((normalizedY * 32_767).rounded())
        )
    }

    private func allocateContact(x: UInt16, y: UInt16) throws -> ActiveContact {
        guard let fingerIndex = (0..<HID.maxFingers).first(where: { !usedFingerIndices.contains($0) }) else {
            throw AOAError.invalidArgument("At most \(HID.maxFingers) simultaneous touches are supported.")
        }
        usedFingerIndices.insert(fingerIndex)
        // Android's HID multitouch driver uses Contact Identifier as the MT
        // slot for this descriptor, whose declared logical range is 0...9.
        return ActiveContact(id: UInt8(fingerIndex), fingerIndex: fingerIndex, x: x, y: y)
    }

    private func freeContact(_ contact: ActiveContact) {
        activeContacts.removeValue(forKey: contact.id)
        usedFingerIndices.remove(contact.fingerIndex)
    }

    private func sendActiveFrame(handle: USBHandle, releasing: ActiveContact? = nil) throws {
        var frameContacts = activeContacts.values
            .filter { $0.id != releasing?.id }
            .sorted { $0.id < $1.id }
            .map { (contact: $0, down: true) }
        if let releasing {
            frameContacts.append((contact: releasing, down: false))
        }

        // Hybrid protocol: the first packet declares the complete frame size;
        // continuation packets use Contact Count 0. Android synchronizes only
        // after receiving all declared contacts.
        let started = ProcessInfo.processInfo.systemUptime
        for (packetIndex, item) in frameContacts.enumerated() {
            let report = HID.touchReport(
                down: item.down,
                x: item.contact.x,
                y: item.contact.y,
                contactID: item.contact.id,
                contactCount: packetIndex == 0 ? UInt8(frameContacts.count) : 0
            )
            try handle.sendHIDReport(report)
        }
        recordTransfer(startedAt: started, reportCount: frameContacts.count)
    }

    private func recordTransfer(startedAt: TimeInterval, reportCount: Int) {
        guard traceHandler != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let milliseconds = (now - startedAt) * 1_000
        transferSampleCount += 1
        transferTotalMilliseconds += milliseconds
        transferMaximumMilliseconds = max(transferMaximumMilliseconds, milliseconds)

        if milliseconds > 3 {
            trace("SLOW USB frame reports=\(reportCount) elapsedMs=\(String(format: "%.2f", milliseconds))")
        }
        guard now - lastTransferSummaryUptime >= 1, transferSampleCount > 0 else { return }
        let average = transferTotalMilliseconds / Double(transferSampleCount)
        trace(
            "USB LATENCY samples=\(transferSampleCount) avgMs=\(String(format: "%.3f", average)) maxMs=\(String(format: "%.3f", transferMaximumMilliseconds))"
        )
        transferSampleCount = 0
        transferTotalMilliseconds = 0
        transferMaximumMilliseconds = 0
        lastTransferSummaryUptime = now
    }

    /// Close one contact while retaining every other active finger in the
    /// same report.
    private func releaseContact(_ contact: ActiveContact, handle: USBHandle) throws {
        try sendActiveFrame(handle: handle, releasing: contact)
    }

    private func endContactLocked(_ contactID: UInt8) throws {
        guard let contact = activeContacts[contactID], let handle else { return }
        try releaseContact(contact, handle: handle)
        trace("UP id=\(contact.id) slot=\(contact.fingerIndex) raw=(\(contact.x),\(contact.y)) remaining=\(activeContacts.count - 1)")
        freeContact(contact)
        if dragContactID == contactID { dragContactID = nil }
    }

    private func endAllContacts() throws {
        guard let handle, !activeContacts.isEmpty else { return }
        while let contact = activeContacts.values.first {
            try releaseContact(contact, handle: handle)
            freeContact(contact)
        }
        dragContactID = nil
    }

    private func endAllContactsSilently() {
        try? endAllContacts()
    }

    private func trace(_ message: @autoclosure () -> String) {
        guard let traceHandler else { return }
        traceHandler(message())
    }
}

// MARK: - Active Contact

private final class ActiveContact {
    let id: UInt8
    let fingerIndex: Int
    var x: UInt16
    var y: UInt16

    init(id: UInt8, fingerIndex: Int, x: UInt16, y: UInt16) {
        self.id = id
        self.fingerIndex = fingerIndex
        self.x = x
        self.y = y
    }
}

import Foundation

private let usage = """
Usage:
  aoa-touch list
  aoa-touch start
  aoa-touch keyboard-test
  aoa-touch tap <x> <y>
  aoa-touch drag <x1> <y1> <x2> <y2> [duration-ms]
  aoa-touch interactive [--verbose]

Touch coordinates are normalized decimal values from 0.0 through 1.0.
`start` switches the first AOA-capable Android USB device into accessory mode.
After it reconnects, use `keyboard-test`, `tap`, or `drag`.
Use `interactive` to keep the HID registered and eliminate per-command setup delay.
"""

private var traceReports = false

private func sendTouchReport(handle: USBHandle, label: String, report: [UInt8]) throws {
    let started = ProcessInfo.processInfo.systemUptime
    try handle.sendHIDReport(report)
    guard traceReports else { return }

    let elapsedMS = (ProcessInfo.processInfo.systemUptime - started) * 1_000
    let bytes = report.map { String(format: "%02x", $0) }.joined(separator: " ")
    print(String(format: "TRACE %-10@ [%@] USB %.2f ms", label as NSString, bytes, elapsedMS))
}

private func normalizedCoordinate(_ text: String) throws -> UInt16 {
    guard let value = Double(text), value.isFinite, (0...1).contains(value) else {
        throw AOAError.invalidArgument("Coordinate `\(text)` must be between 0.0 and 1.0.")
    }
    return UInt16((value * 32_767).rounded())
}

private func withHID(
    context: USBContext,
    descriptor: [UInt8],
    body: (USBHandle) throws -> Void
) throws {
    let handle = try context.openFirstAccessory()
    try handle.registerHID(descriptor: descriptor)
    Thread.sleep(forTimeInterval: 0.35)
    defer { try? handle.unregisterHID() }
    try body(handle)
}

func releaseTouch(handle: USBHandle, x: UInt16, y: UInt16, contactID: UInt8) throws {
    // Close the active MT slot, then send the empty contact frame expected by
    // Android HID multitouch implementations.
    try sendTouchReport(handle: handle, label: "UP", report: HID.touchReport(
        fingerIndex: 0, down: false, x: x, y: y, contactID: contactID, contactCount: 1
    ))
    Thread.sleep(forTimeInterval: 0.016)
    try sendTouchReport(handle: handle, label: "EMPTY", report: HID.touchReport(
        fingerIndex: 0, down: false, x: x, y: y, contactID: contactID, contactCount: 0
    ))
}

private func sendTap(
    handle: USBHandle,
    xText: String,
    yText: String,
    contactID: UInt8 = 1
) throws {
    let x = try normalizedCoordinate(xText)
    let y = try normalizedCoordinate(yText)
    try sendTouchReport(handle: handle, label: "DOWN", report: HID.touchReport(
        fingerIndex: 0, down: true, x: x, y: y, contactID: contactID
    ))
    Thread.sleep(forTimeInterval: 0.045)
    try releaseTouch(handle: handle, x: x, y: y, contactID: contactID)
}

private func sendDrag(
    handle: USBHandle,
    arguments: [String],
    contactID: UInt8 = 1
) throws {
    guard arguments.count == 4 || arguments.count == 5 else {
        throw AOAError.invalidArgument("drag requires x1 y1 x2 y2 [duration-ms]")
    }
    let x1 = try normalizedCoordinate(arguments[0])
    let y1 = try normalizedCoordinate(arguments[1])
    let x2 = try normalizedCoordinate(arguments[2])
    let y2 = try normalizedCoordinate(arguments[3])
    let durationMS = arguments.count == 5 ? (Int(arguments[4]) ?? 500) : 500
    guard (20...10_000).contains(durationMS) else {
        throw AOAError.invalidArgument("Duration must be between 20 and 10000 milliseconds.")
    }

    // Give InputReader time to establish ACTION_DOWN before changing axes.
    try sendTouchReport(handle: handle, label: "DOWN", report: HID.touchReport(
        fingerIndex: 0, down: true, x: x1, y: y1, contactID: contactID
    ))
    Thread.sleep(forTimeInterval: 0.032)

    let steps = max(2, durationMS / 16)
    for step in 1...steps {
        let progress = Double(step) / Double(steps)
        let x = UInt16((Double(x1) + (Double(x2) - Double(x1)) * progress).rounded())
        let y = UInt16((Double(y1) + (Double(y2) - Double(y1)) * progress).rounded())
        try sendTouchReport(handle: handle, label: "MOVE \(step)", report: HID.touchReport(
            fingerIndex: 0, down: true, x: x, y: y, contactID: contactID
        ))
        Thread.sleep(forTimeInterval: Double(durationMS) / 1_000 / Double(steps))
    }
    Thread.sleep(forTimeInterval: 0.016)
    try releaseTouch(handle: handle, x: x2, y: y2, contactID: contactID)
}

private func runInteractive(context: USBContext) throws {
    let handle = try context.openFirstAccessory()
    try handle.registerHID(descriptor: HID.touchDescriptor)
    defer { try? handle.unregisterHID() }
    Thread.sleep(forTimeInterval: 0.35)

    print("Touch HID ready. Commands: tap x y | drag x1 y1 x2 y2 [ms] | quit")
    var nextContactID: UInt8 = 1
    while true {
        print("> ", terminator: "")
        guard let line = readLine() else { break }
        let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let command = parts.first else { continue }

        do {
            switch command.lowercased() {
            case "tap" where parts.count == 3:
                try sendTap(
                    handle: handle,
                    xText: parts[1],
                    yText: parts[2],
                    contactID: nextContactID
                )
                nextContactID = nextContactID == 255 ? 1 : nextContactID + 1
            case "drag":
                try sendDrag(
                    handle: handle,
                    arguments: Array(parts.dropFirst()),
                    contactID: nextContactID
                )
                nextContactID = nextContactID == 255 ? 1 : nextContactID + 1
            case "quit", "exit":
                return
            case "help":
                print("tap x y | drag x1 y1 x2 y2 [duration-ms] | quit")
            default:
                print("Unknown command. Type `help`.")
            }
        } catch {
            print("error: \(error.localizedDescription)")
        }
    }
}

func runAOATouchCommand() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = arguments.first else {
        print(usage)
        return
    }

    let context = try USBContext()
    switch command {
    case "list":
        let devices = try context.devices()
        if devices.isEmpty {
            print("No USB devices found.")
        }
        for device in devices {
            let mode = device.isAccessoryMode ? " [AOA accessory]" : ""
            print("\(device.identifier)\(mode)")
        }

    case "start":
        let (handle, info, version) = try context.openFirstAOACapable()
        guard version >= 2 else { throw AOAError.unsupportedProtocol(version) }
        print("Found \(info.identifier), AOA protocol \(version). Switching modes...")
        try handle.startAccessoryMode()
        print("Switch requested. Wait 2 seconds, then run `aoa-touch list`.")

    case "keyboard-test":
        try withHID(context: context, descriptor: HID.keyboardDescriptor) { handle in
            // HID usage 0x04 is the letter A.
            try handle.sendHIDReport([0, 0, 0x04, 0, 0, 0, 0, 0])
            Thread.sleep(forTimeInterval: 0.08)
            try handle.sendHIDReport([0, 0, 0, 0, 0, 0, 0, 0])
        }
        print("Sent one keyboard `a` press.")

    case "tap":
        guard arguments.count == 3 else { throw AOAError.invalidArgument(usage) }
        try withHID(context: context, descriptor: HID.touchDescriptor) { handle in
            try sendTap(handle: handle, xText: arguments[1], yText: arguments[2])
        }
        print("Sent tap at (\(arguments[1]), \(arguments[2])).")

    case "drag":
        guard arguments.count == 5 || arguments.count == 6 else {
            throw AOAError.invalidArgument(usage)
        }
        try withHID(context: context, descriptor: HID.touchDescriptor) { handle in
            try sendDrag(handle: handle, arguments: Array(arguments.dropFirst()))
        }
        print("Sent drag.")

    case "interactive":
        traceReports = arguments.dropFirst().contains("--verbose")
        try runInteractive(context: context)

    case "help", "--help", "-h":
        print(usage)

    default:
        throw AOAError.invalidArgument("Unknown command `\(command)`.\n\n\(usage)")
    }
}

public enum AOATouchCommand {
    public static func run() throws {
        try runAOATouchCommand()
    }
}

import Foundation

enum AOA {
    static let googleVendorID: UInt16 = 0x18d1
    static let accessoryProductIDs: Set<UInt16> = [0x2d00, 0x2d01, 0x2d02, 0x2d03, 0x2d04, 0x2d05]
    static let controlTimeoutMS: UInt32 = 1_000

    private static let getProtocol: UInt8 = 51
    private static let sendString: UInt8 = 52
    private static let startAccessory: UInt8 = 53
    private static let registerHID: UInt8 = 54
    private static let unregisterHID: UInt8 = 55
    private static let setHIDDescriptor: UInt8 = 56
    private static let sendHIDEvent: UInt8 = 57

    static let hidID: UInt16 = 1

    static let identity = [
        "DeltaForceAuto",
        "AOA Touch Test Accessory",
        "USB HID input test tool",
        "0.1",
        "https://localhost/aoa-touch",
        "AOA-TOUCH-001"
    ]
}

extension USBHandle {
    func aoaProtocolVersion() throws -> UInt16 {
        let bytes = try controlIn(request: 51, length: 2)
        guard bytes.count == 2 else {
            throw AOAError.noDevice("AOA protocol query returned \(bytes.count) bytes instead of 2.")
        }
        return UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
    }

    func startAccessoryMode() throws {
        let version = try aoaProtocolVersion()
        guard version >= 2 else { throw AOAError.unsupportedProtocol(version) }

        for (index, string) in AOA.identity.enumerated() {
            let nulTerminated = Array(string.utf8) + [0]
            try controlOut(request: 52, index: UInt16(index), bytes: nulTerminated)
        }
        try controlOut(request: 53)
    }

    func registerHID(descriptor: [UInt8]) throws {
        try controlOut(request: 54, value: AOA.hidID, index: UInt16(descriptor.count))

        var offset = 0
        while offset < descriptor.count {
            let end = min(offset + 256, descriptor.count)
            try controlOut(
                request: 56,
                value: AOA.hidID,
                index: UInt16(offset),
                bytes: Array(descriptor[offset..<end])
            )
            offset = end
        }
    }

    func sendHIDReport(_ report: [UInt8]) throws {
        try controlOut(request: 57, value: AOA.hidID, bytes: report)
    }

    func unregisterHID() throws {
        try controlOut(request: 55, value: AOA.hidID)
    }
}

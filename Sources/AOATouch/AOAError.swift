import CLibUSB
import Foundation

enum AOAError: LocalizedError {
    case libusb(operation: String, code: Int32)
    case noDevice(String)
    case unsupportedProtocol(UInt16)
    case invalidArgument(String)

    var errorDescription: String? {
        switch self {
        case let .libusb(operation, code):
            let message = String(cString: libusb_error_name(code))
            return "\(operation) failed: \(message) (\(code))"
        case let .noDevice(message):
            return message
        case let .unsupportedProtocol(version):
            return "Device reports AOA protocol \(version); AOA HID requires version 2 or newer."
        case let .invalidArgument(message):
            return message
        }
    }
}

@inline(__always)
func requireUSB(_ result: Int32, _ operation: String) throws {
    guard result >= 0 else {
        throw AOAError.libusb(operation: operation, code: result)
    }
}

import Foundation

enum TouchBindingKind: String, Codable, CaseIterable, Identifiable {
    case tap = "Tap"
    case drag = "Drag"
    case joystick = "Joystick"

    var id: String { rawValue }
}

struct JoystickKeys: Codable, Equatable {
    var up: String
    var left: String
    var down: String
    var right: String

    static let wasd = JoystickKeys(up: "W", left: "A", down: "S", right: "D")

    func direction(for normalizedKey: String) -> JoystickDirection? {
        if up.lowercased() == normalizedKey { return .up }
        if left.lowercased() == normalizedKey { return .left }
        if down.lowercased() == normalizedKey { return .down }
        if right.lowercased() == normalizedKey { return .right }
        return nil
    }
}

struct JoystickSprintPoint: Codable, Equatable {
    var x: Double
    var y: Double
}

enum JoystickDirection: String, Hashable {
    case up
    case left
    case down
    case right
}

struct TouchBinding: Codable, Identifiable, Equatable {
    var id = UUID()
    var key: String
    var kind: TouchBindingKind
    var x: Double
    var y: Double
    var radius: Double
    var joystickKeys: JoystickKeys? = nil
    var joystickSprintPoint: JoystickSprintPoint? = nil
    var joystickSprintLeftPoint: JoystickSprintPoint? = nil
    var joystickSprintRightPoint: JoystickSprintPoint? = nil

    static let defaults = [
        TouchBinding(key: "F", kind: .tap, x: 0.7, y: 0.7, radius: 0.08),
        TouchBinding(key: "Mouse", kind: .drag, x: 0.3, y: 0.7, radius: 0.15)
    ]
}

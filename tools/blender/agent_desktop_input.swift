import ApplicationServices
import AppKit
import Carbon
import Foundation

enum DesktopInputError: Error {
    case invalidArguments
    case unavailable
}

func postMouseEvent(
    _ type: CGEventType,
    _ point: CGPoint,
    _ button: CGMouseButton = .left,
    target: ProcessSerialNumber? = nil
) throws {
    guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button) else {
        throw DesktopInputError.unavailable
    }
    if var target {
        withUnsafeMutablePointer(to: &target) { pointer in
            event.postToPSN(processSerialNumber: UnsafeMutableRawPointer(pointer))
        }
    } else {
        event.post(tap: .cghidEventTap)
    }
}

@_silgen_name("GetProcessForPID")
func legacyGetProcessForPID(_ pid: pid_t, _ process: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

func processSerialNumber(for pid: pid_t) throws -> ProcessSerialNumber {
    var process = ProcessSerialNumber()
    guard legacyGetProcessForPID(pid, &process) == noErr else {
        throw DesktopInputError.unavailable
    }
    return process
}

func drag(
    from: CGPoint,
    to: CGPoint,
    duration: TimeInterval,
    target: ProcessSerialNumber? = nil,
    flags: CGEventFlags = []
) throws {
    func post(_ type: CGEventType, _ point: CGPoint) throws {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else {
            throw DesktopInputError.unavailable
        }
        event.flags = flags
        if var target {
            withUnsafeMutablePointer(to: &target) { pointer in
                event.postToPSN(processSerialNumber: UnsafeMutableRawPointer(pointer))
            }
        } else {
            event.post(tap: .cghidEventTap)
        }
    }
    try post(.mouseMoved, from)
    Thread.sleep(forTimeInterval: 0.10)
    try post(.leftMouseDown, from)
    let steps = max(2, Int(duration * 90.0))
    for step in 1...steps {
        let fraction = CGFloat(step) / CGFloat(steps)
        let point = CGPoint(
            x: from.x + (to.x - from.x) * fraction,
            y: from.y + (to.y - from.y) * fraction
        )
        try post(.leftMouseDragged, point)
        Thread.sleep(forTimeInterval: duration / Double(steps))
    }
    try post(.leftMouseUp, to)
}

func sendKey(_ keyCode: CGKeyCode, target: ProcessSerialNumber? = nil) throws {
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
          let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
        throw DesktopInputError.unavailable
    }
    if var target {
        withUnsafeMutablePointer(to: &target) { pointer in
            let rawPointer = UnsafeMutableRawPointer(pointer)
            down.postToPSN(processSerialNumber: rawPointer)
            up.postToPSN(processSerialNumber: rawPointer)
        }
    } else {
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

func sendCommandKey(_ keyCode: CGKeyCode, target: ProcessSerialNumber? = nil) throws {
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
          let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
        throw DesktopInputError.unavailable
    }
    down.flags = .maskCommand
    up.flags = .maskCommand
    if var target {
        withUnsafeMutablePointer(to: &target) { pointer in
            let rawPointer = UnsafeMutableRawPointer(pointer)
            down.postToPSN(processSerialNumber: rawPointer)
            up.postToPSN(processSerialNumber: rawPointer)
        }
    } else {
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

func requireTrustedInput() throws {
    guard AXIsProcessTrusted() else {
        throw DesktopInputError.unavailable
    }
}

func activate(pid: pid_t) throws {
    guard let application = NSRunningApplication(processIdentifier: pid) else {
        throw DesktopInputError.unavailable
    }
    application.activate(options: [.activateAllWindows])
    Thread.sleep(forTimeInterval: 0.35)
}

func activateAndDrag(pid: pid_t, keyCode: CGKeyCode, from: CGPoint, to: CGPoint, duration: TimeInterval) throws {
    try activate(pid: pid)
    try sendKey(keyCode)
    Thread.sleep(forTimeInterval: 0.25)
    try drag(from: from, to: to, duration: duration)
}

let arguments = Array(CommandLine.arguments.dropFirst())

do {
    guard let command = arguments.first else {
        throw DesktopInputError.invalidArguments
    }
    if command == "--check" {
        print(AXIsProcessTrusted() ? "trusted" : "untrusted")
    } else if command == "--key", arguments.count == 2, let keyCode = UInt16(arguments[1]) {
        try requireTrustedInput()
        try sendKey(CGKeyCode(keyCode))
        print("keyed")
    } else if command == "--activate-pid", arguments.count == 2, let pid = Int32(arguments[1]) {
        try activate(pid: pid_t(pid))
        print("activated")
    } else if command == "--key-pid", arguments.count == 3,
              let pid = Int32(arguments[1]), let keyCode = UInt16(arguments[2]) {
        try requireTrustedInput()
        try sendKey(CGKeyCode(keyCode), target: try processSerialNumber(for: pid_t(pid)))
        print("keyed")
    } else if command == "--command-key-pid", arguments.count == 3,
              let pid = Int32(arguments[1]), let keyCode = UInt16(arguments[2]) {
        try requireTrustedInput()
        try sendCommandKey(CGKeyCode(keyCode), target: try processSerialNumber(for: pid_t(pid)))
        print("command-keyed")
    } else if command == "--activate-key-drag-pid", arguments.count == 8,
              let pid = Int32(arguments[1]), let keyCode = UInt16(arguments[2]),
              let startX = Double(arguments[3]), let startY = Double(arguments[4]),
              let endX = Double(arguments[5]), let endY = Double(arguments[6]),
              let duration = Double(arguments[7]) {
        try requireTrustedInput()
        try activateAndDrag(
            pid: pid_t(pid),
            keyCode: CGKeyCode(keyCode),
            from: CGPoint(x: startX, y: startY),
            to: CGPoint(x: endX, y: endY),
            duration: duration
        )
        print("activated-keyed-dragged")
    } else if command == "--drag", arguments.count == 6,
              let startX = Double(arguments[1]), let startY = Double(arguments[2]),
              let endX = Double(arguments[3]), let endY = Double(arguments[4]),
              let duration = Double(arguments[5]) {
        try requireTrustedInput()
        try drag(
            from: CGPoint(x: startX, y: startY),
            to: CGPoint(x: endX, y: endY),
            duration: duration
        )
        print("dragged")
    } else if command == "--drag-pid", arguments.count == 7,
              let pid = Int32(arguments[1]),
              let startX = Double(arguments[2]), let startY = Double(arguments[3]),
              let endX = Double(arguments[4]), let endY = Double(arguments[5]),
              let duration = Double(arguments[6]) {
        try requireTrustedInput()
        try drag(
            from: CGPoint(x: startX, y: startY),
            to: CGPoint(x: endX, y: endY),
            duration: duration,
            target: try processSerialNumber(for: pid_t(pid))
        )
        print("dragged")
    } else if command == "--shift-drag-pid", arguments.count == 7,
              let pid = Int32(arguments[1]),
              let startX = Double(arguments[2]), let startY = Double(arguments[3]),
              let endX = Double(arguments[4]), let endY = Double(arguments[5]),
              let duration = Double(arguments[6]) {
        try requireTrustedInput()
        try drag(
            from: CGPoint(x: startX, y: startY),
            to: CGPoint(x: endX, y: endY),
            duration: duration,
            target: try processSerialNumber(for: pid_t(pid)),
            flags: .maskShift
        )
        print("shift-dragged")
    } else {
        throw DesktopInputError.invalidArguments
    }
} catch DesktopInputError.invalidArguments {
    FileHandle.standardError.write(Data("Usage: agent_desktop_input --check | --activate-pid pid | --key keyCode | --key-pid pid keyCode | --command-key-pid pid keyCode | --activate-key-drag-pid pid keyCode startX startY endX endY duration | --drag startX startY endX endY duration | --drag-pid pid startX startY endX endY duration | --shift-drag-pid pid startX startY endX endY duration\n".utf8))
    exit(2)
} catch {
    FileHandle.standardError.write(Data("Accessibility input is not trusted for this process.\n".utf8))
    exit(3)
}

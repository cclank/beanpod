import Foundation

// Compile this file together with App/DictationShortcut.swift; no Swift Testing dependency is needed.
typealias Mods = DictationShortcut.Modifiers
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
    checks += 1
}
func event(_ code: Int, _ down: Bool, _ modifiers: Mods = [], repeating: Bool = false) -> DictationKeyEvent {
    DictationKeyEvent(code: code, down: down, modifiers: modifiers, repeating: repeating)
}

do {
    var tracker = DictationShortcutTracker()
    let shortcut = DictationShortcut(code: 100) // F8
    var r = tracker.handle(event(100, true), shortcut: shortcut)
    check(r.press && r.suppress && !r.release, "F8 starts once and is consumed")
    r = tracker.handle(event(100, true, repeating: true), shortcut: shortcut)
    check(!r.press && r.suppress, "Auto-repeat cannot start another capture or reach the foreground app")
    r = tracker.handle(event(100, false), shortcut: shortcut)
    check(r.release && r.suppress && !tracker.active, "F8 release ends capture and is consumed")
    check(tracker.handle(event(100, true), shortcut: shortcut).press, "A fresh physical press starts the next capture")
}

do {
    var tracker = DictationShortcutTracker()
    let shortcut = DictationShortcut(code: 40, modifiers: Mods([.control, .option]).rawValue) // Ctrl+Option+K
    check(!tracker.handle(event(40, true), shortcut: shortcut).suppress, "Unmodified K remains ordinary typing")
    _ = tracker.handle(event(40, false), shortcut: shortcut)
    check(!tracker.handle(event(40, true, [.control, .option, .shift]), shortcut: shortcut).press, "Extra modifiers do not match")
    _ = tracker.handle(event(40, false), shortcut: shortcut)
    check(tracker.handle(event(40, true, [.control, .option]), shortcut: shortcut).press, "Configured chord starts capture")
    check(tracker.handle(event(59, false, [.option]), shortcut: shortcut).release, "Releasing a required modifier first ends capture")
    let repeated = tracker.handle(event(40, true, [.option], repeating: true), shortcut: shortcut)
    check(repeated.suppress && !repeated.press, "Held trigger stays consumed after an early modifier release")
    let up = tracker.handle(event(40, false, [.option]), shortcut: shortcut)
    check(up.suppress && !up.release, "The trigger key-up is consumed without ending twice")
}

do {
    var tracker = DictationShortcutTracker()
    let shortcut = DictationShortcut(code: 60) // Existing right Shift setting
    check(!tracker.handle(event(56, true, [.shift]), shortcut: shortcut).press, "Left Shift does not trigger right Shift")
    let down = tracker.handle(event(60, true, [.shift]), shortcut: shortcut)
    check(down.press && !down.suppress, "Existing right Shift setting works without swallowing modifier state")
    check(tracker.handle(event(60, false, [.shift]), shortcut: shortcut).release, "Right Shift key-up ends capture even with left Shift still held")
    tracker.reset()
    check(!tracker.active, "Reset clears the listening state")
}

do {
    var tracker = DictationShortcutTracker()
    let shortcut = DictationShortcut(code: 100, modifiers: Mods.function.rawValue)
    check(!tracker.handle(event(100, true), shortcut: shortcut).press, "Plain F8 does not trigger Fn+F8")
    _ = tracker.handle(event(100, false), shortcut: shortcut)
    check(tracker.handle(event(100, true, [.function]), shortcut: shortcut).press, "Physical Fn+F8 matches")
    check(tracker.handle(event(63, false), shortcut: shortcut).release, "Releasing Fn first ends the chord")
    check(tracker.handle(event(100, false), shortcut: shortcut).suppress, "F8 release remains consumed")
}

do {
    var recorder = DictationShortcutRecorder()
    check(recorder.handle(event(49, true)) == nil, "Space recording waits for release")
    check(recorder.handle(event(49, false)) == DictationShortcut(code: 49), "Space can be assigned")
    _ = recorder.handle(event(55, true, [.command]))
    _ = recorder.handle(event(56, true, [.command, .shift]))
    _ = recorder.handle(event(40, true, [.command, .shift]))
    check(recorder.handle(event(55, false, [.shift])) == nil, "Releasing Command first does not replace a recorded key chord")
    check(recorder.handle(event(40, false, [.shift])) == DictationShortcut(code: 40, modifiers: Mods([.command, .shift]).rawValue), "The complete chord is saved")
    _ = recorder.handle(event(60, true, [.shift]))
    check(recorder.handle(event(60, false)) == DictationShortcut(code: 60), "A modifier-only shortcut remains assignable")
    _ = recorder.handle(event(100, true))
    recorder.reset()
    check(recorder.handle(event(100, false)) == nil, "Cancel leaves no pending shortcut")
    _ = recorder.handle(event(59, true, [.control]))
    _ = recorder.handle(event(57, true, [.control]))
    check(recorder.handle(event(59, false)) == nil, "Caps Lock is rejected without silently assigning its modifier")
}

check(DictationShortcut(code: 100).name == "F8", "F8 has a readable label")
check(DictationShortcut(code: 90).name == "F20", "F20 is recognized")
check(DictationShortcut(code: 123).name == "←", "Arrow keys are recognized")
check(DictationShortcut(code: 40, modifiers: Mods([.control, .option]).rawValue).name == "⌃⌥K", "The configured chord is displayed in full")
check(DictationShortcut(code: 60, modifiers: Mods.shift.rawValue).modifiers.isEmpty, "A modifier trigger is not duplicated in the stored chord")
print("Dictation shortcut checks passed: \(checks)")

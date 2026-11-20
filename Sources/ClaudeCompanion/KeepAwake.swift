import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac from going to sleep while Claude is working, without keeping the screen on:
/// the display still turns off and the session still locks, so nobody can see your work.
/// Uses macOS's "prevent idle system sleep" assertion, released as soon as Claude is done.
@MainActor
enum KeepAwake {
    private static var assertion: IOPMAssertionID?

    static var isHolding: Bool { assertion != nil }

    static func set(_ on: Bool) {
        if on, assertion == nil {
            var id: IOPMAssertionID = 0
            let reason = "Claude is working (Claude Companion)" as CFString
            if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                           IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &id) == kIOReturnSuccess {
                assertion = id
            }
        } else if !on, let id = assertion {
            IOPMAssertionRelease(id)
            assertion = nil
        }
    }
}

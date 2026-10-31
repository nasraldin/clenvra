// Test VM only: types the VM account's password into macOS password dialogs (SecurityAgent), as a person would.
// While a UI test runs, macOS is in automation mode and hides that dialog from window lists, and the sandboxed test
// runner cannot share files with this agent, so the test asks for each answer with a distributed notification.
// Started by scripts/e2e-helper.sh with Accessibility in the test image; never run on a real Mac.
import CoreGraphics
import Foundation

let password = CommandLine.arguments.dropFirst().first ?? "admin"
let request = Notification.Name("com.nasraldin.clenvra.e2e.typePassword")

func type(_ text: String) {
    let source = CGEventSource(stateID: .hidSystemState)
    for unit in text.utf16 {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
            event?.keyboardSetUnicodeString(stringLength: 1, unicodeString: [unit])
            event?.post(tap: .cghidEventTap)
        }
        usleep(50_000)
    }
    for down in [true, false] {
        CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: down)?.post(tap: .cghidEventTap)  // Return
    }
}

var answered = 0
let observer = DistributedNotificationCenter.default().addObserver(forName: request, object: nil, queue: .main) { _ in
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {  // let the dialog appear and take the keyboard
        type(password)
        answered += 1
        print("answered password dialog \(answered)")
        fflush(stdout)
    }
}
print("listening")
fflush(stdout)
RunLoop.main.run()
withExtendedLifetime(observer) {}

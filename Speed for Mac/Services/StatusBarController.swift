import Foundation
import AppKit
import SwiftUI

@MainActor
final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let popover: NSPopover

    init<Content: View>(rootView: Content) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        super.init()

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 480, height: 760)
        popover.contentViewController = NSHostingController(rootView: rootView)

        if let button = statusItem.button {
            button.title = "Speed [G]"
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
    }

    func updateStatusTitle(simActive: Bool, memoryPressure: MemoryPressureLevel) {
        guard let button = statusItem.button else { return }

        let pressureCode: String
        switch memoryPressure {
        case .green:
            pressureCode = "G"
        case .yellow:
            pressureCode = "Y"
        case .red:
            pressureCode = "R"
        }

        let simCode = simActive ? "SIM" : "IDLE"
        button.title = "Speed \(simCode) [\(pressureCode)]"
    }

    func showPopover() {
        guard let button = statusItem.button else { return }
        guard !popover.isShown else { return }

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
    }

    @objc
    private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.becomeKey()
        }
    }
}

//
//  AppDelegate.swift
//  MSJobMonitor
//
//  Created by Dan Chernopolskii on 9/28/25.
//

import SwiftUI
import Foundation
import Combine
import UserNotifications
import AppKit


class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var popover = NSPopover()
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusBar()
        Task {
            await JobManager.shared.startMonitoring()
        }
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
    
    func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            button.image = NSImage(systemSymbolName: "briefcase.fill", accessibilityDescription: "Job Monitor")?
                .withSymbolConfiguration(config)
            button.action = #selector(togglePopover)
            button.toolTip = "Microsoft Job Monitor"
        }
    }
    
    @objc func togglePopover() {
        if let window = NSApplication.shared.windows.first {
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
}

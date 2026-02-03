//
//  AppDelegate.swift
//  Vizzly
//
//  Created by Robert DeLuca on 1/27/26.
//

import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // App is now purely SwiftUI-driven via MenuBarExtra
        // ServerManager lifecycle is handled by @StateObject in VizzlyApp
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
}

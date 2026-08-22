import AppKit
import AVFoundation
import ApplicationServices

enum PermissionState: Sendable {
    case granted, denied, notDetermined
}

@MainActor
struct PermissionService {
    var microphone: PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    var accessibility: PermissionState {
        AXIsProcessTrusted() ? .granted : .denied
    }

    var inputMonitoring: PermissionState {
        CGPreflightListenEventAccess() ? .granted : .denied
    }

    func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    func requestInputMonitoring() -> Bool {
        if CGPreflightListenEventAccess() { return true }
        _ = CGRequestListenEventAccess()
        return CGPreflightListenEventAccess()
    }

    func openInputMonitoringSettings() {
        openPrivacyPane("ListenEvent")
    }

    func openPrivacyPane(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}

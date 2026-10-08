//
//  DownloadsViewModel+Notifications.swift
//  Torravia
//

#if os(macOS)
import AppKit
import Foundation
import UserNotifications

@MainActor
extension DownloadsViewModel {
    func requestNotificationAuthorization() {
        guard !isHeadless else { return }
        notificationCenter.delegate = notificationDelegate
        notificationCenter.getNotificationSettings { [weak self] settings in
            Task { [weak self] in
                await self?.handleNotificationSettings(settings)
            }
        }
    }

    func scheduleCompletionNotification(for download: Download) {
        guard !isHeadless else { return }
        guard preferences.areNotificationsEnabled else { return }
        if let granted = notificationAuthorizationGranted, !granted {
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "Download Complete"
        content.body = download.title
        content.sound = preferences.isCompletionSoundEnabled ? .default : nil

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(
            identifier: "download-complete-\(download.id.uuidString)",
            content: content,
            trigger: trigger
        )

        notificationCenter.add(request) { error in
            if let error {
                print("[DownloadsViewModel] failed to post notification: \(error)")
            } else {
                print("[DownloadsViewModel] scheduled completion notification for \(download.title)")
            }
        }
    }

    private func handleNotificationSettings(_ settings: UNNotificationSettings) {
        switch settings.authorizationStatus {
        case .notDetermined:
            notificationAuthorizationGranted = nil
            requestNotificationPermissionPrompt()
        case .denied:
            notificationAuthorizationGranted = false
        case .authorized, .provisional:
            notificationAuthorizationGranted = true
        @unknown default:
            notificationAuthorizationGranted = nil
        }
    }

    private func requestNotificationPermissionPrompt() {
        guard !didRequestNotificationAuthorization else { return }
        didRequestNotificationAuthorization = true
        notificationCenter.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            if let error {
                print("[DownloadsViewModel] notification authorization failed: \(error)")
            }
            Task { [weak self] in
                await self?.handleAuthorizationResult(granted: granted)
            }
        }
    }

    private func handleAuthorizationResult(granted: Bool) {
        notificationAuthorizationGranted = granted
        if !granted {
            print("[DownloadsViewModel] notification authorization not granted")
        }
    }

    func requestDockTileUpdate() {
        guard !isHeadless else { return }
        dockTileUpdateRequested = true
        guard !dockTileUpdateScheduled else { return }
        dockTileUpdateScheduled = true

        dockTileUpdateTask?.cancel()
        dockTileUpdateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                self.updateDockTile()
                self.dockTileUpdateRequested = false
                do {
                    try await Task.sleep(nanoseconds: Self.dockTileUpdateIntervalNanoseconds)
                } catch {
                    break
                }
                if !self.dockTileUpdateRequested {
                    break
                }
            }
            self.dockTileUpdateScheduled = false
        }
    }

    func updateDockTile() {
        guard !isHeadless else { return }
        var downloading = 0
        var totalDownload: Int64 = 0
        var totalUpload: Int64 = 0

        for download in downloads {
            let isDownloading = download.status == .downloading
            let isSeeding = download.status == .completed && download.isSeeding
            guard isDownloading || isSeeding else { continue }

            if isDownloading {
                downloading += 1
                if download.speedBytesPerSec > 0 {
                    let result = totalDownload.addingReportingOverflow(download.speedBytesPerSec)
                    totalDownload = result.overflow ? Int64.max : result.partialValue
                }
            }
            if download.uploadSpeedBytesPerSec > 0 {
                let result = totalUpload.addingReportingOverflow(download.uploadSpeedBytesPerSec)
                totalUpload = result.overflow ? Int64.max : result.partialValue
            }
        }

        let stats: DockTileController.Stats?
        if downloading == 0 && totalDownload == 0 && totalUpload == 0 {
            stats = nil
        } else {
            stats = DockTileController.Stats(
                downloadingCount: downloading,
                downloadSpeed: totalDownload,
                uploadSpeed: totalUpload
            )
        }
        DockTileController.shared.update(with: stats)
    }
}
#endif

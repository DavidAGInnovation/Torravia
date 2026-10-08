import SwiftUI

struct SeedingLimitsEditor: View {
    @EnvironmentObject private var downloadsVM: DownloadsViewModel
    @Environment(\.dismiss) private var dismiss
    let download: DownloadsViewModel.Download
    @State private var ratio: String
    @State private var seedingMinutes: String
    @State private var inactiveMinutes: String
    @State private var action: DownloadsViewModel.Download.ShareRatioAction

    init(download: DownloadsViewModel.Download) {
        self.download = download
        _ratio = State(initialValue: download.shareRatioLimit.map { String($0) } ?? "0")
        _seedingMinutes = State(initialValue: String(download.seedingTimeLimitMinutes ?? 0))
        _inactiveMinutes = State(initialValue: String(download.inactiveSeedingTimeLimitMinutes ?? 0))
        let hasPolicy = download.shareRatioLimit != nil || download.seedingTimeLimitMinutes != nil || download.inactiveSeedingTimeLimitMinutes != nil
        _action = State(initialValue: hasPolicy ? download.shareRatioAction : .pause)
    }

    private var isValid: Bool {
        guard let ratioValue = Double(ratio), ratioValue.isFinite, ratioValue >= 0,
              let time = Int(seedingMinutes), let idle = Int(inactiveMinutes) else { return false }
        return (0...5_256_000).contains(time) && (0...5_256_000).contains(idle)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Seeding limits").font(.headline)
            Text(download.title).font(.subheadline).lineLimit(2)
            Form {
                TextField("Share ratio", text: $ratio)
                TextField("Seeding time (minutes)", text: $seedingMinutes)
                TextField("Inactivity (minutes)", text: $inactiveMinutes)
                Picker("When a limit is reached", selection: $action) {
                    Text("Keep seeding").tag(DownloadsViewModel.Download.ShareRatioAction.none)
                    Text("Pause torrent").tag(DownloadsViewModel.Download.ShareRatioAction.pause)
                    Text("Remove torrent (keep files)").tag(DownloadsViewModel.Download.ShareRatioAction.remove)
                }
            }
            Text("0 disables a limit. After completion, the first enabled limit reached triggers the action. Paused and offline time do not count. Uploading resets inactivity.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") {
                    guard isValid else { return }
                    downloadsVM.setSeedingPolicy(for: download.id, ratioLimit: Double(ratio),
                        seedingMinutes: Int(seedingMinutes), inactiveMinutes: Int(inactiveMinutes), action: action)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction).disabled(!isValid)
            }
        }
        .padding(20).frame(width: 430)
    }
}

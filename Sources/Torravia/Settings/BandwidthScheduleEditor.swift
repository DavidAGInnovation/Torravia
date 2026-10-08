import SwiftUI
import AppKit

struct BandwidthScheduleEditor: View {
    @ObservedObject var preferences: SeedingPreferencesStore
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Bandwidth Schedule").font(.title2.bold())
            Form {
                Toggle("Enable scheduled limits", isOn: $preferences.bandwidthSchedule.enabled)
                DatePicker("Start", selection: timeBinding(start: true), displayedComponents: .hourAndMinute)
                DatePicker("End", selection: timeBinding(start: false), displayedComponents: .hourAndMinute)
                Stepper("Download: \(preferences.bandwidthSchedule.downloadLimitMBps) MB/s", value: $preferences.bandwidthSchedule.downloadLimitMBps, in: 0...1000)
                Stepper("Upload: \(preferences.bandwidthSchedule.uploadLimitMBps) MB/s", value: $preferences.bandwidthSchedule.uploadLimitMBps, in: 0...1000)
            }
            Text("Days when the interval starts").font(.headline)
            HStack {
                ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { day in
                    Toggle(Calendar.current.shortWeekdaySymbols[day - 1], isOn: Binding(get: {
                        preferences.bandwidthSchedule.weekdays.contains(day)
                    }, set: { selected in
                        if selected { preferences.bandwidthSchedule.weekdays.insert(day) }
                        else { preferences.bandwidthSchedule.weekdays.remove(day) }
                    })).toggleStyle(.button)
                }
            }
            Text("Uses this Mac’s local time. An end before the start continues into the next day. Equal times apply all day. Zero means unlimited. Your normal limits return outside the interval.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(preferences.bandwidthSchedule.isActive(at: context.date) ? "Scheduled limits are active now." : "Normal limits are active now.").foregroundStyle(.secondary)
            }
            HStack { Spacer(); Button("Done", action: close).keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 500)
    }

    private func timeBinding(start: Bool) -> Binding<Date> {
        Binding(get: {
            let minutes = start ? preferences.bandwidthSchedule.startMinute : preferences.bandwidthSchedule.endMinute
            return Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let minutes = Calendar.current.component(.hour, from: date) * 60 + Calendar.current.component(.minute, from: date)
            if start { preferences.bandwidthSchedule.startMinute = minutes }
            else { preferences.bandwidthSchedule.endMinute = minutes }
        })
    }
}

@MainActor
enum PreferencesPanels {
    static func showBandwidthSchedule(_ preferences: SeedingPreferencesStore, parent: NSWindow?) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 548, height: 450),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Bandwidth Schedule"
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: BandwidthScheduleEditor(preferences: preferences) { [weak panel, weak parent] in
            guard let panel else { return }
            if let parent { parent.endSheet(panel) }
            panel.close()
        })
        if let parent { parent.beginSheet(panel) }
        else { panel.center(); panel.makeKeyAndOrderFront(nil) }
    }
}

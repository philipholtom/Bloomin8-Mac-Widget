import Bloomin8Core
import SwiftUI

/// Settings → Content → Countdown: the dates to count down to.
struct CountdownSettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Group {
            Text("The Countdown card counts the days to your nearest event, with the next two below it. Put it on a daily schedule (Automation → Scheduled Content, with “Use today's picture”) and it stays right each morning.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach($settings.countdownOptions.events) { $event in
                HStack {
                    TextField("", text: $event.name, prompt: Text("Event name"))
                        .textFieldStyle(.roundedBorder)
                    DatePicker("", selection: $event.date, displayedComponents: .date)
                        .labelsHidden()
                        .fixedSize()
                    Button {
                        settings.countdownOptions.events.removeAll { $0.id == event.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .help("Remove this event")
                }
            }

            HStack {
                Button("Add Event") {
                    let nextMonth = Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date()
                    settings.countdownOptions.events.append(CountdownEvent(name: "", date: nextMonth))
                }
                Spacer()
                if pastCount > 0 {
                    Button("Remove \(pastCount) past") {
                        let today = Calendar.current.startOfDay(for: Date())
                        settings.countdownOptions.events.removeAll { Calendar.current.startOfDay(for: $0.date) < today }
                    }
                    .help("Events whose date has passed are skipped automatically; this tidies them away.")
                }
            }
        }
    }

    private var pastCount: Int {
        let today = Calendar.current.startOfDay(for: Date())
        return settings.countdownOptions.events.filter { Calendar.current.startOfDay(for: $0.date) < today }.count
    }
}

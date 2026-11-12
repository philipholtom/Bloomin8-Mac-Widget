import Bloomin8Core
import SwiftUI

/// Settings → Content → Agenda: calendar permission, what the card includes,
/// and which calendars appear on it.
struct AgendaSettingsView: View {
    @ObservedObject var settings: AppSettings

    @State private var authorized = AgendaCalendars.isAuthorized
    @State private var canAsk = AgendaCalendars.canAsk
    @State private var calendars: [AgendaCalendars.CalendarInfo] = []

    var body: some View {
        Group {
            Text("A card of today's events from your Mac's calendars. It's shown on the frame for anyone in the room to read, so leave off any calendar you'd rather keep private.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if authorized {
                Toggle("Include tomorrow", isOn: $settings.agendaOptions.includeTomorrow)
                HStack {
                    Toggle("Show today's forecast", isOn: $settings.agendaOptions.showWeather)
                    InfoButton("Uses the weather location set below. Left off the card if no location is set.")
                }
                if calendars.isEmpty {
                    Text("No calendars found.").foregroundStyle(.secondary)
                } else {
                    DisclosureGroup("Calendars on the card (\(calendars.count - excludedCount) of \(calendars.count))") {
                        ForEach(calendars) { calendar in
                            Toggle(isOn: binding(for: calendar.id)) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(calendar.title)
                                    if !calendar.source.isEmpty {
                                        Text(calendar.source).font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            } else if canAsk {
                Button("Allow Calendar Access…") {
                    Task {
                        _ = await AgendaCalendars.requestAccess()
                        refresh()
                    }
                }
            } else {
                Label("Calendar access is off for Bloomin8 Mac. Turn it on in System Settings → Privacy & Security → Calendars.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .onAppear { refresh() }
    }

    private var excludedCount: Int {
        calendars.filter { settings.agendaOptions.excludedCalendarIDs.contains($0.id) }.count
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { !settings.agendaOptions.excludedCalendarIDs.contains(id) },
            set: { shown in
                if shown { settings.agendaOptions.excludedCalendarIDs.remove(id) }
                else { settings.agendaOptions.excludedCalendarIDs.insert(id) }
            }
        )
    }

    private func refresh() {
        authorized = AgendaCalendars.isAuthorized
        canAsk = AgendaCalendars.canAsk
        calendars = AgendaCalendars.calendars()
    }
}

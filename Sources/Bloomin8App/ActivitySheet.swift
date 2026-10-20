import Bloomin8Core
import SwiftUI

/// A simple list of the last ~50 things the app tried to do to the frame,
/// with the outcome — see `PhotoController.recentActivity`. Distinct from
/// "Logs" in the toolbar, which shows the frame's own diagnostic log; this
/// is the app's own record, so a failure that only flashed briefly in the
/// sidebar's status line is still findable afterwards.
struct ActivitySheet: View {
    @ObservedObject var controller: PhotoController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Activity")
                    .font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)

            Divider()

            if controller.recentActivity.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("Nothing to show yet.")
                        .foregroundStyle(.secondary)
                    Text("Uploads, sends, and other actions on the frame will show up here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(controller.recentActivity) { event in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: event.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(event.success ? Color.green : Color.red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.message)
                            Text(event.date.formatted(date: .omitted, time: .standard))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 460, idealWidth: 500, minHeight: 380, idealHeight: 480)
        .onAppear { controller.hasUnseenActivityFailure = false }
    }
}

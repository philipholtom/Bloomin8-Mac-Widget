import Bloomin8Core
import SwiftUI

/// The last few Bluetooth wake attempts with timings and signal strength.
struct WakeHistoryView: View {
    @State private var records: [WakeRecord] = []

    var body: some View {
        let summary = WakeHistory.summary(records)
        VStack(alignment: .leading, spacing: 8) {
            if records.isEmpty {
                Text("No Bluetooth wakes recorded yet. Each wake adds a line here, so a slowdown can be measured.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(headline(summary)).font(.callout)
                ForEach(records.suffix(8).reversed()) { record in
                    HStack(spacing: 8) {
                        Image(systemName: record.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(record.succeeded ? .green : .red)
                        Text(record.date.formatted(date: .abbreviated, time: .shortened)).monospacedDigit()
                        Spacer()
                        Text(detail(record)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .font(.caption)
                }
                Button("Clear History") { WakeHistory.clear(); records = [] }
                    .controlSize(.small)
            }
        }
        .onAppear { records = WakeHistory.load() }
    }

    private func headline(_ s: WakeHistory.Summary) -> String {
        var parts = ["\(s.successes) of \(s.attempts) woke the frame"]
        if let m = s.medianSeconds { parts.append(String(format: "typically %.1fs", m)) }
        if let r = s.medianRSSI { parts.append("signal about \(r) dBm") }
        return parts.joined(separator: " · ")
    }

    private func detail(_ r: WakeRecord) -> String {
        guard r.succeeded else { return r.foundSeconds == nil ? "frame not found (\(Int(r.totalSeconds))s)" : "failed after \(String(format: "%.1f", r.totalSeconds))s" }
        var text = String(format: "%.1fs", r.totalSeconds)
        if let rssi = r.rssi { text += " · \(rssi) dBm" }
        if r.usedFallbackScan { text += " · slow scan" }
        return text
    }
}

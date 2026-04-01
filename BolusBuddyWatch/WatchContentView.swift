import SwiftUI

struct WatchContentView: View {
    @EnvironmentObject var detector: EatingDetector
    @AppStorage("autoStart") private var autoStart = true

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                // Status indicator
                ZStack {
                    Circle()
                        .fill(detector.isMonitoring ?
                              (detector.isEatingDetected ? Color.orange : Color.green) :
                              Color.gray.opacity(0.3))
                        .frame(width: 60, height: 60)

                    Image(systemName: detector.isEatingDetected ? "fork.knife" :
                            (detector.isMonitoring ? "waveform" : "pause.circle"))
                        .font(.system(size: 24))
                        .foregroundStyle(.white)
                }

                // Status text
                Text(statusText)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .multilineTextAlignment(.center)

                // Bite counter + location status
                if detector.isMonitoring {
                    if detector.locationTriggered, let place = detector.locationDetector.currentPlaceName {
                        HStack(spacing: 4) {
                            Image(systemName: "mappin.circle.fill")
                                .font(.system(size: 10))
                            Text(place)
                                .font(.system(size: 11))
                                .lineLimit(1)
                        }
                        .foregroundStyle(.orange)
                    } else if detector.locationDetector.isAtFoodPlace, let place = detector.locationDetector.currentPlaceName {
                        HStack(spacing: 4) {
                            Image(systemName: "mappin")
                                .font(.system(size: 10))
                            Text(place)
                                .font(.system(size: 11))
                                .lineLimit(1)
                        }
                        .foregroundStyle(.yellow)
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "hand.raised")
                                .font(.system(size: 10))
                            Text("Bites: \(detector.biteCount)")
                                .font(.system(size: 11, design: .monospaced))
                        }
                        .foregroundStyle(.secondary)
                    }
                }

                // Toggle button
                Button(action: toggleMonitoring) {
                    HStack {
                        Image(systemName: detector.isMonitoring ? "stop.fill" : "play.fill")
                        Text(detector.isMonitoring ? "Stop" : "Start")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(detector.isMonitoring ? .red : .green)

                // Dismiss alert button
                if detector.isEatingDetected {
                    Button("I Bolused") {
                        detector.resetAlert()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                }

                // Sensitivity slider
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sensitivity")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Slider(value: $detector.sensitivity, in: 0.5...1.5, step: 0.1)
                }
                .padding(.top, 4)

                // Auto-start toggle
                Toggle("Auto-start", isOn: $autoStart)
                    .font(.system(size: 11))
                    .onChange(of: autoStart) { _, newValue in
                        if newValue && !detector.isMonitoring {
                            detector.startMonitoring()
                        }
                    }

                // Location detection toggle
                Toggle("Location alerts", isOn: $detector.locationDetector.isEnabled)
                    .font(.system(size: 11))

                // Last alert time
                if let lastAlert = detector.lastAlertTime {
                    Text("Last alert: \(lastAlert.formatted(.dateTime.hour().minute()))")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }

                // Version
                Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 4)
        }
        .onAppear {
            if autoStart && !detector.isMonitoring {
                detector.startMonitoring()
            }
        }
    }

    private var statusText: String {
        if !detector.isMonitoring { return "Not Monitoring" }
        if detector.isEatingDetected && detector.locationTriggered {
            return "At a restaurant!\nDid you bolus?"
        }
        if detector.isEatingDetected { return "Eating Detected!\nDid you bolus?" }
        return "Monitoring..."
    }

    private var statusColor: Color {
        if !detector.isMonitoring { return .secondary }
        if detector.isEatingDetected { return .orange }
        return .green
    }

    private func toggleMonitoring() {
        if detector.isMonitoring {
            detector.stopMonitoring()
        } else {
            detector.startMonitoring()
        }
    }
}

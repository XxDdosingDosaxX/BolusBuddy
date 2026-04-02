import SwiftUI

struct WatchContentView: View {
    @EnvironmentObject var detector: EatingDetector
    @AppStorage("autoStart") private var autoStart = true

    var body: some View {
        NavigationStack {
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

                // Record Meal button
                if detector.isMonitoring {
                    Button(action: {
                        if detector.isRecordingMeal {
                            detector.stopRecordingMeal()
                        } else {
                            detector.startRecordingMeal()
                        }
                    }) {
                        HStack {
                            Circle()
                                .fill(detector.isRecordingMeal ? Color.red : Color.red.opacity(0.5))
                                .frame(width: 8, height: 8)
                            Text(detector.isRecordingMeal ? "Stop Recording (\(detector.mealLog.count))" : "Record Meal")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(detector.isRecordingMeal ? .red : .orange)
                }

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

                // Debug mode toggle
                Toggle("Debug", isOn: $detector.debugMode)
                    .font(.system(size: 11))

                // Debug overlay — live sensor values
                if detector.debugMode && detector.isMonitoring {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("LIVE SENSOR DATA")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(.cyan)

                        // Arm elevation (gravity.y)
                        HStack {
                            Text("Elev:")
                                .frame(width: 40, alignment: .leading)
                            ProgressView(value: min(max(detector.debugGravityY + 0.5, 0), 1.5) / 1.5)
                                .tint(detector.debugGravityY > (0.25 / detector.sensitivity) ? .green : .gray)
                            Text(String(format: "%.2f", detector.debugGravityY))
                        }
                        .font(.system(size: 9, design: .monospaced))

                        // Wrist rotation (rotationRate.x)
                        HStack {
                            Text("Wrist:")
                                .frame(width: 40, alignment: .leading)
                            ProgressView(value: min(detector.debugRotationRate / 3.0, 1.0))
                                .tint(detector.debugRotationRate > (0.5 / detector.sensitivity) ? .green : .gray)
                            Text(String(format: "%.1f", detector.debugRotationRate))
                        }
                        .font(.system(size: 9, design: .monospaced))

                        // Acceleration magnitude
                        HStack {
                            Text("Accel:")
                                .frame(width: 40, alignment: .leading)
                            ProgressView(value: min(detector.debugAccelMag / 2.0, 1.0))
                                .tint(.blue)
                            Text(String(format: "%.2f", detector.debugAccelMag))
                        }
                        .font(.system(size: 9, design: .monospaced))

                        // Repetition score (autocorrelation)
                        HStack {
                            Text("Reptn:")
                                .frame(width: 40, alignment: .leading)
                            ProgressView(value: min(detector.debugRepetition, 1.0))
                                .tint(detector.debugRepetition > 0.3 ? .orange : .gray)
                            Text(String(format: "%.2f", detector.debugRepetition))
                        }
                        .font(.system(size: 9, design: .monospaced))

                        // State row
                        HStack(spacing: 4) {
                            Circle()
                                .fill(detector.debugArmRaised ? Color.green : Color.gray)
                                .frame(width: 6, height: 6)
                            Text(detector.debugArmRaised ? "ARM UP" : "arm down")
                                .font(.system(size: 9, design: .monospaced))
                            Spacer()
                            if !detector.debugIsStationary {
                                Text("MOVING")
                                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.red)
                            }
                            Text("Bites: \(detector.biteCount)")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(6)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(8)
                }

                // Last alert time
                if let lastAlert = detector.lastAlertTime {
                    Text("Last alert: \(lastAlert.formatted(.dateTime.hour().minute()))")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }

                // Saved meals summary
                if !detector.savedMeals.isEmpty {
                    NavigationLink {
                        SavedMealsView()
                            .environmentObject(detector)
                    } label: {
                        HStack {
                            Image(systemName: "list.clipboard")
                                .font(.system(size: 10))
                            Text("Meal Logs (\(detector.savedMeals.count))")
                                .font(.system(size: 11))
                        }
                    }
                }

                // Location permission warning
                if detector.locationDetector.needsAlwaysPermission {
                    VStack(spacing: 4) {
                        Text("Location: When In Use only")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.yellow)
                        Text("Go to Settings > Privacy > Location > BolusBuddy > Always")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(6)
                    .background(Color.yellow.opacity(0.15))
                    .cornerRadius(6)
                }

                // Version
                Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 4)
        }
        .onAppear {
            detector.loadMealsFromDisk()
            if autoStart && !detector.isMonitoring {
                detector.startMonitoring()
            }
        }
        } // NavigationStack
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

// MARK: - Saved Meals View

struct SavedMealsView: View {
    @EnvironmentObject var detector: EatingDetector

    var body: some View {
        List {
            ForEach(Array(detector.savedMeals.enumerated().reversed()), id: \.element.id) { index, meal in
                NavigationLink {
                    MealDetailView(meal: meal)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(meal.date.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                            .font(.system(size: 11, weight: .semibold))
                        HStack {
                            Text("\(Int(meal.duration/60))m")
                            Text("·")
                            Text("\(meal.entries.count) pts")
                            Text("·")
                            Text("\(meal.bitesCounted) bites")
                        }
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    }
                }
                .swipeActions {
                    Button(role: .destructive) {
                        detector.deleteMeal(at: index)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle("Meal Logs")
    }
}

// MARK: - Meal Detail View

struct MealDetailView: View {
    let meal: SavedMeal

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(meal.date.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                    .font(.system(size: 12, weight: .bold))

                // Summary stats
                VStack(alignment: .leading, spacing: 4) {
                    Text("SUMMARY")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(.cyan)

                    HStack {
                        StatBox(label: "Duration", value: "\(Int(meal.duration/60))m")
                        StatBox(label: "Samples", value: "\(meal.entries.count)")
                    }
                    HStack {
                        StatBox(label: "Bites", value: "\(meal.bitesCounted)")
                        StatBox(label: "Max Elev", value: String(format: "%.2f", meal.maxGravityY))
                    }
                    HStack {
                        StatBox(label: "Avg Elev", value: String(format: "%.2f", meal.avgGravityY))
                        StatBox(label: "Avg Wrist", value: String(format: "%.1f", meal.avgRotationRate))
                    }
                    HStack {
                        StatBox(label: "Max Wrist", value: String(format: "%.1f", meal.maxRotationRate))
                        StatBox(label: "Avg Reptn", value: String(format: "%.2f", meal.avgRepetition))
                    }
                }
                .padding(6)
                .background(Color.black.opacity(0.4))
                .cornerRadius(6)

                // Threshold analysis
                VStack(alignment: .leading, spacing: 4) {
                    Text("THRESHOLD ANALYSIS")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(.orange)

                    let elevAbove = meal.entries.filter { $0.gravityY > 0.25 }.count
                    let rotAbove = meal.entries.filter { $0.rotationRate > 0.5 }.count
                    let repAbove = meal.entries.filter { $0.repetitionScore > 0.3 }.count
                    let total = meal.entries.count
                    let elevPct = total == 0 ? 0 : Int(Double(elevAbove) / Double(total) * 100)
                    let rotPct = total == 0 ? 0 : Int(Double(rotAbove) / Double(total) * 100)
                    let repPct = total == 0 ? 0 : Int(Double(repAbove) / Double(total) * 100)

                    Text("Elev > 0.25: \(elevPct)%")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(elevPct > 15 ? .green : .red)
                    Text("Wrist > 0.5: \(rotPct)%")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(rotPct > 15 ? .green : .red)
                    Text("Reptn > 0.3: \(repPct)%")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(repPct > 30 ? .green : .red)

                    if elevPct < 10 {
                        Text("Arm rarely reached threshold")
                            .font(.system(size: 8))
                            .foregroundStyle(.yellow)
                    }
                    if rotPct < 10 {
                        Text("Wrist rotation rarely crossed threshold")
                            .font(.system(size: 8))
                            .foregroundStyle(.yellow)
                    }
                    if repPct > 30 {
                        Text("Strong repetitive pattern detected")
                            .font(.system(size: 8))
                            .foregroundStyle(.green)
                    }
                }
                .padding(6)
                .background(Color.black.opacity(0.4))
                .cornerRadius(6)

                // Raw data scroll
                VStack(alignment: .leading, spacing: 2) {
                    Text("RAW DATA (last 20)")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)

                    ForEach(meal.entries.suffix(20)) { entry in
                        HStack(spacing: 3) {
                            Text(entry.timestamp.formatted(.dateTime.second()))
                                .frame(width: 18, alignment: .leading)
                            Text("E:\(String(format: "%.1f", entry.gravityY))")
                                .foregroundStyle(entry.gravityY > 0.25 ? .green : .gray)
                            Text("W:\(String(format: "%.1f", entry.rotationRate))")
                                .foregroundStyle(entry.rotationRate > 0.5 ? .green : .gray)
                            Text("R:\(String(format: "%.1f", entry.repetitionScore))")
                                .foregroundStyle(entry.repetitionScore > 0.3 ? .orange : .gray)
                            if entry.armRaised {
                                Text("^")
                                    .foregroundStyle(.green)
                            }
                        }
                        .font(.system(size: 7, design: .monospaced))
                    }
                }
                .padding(6)
                .background(Color.black.opacity(0.4))
                .cornerRadius(6)
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Detail")
    }
}

struct StatBox: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
            Text(label)
                .font(.system(size: 7))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

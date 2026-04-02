import Foundation
import CoreMotion
import UserNotifications
#if os(watchOS)
import WatchKit
#endif

/// Detects eating gestures using Apple Watch accelerometer and gyroscope.
///
/// Phase 1 detection (research-backed):
/// - gravity.y for arm elevation (more stable than Euler pitch, no gimbal lock)
/// - rotationRate.x for wrist supination/pronation (instantaneous, no windowing needed)
/// - userAcceleration magnitude for dynamic hand movement
/// - Median filter smoothing (outlier-robust vs mean)
/// - Autocorrelation of acceleration for repetitive eating pattern detection
/// - CMMotionActivity gating: only detect when user is stationary
///
/// Also uses location to detect food establishments (5 min dwell = reminder).
class EatingDetector: NSObject, ObservableObject {
    static let shared = EatingDetector()

    private let motionManager = CMMotionManager()
    var locationDetector = LocationDetector()

    // Detection state
    @Published var isMonitoring = false
    @Published var isEatingDetected = false
    @Published var biteCount = 0
    @Published var lastAlertTime: Date?
    @Published var sensitivity: Double = 1.0 // 0.5 = less sensitive, 1.5 = more sensitive
    @Published var locationTriggered = false  // True when location triggered the alert

    // Debug mode — shows live sensor values on screen
    @Published var debugMode = false
    @Published var debugGravityY: Double = 0       // arm elevation (-1 down, +1 up)
    @Published var debugRotationRate: Double = 0    // wrist rotation speed (rad/s)
    @Published var debugAccelMag: Double = 0        // user acceleration magnitude
    @Published var debugArmRaised = false
    @Published var debugRepetition: Double = 0      // autocorrelation score (0-1)
    @Published var debugIsStationary = true         // from CMMotionActivity

    // Meal recording — logs sensor data for threshold tuning
    @Published var isRecordingMeal = false
    @Published var mealLog: [MealLogEntry] = []
    @Published var savedMeals: [SavedMeal] = []
    private var lastLogTime: Date?
    private let logInterval: TimeInterval = 0.5 // Log every 0.5s (2Hz)

    // Bite detection
    private var biteEvents: [Date] = []
    private var isArmRaised = false
    private var peakRotationInCycle: Double = 0     // track max wrist rotation during arm-up

    // Thresholds (research-backed)
    private let biteWindowSeconds: TimeInterval = 180       // 3-minute window (was 2m — research shows 3-4m is better)
    private let minimumBitesForEating = 3                    // 3 bites = eating (Klue uses 3)
    private let alertCooldownMinutes: TimeInterval = 30      // Don't re-alert for 30 min

    // Gravity.y thresholds (arm elevation via gravity vector)
    // gravity.y: -1.0 = arm pointing straight down, 0.0 = horizontal, +1.0 = straight up
    // Negated: -gravity.y gives us elevation where positive = arm raised
    private let armRaisedThreshold: Double = 0.25           // arm raised ~15° above horizontal
    private let armLoweredThreshold: Double = 0.10          // arm back near horizontal

    // RotationRate.x threshold (wrist supination/pronation in rad/s)
    // Eating typically shows peaks > 0.8 rad/s during fork-to-mouth
    private let minimumWristRotation: Double = 0.5          // rad/s peak during cycle

    // Acceleration magnitude threshold (filters out static arm positions)
    private let minimumAccelMag: Double = 0.05              // must have some dynamic motion

    // Autocorrelation — detects repetitive eating pattern
    private var accelMagHistory: [Double] = []              // rolling buffer of accel magnitudes
    private let accelHistorySize = 150                       // 6 seconds at 25Hz
    private let repetitionThreshold: Double = 0.3           // autocorrelation score for "repetitive"
    private var repetitionScore: Double = 0

    // Smoothing buffers (median filter, 2-3 second windows)
    private var gravityYHistory: [Double] = []
    private var rotationXHistory: [Double] = []
    private let smoothingWindow = 15 // samples at 25Hz = 0.6s (median filter handles outliers)

    // Activity state — only detect eating when stationary
    private var isUserStationary = true
    private var activityManager: CMMotionActivityManager?

    // Extended runtime for background
    #if os(watchOS)
    private var session: WKExtendedRuntimeSession?
    #endif

    // MARK: - Public API

    func startMonitoring() {
        guard motionManager.isDeviceMotionAvailable else {
            print("BolusBuddy: Device motion not available")
            return
        }

        requestNotificationPermission()

        // Start location-based detection
        locationDetector.onFoodPlaceDwellDetected = { [weak self] placeName in
            self?.handleFoodPlaceDwell(placeName: placeName)
        }
        locationDetector.startMonitoring()

        // Start activity monitoring (stationary detection)
        activityManager = CMMotionActivityManager()
        startActivityMonitoring()

        // Trigger the motion permission prompt
        let now = Date()
        let oneHourAgo = now.addingTimeInterval(-3600)
        activityManager?.queryActivityStarting(from: oneHourAgo, to: now, to: .main) { [weak self] _, _ in
            self?.beginMotionUpdates()
        }
    }

    private func startActivityMonitoring() {
        activityManager?.startActivityUpdates(to: .main) { [weak self] activity in
            guard let self = self, let activity = activity else { return }
            // User is "stationary" if not walking, running, cycling, or in a vehicle
            let stationary = activity.stationary || (!activity.walking && !activity.running && !activity.cycling && !activity.automotive)
            self.isUserStationary = stationary
            if self.debugMode {
                DispatchQueue.main.async {
                    self.debugIsStationary = stationary
                }
            }
        }
    }

    private func beginMotionUpdates() {
        let status = CMMotionActivityManager.authorizationStatus()
        guard status == .authorized || status == .notDetermined else {
            print("BolusBuddy: Motion permission denied (status: \(status.rawValue))")
            return
        }

        #if os(watchOS)
        startExtendedSession()
        #endif

        motionManager.deviceMotionUpdateInterval = 1.0 / 25.0 // 25Hz
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            guard let self = self, let motion = motion else { return }
            self.processMotion(motion)
        }

        isMonitoring = true
        print("BolusBuddy: Eating detection started (Phase 1 — gravity + rotationRate + autocorrelation)")
    }

    func stopMonitoring() {
        motionManager.stopDeviceMotionUpdates()
        activityManager?.stopActivityUpdates()
        locationDetector.stopMonitoring()
        #if os(watchOS)
        session?.invalidate()
        session = nil
        #endif
        isMonitoring = false
        isEatingDetected = false
        locationTriggered = false
        biteEvents.removeAll()
        biteCount = 0
        accelMagHistory.removeAll()
        gravityYHistory.removeAll()
        rotationXHistory.removeAll()
        repetitionScore = 0
        print("BolusBuddy: Eating detection stopped")
    }

    func resetAlert() {
        isEatingDetected = false
        locationTriggered = false
        biteEvents.removeAll()
        biteCount = 0
    }

    // MARK: - Location-Based Detection

    private func handleFoodPlaceDwell(placeName: String) {
        if let lastAlert = lastAlertTime,
           Date().timeIntervalSince(lastAlert) < alertCooldownMinutes * 60 {
            return
        }

        DispatchQueue.main.async {
            self.isEatingDetected = true
            self.locationTriggered = true
            self.lastAlertTime = Date()
        }

        motionManager.stopDeviceMotionUpdates()
        sendBolusReminder(locationName: placeName)

        DispatchQueue.main.asyncAfter(deadline: .now() + alertCooldownMinutes * 60) { [weak self] in
            guard let self = self, self.isMonitoring else { return }
            self.locationTriggered = false
            self.beginMotionUpdates()
        }
    }

    // MARK: - Motion Processing (Phase 1 — research-backed)

    private func processMotion(_ motion: CMDeviceMotion) {
        if locationTriggered { return }

        // --- Extract signals ---

        // Arm elevation from gravity vector (more stable than Euler pitch)
        // gravity.y is negative when arm hangs down, positive when raised
        // We negate it so positive = arm up
        let armElevation = -motion.gravity.y

        // Wrist rotation speed (supination/pronation)
        let wristRotation = abs(motion.rotationRate.x)

        // User acceleration magnitude (dynamic movement, gravity removed)
        let ax = motion.userAcceleration.x
        let ay = motion.userAcceleration.y
        let az = motion.userAcceleration.z
        let accelMag = sqrt(ax*ax + ay*ay + az*az)

        // --- Smoothing with median filter ---
        gravityYHistory.append(armElevation)
        rotationXHistory.append(wristRotation)
        if gravityYHistory.count > smoothingWindow { gravityYHistory.removeFirst() }
        if rotationXHistory.count > smoothingWindow { rotationXHistory.removeFirst() }

        let smoothedElevation = medianFilter(gravityYHistory)
        let smoothedRotation = medianFilter(rotationXHistory)

        // --- Autocorrelation for repetitive pattern detection ---
        accelMagHistory.append(accelMag)
        if accelMagHistory.count > accelHistorySize { accelMagHistory.removeFirst() }
        // Compute autocorrelation every ~1 second (every 25 samples)
        if accelMagHistory.count >= accelHistorySize && accelMagHistory.count % 25 == 0 {
            repetitionScore = computeAutocorrelation(accelMagHistory, lagRange: 50...75)
            // lag 50-75 at 25Hz = 2-3 second period = typical bite interval
        }

        // --- Track peak rotation during arm-raised cycle ---
        if isArmRaised {
            peakRotationInCycle = max(peakRotationInCycle, smoothedRotation)
        }

        // Adjusted thresholds based on sensitivity
        let raiseThreshold = armRaisedThreshold / sensitivity
        let lowerThreshold = armLoweredThreshold / sensitivity
        let rotationThreshold = minimumWristRotation / sensitivity

        // --- Update debug values ---
        if debugMode {
            DispatchQueue.main.async {
                self.debugGravityY = smoothedElevation
                self.debugRotationRate = smoothedRotation
                self.debugAccelMag = accelMag
                self.debugArmRaised = self.isArmRaised
                self.debugRepetition = self.repetitionScore
            }
        }
        logSensorData(
            gravityY: smoothedElevation,
            rotationRate: smoothedRotation,
            accelMag: accelMag,
            repetitionScore: repetitionScore
        )

        // --- Gate: skip detection if user is walking/driving ---
        if !isUserStationary { return }

        // --- Bite detection (two-phase cycle) ---

        // Phase 1: Arm goes up
        if smoothedElevation > raiseThreshold && !isArmRaised {
            isArmRaised = true
            peakRotationInCycle = smoothedRotation
        }
        // Phase 2: Arm comes back down — check if it was a bite
        else if smoothedElevation < lowerThreshold && isArmRaised {
            isArmRaised = false

            // A bite requires: wrist rotated during the raise AND some dynamic motion
            let hadRotation = peakRotationInCycle > rotationThreshold
            let hadMovement = accelMag > minimumAccelMag

            if hadRotation && hadMovement {
                recordBiteEvent()
            }

            peakRotationInCycle = 0
        }
    }

    // MARK: - Median Filter

    private func medianFilter(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2.0
        }
        return sorted[mid]
    }

    // MARK: - Autocorrelation (detects repetitive eating motion)

    private func computeAutocorrelation(_ signal: [Double], lagRange: ClosedRange<Int>) -> Double {
        let n = signal.count
        guard n > lagRange.upperBound else { return 0 }

        let mean = signal.reduce(0, +) / Double(n)
        let variance = signal.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(n)
        guard variance > 0.0001 else { return 0 } // near-zero variance = no motion

        var maxCorrelation: Double = 0

        for lag in lagRange {
            var correlation: Double = 0
            let count = n - lag
            for i in 0..<count {
                correlation += (signal[i] - mean) * (signal[i + lag] - mean)
            }
            correlation /= Double(count) * variance
            maxCorrelation = max(maxCorrelation, correlation)
        }

        return min(max(maxCorrelation, 0), 1) // clamp to 0-1
    }

    // MARK: - Bite Recording

    private func recordBiteEvent() {
        let now = Date()
        biteEvents.append(now)

        // Remove old events outside the window
        biteEvents = biteEvents.filter { now.timeIntervalSince($0) < biteWindowSeconds }

        DispatchQueue.main.async {
            self.biteCount = self.biteEvents.count
        }

        // Check if we've reached the eating threshold
        // Bonus: if repetition score is high, we're more confident it's eating
        let effectiveMinBites = repetitionScore > repetitionThreshold
            ? max(minimumBitesForEating - 1, 2)  // need fewer bites if motion is clearly repetitive
            : minimumBitesForEating

        if biteEvents.count >= effectiveMinBites && !isEatingDetected {
            if let lastAlert = lastAlertTime,
               Date().timeIntervalSince(lastAlert) < alertCooldownMinutes * 60 {
                return
            }

            DispatchQueue.main.async {
                self.isEatingDetected = true
                self.lastAlertTime = Date()
            }
            sendBolusReminder(locationName: nil)
        }
    }

    // MARK: - Notifications

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                print("BolusBuddy: Notification permission granted")
            }
        }
    }

    private func sendBolusReminder(locationName: String?) {
        #if os(watchOS)
        WKInterfaceDevice.current().play(.notification)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            WKInterfaceDevice.current().play(.retry)
        }
        #endif

        let content = UNMutableNotificationContent()
        if let name = locationName {
            content.title = "At \(name) — bolus?"
            content.body = "You've been at \(name) for 5 minutes. Don't forget to bolus!"
        } else {
            content.title = "Did you bolus?"
            content.body = "Eating detected! Don't forget to bolus for your meal."
        }
        content.sound = .default
        content.categoryIdentifier = "BOLUS_REMINDER"
        content.interruptionLevel = .timeSensitive

        let request = UNNotificationRequest(
            identifier: "bolus-reminder-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("BolusBuddy: Notification error: \(error)")
            } else {
                print("BolusBuddy: Bolus reminder sent!")
            }
        }

        // Follow-up in 5 minutes
        let followUp = UNMutableNotificationContent()
        followUp.title = "Bolus Reminder"
        followUp.body = "Just checking - did you bolus for your meal? It's been 5 minutes."
        followUp.sound = .default
        followUp.interruptionLevel = .timeSensitive

        let followUpRequest = UNNotificationRequest(
            identifier: "bolus-followup-\(Date().timeIntervalSince1970)",
            content: followUp,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 300, repeats: false)
        )
        UNUserNotificationCenter.current().add(followUpRequest)
    }

    // MARK: - Meal Recording

    func startRecordingMeal() {
        mealLog.removeAll()
        lastLogTime = nil
        isRecordingMeal = true
        debugMode = true
        print("BolusBuddy: Meal recording started")
    }

    func stopRecordingMeal() {
        isRecordingMeal = false
        if !mealLog.isEmpty {
            let meal = SavedMeal(
                date: Date(),
                entries: mealLog,
                bitesCounted: biteCount
            )
            savedMeals.append(meal)
            saveMealsToDisk()
            print("BolusBuddy: Meal recorded — \(mealLog.count) samples, \(biteCount) bites detected")
        }
    }

    func deleteMeal(at index: Int) {
        guard index < savedMeals.count else { return }
        savedMeals.remove(at: index)
        saveMealsToDisk()
    }

    private func logSensorData(gravityY: Double, rotationRate: Double, accelMag: Double, repetitionScore: Double) {
        guard isRecordingMeal else { return }
        let now = Date()
        if let last = lastLogTime, now.timeIntervalSince(last) < logInterval { return }
        lastLogTime = now

        let entry = MealLogEntry(
            timestamp: now,
            gravityY: gravityY,
            rotationRate: rotationRate,
            accelMag: accelMag,
            repetitionScore: repetitionScore,
            armRaised: isArmRaised,
            biteCount: biteEvents.count
        )
        DispatchQueue.main.async {
            self.mealLog.append(entry)
        }
    }

    private func saveMealsToDisk() {
        guard let data = try? JSONEncoder().encode(savedMeals) else { return }
        UserDefaults.standard.set(data, forKey: "savedMeals_v2")
    }

    func loadMealsFromDisk() {
        guard let data = UserDefaults.standard.data(forKey: "savedMeals_v2"),
              let meals = try? JSONDecoder().decode([SavedMeal].self, from: data) else { return }
        savedMeals = meals
    }

    #if os(watchOS)
    // MARK: - Extended Runtime Session

    private func startExtendedSession() {
        session?.invalidate()
        session = WKExtendedRuntimeSession()
        session?.delegate = self
        session?.start()
    }
    #endif
}

#if os(watchOS)
extension EatingDetector: WKExtendedRuntimeSessionDelegate {
    func extendedRuntimeSessionDidStart(_ session: WKExtendedRuntimeSession) {
        print("BolusBuddy: Extended session started")
    }

    func extendedRuntimeSessionWillExpire(_ session: WKExtendedRuntimeSession) {
        print("BolusBuddy: Extended session expiring, restarting...")
        startExtendedSession()
    }

    func extendedRuntimeSession(_ session: WKExtendedRuntimeSession, didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason, error: (any Error)?) {
        print("BolusBuddy: Extended session invalidated: \(reason.rawValue)")
        if isMonitoring {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.startExtendedSession()
            }
        }
    }
}
#endif

// MARK: - Meal Log Data Models

struct MealLogEntry: Codable, Identifiable {
    let id = UUID()
    let timestamp: Date
    let gravityY: Double        // arm elevation (-gravity.y)
    let rotationRate: Double    // wrist rotation speed (rad/s)
    let accelMag: Double        // user acceleration magnitude
    let repetitionScore: Double // autocorrelation (0-1)
    let armRaised: Bool
    let biteCount: Int

    enum CodingKeys: String, CodingKey {
        case timestamp, gravityY, rotationRate, accelMag, repetitionScore, armRaised, biteCount
    }
}

struct SavedMeal: Codable, Identifiable {
    let id = UUID()
    let date: Date
    let entries: [MealLogEntry]
    let bitesCounted: Int

    var duration: TimeInterval {
        guard let first = entries.first, let last = entries.last else { return 0 }
        return last.timestamp.timeIntervalSince(first.timestamp)
    }

    var maxGravityY: Double { entries.map(\.gravityY).max() ?? 0 }
    var avgGravityY: Double { entries.isEmpty ? 0 : entries.map(\.gravityY).reduce(0, +) / Double(entries.count) }
    var maxRotationRate: Double { entries.map(\.rotationRate).max() ?? 0 }
    var avgRotationRate: Double { entries.isEmpty ? 0 : entries.map(\.rotationRate).reduce(0, +) / Double(entries.count) }
    var avgAccelMag: Double { entries.isEmpty ? 0 : entries.map(\.accelMag).reduce(0, +) / Double(entries.count) }
    var avgRepetition: Double { entries.isEmpty ? 0 : entries.map(\.repetitionScore).reduce(0, +) / Double(entries.count) }

    enum CodingKeys: String, CodingKey {
        case date, entries, bitesCounted
    }
}

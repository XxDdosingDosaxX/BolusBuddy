import Foundation
import CoreMotion
import UserNotifications
#if os(watchOS)
import WatchKit
#endif

/// Detects eating gestures using Apple Watch accelerometer and gyroscope.
/// Eating involves repeated arm-raise-to-mouth cycles with wrist rotation.
/// Also uses location to detect food establishments (5 min dwell = reminder).
/// When eating is detected for ~2 minutes without a recent bolus, sends an alert.
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

    // Bite detection
    private var biteEvents: [Date] = []
    private var isArmRaised = false
    private var wasArmRaised = false
    private var lastMotionUpdate = Date()

    // Thresholds (tunable)
    private let biteWindowSeconds: TimeInterval = 120      // 2-minute window
    private let minimumBitesForEating = 5                   // 5 bites = eating
    private let alertCooldownMinutes: TimeInterval = 30     // Don't re-alert for 30 min
    private let armRaisedPitchThreshold: Double = 0.45      // ~26 degrees (radians)
    private let armLoweredPitchThreshold: Double = 0.25     // ~14 degrees
    private let minimumWristRoll: Double = 0.3              // Minimum roll change for bite

    // Smoothing
    private var pitchHistory: [Double] = []
    private var rollHistory: [Double] = []
    private let smoothingWindow = 10 // samples

    // Extended runtime for background
    #if os(watchOS)
    private var session: WKExtendedRuntimeSession?
    #endif

    // Retain the activity manager so the permission dialog actually appears
    private var activityManager: CMMotionActivityManager?

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

        // Trigger the motion permission prompt by querying CMMotionActivityManager.
        // CMMotionManager alone does NOT trigger the system permission dialog.
        // Must retain activityManager as a property or the callback never fires.
        activityManager = CMMotionActivityManager()
        let now = Date()
        let oneHourAgo = now.addingTimeInterval(-3600)
        activityManager?.queryActivityStarting(from: oneHourAgo, to: now, to: .main) { [weak self] _, _ in
            // Permission dialog has been shown (or was already granted).
            self?.beginMotionUpdates()
        }
    }

    private func beginMotionUpdates() {
        // Check authorization after the prompt
        let status = CMMotionActivityManager.authorizationStatus()
        guard status == .authorized || status == .notDetermined else {
            print("BolusBuddy: Motion permission denied (status: \(status.rawValue))")
            return
        }

        #if os(watchOS)
        startExtendedSession()
        #endif

        motionManager.deviceMotionUpdateInterval = 1.0 / 25.0 // 25Hz (battery-efficient)
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            guard let self = self, let motion = motion else { return }
            self.processMotion(motion)
        }

        isMonitoring = true
        print("BolusBuddy: Eating detection started")
    }

    func stopMonitoring() {
        motionManager.stopDeviceMotionUpdates()
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
        // Check cooldown — don't alert if we recently alerted
        if let lastAlert = lastAlertTime,
           Date().timeIntervalSince(lastAlert) < alertCooldownMinutes * 60 {
            return
        }

        DispatchQueue.main.async {
            self.isEatingDetected = true
            self.locationTriggered = true
            self.lastAlertTime = Date()
        }

        // Stop motion updates for this meal — location already triggered
        motionManager.stopDeviceMotionUpdates()

        sendBolusReminder(locationName: placeName)

        // Resume motion detection after cooldown
        DispatchQueue.main.asyncAfter(deadline: .now() + alertCooldownMinutes * 60) { [weak self] in
            guard let self = self, self.isMonitoring else { return }
            self.locationTriggered = false
            self.beginMotionUpdates()
        }
    }

    // MARK: - Motion Processing

    private func processMotion(_ motion: CMDeviceMotion) {
        // Skip motion detection if location already triggered for this meal
        if locationTriggered { return }

        let pitch = motion.attitude.pitch
        let roll = motion.attitude.roll

        // Add to smoothing buffers
        pitchHistory.append(pitch)
        rollHistory.append(roll)
        if pitchHistory.count > smoothingWindow { pitchHistory.removeFirst() }
        if rollHistory.count > smoothingWindow { rollHistory.removeFirst() }

        let smoothedPitch = pitchHistory.reduce(0, +) / Double(pitchHistory.count)
        let smoothedRoll = rollHistory.reduce(0, +) / Double(rollHistory.count)

        // Adjusted thresholds based on sensitivity
        let raiseThreshold = armRaisedPitchThreshold / sensitivity
        let lowerThreshold = armLoweredPitchThreshold / sensitivity

        // Detect arm raise-to-mouth cycle
        // Phase 1: Arm goes up (pitch increases past threshold)
        if smoothedPitch > raiseThreshold && !isArmRaised {
            isArmRaised = true
        }
        // Phase 2: Arm comes back down (pitch drops below lower threshold)
        else if smoothedPitch < lowerThreshold && isArmRaised {
            isArmRaised = false

            // Check if there was meaningful wrist rotation during this cycle
            let rollRange = (rollHistory.max() ?? 0) - (rollHistory.min() ?? 0)
            if rollRange > minimumWristRoll / sensitivity {
                recordBiteEvent()
            }
        }
    }

    private func recordBiteEvent() {
        let now = Date()
        biteEvents.append(now)

        // Remove old events outside the window
        biteEvents = biteEvents.filter { now.timeIntervalSince($0) < biteWindowSeconds }

        DispatchQueue.main.async {
            self.biteCount = self.biteEvents.count
        }

        // Check if we've reached the eating threshold
        if biteEvents.count >= minimumBitesForEating && !isEatingDetected {
            // Check cooldown
            if let lastAlert = lastAlertTime,
               Date().timeIntervalSince(lastAlert) < alertCooldownMinutes * 60 {
                return // Still in cooldown
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
        // Haptic alert on watch
        WKInterfaceDevice.current().play(.notification)

        // Schedule a second haptic after 2 seconds for urgency
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            WKInterfaceDevice.current().play(.retry)
        }
        #endif

        // Local notification (appears on watch + mirrors to phone)
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
            trigger: nil // Deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("BolusBuddy: Notification error: \(error)")
            } else {
                print("BolusBuddy: Bolus reminder sent!")
            }
        }

        // Send a follow-up reminder in 5 minutes if they might have forgotten
        let followUpContent = UNMutableNotificationContent()
        followUpContent.title = "Bolus Reminder"
        followUpContent.body = "Just checking - did you bolus for your meal? It's been 5 minutes."
        followUpContent.sound = .default
        followUpContent.interruptionLevel = .timeSensitive

        let followUpTrigger = UNTimeIntervalNotificationTrigger(timeInterval: 300, repeats: false)
        let followUpRequest = UNNotificationRequest(
            identifier: "bolus-followup-\(Date().timeIntervalSince1970)",
            content: followUpContent,
            trigger: followUpTrigger
        )

        UNUserNotificationCenter.current().add(followUpRequest)
    }

    #if os(watchOS)
    // MARK: - Extended Runtime Session (keeps app running in background)

    private func startExtendedSession() {
        session?.invalidate()
        session = WKExtendedRuntimeSession()
        session?.delegate = self
        session?.start()
    }
    #endif
}

#if os(watchOS)
// MARK: - Extended Runtime Session Delegate
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

import Foundation
import CoreLocation
import MapKit

/// Detects when the user has been at a food establishment for 5+ minutes.
/// When triggered, suppresses motion detection and sends a bolus reminder.
class LocationDetector: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationDetector()

    private let locationManager = CLLocationManager()

    @Published var isEnabled = true
    @Published var isAtFoodPlace = false
    @Published var currentPlaceName: String?

    // Track how long we've been at a food place
    private var foodPlaceArrivalTime: Date?
    private var lastFoodPlaceCheck: Date?
    private var currentFoodPlaceLocation: CLLocation?
    private let dwellTimeThreshold: TimeInterval = 5 * 60 // 5 minutes
    private let searchRadius: CLLocationDistance = 50      // 50 meters
    private let checkInterval: TimeInterval = 60           // Check every 60 seconds

    // Food-related POI categories
    private let foodCategories: [MKPointOfInterestCategory] = [
        .restaurant,
        .cafe,
        .bakery,
        .foodMarket,
    ]

    // Callback when food place dwell triggers
    var onFoodPlaceDwellDetected: ((String) -> Void)?

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.distanceFilter = 30 // Only update when moved 30m
    }

    func startMonitoring() {
        guard isEnabled else { return }

        let status = locationManager.authorizationStatus
        if status == .notDetermined {
            locationManager.requestAlwaysAuthorization()
        } else if status == .authorizedWhenInUse || status == .authorizedAlways {
            locationManager.startUpdatingLocation()
            print("BolusBuddy: Location monitoring started")
        }
    }

    func stopMonitoring() {
        locationManager.stopUpdatingLocation()
        resetState()
        print("BolusBuddy: Location monitoring stopped")
    }

    private func resetState() {
        foodPlaceArrivalTime = nil
        currentFoodPlaceLocation = nil
        DispatchQueue.main.async {
            self.isAtFoodPlace = false
            self.currentPlaceName = nil
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse ||
           manager.authorizationStatus == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last, isEnabled else { return }

        // Throttle checks to once per minute
        if let lastCheck = lastFoodPlaceCheck,
           Date().timeIntervalSince(lastCheck) < checkInterval {
            // But still check dwell time if we're already at a food place
            checkDwellTime()
            return
        }
        lastFoodPlaceCheck = Date()

        checkForFoodPlaces(at: location)
    }

    // MARK: - Food Place Detection

    private func checkForFoodPlaces(at location: CLLocation) {
        let request = MKLocalPointsOfInterestRequest(center: location.coordinate, radius: searchRadius)
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: foodCategories)

        let search = MKLocalSearch(request: request)
        search.start { [weak self] response, error in
            guard let self = self else { return }

            if let error = error {
                print("BolusBuddy: Location search error: \(error.localizedDescription)")
                return
            }

            guard let response = response, !response.mapItems.isEmpty else {
                // Not at a food place — reset if we were tracking one
                if self.foodPlaceArrivalTime != nil {
                    print("BolusBuddy: Left food place area")
                    self.resetState()
                }
                return
            }

            // Found a food place nearby
            let closestFood = response.mapItems.first!
            let placeName = closestFood.name ?? "Restaurant"

            if self.foodPlaceArrivalTime == nil {
                // Just arrived at a food place
                self.foodPlaceArrivalTime = Date()
                self.currentFoodPlaceLocation = location
                DispatchQueue.main.async {
                    self.currentPlaceName = placeName
                    self.isAtFoodPlace = true
                }
                print("BolusBuddy: Arrived at food place: \(placeName)")
            }

            self.checkDwellTime()
        }
    }

    private func checkDwellTime() {
        guard let arrivalTime = foodPlaceArrivalTime else { return }

        let dwellTime = Date().timeIntervalSince(arrivalTime)
        if dwellTime >= dwellTimeThreshold {
            let name = currentPlaceName ?? "a restaurant"
            print("BolusBuddy: Dwell time exceeded at \(name) (\(Int(dwellTime/60)) min)")
            onFoodPlaceDwellDetected?(name)
            // Reset so we don't re-trigger
            foodPlaceArrivalTime = nil
        }
    }
}

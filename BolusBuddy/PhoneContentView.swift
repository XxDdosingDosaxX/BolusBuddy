import SwiftUI

struct PhoneContentView: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Header
                    VStack(spacing: 8) {
                        Image(systemName: "fork.knife.circle.fill")
                            .font(.system(size: 70))
                            .foregroundStyle(.orange)
                        Text("BolusBuddy")
                            .font(.largeTitle.bold())
                        Text("Never forget to bolus again")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 20)

                    // How it works
                    VStack(alignment: .leading, spacing: 16) {
                        SectionCard(
                            icon: "applewatch",
                            color: .blue,
                            title: "Wrist Motion Detection",
                            description: "Your Apple Watch detects the repeated hand-to-mouth motion pattern of eating using its accelerometer and gyroscope."
                        )

                        SectionCard(
                            icon: "fork.knife",
                            color: .orange,
                            title: "Eating Recognition",
                            description: "After detecting 5+ bite-like motions in 2 minutes, BolusBuddy recognizes you're eating a meal."
                        )

                        SectionCard(
                            icon: "bell.badge.fill",
                            color: .red,
                            title: "Bolus Reminder",
                            description: "You'll get a haptic buzz and notification on your watch AND phone asking if you've bolused. A follow-up comes in 5 minutes."
                        )

                        SectionCard(
                            icon: "slider.horizontal.3",
                            color: .purple,
                            title: "Adjustable Sensitivity",
                            description: "Too many false alerts? Lower sensitivity. Missing meals? Raise it. Adjust from the watch app."
                        )
                    }
                    .padding(.horizontal)

                    // Setup instructions
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Setup")
                            .font(.headline)
                            .padding(.horizontal)

                        VStack(alignment: .leading, spacing: 8) {
                            SetupStep(number: 1, text: "Open BolusBuddy on your Apple Watch")
                            SetupStep(number: 2, text: "Tap 'Start' to begin monitoring")
                            SetupStep(number: 3, text: "Enable 'Auto-start' so it runs automatically")
                            SetupStep(number: 4, text: "Allow notifications when prompted")
                            SetupStep(number: 5, text: "That's it! Eat normally and get reminded")
                        }
                        .padding(.horizontal)
                    }

                    // Footer
                    Text("BolusBuddy runs continuously on your Apple Watch.\nNotifications appear on both watch and phone.\nNo data leaves your device.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            }
            .navigationTitle("")
        }
    }
}

struct SectionCard: View {
    let icon: String
    let color: Color
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.bold())
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}

struct SetupStep: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.orange)
                .clipShape(Circle())
            Text(text)
                .font(.subheadline)
        }
    }
}

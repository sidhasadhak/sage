import SwiftUI
import Combine
#if canImport(UIKit)
import UIKit
#endif

// MARK: - OnboardingView
//
// Shown on first install via a .fullScreenCover in ContentView.
// Three pages, non-swipe-dismissible:
//
//   Page 0 — Welcome + name
//   Page 1 — Privacy promise + permission grants
//   Page 2 — Indexing kickoff (1 month, background)
//
// Sets UserDefaults key "sage_onboarding_complete" = true on finish
// so it never shows again.

struct OnboardingView: View {
    @EnvironmentObject var container: AppContainer
    @AppStorage("sage_user_name") private var userName: String = ""
    @AppStorage("sage_onboarding_complete") private var onboardingComplete: Bool = false

    @State private var page        = 0
    @State private var nameInput   = ""
    @State private var indexingStarted = false

    var body: some View {
        TabView(selection: $page) {
            WelcomePage(nameInput: $nameInput, onContinue: { page = 1 })
                .tag(0)
            PrivacyPermissionsPage(onContinue: { page = 2 })
                .tag(1)
            IndexingPage(indexingStarted: $indexingStarted, onFinish: finish)
                .tag(2)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .ignoresSafeArea()
        .interactiveDismissDisabled()
        // Page 2 auto-fires indexing
        .onChange(of: page) { _, newPage in
            if newPage == 2 { kickOffIndexing() }
        }
    }

    // MARK: - Actions

    private func kickOffIndexing() {
        guard !indexingStarted else { return }
        indexingStarted = true
        // Lock the indexing window to 1 month for the first run.
        UserDefaults.standard.set(1, forKey: "indexing_period_months")
        Task {
            await container.indexingService.indexAll(isBackgroundRun: false)
        }
    }

    private func finish() {
        let trimmed = nameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { userName = trimmed }
        onboardingComplete = true
    }
}

// MARK: - Page 0: Welcome + Name

private struct WelcomePage: View {
    @Binding var nameInput: String
    let onContinue: () -> Void

    @FocusState private var focused: Bool
    @State private var suggestion = ""

    var body: some View {
        ZStack {
            // Subtle gradient background
            LinearGradient(
                colors: [Color.accentColor.opacity(0.06), Color(.systemBackground)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 36) {
                    // Logo
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(0.12))
                            .frame(width: 100, height: 100)
                        Circle()
                            .fill(Color.accentColor.opacity(0.2))
                            .frame(width: 76, height: 76)
                        Image(systemName: "brain.head.profile")
                            .font(.system(size: 38))
                            .foregroundStyle(Color.accentColor)
                    }

                    VStack(spacing: 10) {
                        Text("Meet Sage")
                            .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        Text("Your private AI assistant.\nNo cloud. No accounts. Just you.")
                            .font(.system(.body, design: .rounded))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    // Name input
                    VStack(spacing: 10) {
                        Text("What should I call you?")
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(.secondary)

                        TextField("Your name", text: $nameInput)
                            .font(.system(.body, design: .rounded))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 14)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .focused($focused)
                            .submitLabel(.continue)
                            .onSubmit(onContinue)
                            .autocorrectionDisabled()

                        if !suggestion.isEmpty && nameInput.isEmpty {
                            Button { nameInput = suggestion } label: {
                                Label("Use \"\(suggestion)\"", systemImage: "person.fill")
                                    .font(.subheadline)
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }

                    Button(action: onContinue) {
                        HStack {
                            Text(nameInput.trimmingCharacters(in: .whitespaces).isEmpty
                                 ? "Skip for now" : "Continue")
                                .font(.system(.body, design: .rounded, weight: .semibold))
                            Image(systemName: "arrow.right")
                                .font(.system(.subheadline, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(nameInput.trimmingCharacters(in: .whitespaces).isEmpty
                                    ? Color(.secondarySystemBackground) : Color.accentColor)
                        .foregroundStyle(nameInput.trimmingCharacters(in: .whitespaces).isEmpty
                                         ? Color.secondary : Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                }
                .padding(.horizontal, 32)

                Spacer()
                Spacer()
            }
        }
        .onAppear {
            suggestion = deviceNameSuggestion()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { focused = true }
        }
    }

    private func deviceNameSuggestion() -> String {
        #if canImport(UIKit)
        let name = UIDevice.current.name
        if let r = name.range(of: "'s ", options: .caseInsensitive) {
            let n = String(name[name.startIndex..<r.lowerBound])
            if !n.isEmpty { return n }
        }
        for suffix in [" iPhone", " iPad"] {
            if name.lowercased().hasSuffix(suffix.lowercased()) {
                let n = String(name.dropLast(suffix.count))
                if !n.isEmpty { return n }
            }
        }
        return ""
        #else
        return ""
        #endif
    }
}

// MARK: - Page 1: Privacy + Permissions

private struct PrivacyPermissionsPage: View {
    @EnvironmentObject var container: AppContainer
    let onContinue: () -> Void

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 32) {
                Spacer().frame(height: 60)

                // Privacy hero
                VStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(Color.green.opacity(0.12))
                            .frame(width: 90, height: 90)
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(Color.green)
                    }

                    VStack(spacing: 8) {
                        Text("Your data never leaves\nthis device. Ever.")
                            .font(.system(.title2, design: .rounded, weight: .bold))
                            .multilineTextAlignment(.center)

                        Text("Sage indexes your personal data entirely on-device using Apple's private frameworks. No internet connection required, no account, no server — your memories stay yours.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 8)
                    }
                }

                // Privacy badges
                HStack(spacing: 12) {
                    PrivacyBadge(icon: "wifi.slash",      label: "Works offline")
                    PrivacyBadge(icon: "icloud.slash",    label: "No cloud sync")
                    PrivacyBadge(icon: "eye.slash.fill",  label: "Private by design")
                }

                Divider()

                // Permissions section
                VStack(alignment: .leading, spacing: 12) {
                    Text("What Sage will index")
                        .font(.system(.headline, design: .rounded))
                        .padding(.horizontal, 4)

                    Text("Grant access below so Sage can build your private memory. You can change this any time in Settings.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)

                    VStack(spacing: 10) {
                        PermissionRow(
                            title: "Photos",
                            icon: "photo.fill",
                            color: .purple,
                            isGranted: container.permissions.isPhotosAuthorized,
                            request: { await container.permissions.requestPhotos() }
                        )
                        PermissionRow(
                            title: "Contacts",
                            icon: "person.2.fill",
                            color: .blue,
                            isGranted: container.permissions.isContactsAuthorized,
                            request: { await container.permissions.requestContacts() }
                        )
                        PermissionRow(
                            title: "Calendar",
                            icon: "calendar",
                            color: .red,
                            isGranted: container.permissions.isCalendarAuthorized,
                            request: { await container.permissions.requestCalendar() }
                        )
                        PermissionRow(
                            title: "Reminders",
                            icon: "checklist",
                            color: .orange,
                            isGranted: container.permissions.isReminderAuthorized,
                            request: { await container.permissions.requestReminders() }
                        )
                    }
                }

                // CTA
                VStack(spacing: 10) {
                    Button(action: grantAllThenContinue) {
                        Text("Grant Access & Continue")
                            .font(.system(.body, design: .rounded, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.accentColor)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    }

                    Button(action: onContinue) {
                        Text("Skip for now")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer().frame(height: 40)
            }
            .padding(.horizontal, 28)
        }
        .background(Color(.systemBackground))
    }

    private func grantAllThenContinue() {
        Task {
            await container.permissions.requestPhotos()
            await container.permissions.requestContacts()
            await container.permissions.requestCalendar()
            await container.permissions.requestReminders()
            onContinue()
        }
    }
}

// MARK: - Privacy badge chip

private struct PrivacyBadge: View {
    let icon: String
    let label: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(Color.green)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color.green.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Page 2: Indexing kickoff

private struct IndexingPage: View {
    @EnvironmentObject var container: AppContainer
    @Binding var indexingStarted: Bool
    let onFinish: () -> Void

    @State private var dotCount = 1
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private var isIndexing: Bool { container.indexingService.isIndexing }
    private var indexed: Int    { container.indexingService.indexedCount }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.accentColor.opacity(0.06), Color(.systemBackground)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 36) {
                    // Animated brain icon
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(0.10))
                            .frame(width: 110, height: 110)
                        Circle()
                            .fill(Color.accentColor.opacity(0.18))
                            .frame(width: 82, height: 82)
                        Image(systemName: isIndexing ? "brain.head.profile" : "checkmark.circle.fill")
                            .font(.system(size: 38))
                            .foregroundStyle(Color.accentColor)
                            .symbolEffect(.pulse, isActive: isIndexing)
                    }

                    VStack(spacing: 12) {
                        Text(isIndexing ? "Building your memory\(dots)" : "All set!")
                            .font(.system(.title2, design: .rounded, weight: .bold))
                            .contentTransition(.identity)
                            .onReceive(timer) { _ in
                                dotCount = dotCount % 3 + 1
                            }

                        Text(isIndexing
                             ? "Sage is privately indexing the last month of your photos, contacts, calendar and reminders — all on this device."
                             : "Your private memory is ready. Sage can now answer questions about your personal data.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 12)
                    }

                    // Progress indicator
                    if isIndexing {
                        VStack(spacing: 10) {
                            ProgressView()
                                .scaleEffect(1.2)
                                .tint(.accentColor)
                            if indexed > 0 {
                                Text("\(indexed) items indexed")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .contentTransition(.numericText())
                            }
                        }
                    }

                    // Privacy reassurance strip
                    HStack(spacing: 6) {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                        Text("Processing entirely on-device · Nothing sent to any server")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.green.opacity(0.08))
                    .clipShape(Capsule())

                    // Continue button — always visible so user isn't blocked
                    Button(action: onFinish) {
                        Text(isIndexing ? "Continue in background" : "Get Started")
                            .font(.system(.body, design: .rounded, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.accentColor)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 32)

                Spacer()
                Spacer()
            }
        }
    }

    private var dots: String { String(repeating: ".", count: dotCount) }
}

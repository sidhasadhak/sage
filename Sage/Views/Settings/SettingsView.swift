import SwiftUI
import SwiftData
import UIKit

struct SettingsView: View {
    @EnvironmentObject var container: AppContainer
    @AppStorage("app_color_scheme") private var colorSchemeRaw: String = AppColorScheme.system.rawValue
    @AppStorage("sage_user_name") private var userName: String = ""
    @AppStorage("indexing_period_months") private var indexingPeriodMonths: Int = 3
    @AppStorage("agent_loop_enabled") private var agentLoopEnabled: Bool = false
    @State private var showIndexConfirm = false
    @State private var showClearConfirm = false
    @State private var isIndexing = false

    // Live count of all MemoryChunks stored on device. Using @Query gives us
    // the real persistent total, unlike indexingService.indexedCount which is
    // a run-counter that resets to 0 every time the app launches.
    @Query private var allChunks: [MemoryChunk]

    private var selectedScheme: Binding<AppColorScheme> {
        Binding(
            get: { AppColorScheme(rawValue: colorSchemeRaw) ?? .system },
            set: { colorSchemeRaw = $0.rawValue }
        )
    }

    var body: some View {
        NavigationStack {
            List {
                // MARK: — Profile
                Section("Profile") {
                    HStack {
                        Label("Your Name", systemImage: "person.fill")
                        Spacer()
                        TextField("Add your name", text: $userName)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(.secondary)
                            .autocorrectionDisabled()
                    }
                }

                // MARK: — Appearance
                Section("Appearance") {
                    Picker("Theme", selection: selectedScheme) {
                        ForEach(AppColorScheme.allCases) { scheme in
                            Label(scheme.rawValue, systemImage: scheme.icon)
                                .tag(scheme)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(.init(top: 8, leading: 0, bottom: 8, trailing: 0))
                }

                // MARK: — AI Models
                Section {
                    aiModelStatusRow
                    modelStorageRow
                    Toggle(isOn: $agentLoopEnabled) {
                        Label("Agent Mode", systemImage: "gearshape.2")
                    }
                } header: {
                    Text("AI Models")
                } footer: {
                    Text("Sage uses two private, on-device models. No data ever leaves your iPhone.\n\nAgent Mode lets Sage call tools (search memory, check your calendar, look up photos) before answering, for more accurate multi-step responses. Slightly slower on simple questions.")
                }

                // MARK: — Permissions
                Section {
                    PermissionRow(
                        title: "Photos",
                        icon: "photo",
                        color: .purple,
                        isGranted: container.permissions.isPhotosAuthorized
                    ) {
                        await container.permissions.requestPhotos()
                    }

                    PermissionRow(
                        title: "Contacts",
                        icon: "person.circle",
                        color: .blue,
                        isGranted: container.permissions.isContactsAuthorized
                    ) {
                        await container.permissions.requestContacts()
                    }

                    PermissionRow(
                        title: "Calendar",
                        icon: "calendar",
                        color: .red,
                        isGranted: container.permissions.isCalendarAuthorized
                    ) {
                        await container.permissions.requestCalendar()
                    }

                    PermissionRow(
                        title: "Reminders",
                        icon: "checklist",
                        color: .orange,
                        isGranted: container.permissions.isReminderAuthorized
                    ) {
                        await container.permissions.requestReminders()
                    }

                    PermissionRow(
                        title: "Microphone & Speech",
                        icon: "mic",
                        color: .green,
                        isGranted: container.permissions.isMicrophoneAuthorized && container.permissions.isSpeechAuthorized
                    ) {
                        await container.permissions.requestVoiceNotePermissions()
                    }
                } header: {
                    Text("Permissions")
                } footer: {
                    Text("All data stays on your device. Sage never sends personal information anywhere.")
                }

                // MARK: — Indexing
                Section {
                    Picker(selection: $indexingPeriodMonths) {
                        Text("1 month").tag(1)
                        Text("3 months").tag(3)
                        Text("6 months").tag(6)
                        Text("1 year").tag(12)
                        Text("2 years").tag(24)
                    } label: {
                        Label("Indexing Period", systemImage: "calendar.badge.clock")
                    }

                    Button {
                        showIndexConfirm = true
                    } label: {
                        Label(
                            isIndexing ? "Indexing…" : "Index All Data",
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                    }
                    .disabled(isIndexing)

                    HStack {
                        Label("Memories indexed", systemImage: "brain")
                        Spacer()
                        Text("\(allChunks.count)")
                            .foregroundStyle(.secondary)
                    }

                    if let date = container.indexingService.lastIndexedAt {
                        HStack {
                            Label("Last indexed", systemImage: "clock")
                            Spacer()
                            Text(date.relativeString)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Memory Index")
                } footer: {
                    Text("Items already indexed are kept. Photos are re-captioned automatically using the SmolVLM model during background indexing.")
                }

                // MARK: — Danger Zone
                Section {
                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Label("Clear All Memories", systemImage: "trash")
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Data")
                } footer: {
                    Text("Clears Sage's memory index. Your original photos, contacts, and calendar data are not affected.")
                }

                // MARK: — Diagnostics
                Section {
                    NavigationLink {
                        DiagnosticsView()
                            .environmentObject(container)
                    } label: {
                        Label("Diagnostics", systemImage: "stethoscope")
                    }
                } footer: {
                    Text("See what's indexed, recent events, and on-disk model integrity. Useful for bug reports.")
                }

                // MARK: — About
                Section("About") {
                    LabeledContent("Version", value: Bundle.main.appVersion)
                    HStack {
                        Label("Privacy", systemImage: "lock.shield")
                        Spacer()
                        Text("100% local")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog(
                "Index all photos, contacts, and calendar events?",
                isPresented: $showIndexConfirm,
                titleVisibility: .visible
            ) {
                Button("Start Indexing") {
                    isIndexing = true
                    Task {
                        let modelID = container.modelManager.chatModel?.catalogID
                        await container.indexingService.indexAll(currentModelID: modelID)
                        isIndexing = false
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This may take a few minutes. Sage will be fully usable during indexing.")
            }
            .alert(
                "Clear all memories?",
                isPresented: $showClearConfirm
            ) {
                Button("Cancel", role: .cancel) {}
                Button("Clear Memory", role: .destructive) {
                    Task {
                        await container.indexingService.clearAllMemories()
                    }
                }
            } message: {
                Text("This removes every indexed photo, note, event, and reminder from Sage's memory. Your originals are not affected. You can re-index anytime.")
            }
        }
    }

    // MARK: - AI Model rows

    private var aiModelStatusRow: some View {
        HStack {
            Label("Chat Model", systemImage: "bubble.left.and.bubble.right.fill")
            Spacer()
            Group {
                switch container.llmService.state {
                case .ready:
                    Label("Active", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .loading(let name):
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.7)
                        Text("Loading \(name)…")
                    }
                    .foregroundStyle(.secondary)
                case .generating:
                    Label("Generating", systemImage: "ellipsis.circle.fill")
                        .foregroundStyle(Color.accentColor)
                case .error:
                    Label("Error", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                case .noModelSelected:
                    Label("Not loaded", systemImage: "circle")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
        }
    }

    private var modelStorageRow: some View {
        HStack {
            Label("On-device storage", systemImage: "internaldrive")
            Spacer()
            Text(container.modelManager.totalStorageGB > 0
                 ? String(format: "%.1f GB", container.modelManager.totalStorageGB)
                 : "—")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Shared permission row

struct PermissionRow: View {
    let title: String
    let icon: String
    let color: Color
    let isGranted: Bool
    let request: () async -> Void

    var body: some View {
        HStack {
            Label(title, systemImage: icon)
                .foregroundStyle(color)
            Spacer()
            if isGranted {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Button("Manage") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } else {
                Button("Allow") {
                    Task { await request() }
                }
                .font(.subheadline)
                .buttonStyle(.bordered)
                .tint(color)
            }
        }
    }
}

// MARK: - Bundle extension

extension Bundle {
    var appVersion: String {
        "\(infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0") (\(infoDictionary?["CFBundleVersion"] as? String ?? "1"))"
    }
}

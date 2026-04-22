import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject var container: AppContainer
    @AppStorage("app_color_scheme") private var colorSchemeRaw: String = AppColorScheme.system.rawValue
    @State private var showIndexConfirm = false
    @State private var showClearConfirm = false
    @State private var isIndexing = false

    private var selectedScheme: Binding<AppColorScheme> {
        Binding(
            get: { AppColorScheme(rawValue: colorSchemeRaw) ?? .system },
            set: { colorSchemeRaw = $0.rawValue }
        )
    }

    var body: some View {
        NavigationStack {
            List {
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

                // MARK: — AI Model
                Section {
                    modelStatusRow
                } header: {
                    Text("AI Model")
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
                        Text("\(container.indexingService.indexedCount)")
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
                        await container.indexingService.indexAll()
                        isIndexing = false
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This may take a few minutes. Sage will be fully usable during indexing.")
            }
            .confirmationDialog(
                "Clear all memories?",
                isPresented: $showClearConfirm,
                titleVisibility: .visible
            ) {
                Button("Clear Memory", role: .destructive) {
                    Task {
                        await container.searchEngine.invalidateCache()
                        await container.spotlightService.removeAll()
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private var modelStatusRow: some View {
        HStack {
            Label("Apple Intelligence", systemImage: "apple.intelligence")
            Spacer()
            if container.llmService.isReady {
                Label("Active", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.subheadline)
            } else {
                Text("Unavailable")
                    .foregroundStyle(.red)
                    .font(.subheadline)
            }
        }
    }
}

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

extension Bundle {
    var appVersion: String {
        "\(infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0") (\(infoDictionary?["CFBundleVersion"] as? String ?? "1"))"
    }
}

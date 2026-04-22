import Foundation
import Photos
import Contacts
import EventKit
import Speech
import AVFoundation

@Observable
final class PermissionCoordinator {

    var photosStatus: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    var contactsStatus: CNAuthorizationStatus = CNContactStore.authorizationStatus(for: .contacts)
    var calendarStatus: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    var reminderStatus: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .reminder)
    var microphoneStatus: AVAudioSession.RecordPermission = AVAudioSession.sharedInstance().recordPermission
    var speechStatus: SFSpeechRecognizerAuthorizationStatus = SFSpeechRecognizer.authorizationStatus()

    func refreshAll() {
        photosStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        contactsStatus = CNContactStore.authorizationStatus(for: .contacts)
        calendarStatus = EKEventStore.authorizationStatus(for: .event)
        reminderStatus = EKEventStore.authorizationStatus(for: .reminder)
        microphoneStatus = AVAudioSession.sharedInstance().recordPermission
        speechStatus = SFSpeechRecognizer.authorizationStatus()
    }

    var isPhotosAuthorized: Bool { photosStatus == .authorized || photosStatus == .limited }
    var isContactsAuthorized: Bool { contactsStatus == .authorized }
    var isCalendarAuthorized: Bool { calendarStatus == .fullAccess }
    var isReminderAuthorized: Bool { reminderStatus == .fullAccess }
    var isMicrophoneAuthorized: Bool { microphoneStatus == .granted }
    var isSpeechAuthorized: Bool { speechStatus == .authorized }

    func requestPhotos() async {
        photosStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    func requestContacts() async {
        do {
            let status = try await ContactsService.requestAuthorization()
            contactsStatus = status
        } catch {
            contactsStatus = .denied
        }
    }

    func requestCalendar() async {
        do {
            let granted = try await CalendarService.store.requestFullAccessToEvents()
            calendarStatus = granted ? .fullAccess : .denied
        } catch {
            calendarStatus = .denied
        }
    }

    func requestReminders() async {
        do {
            let granted = try await CalendarService.store.requestFullAccessToReminders()
            reminderStatus = granted ? .fullAccess : .denied
        } catch {
            reminderStatus = .denied
        }
    }

    func requestMicrophone() async {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { _ in
                continuation.resume()
            }
        }
        microphoneStatus = AVAudioSession.sharedInstance().recordPermission
    }

    func requestSpeech() async {
        speechStatus = await TranscriptionService.shared.requestAuthorization()
    }

    func requestVoiceNotePermissions() async {
        await requestMicrophone()
        await requestSpeech()
    }
}

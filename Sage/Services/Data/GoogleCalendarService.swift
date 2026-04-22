import Foundation
import AuthenticationServices
import UIKit

// MARK: - Google Calendar OAuth + REST integration
// Setup: Create a project at console.cloud.google.com, enable Calendar API,
// create OAuth 2.0 credentials (iOS app), and replace the placeholders below.

@Observable
@MainActor
final class GoogleCalendarService: NSObject {

    // MARK: - Configuration
    // Replace with your Google Cloud OAuth client ID for iOS
    private let clientID = "YOUR_GOOGLE_CLIENT_ID.apps.googleusercontent.com"
    private let redirectScheme = "com.amitkamlapure.sage"
    private let scopes = "https://www.googleapis.com/auth/calendar.readonly https://www.googleapis.com/auth/calendar.events.readonly"

    private(set) var isSignedIn = false
    private(set) var accountEmail: String?
    private(set) var isSyncing = false
    private(set) var lastSyncedAt: Date?
    private(set) var error: String?

    private var accessToken: String? {
        get { UserDefaults.standard.string(forKey: "gcal_access_token") }
        set { UserDefaults.standard.set(newValue, forKey: "gcal_access_token") }
    }
    private var refreshToken: String? {
        get { UserDefaults.standard.string(forKey: "gcal_refresh_token") }
        set { UserDefaults.standard.set(newValue, forKey: "gcal_refresh_token") }
    }
    private var tokenExpiry: Date? {
        get { UserDefaults.standard.object(forKey: "gcal_token_expiry") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "gcal_token_expiry") }
    }

    override init() {
        super.init()
        isSignedIn = accessToken != nil
        accountEmail = UserDefaults.standard.string(forKey: "gcal_account_email")
    }

    // MARK: - Sign In

    func signIn() async throws {
        guard !clientID.hasPrefix("YOUR_") else {
            error = "Google Calendar not configured. Add your OAuth client ID."
            return
        }
        let state = UUID().uuidString
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: "\(redirectScheme):/oauth2callback"),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scopes),
            .init(name: "state", value: state),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]
        let authURL = components.url!
        let callbackScheme = redirectScheme

        let code = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: callbackScheme) { url, err in
                if let err { continuation.resume(throwing: err); return }
                guard let url,
                      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                      let code = components.queryItems?.first(where: { $0.name == "code" })?.value
                else {
                    continuation.resume(throwing: URLError(.badServerResponse)); return
                }
                continuation.resume(returning: code)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }

        try await exchangeCodeForTokens(code)
        try await fetchAccountEmail()
        isSignedIn = true
    }

    func signOut() {
        accessToken = nil; refreshToken = nil; tokenExpiry = nil
        UserDefaults.standard.removeObject(forKey: "gcal_account_email")
        accountEmail = nil; isSignedIn = false
    }

    // MARK: - Token Management

    private func exchangeCodeForTokens(_ code: String) async throws {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "code": code, "client_id": clientID,
            "redirect_uri": "\(redirectScheme):/oauth2callback",
            "grant_type": "authorization_code"
        ].map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
         .joined(separator: "&")
        request.httpBody = body.data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONDecoder().decode(TokenResponse.self, from: data)
        accessToken = json.access_token
        if let rt = json.refresh_token { refreshToken = rt }
        tokenExpiry = Date().addingTimeInterval(Double(json.expires_in - 60))
    }

    private func refreshAccessToken() async throws {
        guard let rt = refreshToken else { throw URLError(.userAuthenticationRequired) }
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "refresh_token": rt, "client_id": clientID, "grant_type": "refresh_token"
        ].map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        request.httpBody = body.data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONDecoder().decode(TokenResponse.self, from: data)
        accessToken = json.access_token
        tokenExpiry = Date().addingTimeInterval(Double(json.expires_in - 60))
    }

    private func validToken() async throws -> String {
        if let expiry = tokenExpiry, expiry > Date(), let token = accessToken { return token }
        try await refreshAccessToken()
        return accessToken ?? ""
    }

    private func fetchAccountEmail() async throws {
        let token = try await validToken()
        var req = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let email = json["email"] as? String {
            accountEmail = email
            UserDefaults.standard.set(email, forKey: "gcal_account_email")
        }
    }

    // MARK: - Calendar Events

    func fetchEvents(from startDate: Date, to endDate: Date) async throws -> [GCalEvent] {
        let token = try await validToken()
        let formatter = ISO8601DateFormatter()
        var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
        components.queryItems = [
            .init(name: "timeMin", value: formatter.string(from: startDate)),
            .init(name: "timeMax", value: formatter.string(from: endDate)),
            .init(name: "singleEvents", value: "true"),
            .init(name: "orderBy", value: "startTime"),
            .init(name: "maxResults", value: "250"),
        ]
        var req = URLRequest(url: components.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        let response = try JSONDecoder().decode(GCalEventList.self, from: data)
        return response.items ?? []
    }

    // MARK: - Sync (called from IndexingService)

    func syncedEvents(from startDate: Date, to endDate: Date) async -> [GCalEvent] {
        guard isSignedIn else { return [] }
        isSyncing = true
        defer { isSyncing = false; lastSyncedAt = Date() }
        do {
            return try await fetchEvents(from: startDate, to: endDate)
        } catch {
            self.error = error.localizedDescription
            return []
        }
    }

    // MARK: - Models

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int
    }
}

struct GCalEvent: Decodable, Identifiable {
    let id: String
    let summary: String?
    let description: String?
    let location: String?
    struct EventDateTime: Decodable {
        let dateTime: String?
        let date: String?
        var resolved: Date? {
            let f = ISO8601DateFormatter()
            if let dt = dateTime { return f.date(from: dt) }
            if let d = date {
                let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
                return df.date(from: d)
            }
            return nil
        }
    }
    let start: EventDateTime?
    let end: EventDateTime?
    let htmlLink: String?
}

private struct GCalEventList: Decodable {
    let items: [GCalEvent]?
}

extension GoogleCalendarService: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        DispatchQueue.main.sync {
            let windowScene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first(where: { $0.activationState == .foregroundActive })
                ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            return windowScene?.windows.first(where: { $0.isKeyWindow })
                ?? windowScene.map { UIWindow(windowScene: $0) }
                ?? UIWindow()
        }
    }
}

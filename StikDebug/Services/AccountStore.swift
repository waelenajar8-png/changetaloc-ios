//
//  AccountStore.swift
//  ChangeTaLoc
//
//  Connexion au compte ChangeTaLoc et vérification du droit d'utiliser l'app.
//  L'app ne parle qu'à changetaloc.com : connexion, renouvellement de session,
//  et « ce compte a-t-il un abonnement ou un essai en cours ? ».
//

import Foundation
import Security
import Combine

final class AccountStore: ObservableObject {
    static let shared = AccountStore()

    enum BlockReason: Equatable {
        case noSubscription
        case trialEnded
        case paymentPending
        case subscriptionEnded
        case offline
    }

    enum State: Equatable {
        case loading
        case signedOut
        case allowed
        case blocked(BlockReason)
    }

    @Published private(set) var state: State = .loading
    @Published private(set) var email: String?
    @Published private(set) var status: String?
    @Published private(set) var trialSecondsLeft: Int?
    /// L'essai est un compte à rebours qui démarre à la première téléportation, puis continue même position réelle.
    @Published private(set) var trialStarted = false
    @Published private(set) var buyURL: URL = AccountStore.defaultBuyURL
    @Published private(set) var isWorking = false

    static let siteURL = URL(string: "https://changetaloc.com")!
    static let defaultBuyURL = URL(string: "https://changetaloc.com/tarifs")!
    static let signUpURL = URL(string: "https://changetaloc.com/connexion")!

    private struct Session: Codable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Double
        var email: String?
    }

    private struct Decision: Codable {
        var access: Bool
        var status: String?
        var trialSecondsLeft: Int?
        var date: Date
    }

    private enum RequestError: Error {
        case unauthorized
        case server(String?)
        case network
    }

    private let sessionKey = "com.changetaloc.session"
    private let decisionKey = "com.changetaloc.lastDecision"
    private let tickInterval: TimeInterval = 60
    private let maxSecondsPerCall = 90
    // Un abonné reste débloqué deux jours sans réseau ; l'essai, lui, se décompte sur l'iPhone en attendant.
    private let offlineGrace: TimeInterval = 48 * 3600

    private var session: Session?
    private var pendingSeconds = 0
    private var timer: Timer?
    private var checkInFlight = false

    private init() {
        // L'ancien mode invité des tests internes n'existe plus : on efface sa trace.
        UserDefaults.standard.removeObject(forKey: "com.changetaloc.guest")
        session = loadSession()
        email = session?.email
        if session == nil {
            state = .signedOut
        } else if let decision = loadDecision(), decision.access, Date().timeIntervalSince(decision.date) < offlineGrace {
            // On rouvre l'app sans attendre le réseau ; la vérification suit juste après.
            status = decision.status
            trialSecondsLeft = decision.trialSecondsLeft
            state = (decision.trialSecondsLeft ?? 1) > 0 ? .allowed : .blocked(.trialEnded)
        }
    }

    // MARK: - Cycle de vie

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refreshAccess()
    }

    func refreshAccess() {
        guard session != nil else { return }
        Task { await check() }
    }

    private func tick() {
        guard session != nil else { return }
        let simulating = LocationSimulationSession.shared.isActive
        if simulating {
            pendingSeconds += Int(tickInterval)
        }
        if simulating || trialStarted {
            if status == "trialing", let left = trialSecondsLeft {
                trialSecondsLeft = max(left - Int(tickInterval), 0)
                // On mémorise le décompte : couper le réseau ou relancer l'app ne remet pas l'essai à zéro.
                if var decision = loadDecision() {
                    decision.trialSecondsLeft = trialSecondsLeft
                    saveDecision(decision)
                }
                if trialSecondsLeft == 0 { block(.trialEnded) }
            }
        }
        Task { await check() }
    }

    // MARK: - Connexion

    @discardableResult
    func signIn(email: String, password: String) async -> String? {
        await MainActor.run { isWorking = true }
        defer { Task { @MainActor in self.isWorking = false } }
        do {
            let json = try await post(path: "/api/app/login", body: ["email": email, "password": password], token: nil)
            guard let newSession = Self.session(from: json) else { return "Réponse inattendue du serveur." }
            await MainActor.run {
                self.session = newSession
                self.saveSession(newSession)
                self.email = newSession.email
                self.state = .loading
            }
            await check()
            return nil
        } catch RequestError.unauthorized {
            return "E-mail ou mot de passe incorrect."
        } catch RequestError.server(let message) {
            return message ?? "Service indisponible. Réessaie dans un instant."
        } catch {
            return "Pas de connexion à Internet."
        }
    }

    /// Connexion sans mot de passe : envoie un code à l'e-mail du compte. Renvoie un message d'erreur, ou nil si c'est parti.
    func requestCode(email: String) async -> String? {
        await MainActor.run { isWorking = true }
        defer { Task { @MainActor in self.isWorking = false } }
        do {
            _ = try await post(path: "/api/app/code", body: ["email": email], token: nil)
            return nil
        } catch RequestError.server(let message) {
            return message ?? "Service indisponible. Réessaie dans un instant."
        } catch {
            return "Pas de connexion à Internet."
        }
    }

    /// Valide le code reçu par e-mail et ouvre la session.
    func signIn(email: String, code: String) async -> String? {
        await MainActor.run { isWorking = true }
        defer { Task { @MainActor in self.isWorking = false } }
        do {
            let json = try await post(path: "/api/app/code", body: ["email": email, "code": code], token: nil)
            guard let newSession = Self.session(from: json) else { return "Réponse inattendue du serveur." }
            await MainActor.run {
                self.session = newSession
                self.saveSession(newSession)
                self.email = newSession.email
                self.state = .loading
            }
            await check()
            return nil
        } catch RequestError.unauthorized {
            return "Code incorrect ou expiré."
        } catch RequestError.server(let message) {
            return message ?? "Service indisponible. Réessaie dans un instant."
        } catch {
            return "Pas de connexion à Internet."
        }
    }

    func signOut() {
        stopSimulation()
        session = nil
        deleteSession()
        UserDefaults.standard.removeObject(forKey: decisionKey)
        pendingSeconds = 0
        DispatchQueue.main.async {
            self.email = nil
            self.status = nil
            self.trialSecondsLeft = nil
            self.state = .signedOut
        }
    }

    // MARK: - Vérification de l'accès

    private func check() async {
        let alreadyRunning: Bool = await MainActor.run {
            if checkInFlight { return true }
            checkInFlight = true
            return false
        }
        if alreadyRunning { return }
        defer { Task { @MainActor in self.checkInFlight = false } }

        guard let token = await validAccessToken() else { return }
        let sending = min(pendingSeconds, maxSecondsPerCall)
        do {
            let json = try await post(path: "/api/app/access", body: ["seconds": sending], token: token)
            await MainActor.run {
                self.pendingSeconds = max(self.pendingSeconds - sending, 0)
                self.apply(json)
            }
        } catch RequestError.unauthorized {
            // Jeton refusé : on tente un renouvellement, sinon retour à l'écran de connexion.
            if await refreshSession() == .refused {
                signOut()
            } else {
                await MainActor.run { self.handleUnreachable() }
            }
        } catch {
            await MainActor.run { self.handleUnreachable() }
        }
    }

    private func apply(_ json: [String: Any]) {
        let access = json["access"] as? Bool ?? false
        let newStatus = json["status"] as? String
        let left = json["trial_seconds_left"] as? Int
        trialStarted = json["trial_started"] as? Bool ?? false
        status = newStatus
        trialSecondsLeft = left
        if let text = json["buy_url"] as? String, let url = URL(string: text), url.host == Self.siteURL.host {
            buyURL = url
        } else {
            buyURL = Self.defaultBuyURL
        }
        saveDecision(Decision(access: access, status: newStatus, trialSecondsLeft: left, date: Date()))

        if access {
            state = .allowed
            return
        }
        switch json["reason"] as? String {
        case "essai_termine": block(.trialEnded)
        case "paiement_en_attente": block(.paymentPending)
        case "abonnement_termine": block(.subscriptionEnded)
        default: block(.noSubscription)
        }
    }

    private func handleUnreachable() {
        if case .blocked(let reason) = state, reason != .offline { return }
        if let decision = loadDecision(), decision.access, Date().timeIntervalSince(decision.date) < offlineGrace {
            if status == "trialing", (trialSecondsLeft ?? 0) <= 0 {
                block(.trialEnded)
            } else {
                state = .allowed
            }
        } else {
            block(.offline)
        }
    }

    private func block(_ reason: BlockReason) {
        if LocationSimulationSession.shared.isActive { stopSimulation() }
        state = .blocked(reason)
    }

    private func stopSimulation() {
        LocationSimulationCommandQueue.shared.async {
            _ = clear_simulated_location()
            DispatchQueue.main.async {
                LocationSimulationSession.shared.stop()
            }
        }
    }

    // MARK: - Session

    private enum RefreshResult { case ok, refused, unreachable }

    private func validAccessToken() async -> String? {
        guard let current = session else { return nil }
        if current.expiresAt - 120 > Date().timeIntervalSince1970 { return current.accessToken }
        switch await refreshSession() {
        case .ok:
            return session?.accessToken
        case .refused:
            signOut()
            return nil
        case .unreachable:
            await MainActor.run { self.handleUnreachable() }
            return nil
        }
    }

    private func refreshSession() async -> RefreshResult {
        guard let current = session else { return .refused }
        do {
            let json = try await post(path: "/api/app/refresh", body: ["refresh_token": current.refreshToken], token: nil)
            guard let newSession = Self.session(from: json) else { return .unreachable }
            await MainActor.run {
                self.session = newSession
                self.saveSession(newSession)
                self.email = newSession.email ?? self.email
            }
            return .ok
        } catch RequestError.unauthorized {
            return .refused
        } catch {
            return .unreachable
        }
    }

    private static func session(from json: [String: Any]) -> Session? {
        guard let access = json["access_token"] as? String,
              let refresh = json["refresh_token"] as? String else { return nil }
        let expires = (json["expires_at"] as? Double) ?? Date().timeIntervalSince1970 + 3600
        return Session(accessToken: access, refreshToken: refresh, expiresAt: expires, email: json["email"] as? String)
    }

    // MARK: - Réseau

    private func post(path: String, body: [String: Any], token: String?) async throws -> [String: Any] {
        guard let url = URL(string: path, relativeTo: Self.siteURL) else { throw RequestError.network }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw RequestError.network
        }
        guard let http = response as? HTTPURLResponse else { throw RequestError.network }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        switch http.statusCode {
        case 200..<300: return json
        case 401: throw RequestError.unauthorized
        default: throw RequestError.server(json["error"] as? String)
        }
    }

    // MARK: - Stockage (trousseau de l'iPhone, avec repli sur les préférences)

    private func keychainQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: sessionKey,
         kSecAttrAccount as String: "session"]
    }

    private func saveSession(_ session: Session) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        SecItemDelete(keychainQuery() as CFDictionary)
        var query = keychainQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        if SecItemAdd(query as CFDictionary, nil) == errSecSuccess {
            UserDefaults.standard.removeObject(forKey: sessionKey)
        } else {
            UserDefaults.standard.set(data, forKey: sessionKey)
        }
    }

    private func loadSession() -> Session? {
        var query = keychainQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        var data: Data?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess {
            data = item as? Data
        }
        if data == nil { data = UserDefaults.standard.data(forKey: sessionKey) }
        guard let data else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    private func deleteSession() {
        SecItemDelete(keychainQuery() as CFDictionary)
        UserDefaults.standard.removeObject(forKey: sessionKey)
    }

    private func saveDecision(_ decision: Decision) {
        if let data = try? JSONEncoder().encode(decision) {
            UserDefaults.standard.set(data, forKey: decisionKey)
        }
    }

    private func loadDecision() -> Decision? {
        guard let data = UserDefaults.standard.data(forKey: decisionKey) else { return nil }
        return try? JSONDecoder().decode(Decision.self, from: data)
    }
}

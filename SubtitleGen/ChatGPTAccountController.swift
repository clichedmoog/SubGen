import Foundation
import SwiftUI

@MainActor
final class ChatGPTAccountController: ObservableObject {
    @Published private(set) var accounts: [ChatGPTAccount] = []
    @Published private(set) var models: [ChatGPTModel] = []
    @Published private(set) var activeID: String?
    @Published var selectedModel = "" {
        didSet { if let activeID { defaults.set(selectedModel, forKey: "chatgpt.model." + activeID) } }
    }
    @Published private(set) var busy = false
    @Published var error: String?
    @Published var showWelcome = false
    @Published private(set) var isSigningIn = false
    private var work: Task<Void, Never>?
    private var generation = UUID()
    private let service = ChatGPTAccountService.shared
    private let defaults = UserDefaults.standard
    static let usageURL = URL(string: "https://chatgpt.com/settings/usage")!
    var active: ChatGPTAccount? { accounts.first { $0.id == activeID } }
    var resolvedModel: String? { selectedModel.isEmpty ? models.first?.slug : models.first(where: { $0.slug == selectedModel })?.slug }
    var canTranslate: Bool { !busy && active?.signedIn == true && active?.planEnabled == true && resolvedModel != nil }
    private var hostID: String {
        if let value = defaults.string(forKey: "chatgpt.hostID"), value.hasPrefix("urn:uuid:"), UUID(uuidString: String(value.dropFirst(9))) != nil { return value }
        let value = "urn:uuid:" + UUID().uuidString.lowercased(); defaults.set(value, forKey: "chatgpt.hostID"); return value
    }
    func reload() {
        begin {
            let accounts = try await self.service.accounts(); try Task.checkCancellation(); self.accounts = accounts
            let stored = self.defaults.string(forKey: "chatgpt.activeID")
            self.activeID = self.accounts.first(where: { $0.id == stored })?.id ?? self.accounts.first?.id
            try await self.loadModels()
        }
    }
    func select(_ id: String) {
        cancel()
        activeID = id; defaults.set(id, forKey: "chatgpt.activeID"); models = []
        begin { try await self.loadModels() }
    }
    func refreshModels() {
        begin {
            if let id = self.activeID { await self.service.resumeUsage(accountID: id) }
            try await self.loadModels(force: true)
        }
    }
    func signIn(newAccount: Bool = false, consent: Bool = false) {
        let accountID = newAccount ? nil : activeID, installationID = hostID
        isSigningIn = true
        begin {
            let id = try await self.service.signIn(accountID: accountID, hostID: installationID, consent: consent)
            try Task.checkCancellation()
            let accounts = try await self.service.accounts(); try Task.checkCancellation(); self.accounts = accounts; self.activeID = id
            self.defaults.set(id, forKey: "chatgpt.activeID")
            // Confirm plan use even if the model catalog is temporarily unavailable.
            if self.active?.planEnabled == true, !self.defaults.bool(forKey: "chatgpt.welcome." + id) { self.showWelcome = true }
            try await self.loadModels(force: true)
        }
    }
    func dismissWelcome() {
        if let activeID { defaults.set(true, forKey: "chatgpt.welcome." + activeID) }; showWelcome = false
    }
    func signOut() {
        guard let id = activeID else { return }
        begin {
            let revoked = try await self.service.signOut(accountID: id)
            try Task.checkCancellation()
            let accounts = try await self.service.accounts(); try Task.checkCancellation(); self.accounts = accounts; self.models = []
            if !revoked { self.error = String(localized: "이 Mac의 연결 정보는 삭제했습니다. 서버 연결 취소는 확인하지 못했습니다. ChatGPT 설정에서 연결을 확인해주세요.") }
        }
    }
    func cancel() {
        generation = UUID(); work?.cancel(); work = nil; busy = false; isSigningIn = false
    }
    private func loadModels(force: Bool = false) async throws {
        models = []
        let accounts = try await service.accounts(); try Task.checkCancellation(); self.accounts = accounts
        guard let id = activeID, active?.signedIn == true, active?.planEnabled == true else { return }
        let values = try await service.models(accountID: id, force: force)
        try Task.checkCancellation(); guard id == activeID else { return }
        models = values
        let stored = defaults.string(forKey: "chatgpt.model." + id) ?? ""
        selectedModel = values.contains(where: { $0.slug == stored }) ? stored : ""
    }
    private func begin(_ operation: @escaping @MainActor () async throws -> Void) {
        work?.cancel(); let id = UUID(); generation = id; busy = true; error = nil
        work = Task {
            do { try await operation() }
            catch is CancellationError {}
            catch ChatGPTFailure.cancelled {}
            catch {
                if self.generation == id {
                    self.error = error.localizedDescription
                    if let accounts = try? await self.service.accounts(), self.generation == id { self.accounts = accounts }
                }
            }
            if self.generation == id { self.busy = false; self.isSigningIn = false; self.work = nil }
        }
    }
}

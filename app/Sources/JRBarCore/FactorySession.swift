import Foundation

public struct FactorySessionProfile: Codable, Hashable, Identifiable, Sendable {
    public var browser: String
    public var profile: String
    public var label: String
    public var id: Self { self }

    public init(browser: String, profile: String, label: String) {
        self.browser = browser
        self.profile = profile
        self.label = label
    }
}

extension CoreModel {
    public func devinSessionProfiles() async throws -> [FactorySessionProfile] {
        let reply = try await send("devin_session_profiles", timeout: 8)
        guard reply.ok else { throw reply.error ?? CoreReplyError(code: "unavailable") }
        return try ReplyDecoding.decode([FactorySessionProfile].self, from: reply.result?["profiles"])
    }

    public func importDevinSession(_ profile: FactorySessionProfile, instance: String) async throws -> String {
        let reply = try await send("devin_session_import", args: [
            "browser": .string(profile.browser), "profile": .string(profile.profile),
            "instance": .string(instance), "confirm": .bool(true),
            "background_repair": .bool(true),
        ], timeout: 30)
        guard reply.ok else { throw reply.error ?? CoreReplyError(code: "browser_import_failed") }
        guard reply.result?["provider"]?.stringValue == "devin",
              reply.result?["instance"]?.stringValue == instance,
              let message = reply.result?["message"]?.stringValue, !message.isEmpty else {
            throw CoreReplyError(code: "bad_reply", message: "The monitor did not confirm this Devin account")
        }
        return message
    }

    public func factorySessionProfiles() async throws -> [FactorySessionProfile] {
        let reply = try await send("factory_session_profiles", timeout: 8)
        guard reply.ok else {
            throw reply.error ?? CoreReplyError(code: "error", message: "Could not list browser profiles")
        }
        return try ReplyDecoding.decode([FactorySessionProfile].self, from: reply.result?["profiles"])
    }

    public func importFactorySession(_ profile: FactorySessionProfile, instance: String) async throws -> String {
        let reply = try await send("factory_session_import", args: [
            "browser": .string(profile.browser), "profile": .string(profile.profile),
            "instance": .string(instance), "confirm": .bool(true),
            "background_repair": .bool(false), "allow_refresh": .bool(true),
        ], timeout: 30)
        return try factorySessionMessage(reply, instance: instance)
    }

    public func disconnectFactorySession(instance: String) async throws -> String {
        let reply = try await send("factory_session_disconnect", args: ["instance": .string(instance)], timeout: 15)
        return try factorySessionMessage(reply, instance: instance)
    }

    private func factorySessionMessage(_ reply: CoreReply, instance: String) throws -> String {
        guard reply.ok else {
            throw reply.error ?? CoreReplyError(code: "error", message: "Factory connection failed")
        }
        guard reply.result?["provider"]?.stringValue == "factory",
              reply.result?["instance"]?.stringValue == instance,
              let message = reply.result?["message"]?.stringValue, !message.isEmpty else {
            throw CoreReplyError(code: "bad_reply", message: "The monitor did not confirm this Factory account")
        }
        return message
    }
}

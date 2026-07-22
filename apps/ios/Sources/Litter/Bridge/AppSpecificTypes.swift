import Foundation

struct AnyEncodable: Encodable {
    private let encodeImpl: (Encoder) throws -> Void

    init<T: Encodable>(_ value: T) {
        encodeImpl = value.encode
    }

    func encode(to encoder: Encoder) throws {
        try encodeImpl(encoder)
    }
}

enum TurnSandboxPolicy: Encodable {
    case dangerFullAccess
    case readOnly
    case workspaceWrite

    init?(mode: String?) {
        switch mode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "danger-full-access":
            self = .dangerFullAccess
        case "read-only":
            self = .readOnly
        case "workspace-write":
            self = .workspaceWrite
        default:
            return nil
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .dangerFullAccess:
            var container = encoder.container(keyedBy: DangerFullAccessCodingKeys.self)
            try container.encode("dangerFullAccess", forKey: .type)
        case .readOnly:
            var container = encoder.container(keyedBy: ReadOnlyCodingKeys.self)
            try container.encode("readOnly", forKey: .type)
            try container.encode(TurnReadOnlyAccess.fullAccess, forKey: .access)
            try container.encode(false, forKey: .networkAccess)
        case .workspaceWrite:
            var container = encoder.container(keyedBy: WorkspaceWriteCodingKeys.self)
            try container.encode("workspaceWrite", forKey: .type)
            try container.encode([String](), forKey: .writableRoots)
            try container.encode(TurnReadOnlyAccess.fullAccess, forKey: .readOnlyAccess)
            try container.encode(false, forKey: .networkAccess)
            try container.encode(false, forKey: .excludeTmpdirEnvVar)
            try container.encode(false, forKey: .excludeSlashTmp)
        }
    }

    var ffiValue: AppSandboxPolicy {
        switch self {
        case .dangerFullAccess:
            return .dangerFullAccess
        case .readOnly:
            return .readOnly(access: .fullAccess, networkAccess: false)
        case .workspaceWrite:
            return .workspaceWrite(
                writableRoots: [],
                readOnlyAccess: .fullAccess,
                networkAccess: false,
                excludeTmpdirEnvVar: false,
                excludeSlashTmp: false
            )
        }
    }

    private enum DangerFullAccessCodingKeys: String, CodingKey {
        case type
    }

    private enum ReadOnlyCodingKeys: String, CodingKey {
        case type
        case access
        case networkAccess
    }

    private enum WorkspaceWriteCodingKeys: String, CodingKey {
        case type
        case writableRoots
        case readOnlyAccess
        case networkAccess
        case excludeTmpdirEnvVar
        case excludeSlashTmp
    }
}

private enum TurnReadOnlyAccess: Encodable {
    case fullAccess

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("fullAccess", forKey: .type)
    }

    private enum CodingKeys: String, CodingKey {
        case type
    }
}

extension AppRealtimeAudioChunk: Encodable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AudioChunkEncodingKeys.self)
        try container.encode(data, forKey: .data)
        try container.encode(sampleRate, forKey: .sampleRate)
        try container.encode(numChannels, forKey: .numChannels)
        try container.encodeIfPresent(samplesPerChannel, forKey: .samplesPerChannel)
    }
}

private enum AudioChunkEncodingKeys: String, CodingKey {
    case data, sampleRate, numChannels, samplesPerChannel
}

extension SkillMetadata: Identifiable {
    public var id: String { "\(path)#\(name)" }
}

extension ExperimentalFeature: Identifiable {
    public var id: String { name }
}

extension ModelInfo: Identifiable {}

extension RateLimitSnapshot: Identifiable {
    public var id: String { limitId ?? UUID().uuidString }
}

extension AppAskForApproval {
    init?(wireValue: String?) {
        switch wireValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "untrusted":
            self = .unlessTrusted
        case "on-failure":
            self = .onFailure
        case "on-request":
            self = .onRequest
        case "never":
            self = .never
        default:
            return nil
        }
    }

    var launchOverrideWireValue: String? {
        switch self {
        case .unlessTrusted:
            return "untrusted"
        case .onFailure:
            return "on-failure"
        case .onRequest:
            return "on-request"
        case .never:
            return "never"
        case .granular:
            return nil
        }
    }

    var displayTitle: String {
        switch self {
        case .unlessTrusted:
            return "Untrusted"
        case .onFailure:
            return "On failure"
        case .onRequest:
            return "On request"
        case .granular:
            return "Granular"
        case .never:
            return "Never"
        }
    }
}

extension AppSandboxMode {
    init?(wireValue: String?) {
        switch wireValue?.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "read-only":
            self = .readOnly
        case "workspace-write":
            self = .workspaceWrite
        case "danger-full-access":
            self = .dangerFullAccess
        default:
            return nil
        }
    }

    var displayTitle: String {
        switch self {
        case .readOnly:
            return "Read only"
        case .workspaceWrite:
            return "Workspace write"
        case .dangerFullAccess:
            return "Full access"
        }
    }
}

extension AppSandboxPolicy {
    var launchOverrideModeWireValue: String? {
        switch self {
        case .dangerFullAccess:
            return "danger-full-access"
        case .readOnly:
            return "read-only"
        case .workspaceWrite:
            return "workspace-write"
        case .externalSandbox:
            return nil
        }
    }

    var launchOverrideMode: AppSandboxMode? {
        launchOverrideModeWireValue.flatMap(AppSandboxMode.init(wireValue:))
    }

    var displayTitle: String {
        switch self {
        case .dangerFullAccess:
            return "Full access"
        case .readOnly:
            return "Read only"
        case .workspaceWrite:
            return "Workspace write"
        case .externalSandbox:
            return "External sandbox"
        }
    }
}

extension AppThreadPermissionPreset {
    var title: String {
        switch self {
        case .supervised:
            return "Supervised"
        case .fullAccess:
            return "Full Access"
        case .custom:
            return "Custom"
        case .unknown:
            return "Unknown"
        }
    }
}

extension ReasoningEffort {
    init?(wireValue: String?) {
        switch wireValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "none":
            self = .none
        case "minimal":
            self = .minimal
        case "low":
            self = .low
        case "medium":
            self = .medium
        case "high":
            self = .high
        case "xhigh":
            self = .xHigh
        case "max":
            self = .max
        case "ultra":
            self = .ultra
        default:
            return nil
        }
    }

    var wireValue: String {
        switch self {
        case .none: return "none"
        case .minimal: return "minimal"
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        case .xHigh: return "xhigh"
        case .max: return "max"
        case .ultra: return "ultra"
        }
    }
}

extension ServiceTier {
    init?(wireValue: String?) {
        switch wireValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "fast":
            self = .fast
        case "flex":
            self = .flex
        default:
            return nil
        }
    }
}

extension AppMergeStrategy {
    init?(wireValue: String?) {
        switch wireValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "replace":
            self = .replace
        case "upsert":
            self = .upsert
        default:
            return nil
        }
    }
}

extension AbsolutePath: Encodable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

extension PlanType {
    init?(wireValue: String?) {
        switch wireValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "free":
            self = .free
        case "go":
            self = .go
        case "plus":
            self = .plus
        case "pro":
            self = .pro
        case "team":
            self = .team
        case "business":
            self = .business
        case "enterprise":
            self = .enterprise
        case "edu":
            self = .edu
        case "unknown":
            self = .unknown
        default:
            return nil
        }
    }

    var wireValue: String {
        switch self {
        case .free: return "free"
        case .go: return "go"
        case .plus: return "plus"
        case .pro: return "pro"
        case .team: return "team"
        case .business: return "business"
        case .enterprise: return "enterprise"
        case .edu: return "edu"
        case .unknown: return "unknown"
        }
    }
}

extension ReasoningEffortOption: Identifiable {
    public var id: String { reasoningEffort.wireValue }
}

extension AppUserInput: Encodable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: UserInputCodingKeys.self)
        switch self {
        case .text(let text, _):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .image(let url):
            try container.encode("image", forKey: .type)
            try container.encode(url, forKey: .url)
        case .localImage(let path):
            try container.encode("localImage", forKey: .type)
            try container.encode(path, forKey: .path)
        case .skill(let name, let path):
            try container.encode("skill", forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(path, forKey: .path)
        case .mention(let name, let path):
            try container.encode("mention", forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(path, forKey: .path)
        }
    }
}

private enum UserInputCodingKeys: String, CodingKey {
    case type, text, url, path, name
}

extension AppReviewTarget: Encodable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: ReviewTargetCodingKeys.self)
        switch self {
        case .uncommittedChanges:
            try container.encode("uncommittedChanges", forKey: .type)
        case .baseBranch(let branch):
            try container.encode("baseBranch", forKey: .type)
            try container.encode(branch, forKey: .branch)
        case .commit(let sha, let title):
            try container.encode("commit", forKey: .type)
            try container.encode(sha, forKey: .sha)
            try container.encodeIfPresent(title, forKey: .title)
        case .custom(let instructions):
            try container.encode("custom", forKey: .type)
            try container.encode(instructions, forKey: .instructions)
        }
    }
}

private enum ReviewTargetCodingKeys: String, CodingKey {
    case type, branch, sha, title, instructions
}

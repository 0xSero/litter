import Foundation

enum MessageRole: Equatable {
    case user
    case assistant
    case system
}

struct ChatMessage: Identifiable, Equatable {
    var id = UUID()
    let role: MessageRole
    var text: String {
        didSet { refreshRenderDigest() }
    }
    var images: [ChatImage] = [] {
        didSet { refreshRenderDigest() }
    }
    var sourceTurnId: String? = nil {
        didSet { refreshRenderDigest() }
    }
    var sourceTurnIndex: Int? = nil {
        didSet { refreshRenderDigest() }
    }
    var isFromUserTurnBoundary: Bool = false {
        didSet { refreshRenderDigest() }
    }
    var agentNickname: String? = nil {
        didSet { refreshRenderDigest() }
    }
    var agentRole: String? = nil {
        didSet { refreshRenderDigest() }
    }
    var widgetState: WidgetState? = nil {
        didSet { refreshRenderDigest() }
    }
    var timestamp: Date
    private(set) var renderDigest: Int

    init(
        id: UUID = UUID(),
        role: MessageRole,
        text: String,
        images: [ChatImage] = [],
        sourceTurnId: String? = nil,
        sourceTurnIndex: Int? = nil,
        isFromUserTurnBoundary: Bool = false,
        agentNickname: String? = nil,
        agentRole: String? = nil,
        widgetState: WidgetState? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.images = images
        self.sourceTurnId = sourceTurnId
        self.sourceTurnIndex = sourceTurnIndex
        self.isFromUserTurnBoundary = isFromUserTurnBoundary
        self.agentNickname = agentNickname
        self.agentRole = agentRole
        self.widgetState = widgetState
        self.timestamp = timestamp
        self.renderDigest = Self.computeRenderDigest(
            role: role,
            text: text,
            images: images,
            sourceTurnId: sourceTurnId,
            sourceTurnIndex: sourceTurnIndex,
            isFromUserTurnBoundary: isFromUserTurnBoundary,
            agentNickname: agentNickname,
            agentRole: agentRole,
            widgetState: widgetState
        )
    }

    private mutating func refreshRenderDigest() {
        renderDigest = Self.computeRenderDigest(
            role: role,
            text: text,
            images: images,
            sourceTurnId: sourceTurnId,
            sourceTurnIndex: sourceTurnIndex,
            isFromUserTurnBoundary: isFromUserTurnBoundary,
            agentNickname: agentNickname,
            agentRole: agentRole,
            widgetState: widgetState
        )
    }

    private static func computeRenderDigest(
        role: MessageRole,
        text: String,
        images: [ChatImage],
        sourceTurnId: String?,
        sourceTurnIndex: Int?,
        isFromUserTurnBoundary: Bool,
        agentNickname: String?,
        agentRole: String?,
        widgetState: WidgetState?
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(String(describing: role))
        hasher.combine(text)
        hasher.combine(sourceTurnId)
        hasher.combine(sourceTurnIndex)
        hasher.combine(isFromUserTurnBoundary)
        hasher.combine(agentNickname)
        hasher.combine(agentRole)
        hasher.combine(images.count)
        for image in images {
            hasher.combine(image.cacheKey)
        }
        if let widgetState {
            hasher.combine(widgetState.callId)
            hasher.combine(widgetState.title)
            hasher.combine(widgetState.widgetHTML)
            hasher.combine(widgetState.width)
            hasher.combine(widgetState.height)
            hasher.combine(widgetState.isFinalized)
        }
        return hasher.finalize()
    }
}

struct WidgetState: Equatable {
    let callId: String
    var title: String
    var widgetHTML: String
    var width: CGFloat
    var height: CGFloat
    var isFinalized: Bool = false
    var appId: String? = nil
}

struct ChatImage: Identifiable, Equatable {
    let id: String
    let source: String
    let cacheKey: String

    init(source: String) {
        self.source = source
        self.cacheKey = Self.makeCacheKey(for: source)
        self.id = self.cacheKey
    }

    init(data: Data, mimeType: String) {
        self.init(source: "data:\(mimeType);base64,\(data.base64EncodedString())")
    }

    static func == (lhs: ChatImage, rhs: ChatImage) -> Bool {
        lhs.cacheKey == rhs.cacheKey
    }

    private static func makeCacheKey(for source: String) -> String {
        var hasher = Hasher()
        hasher.combine(source)
        return String(hasher.finalize())
    }
}

enum ConversationStatus: Equatable {
    case idle
    case connecting
    case ready
    case thinking
    case error(String)
}

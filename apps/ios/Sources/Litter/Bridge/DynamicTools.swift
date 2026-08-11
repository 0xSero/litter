import Foundation

// MARK: - Dynamic Tool Spec (sent on thread/start)

struct DynamicToolSpecParams: Encodable {
    let name: String
    let description: String
    let inputSchema: AnyEncodable

    enum CodingKeys: String, CodingKey {
        case name, description, inputSchema
    }

    func rpcSpec(deferLoading: Bool = false) throws -> AppDynamicToolSpec {
        AppDynamicToolSpec(
            name: name,
            description: description,
            inputSchemaJson: String(data: try JSONEncoder().encode(inputSchema), encoding: .utf8) ?? "{}",
            deferLoading: deferLoading
        )
    }
}

// MARK: - JSON Schema Builder

indirect enum JSONSchema: Encodable {
    case object([String: JSONSchema], required: [String])
    case array(items: JSONSchema)
    case string(description: String? = nil)
    case stringEnum(values: [String], description: String? = nil)
    case number(description: String? = nil)
    case boolean(description: String? = nil)

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: SchemaKeys.self)
        switch self {
        case .object(let properties, let required):
            try container.encode("object", forKey: .type)
            try container.encode(properties, forKey: .properties)
            if !required.isEmpty {
                try container.encode(required, forKey: .required)
            }
        case .array(let items):
            try container.encode("array", forKey: .type)
            try container.encode(items, forKey: .items)
        case .string(let description):
            try container.encode("string", forKey: .type)
            if let description { try container.encode(description, forKey: .description) }
        case .stringEnum(let values, let description):
            try container.encode("string", forKey: .type)
            try container.encode(values, forKey: .enum_)
            if let description { try container.encode(description, forKey: .description) }
        case .number(let description):
            try container.encode("number", forKey: .type)
            if let description { try container.encode(description, forKey: .description) }
        case .boolean(let description):
            try container.encode("boolean", forKey: .type)
            if let description { try container.encode(description, forKey: .description) }
        }
    }

    private enum SchemaKeys: String, CodingKey {
        case type, properties, required, items, description
        case enum_ = "enum"
    }
}

import Foundation
import FoundationModels
import Vapor

// MARK: - response_format

/// How a response must be shaped to satisfy `response_format`
nonisolated enum StructuredOutput: Sendable {
    /// Guided generation constrains the model to the schema
    case guided(GenerationSchema)
    /// Content tagging ignores schemas and instructions but reliably returns comma-separated
    /// tags, so its plain text is split and wrapped into the requested JSON afterwards
    case tagList(TagListShape)
}

extension ResponseFormat {
    /// The output shape for this format and model, or nil for plain text
    nonisolated func structuredOutput(for model: AppleModel) throws -> StructuredOutput? {
        switch type {
        case "text":
            return nil
        case "json_schema":
            guard let format = jsonSchema, let schema = format.schema else {
                throw Abort(.badRequest, reason: "response_format json_schema requires json_schema.schema")
            }
            if model == .onDeviceContentTagging {
                guard let shape = TagListShape(schema: schema) else {
                    throw Abort(
                        .badRequest,
                        reason:
                            "Content tagging only returns a list of tags: use an array of strings, or an object with a single array-of-strings property"
                    )
                }
                return .tagList(shape)
            }
            return .guided(
                try JSONSchemaConverter.generationSchema(
                    name: format.name ?? "Response", description: format.description, schema: schema))
        case "json_object":
            guard model == .onDeviceContentTagging else {
                throw Abort(
                    .badRequest,
                    reason: "response_format json_object isn't supported; use json_schema with a schema")
            }
            return .tagList(TagListShape(key: "tags"))
        default:
            throw Abort(.badRequest, reason: "Unsupported response_format type: \(type)")
        }
    }
}

// MARK: - Tag lists

/// A JSON shape that holds a list of tags: `["a", "b"]` or `{"key": ["a", "b"]}`
nonisolated struct TagListShape: Sendable {
    /// Property holding the tags; nil for a top-level array
    let key: String?
    var minimumCount: Int?
    var maximumCount: Int?

    init(key: String?, minimumCount: Int? = nil, maximumCount: Int? = nil) {
        self.key = key
        self.minimumCount = minimumCount
        self.maximumCount = maximumCount
    }

    /// Recognizes an array of strings, or an object whose only property is one
    init?(schema: JSONValue) {
        func stringArray(_ schema: JSONValue) -> (min: Int?, max: Int?)? {
            guard schema["type"]?.string == "array" || schema["items"] != nil,
                schema["items"]?["type"]?.string == "string"
            else { return nil }
            return (schema["minItems"]?.int, schema["maxItems"]?.int)
        }

        if let limits = stringArray(schema) {
            self.init(key: nil, minimumCount: limits.min, maximumCount: limits.max)
        } else if let properties = schema["properties"]?.object, properties.count == 1,
            let property = properties.first, let limits = stringArray(property.value)
        {
            self.init(key: property.key, minimumCount: limits.min, maximumCount: limits.max)
        } else {
            return nil
        }
    }

    /// Split model text like "Apple, MacBook Pro, M5 chips" into the JSON shape
    func json(from text: String) throws -> String {
        var seen = Set<String>()
        var tags: [String] = []
        let separators = CharacterSet(charactersIn: ",，、;；\n")
        let trimmed = CharacterSet.whitespacesAndNewlines.union(
            CharacterSet(charactersIn: "\"'“”‘’`-*•.。[]"))
        for part in text.components(separatedBy: separators) {
            let tag = part.trimmingCharacters(in: trimmed)
            guard !tag.isEmpty, seen.insert(tag.lowercased()).inserted else { continue }
            tags.append(tag)
        }
        if let maximumCount {
            tags = Array(tags.prefix(maximumCount))
        }
        if let minimumCount, tags.count < minimumCount {
            throw Abort(
                .unprocessableEntity,
                reason: "The model returned \(tags.count) tags, fewer than the schema's minItems (\(minimumCount))")
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try key.map { try encoder.encode([$0: tags]) } ?? encoder.encode(tags)
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - JSON Schema → FoundationModels

/// Converts a JSON Schema (the subset OpenAI structured outputs use) into a `GenerationSchema`
/// for guided generation.
///
/// Supported: object (properties, required), array (items, minItems, maxItems), string (enum,
/// const, pattern), integer and number (minimum, maximum), boolean, anyOf/oneOf, nullable types,
/// and `$ref` into `$defs` / `definitions`. JSON object key order isn't preserved by `Codable`,
/// so properties are generated in `required` order, then the optional ones alphabetically.
nonisolated enum JSONSchemaConverter {
    static func generationSchema(name: String, description: String?, schema: JSONValue) throws
        -> GenerationSchema
    {
        guard schema.object != nil else {
            throw invalid("the schema must be a JSON object")
        }

        var dependencies: [DynamicGenerationSchema] = []
        for key in ["$defs", "definitions"] {
            for (definitionName, definition) in (schema[key]?.object ?? [:]).sorted(by: { $0.key < $1.key }) {
                dependencies.append(try convert(definition, name: definitionName))
            }
        }

        let root = try convert(schema, name: name, description: description)
        do {
            return try GenerationSchema(root: root, dependencies: dependencies)
        } catch {
            throw invalid(error.localizedDescription)
        }
    }

    private static func convert(_ schema: JSONValue, name: String, description: String? = nil)
        throws -> DynamicGenerationSchema
    {
        guard schema.object != nil else {
            throw invalid("\(name) must be a schema object")
        }
        let description = description ?? schema["description"]?.string

        if let reference = schema["$ref"]?.string {
            guard let definitionName = reference.split(separator: "/").last,
                reference.hasPrefix("#/$defs/") || reference.hasPrefix("#/definitions/")
            else {
                throw invalid("only local $ref into $defs or definitions is supported (\(reference))")
            }
            return DynamicGenerationSchema(referenceTo: String(definitionName))
        }

        if let choices = (schema["anyOf"] ?? schema["oneOf"])?.array {
            // A null branch only marks the value as nullable; optional properties cover that
            let branches = choices.filter { $0["type"]?.string != "null" }
            if branches.count == 1 {
                return try convert(branches[0], name: name, description: description)
            }
            return DynamicGenerationSchema(
                name: name, description: description,
                anyOf: try branches.enumerated().map { index, branch in
                    try convert(branch, name: "\(name)_\(index)")
                })
        }

        if let values = schema["enum"]?.array {
            let strings = values.compactMap(\.string)
            guard strings.count == values.count, !strings.isEmpty else {
                throw invalid("\(name): only non-empty string enums are supported")
            }
            return DynamicGenerationSchema(name: name, description: description, anyOf: strings)
        }

        if let constant = schema["const"]?.string {
            return DynamicGenerationSchema(name: name, description: description, anyOf: [constant])
        }

        switch try type(of: schema, name: name) {
        case "object":
            let properties = schema["properties"]?.object ?? [:]
            let required = (schema["required"]?.array ?? []).compactMap(\.string)
                .filter { properties[$0] != nil }
            let optional = properties.keys.filter { !required.contains($0) }.sorted()
            return DynamicGenerationSchema(
                name: name, description: description,
                properties: try (required + optional).map { key in
                    let property = properties[key]!
                    return DynamicGenerationSchema.Property(
                        name: key,
                        description: property["description"]?.string,
                        schema: try convert(property, name: "\(name)_\(key)"),
                        isOptional: !required.contains(key))
                })

        case "array":
            guard let items = schema["items"] else {
                throw invalid("\(name): arrays need an items schema")
            }
            return DynamicGenerationSchema(
                arrayOf: try convert(items, name: "\(name)_item"),
                minimumElements: schema["minItems"]?.int,
                maximumElements: schema["maxItems"]?.int)

        case "string":
            if let pattern = schema["pattern"]?.string {
                let regex: Regex<AnyRegexOutput>
                do {
                    regex = try Regex(pattern)
                } catch {
                    throw invalid("\(name): invalid pattern \(pattern)")
                }
                return DynamicGenerationSchema(type: String.self, guides: [.pattern(regex)])
            }
            return DynamicGenerationSchema(type: String.self)

        case "integer":
            var guides: [GenerationGuide<Int>] = []
            if let minimum = schema["minimum"]?.int { guides.append(.minimum(minimum)) }
            if let maximum = schema["maximum"]?.int { guides.append(.maximum(maximum)) }
            return DynamicGenerationSchema(type: Int.self, guides: guides)

        case "number":
            var guides: [GenerationGuide<Double>] = []
            if let minimum = schema["minimum"]?.double { guides.append(.minimum(minimum)) }
            if let maximum = schema["maximum"]?.double { guides.append(.maximum(maximum)) }
            return DynamicGenerationSchema(type: Double.self, guides: guides)

        case "boolean":
            return DynamicGenerationSchema(type: Bool.self)

        case let other:
            throw invalid("\(name): unsupported type \(other)")
        }
    }

    /// The schema's type, ignoring "null" in type arrays and inferring object/array when omitted
    private static func type(of schema: JSONValue, name: String) throws -> String {
        if let type = schema["type"]?.string {
            return type
        }
        if let types = schema["type"]?.array?.compactMap(\.string).filter({ $0 != "null" }),
            let type = types.first
        {
            guard types.count == 1 else {
                throw invalid("\(name): multiple types (\(types.joined(separator: ", "))) aren't supported")
            }
            return type
        }
        if schema["properties"] != nil { return "object" }
        if schema["items"] != nil { return "array" }
        throw invalid("\(name): missing type")
    }

    private static func invalid(_ detail: String) -> Abort {
        Abort(.badRequest, reason: "Unsupported response_format schema: \(detail)")
    }
}

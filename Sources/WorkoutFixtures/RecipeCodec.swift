import Foundation

public enum GenerationRecipeCodingError: Error, Equatable, Sendable, LocalizedError {
  case invalidTopLevel
  case unknownField(path: String)

  public var errorDescription: String? {
    switch self {
    case .invalidTopLevel:
      "The generation recipe must be a JSON object."
    case .unknownField(let path):
      "Unknown generation recipe field at '\(path)'."
    }
  }
}

public struct GenerationRecipeCodec: Sendable {
  public init() {}

  public func decode(_ data: Data) throws -> GenerationRecipe {
    let raw = try JSONSerialization.jsonObject(with: data)
    guard let object = raw as? [String: Any] else {
      throw GenerationRecipeCodingError.invalidTopLevel
    }
    if let path = Self.firstUnknownField(in: object) {
      throw GenerationRecipeCodingError.unknownField(path: path)
    }
    return try JSONDecoder().decode(GenerationRecipe.self, from: data)
  }

  public func encode(_ recipe: GenerationRecipe) throws -> Data {
    try CanonicalFixtureJSON.encode(recipe)
  }

  public static var schemaData: Data {
    get throws {
      guard
        let url = Bundle.module.url(
          forResource: "GenerationRecipe.schema",
          withExtension: "json"
        )
      else {
        throw CocoaError(.fileNoSuchFile)
      }
      return try Data(contentsOf: url)
    }
  }

  private static func firstUnknownField(in object: [String: Any]) -> String? {
    if let field = unknown(in: object, allowed: ["transforms"]) { return field }
    guard let transforms = object["transforms"] as? [[String: Any]] else { return nil }
    for (index, transform) in transforms.enumerated() {
      if let field = unknown(in: transform, allowed: transformKeys) {
        return "transforms[\(index)].\(field)"
      }
      for (key, allowed) in nestedKeys {
        if let nested = transform[key] as? [String: Any],
          let field = unknown(in: nested, allowed: allowed)
        {
          return "transforms[\(index)].\(key).\(field)"
        }
      }
    }
    return nil
  }

  private static func unknown(in object: [String: Any], allowed: Set<String>) -> String? {
    object.keys.sorted().first { !allowed.contains($0) }
  }

  private static let transformKeys: Set<String> = [
    "kind", "metric", "integerRange", "valueRange", "standardDeviation",
    "minimum", "maximum", "intervalSeconds", "coordinate", "degrees", "maxMeters",
  ]
  private static let nestedKeys: [String: Set<String>] = [
    "integerRange": ["lowerBound", "upperBound"],
    "valueRange": ["lowerBound", "upperBound"],
    "coordinate": ["latitude", "longitude"],
  ]
}

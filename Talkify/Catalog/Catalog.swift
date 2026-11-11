import Foundation

/// The bundled list of Catalog Models: the only place one is ever named.
///
/// It ships inside the signed app as `catalog.json` and is never fetched. A change to it is
/// a reviewed pull request and reaches users with the next app update, so the hashes it pins
/// carry the app's own signature.
struct Catalog: Codable, Equatable, Sendable {
  var schemaVersion: Int
  /// Rises by one on every change to the file.
  var catalogVersion: Int
  var models: [CatalogModel]

  static let resourceName = "catalog"

  init(schemaVersion: Int, catalogVersion: Int, models: [CatalogModel]) {
    self.schemaVersion = schemaVersion
    self.catalogVersion = catalogVersion
    self.models = models
  }

  init(data: Data) throws {
    self = try JSONDecoder().decode(Catalog.self, from: data)
  }

  /// Reads the copy compiled into `bundle`. Throws when the resource is missing, so a
  /// build that lost the file fails loudly instead of listing nothing.
  static func bundled(in bundle: Bundle = .main) throws -> Catalog {
    guard let url = bundle.url(forResource: resourceName, withExtension: "json") else {
      throw CocoaError(.fileNoSuchFile)
    }
    return try Catalog(data: Data(contentsOf: url))
  }
}

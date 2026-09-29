import Foundation
import MickCore

extension MoveCatalog {
    /// The bundled `moves.json` (SPEC §10.1), shipped as a MickIO resource.
    public static var bundledURL: URL? {
        Bundle.module.url(forResource: "moves", withExtension: "json")
    }

    /// Loads the bundled catalogue. Throws if it's missing or invalid, which only a
    /// broken build can cause.
    public static func bundled() throws -> MoveCatalog {
        guard let url = bundledURL else { throw CocoaError(.fileNoSuchFile) }
        return try decode(Data(contentsOf: url))
    }
}

extension LineCatalog {
    /// The bundled `lines.json` (SPEC §10.2), shipped as a MickIO resource.
    public static var bundledURL: URL? {
        Bundle.module.url(forResource: "lines", withExtension: "json")
    }

    /// Loads the bundled line pools. Throws if they're missing or invalid, which only a
    /// broken build can cause.
    public static func bundled() throws -> LineCatalog {
        guard let url = bundledURL else { throw CocoaError(.fileNoSuchFile) }
        return try decode(Data(contentsOf: url))
    }
}

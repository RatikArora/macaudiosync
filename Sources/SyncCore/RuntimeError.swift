import Foundation

/// Simple string-payload error for CLI-level failures.
public struct RuntimeError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

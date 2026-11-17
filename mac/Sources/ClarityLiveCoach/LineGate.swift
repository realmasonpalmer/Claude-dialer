import Foundation

/// Tracks whether a streaming live line was checked and passed (main actor only).
@MainActor
final class LineGate {
    var checked = false
    var passed = false
}

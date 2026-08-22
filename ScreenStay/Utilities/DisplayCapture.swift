import AppKit
import CoreGraphics

/// Presentation helpers for display topologies.
///
/// Capture itself lives in `DisplayTopology.current()`. There used to be a
/// second capture path here that read `NSScreen` instead of CoreGraphics, which
/// meant a persisted `position` could be in either coordinate space depending
/// on which code wrote it.
enum DisplayCapture {

    /// Get a human-readable description of the topology
    static func describeTopology(_ topology: DisplayTopology) -> String {
        var parts: [String] = []

        let builtInCount = topology.displays.filter { $0.isBuiltIn }.count
        let externalCount = topology.displays.filter { !$0.isBuiltIn }.count

        if builtInCount > 0 {
            parts.append("Built-in")
        }

        if externalCount > 0 {
            let externalResolutions = topology.displays
                .filter { !$0.isBuiltIn }
                .map { "\(Int($0.resolution.width))x\(Int($0.resolution.height))" }
                .joined(separator: ", ")
            parts.append("\(externalCount) External (\(externalResolutions))")
        }

        return parts.joined(separator: " + ")
    }
}

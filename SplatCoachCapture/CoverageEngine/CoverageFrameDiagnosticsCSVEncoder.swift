import Foundation

enum CoverageFrameDiagnosticsCSVEncoder {
    static let columns = [
        "frameNumber",
        "timestamp",
        "absoluteYawRadians",
        "absoluteYawDegrees",
        "startYawRadians",
        "startYawDegrees",
        "startRelativeYawRadians",
        "startRelativeYawDegrees",
        "normalizedYawDegrees",
        "assignedSector",
        "sectorStartDegrees",
        "sectorEndDegrees",
        "saved",
        "excluded",
        "exclusionReason",
        "evidenceWeight",
        "viewChangeScore",
        "newAngleDecision",
        "overlapDecision",
        "movementClassification",
        "scanHealth"
    ]

    static func encode(_ diagnostics: [CoverageFrameDiagnostic]) -> Data? {
        let header = columns.joined(separator: ",")
        let formatter = ISO8601DateFormatter()
        let rows = diagnostics.map { diagnostic in
            [
                "\(diagnostic.frameNumber)",
                formatter.string(from: diagnostic.timestamp),
                number(diagnostic.absoluteYawRadians),
                number(diagnostic.absoluteYawDegrees),
                number(diagnostic.startYawRadians),
                number(diagnostic.startYawDegrees),
                number(diagnostic.startRelativeYawRadians),
                number(diagnostic.startRelativeYawDegrees),
                number(diagnostic.normalizedYawDegrees),
                diagnostic.assignedSector?.rawValue ?? "",
                number(diagnostic.assignedSectorStartDegrees),
                number(diagnostic.assignedSectorEndDegrees),
                diagnostic.saved ? "true" : "false",
                diagnostic.excluded ? "true" : "false",
                diagnostic.exclusionReason ?? "",
                number(diagnostic.evidenceWeight),
                number(diagnostic.viewChangeScore),
                diagnostic.newAngleDecision ? "true" : "false",
                diagnostic.overlapDecision ? "true" : "false",
                diagnostic.movementClassification.rawValue,
                diagnostic.scanHealth
            ]
            .map(escape)
            .joined(separator: ",")
        }

        return (([header] + rows).joined(separator: "\n") + "\n").data(using: .utf8)
    }

    private static func number(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "" }
        return String(format: "%.6f", value)
    }

    private static func escape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }
}

//
//  MissionView.swift
//  SplatCoachCapture
//
//  Created by OpenAI on 7/8/26.
//

import SwiftUI

struct MissionView: View {
    @ObservedObject var manager: MissionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            Text(manager.progress.instruction)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(2)

            VStack(spacing: 8) {
                ForEach(manager.progress.evidence) { evidence in
                    evidenceRow(evidence)
                }
            }

            if let debugText = manager.progress.debugText {
                Text(debugText)
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(2)
                    .accessibilityLabel("Mission movement debug \(debugText)")
            }
        }
        .padding(12)
        .frame(width: 286, alignment: .leading)
        .background(.black.opacity(0.64), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(statusColor.opacity(0.48), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
        .allowsHitTesting(false)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(manager.activeMission.title)
                    .font(.caption.weight(.black))
                    .textCase(.uppercase)
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(manager.progress.status.rawValue)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(statusColor)
                    .textCase(.uppercase)
            }

            Spacer()

            Image(systemName: statusIconName)
                .font(.body.weight(.bold))
                .foregroundStyle(statusColor)
                .frame(width: 26, height: 26)
                .background(statusColor.opacity(0.16), in: Circle())
        }
    }

    private func evidenceRow(_ evidence: MissionEvidence) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(evidence.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.72))

                Spacer()

                Text(evidence.detail)
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white.opacity(0.86))
                    .lineLimit(1)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.14))

                    Capsule()
                        .fill(color(for: evidence.level))
                        .frame(width: max(proxy.size.width * evidence.level.barFill, 8))
                }
            }
            .frame(height: 5)
        }
    }

    private var statusColor: Color {
        switch manager.progress.status {
        case .collecting:
            return .orange
        case .likelyComplete:
            return .yellow
        case .complete:
            return .green
        case .needsAttention:
            return .red
        }
    }

    private var statusIconName: String {
        switch manager.progress.status {
        case .collecting:
            return "figure.walk"
        case .likelyComplete:
            return "checkmark.seal"
        case .complete:
            return "checkmark.circle.fill"
        case .needsAttention:
            return "exclamationmark.triangle"
        }
    }

    private func color(for level: MissionEvidenceLevel) -> Color {
        switch level {
        case .none:
            return .gray
        case .building:
            return .orange
        case .steady:
            return .yellow
        case .strong:
            return .green
        }
    }
}

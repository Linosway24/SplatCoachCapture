//
//  CoverageView.swift
//  SplatCoachCapture
//
//  Created by OpenAI on 7/8/26.
//

import SwiftUI

struct CoverageView: View {
    @ObservedObject var manager: CoverageManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            Text(manager.summary.recommendation.text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.86))
                .lineLimit(2)

            VStack(spacing: 7) {
                ForEach(manager.summary.sectors) { sector in
                    sectorRow(sector)
                }
            }
        }
        .padding(12)
        .frame(width: 286, alignment: .leading)
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(recommendationColor.opacity(0.42), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.38), radius: 12, y: 5)
        .allowsHitTesting(false)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("Coverage", systemImage: "square.grid.2x2")
                .font(.caption.weight(.black))
                .textCase(.uppercase)

            Spacer()
        }
        .foregroundStyle(.white)
    }

    private func sectorRow(_ sector: CoverageEvidence) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(sector.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.72))

                Spacer()

                Text(detailText(for: sector))
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.13))

                    Capsule()
                        .fill(color(for: sector.level))
                        .frame(width: max(proxy.size.width * sector.level.barFill, 8))
                }
            }
            .frame(height: 5)

            Text(sector.rationale)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.58))
                .lineLimit(1)
        }
    }

    private func detailText(for sector: CoverageEvidence) -> String {
        "\(sector.level.title) · S\(sector.savedFrames) A\(sector.newAngleFrames)"
    }

    private var recommendationColor: Color {
        switch manager.summary.recommendation.priority {
        case .complete:
            return .green
        case .important:
            return .orange
        case .normal:
            return .yellow
        }
    }

    private func color(for level: CoverageEvidenceLevel) -> Color {
        switch level {
        case .none:
            return .gray
        case .sparse:
            return .orange
        case .adequate:
            return .yellow
        case .strong:
            return .green
        }
    }
}

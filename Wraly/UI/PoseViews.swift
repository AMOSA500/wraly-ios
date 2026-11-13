import SwiftUI
import WralyCore

/// The pose being directed, with a live checklist the camera ticks off.
struct PoseCard: View {
    @Environment(CoachController.self) private var coach
    @Binding var showPicker: Bool

    var body: some View {
        if let recipe = coach.poseRecipe {
            let progress = coach.state.pose?.recipe == recipe ? coach.state.pose : nil
            let matched = progress?.matched ?? false
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Button { showPicker = true } label: {
                        HStack(spacing: 6) {
                            Image(systemName: recipe.symbol)
                            Text(recipe.name).font(.footnote.weight(.semibold))
                            Image(systemName: "chevron.down").font(.caption2)
                        }
                    }
                    .accessibilityLabel("Pose: \(recipe.name). Choose another pose")
                    Spacer(minLength: 4)
                    if matched {
                        Label("Pose confirmed", systemImage: "checkmark.seal.fill")
                            .font(.caption.weight(.bold)).foregroundStyle(.green)
                    } else {
                        Text("\(progress?.metCount ?? 0)/\(recipe.steps.count)")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Button { coach.nextPose(-1) } label: { Image(systemName: "chevron.left") }
                        .accessibilityLabel("Previous pose")
                    Button { coach.nextPose() } label: { Image(systemName: "chevron.right") }
                        .accessibilityLabel("Next pose")
                }
                FlowRow(spacing: 4) {
                    ForEach(Array(recipe.steps.enumerated()), id: \.element.id) { i, step in
                        let status = progress?.steps[i]
                        let isNext = progress?.nextStep?.id == step.id
                        HStack(spacing: 3) {
                            Image(systemName: status?.met == true ? "checkmark.circle.fill"
                                  : status?.unknown == true ? "questionmark.circle" : "circle")
                            Text(step.label)
                        }
                        .font(.caption2.weight(isNext ? .bold : .regular))
                        .foregroundStyle(status?.met == true ? Color.green : isNext ? Color.yellow : Color.white.opacity(0.8))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color.white.opacity(isNext ? 0.15 : 0.06), in: Capsule())
                        .accessibilityLabel("\(step.label), \(status?.met == true ? "done" : "not yet")")
                    }
                }
            }
            .tint(.white)
            .padding(10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(matched ? Color.green : .clear, lineWidth: 2))
            .animation(.snappy, value: progress?.metCount)
        } else {
            Button { coach.poseGuide = true } label: {
                Label("Suggest a pose", systemImage: "figure.stand")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.black.opacity(0.5), in: Capsule())
            }
            .tint(.white)
        }
    }
}

/// Wraps chips onto new lines when they don't fit.
struct FlowRow: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews)
        let h = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        let w = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? w, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews) {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
            if rows[rows.count - 1].width + extra > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            let addWidth = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
            rows[rows.count - 1].indices.append(i)
            rows[rows.count - 1].width += addWidth
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}

/// Recommended poses for the shot being framed.
struct PosePickerSheet: View {
    @Environment(CoachController.self) private var coach
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var coach = coach
        NavigationStack {
            List {
                Section {
                    Toggle("Pose guide", isOn: $coach.poseGuide)
                    Toggle("Next pose after each photo", isOn: $coach.autoNextPose)
                        .disabled(!coach.poseGuide)
                } footer: {
                    Text("Tell your subject each step. Wraly ticks it off when the camera sees it, and waits for the full pose before taking the shot.")
                }

                Section("Recommended for \(coach.state.shot.title)") {
                    ForEach(coach.recommendedPoses) { recipe in
                        Button {
                            coach.poseGuide = true
                            coach.poseRecipe = recipe
                            dismiss()
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: recipe.symbol).font(.title3).frame(width: 30)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(recipe.name).font(.headline)
                                    Text(recipe.summary).font(.footnote).foregroundStyle(.secondary)
                                    ForEach(recipe.steps) { step in
                                        Text("• \(step.say)").font(.caption)
                                    }
                                }
                                Spacer(minLength: 0)
                                if recipe == coach.poseRecipe {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                        .tint(.primary)
                    }
                }
            }
            .navigationTitle("Poses")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

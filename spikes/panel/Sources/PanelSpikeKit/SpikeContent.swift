import SwiftUI

/// State behind the spike panel. Records every interaction so tests and the
/// smoke mode can check that a single click landed.
@MainActor
@Observable
public final class SpikeModel {
    public static let itemTitles = ["Stand up", "Hands on your lower back, lean back, 20s", "Roll your shoulders, 10 times"]

    public var checked: [Bool] = Array(repeating: false, count: SpikeModel.itemTitles.count)
    public var notNowTaps = 0
    public var snoozeTaps = 0
    /// Frames of the interactive controls, in the hosting view's top-left-origin space.
    public var controlFrames: [String: CGRect] = [:]
    public var onInteraction: (@MainActor (String) -> Void)?

    public init() {}

    public static func toggleID(_ index: Int) -> String { "toggle.\(index)" }
    public static let notNowID = "button.notNow"
    public static let snoozeID = "button.snooze"

    func record(_ what: String) { onInteraction?(what) }
}

/// Stand-in for the reminder panel's content: an opener, checkbox toggles, two plain buttons.
public struct SpikeContentView: View {
    @Bindable var model: SpikeModel

    public init(model: SpikeModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Up. Now. The agent's got it.")
                .font(.headline)
            ForEach(SpikeModel.itemTitles.indices, id: \.self) { i in
                Toggle(SpikeModel.itemTitles[i], isOn: Binding(
                    get: { model.checked[i] },
                    set: { model.checked[i] = $0; model.record("toggle \(i) -> \($0)") }
                ))
                .toggleStyle(.checkbox)
                .fixedSize()
                .reportFrame(SpikeModel.toggleID(i), into: model)
            }
            HStack(spacing: 16) {
                Button("Not now") {
                    model.notNowTaps += 1
                    model.record("not now")
                }
                .buttonStyle(.plain)
                .reportFrame(SpikeModel.notNowID, into: model)
                Button("Snooze") {
                    model.snoozeTaps += 1
                    model.record("snooze")
                }
                .buttonStyle(.plain)
                .reportFrame(SpikeModel.snoozeID, into: model)
            }
            .padding(.top, 4)
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

private extension View {
    func reportFrame(_ id: String, into model: SpikeModel) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.controlFrames[id] = $0 }
    }
}

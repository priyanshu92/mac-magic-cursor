import AppKit
import MagicCursorCore
import SwiftUI

/// The native Settings window opened from the menu bar. It binds to the same
/// model as the panel's built-in settings, so changes appear in both places.
struct PreferencesView: View {
  @ObservedObject var model: AppModel

  var body: some View {
    Form {
      Section {
        Picker("When you select something", selection: $model.selectionMode) {
          ForEach(SelectionMode.allCases, id: \.self) { mode in
            Text(mode.title).tag(mode)
          }
        }
        .pickerStyle(.radioGroup)
        Text(
          model.selectionMode == .answerImmediately
            ? "Explains the selection right away, then suggests follow-up questions."
            : "Shows the selection with suggestions and waits for your question, like Googlebook."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
      } header: {
        Text("After selecting")
      }

      Section {
        Toggle("Shake the pointer to start selecting", isOn: $model.shakeEnabled)
        Picker("Sensitivity", selection: $model.sensitivity) {
          ForEach(ShakeDetector.Sensitivity.allCases, id: \.self) { value in
            Text(value.title).tag(value)
          }
        }
        .pickerStyle(.segmented)
        .disabled(!model.shakeEnabled)
        Text("Gentle needs less movement. Deliberate avoids accidental activation.")
          .font(.callout)
          .foregroundStyle(.secondary)
      } header: {
        Text("Shake gesture")
      }

      Section {
        LabeledContent("Width") {
          HStack {
            // A stepped slider draws a dense row of tick marks on macOS, so
            // round in the binding instead.
            Slider(
              value: Binding(
                get: { model.cardWidth }, set: { model.cardWidth = $0.rounded() }),
              in: AppModel.cardWidthRange)
            Text("\(Int(model.cardWidth)) pt")
              .monospacedDigit()
              .frame(width: 52, alignment: .trailing)
          }
        }
        LabeledContent("Height") {
          Text(
            model.userCardHeight.map { "\(Int($0)) pt" } ?? "Fits the conversation")
        }
        HStack {
          Text("Drag the card's edges to resize it. Double-click a bottom corner to reset.")
            .font(.callout)
            .foregroundStyle(.secondary)
          Spacer()
          Button("Reset Size", action: model.resetCardSize)
            .disabled(!model.isCustomSize)
        }
      } header: {
        Text("Answer card")
      }

      Section {
        LabeledContent("Screen Recording") {
          HStack {
            Text(model.screenPermission ? "Allowed" : "Not allowed")
              .foregroundStyle(model.screenPermission ? .secondary : Color.orange)
            Button("Open Privacy Settings", action: model.openPrivacySettings)
          }
        }
        if let message = model.errorMessage {
          Text(message)
            .font(.callout)
            .foregroundStyle(Color.orange)
        }
        LabeledContent("Apple Intelligence") {
          Text(model.modelMessage == nil ? "Available" : "Unavailable")
            .foregroundStyle(.secondary)
        }
        if let message = model.modelMessage {
          Text(message).font(.callout).foregroundStyle(.secondary)
        }
        Text(
          "Selections, answers, and chat history stay on your Mac in memory and are cleared when you quit."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
      } header: {
        Text("Permissions and privacy")
      }
    }
    .formStyle(.grouped)
    .frame(width: 520, height: 690)
  }
}

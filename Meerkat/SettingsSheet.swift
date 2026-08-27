import AppKit
import SwiftData
import SwiftUI

struct SettingsSheet: View {
    var onBack: () -> Void = {}

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Camera.sortIndex) private var cameras: [Camera]
    @AppStorage(AppInfo.cameraLabelVisibilityKey) private var cameraLabelVisibility = CameraLabelVisibility.always
    @State private var saveErrorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            ScrollView {
                VStack(spacing: 12) {
                    SettingsGroup(
                        title: "Cameras",
                        subtitle: "Live streams shown in the grid"
                    ) {
                        ForEach(cameras) { camera in
                            CameraRow(camera: camera) {
                                remove(camera)
                            }

                            Divider()
                        }

                        Button("Add camera") {
                            addCamera()
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .accessibilityIdentifier("settings-add-camera")
                    }

                    SettingsGroup(
                        title: "Display",
                        subtitle: "Overlay text on camera tiles"
                    ) {
                        LabeledContent("Show camera labels") {
                            Spacer()
                            Picker("Show camera labels", selection: $cameraLabelVisibility) {
                                ForEach(CameraLabelVisibility.allCases, id: \.self) { option in
                                    Text(option.title).tag(option)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .fixedSize()
                            .accessibilityIdentifier("settings-show-camera-labels")
                        }
                    }
                }
                .padding(12)
            }

            Divider()

            Button("Quit", role: .destructive) {
                NSApplication.shared.terminate(nil)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityIdentifier("settings-quit")
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .alert(
            "Could not save cameras",
            isPresented: Binding(
                get: { saveErrorMessage != nil },
                set: { if !$0 { saveErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                saveErrorMessage = nil
            }
        } message: {
            if let saveErrorMessage {
                Text(saveErrorMessage)
            }
        }
    }

    private var headerBar: some View {
        HStack {
            Button(action: onBack) {
                Label("Back", systemImage: "chevron.backward")
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(-14)
            .accessibilityLabel("Back")
            .accessibilityIdentifier("settings-back")

            Text("Settings")
                .accessibilityIdentifier("settings-title")

            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.background)
    }

    private func addCamera() {
        modelContext.insert(
            Camera(
                name: "",
                streamURLString: "",
                sortIndex: (cameras.map(\.sortIndex).max() ?? -1) + 1
            )
        )
        saveChanges()
    }

    private func remove(_ camera: Camera) {
        modelContext.delete(camera)
        saveChanges()
    }

    private func saveChanges() {
        do {
            try modelContext.save()
        } catch {
            saveErrorMessage = error.localizedDescription
        }
    }
}

private struct SettingsGroup<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)

                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            .quaternary.opacity(0.4),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }
}

private struct CameraRow: View {
    @Bindable var camera: Camera
    var onRemove: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            LabeledContent("URL") {
                Spacer()
                TextField("https://", text: $camera.streamURLString)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 300)
                    .accessibilityIdentifier("\(camera.cameraID.uuidString)-url")
            }

            HStack(spacing: 12) {
                LabeledContent("Name") {
                    Spacer()
                    TextField("Name", text: $camera.name)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 202)
                        .accessibilityIdentifier("\(camera.cameraID.uuidString)-name")
                }

                Divider()

                Button("Remove", role: .destructive, action: onRemove)
                    .accessibilityIdentifier("\(camera.cameraID.uuidString)-remove")
            }
        }
    }
}

#Preview("Empty Light") {
    SettingsSheet()
        .frame(width: 420, height: 360)
        .modelContainer(Persistence.preview(cameras: []))
        .preferredColorScheme(.light)
}

#Preview("Empty Dark") {
    SettingsSheet()
        .frame(width: 420, height: 360)
        .modelContainer(Persistence.preview(cameras: []))
        .preferredColorScheme(.dark)
}

#Preview("With Cameras") {
    SettingsSheet()
        .frame(width: 420, height: 620)
        .modelContainer(
            Persistence.preview(cameras: [
                ("Camera 1", "https://camera.test/1"),
                ("Camera 2", "https://camera.test/2"),
            ])
        )
        .preferredColorScheme(.light)
}

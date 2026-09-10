import AppKit
import SwiftData
import SwiftUI

struct SettingsSheet: View {
    var onBack: () -> Void = {}
    var canCheckForUpdates = false
    var onCheckForUpdates: () -> Void = {}

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Camera.sortIndex) private var cameras: [Camera]
    @AppStorage(AppInfo.cameraLabelVisibilityKey) private var cameraLabelVisibility = CameraLabelVisibility.always
    @State private var cameraPendingRemoval: Camera?
    @State private var saveErrorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            ScrollView {
                VStack(spacing: 12) {
                    SettingsGroup(
                        title: "Cameras"
                    ) {
                        Button {
                            addCamera()
                        } label: {
                            Label("Add camera", systemImage: "plus")
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .controlSize(.small)
                        .accessibilityIdentifier("settings-add-camera")

                        ForEach(cameras) { camera in
                            CameraRow(camera: camera) {
                                cameraPendingRemoval = camera
                            }
                        }
                    }

                    SettingsGroup(
                        title: "Display"
                    ) {
                        SettingsSurface {
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

                    SettingsGroup(
                        title: "Updates"
                    ) {
                        SettingsSurface {
                            LabeledContent("Keep Meerkat up to date") {
                                Button("Check for Updates…", action: onCheckForUpdates)
                                    .controlSize(.small)
                                    .disabled(!canCheckForUpdates)
                                    .accessibilityIdentifier("settings-check-for-updates")
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }

            Divider()

            HStack {
                Text("Meerkat \(AppInfo.version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Meerkat \(AppInfo.version)")
                    .accessibilityIdentifier("settings-version")

                Spacer()

                Button("Quit Meerkat", role: .destructive) {
                    NSApplication.shared.terminate(nil)
                }
                .accessibilityIdentifier("settings-quit")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .background(SettingsFocusDismissal())
        .allowsHitTesting(cameraPendingRemoval == nil)
        .accessibilityHidden(cameraPendingRemoval != nil)
        .overlay {
            if let camera = cameraPendingRemoval {
                removalConfirmation(for: camera)
            }
        }
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

    private func displayName(for camera: Camera) -> String {
        camera.name.isEmpty ? "this camera" : "“\(camera.name)”"
    }

    private func removalConfirmation(for camera: Camera) -> some View {
        ZStack {
            Color.black.opacity(0.2)

            VStack(alignment: .center, spacing: 16) {
                Image(systemName: "trash.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.red)
                    .frame(width: 40, height: 40)
                    .background(.red.opacity(0.12), in: Circle())

                VStack(spacing: 6) {
                    Text("Remove \(displayName(for: camera))?")
                        .font(.headline)

                    Text("This camera will be removed from Meerkat. This action can’t be undone.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    Button("Cancel") {
                        cameraPendingRemoval = nil
                    }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("cancel-camera-removal")

                    Button("Remove Camera", role: .destructive) {
                        cameraPendingRemoval = nil
                        remove(camera)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .accessibilityIdentifier("confirm-camera-removal")
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(20)
            .frame(width: 320)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.18), radius: 20, y: 8)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("camera-removal-dialog")
        }
        .onExitCommand {
            cameraPendingRemoval = nil
        }
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
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsSurface<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                .fill.quaternary,
                in: ConcentricRectangle(corners: .concentric(minimum: 12))
            )
    }
}

private struct CameraRow: View {
    @Bindable var camera: Camera
    var onRemove: () -> Void
    @State private var input: CameraInput
    @State private var endpointProbeInput: CameraInput?
    @State private var endpointError: String?
    @FocusState private var addressFocused: Bool

    init(camera: Camera, onRemove: @escaping () -> Void) {
        self.camera = camera
        self.onRemove = onRemove
        var input = CameraInput(camera.streamURLString)
        input.requiresAuthentication = camera.authenticationRequired
            ?? (camera.streamURLString.isEmpty || input.address != camera.streamURLString)
        _input = State(initialValue: input)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cameraHeader

            Divider()
                .padding(.bottom, 16)

            VStack(alignment: .leading, spacing: 16) {
                CameraField(
                    title: "Name",
                    detail: "Shown on the camera tile"
                ) {
                    TextField("Front door", text: $camera.name)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("\(camera.cameraID.uuidString)-name")
                }

                Divider()

                CameraField(
                    title: "Camera address",
                    detail: "Enter an IP address or a complete HTTPS URL"
                ) {
                    if let endpointError {
                        Label(endpointError, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("\(camera.cameraID.uuidString)-error")
                    }

                    TextField("192.168.1.100", text: addressBinding)
                        .focused($addressFocused)
                        .onSubmit { addressFocused = false }
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("\(camera.cameraID.uuidString)-url")
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Camera requires authentication", isOn: $input.requiresAuthentication)
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier("\(camera.cameraID.uuidString)-auth")

                    if input.requiresAuthentication {
                        HStack(alignment: .top, spacing: 10) {
                            CameraField(title: "Username") {
                                TextField("Username", text: $input.username)
                                    .textFieldStyle(.roundedBorder)
                                    .accessibilityIdentifier("\(camera.cameraID.uuidString)-username")
                            }

                            CameraField(title: "Password") {
                                SecureField("Password", text: $input.password)
                                    .textFieldStyle(.roundedBorder)
                                    .accessibilityIdentifier("\(camera.cameraID.uuidString)-password")
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(
            .fill.quaternary,
            in: ConcentricRectangle(corners: .concentric(minimum: 12))
        )
        .onChange(of: input) {
            camera.authenticationRequired = input.requiresAuthentication
            camera.streamURLString = input.streamURL?.absoluteString ?? input.address
            endpointError = nil
            endpointProbeInput = input
        }
        .onChange(of: addressFocused) {
            if !addressFocused { input.address = CameraInput(input.address).address }
        }
        .task(id: endpointProbeInput) {
            guard let input = endpointProbeInput else { return }
            guard !input.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            do {
                try await Task.sleep(for: .milliseconds(700))
                guard let url = input.streamURL else {
                    endpointError = "Enter a valid camera address."
                    return
                }
                try await CameraEndpointCheck(url: url).check()
            } catch {
                guard !Task.isCancelled else { return }
                endpointError = (error as? CameraEndpointCheck.Failure)?.errorDescription
                    ?? "Could not reach the camera. Check the address and connection."
            }
        }
    }

    private var cameraHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "video.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 30, height: 30)
                .background(.tint.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(camera.name.isEmpty ? "New camera" : camera.name)
                    .font(.headline)
                    .lineLimit(1)
            }

            Spacer()

            Button(role: .destructive, action: onRemove) {
                Image(systemName: "trash")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .help("Remove camera")
            .accessibilityLabel("Remove camera")
            .accessibilityIdentifier("\(camera.cameraID.uuidString)-remove")
        }
        .padding(.bottom, 14)
    }

    private var addressBinding: Binding<String> {
        Binding(
            get: { input.address },
            set: { address in
                var updated = input
                updated.address = address
                updated.importCredentials()
                updated.address = address
                input = updated
            }
        )
    }
}

private struct CameraField<Content: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.medium))

                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsFocusDismissal: NSViewRepresentable {
    func makeNSView(context: Context) -> FocusView { FocusView() }
    func updateNSView(_ nsView: FocusView, context: Context) {}

    final class FocusView: NSView {
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                var hit = window.contentView?.hitTest(event.locationInWindow)
                while let view = hit {
                    if view is NSTextField || view is NSTextView { return event }
                    hit = view.superview
                }
                window.makeFirstResponder(nil)
                return event
            }
        }

        isolated deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
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

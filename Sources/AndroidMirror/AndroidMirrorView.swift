import AppKit
import SwiftUI

struct AndroidMirrorView: View {
    @EnvironmentObject private var model: AndroidMirrorModel
    @State private var claimedInitialInputFocus = false

    var body: some View {
        Group {
            if model.isVideoMaximized && !model.isMappingEditorPresented {
                maximizedFeed
            } else {
                standardLayout
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: model.refreshDevices) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh connected devices")

                Button(action: model.toggleStreaming) {
                    Image(systemName: model.isStreaming ? "pause.fill" : "play.fill")
                }
                .help(model.isStreaming ? "Pause screen preview" : "Start screen preview")
                .disabled(model.selectedSerial == nil)

                audioVolumeControl

                Button(action: model.toggleVideoMaximized) {
                    Image(systemName: model.isVideoMaximized
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right")
                }
                .help(model.isVideoMaximized ? "Restore window layout" : "Maximize video feed")
                .disabled(model.isMappingEditorPresented)

                Button(action: model.toggleMappingEditor) {
                    Image(systemName: "command")
                }
                .help("Toggle mapping editor (⌘K)")
            }
        }
        .onAppear {
            guard !claimedInitialInputFocus else { return }
            claimedInitialInputFocus = true
            model.claimInputFocus()
        }
    }

    private var standardLayout: some View {
        NavigationSplitView {
            List(selection: selectedDevice) {
                Section("Devices") {
                    ForEach(model.devices) { device in
                        HStack(spacing: 10) {
                            Image(systemName: device.isReady ? "iphone" : "iphone.slash")
                                .foregroundStyle(device.isReady ? .primary : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.title)
                                Text(device.serial)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tag(device.serial)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 250)
        } detail: {
            VStack(spacing: 0) {
                mirrorHeader
                Divider()
                if model.isMappingEditorPresented {
                    MappingEditorView()
                } else {
                    DeviceScreenView(image: model.frame, status: model.status)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private var maximizedFeed: some View {
        ZStack(alignment: .topTrailing) {
            DeviceScreenView(image: model.frame, status: model.status)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)

            Button(action: model.toggleVideoMaximized) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .padding(8)
                    .background(.black.opacity(0.62), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Restore window layout")
            .padding(14)
        }
    }

    private var audioVolumeControl: some View {
        HStack(spacing: 5) {
            Image(systemName: model.audioVolume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .foregroundStyle(.secondary)
            Slider(value: $model.audioVolume, in: 0...1)
                .frame(width: 88)
            Text("\(Int((model.audioVolume * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)
        }
        .help("Android audio volume on this Mac")
    }

    private var selectedDevice: Binding<String?> {
        Binding(
            get: { model.selectedSerial },
            set: { if let serial = $0 { model.selectDevice(serial) } }
        )
    }

    private var mirrorHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.on.rectangle")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.isMappingEditorPresented ? "Mapping editor" : (model.devices.first(where: { $0.serial == model.selectedSerial })?.title ?? "Android screen"))
                    .font(.headline)
                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if model.isOptionDragLocked {
                Label("Mouse locked", systemImage: "lock.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

private struct MappingEditorView: View {
    @EnvironmentObject private var model: AndroidMirrorModel

    var body: some View {
        HStack(spacing: 0) {
            MappingCanvas(image: model.frame)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            MappingInspector()
                .frame(width: 290)
        }
    }
}

private struct MappingCanvas: View {
    @EnvironmentObject private var model: AndroidMirrorModel
    let image: NSImage?

    var body: some View {
        GeometryReader { proxy in
            let imageAspect = image.map { max($0.size.width / $0.size.height, 0.01) } ?? (9.0 / 16.0)
            let canvasSize = fittedSize(in: proxy.size, aspect: imageAspect)

            ZStack {
                Color.black

                ZStack {
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.none)
                            .scaledToFill()
                            .frame(width: canvasSize.width, height: canvasSize.height)
                            .clipped()
                    } else {
                        Image(systemName: "rectangle.on.rectangle")
                            .font(.system(size: 40))
                            .foregroundStyle(.white.opacity(0.55))
                    }

                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(placementGesture(canvasSize: canvasSize))

                    ForEach(model.bindings) { binding in
                        BindingCircle(binding: binding, canvasSize: canvasSize)
                            .position(
                                x: canvasSize.width * binding.x,
                                y: canvasSize.height * binding.y
                            )
                            .allowsHitTesting(model.placementKind == nil)
                    }

                    ForEach(model.bindings.filter { $0.kind == .joystick }) { binding in
                        ForEach(JoystickSprintMarkerKind.allCases) { kind in
                            JoystickSprintMarker(binding: binding, canvasSize: canvasSize, kind: kind)
                                .allowsHitTesting(model.placementKind == nil)
                        }
                    }
                }
                .frame(width: canvasSize.width, height: canvasSize.height)
                .coordinateSpace(name: "mappingCanvas")

                if let placementKind = model.placementKind {
                    VStack(spacing: 6) {
                        Image(systemName: placementIcon(for: placementKind))
                            .font(.title2)
                        Text("Click the screen to place a \(placementKind.rawValue.lowercased()) area")
                            .font(.callout.weight(.semibold))
                        Text("Esc or Cancel returns to editing")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .allowsHitTesting(false)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private func placementIcon(for kind: TouchBindingKind) -> String {
        switch kind {
        case .tap: return "hand.tap.fill"
        case .drag: return "arrow.left.and.right.circle.fill"
        case .joystick: return "circle.grid.cross.fill"
        }
    }

    private func fittedSize(in size: CGSize, aspect: CGFloat) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }
        if size.width / size.height > aspect {
            return CGSize(width: size.height * aspect, height: size.height)
        }
        return CGSize(width: size.width, height: size.width / aspect)
    }

    private func placementGesture(canvasSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("mappingCanvas"))
            .onEnded { value in
                guard model.placementKind != nil,
                      abs(value.translation.width) < 3,
                      abs(value.translation.height) < 3 else { return }
                model.placeBinding(
                    x: Double(value.location.x / canvasSize.width),
                    y: Double(value.location.y / canvasSize.height)
                )
            }
    }
}

private enum JoystickSprintMarkerKind: CaseIterable, Identifiable, Hashable {
    case forward
    case left
    case right

    var id: Self { self }
}

private struct JoystickSprintMarker: View {
    @EnvironmentObject private var model: AndroidMirrorModel
    let binding: TouchBinding
    let canvasSize: CGSize
    let kind: JoystickSprintMarkerKind

    private var point: JoystickSprintPoint {
        switch kind {
        case .forward:
            return binding.joystickSprintPoint
                ?? JoystickSprintPoint(x: binding.x, y: max(binding.y - 0.25, 0.08))
        case .left:
            return binding.joystickSprintLeftPoint
                ?? JoystickSprintPoint(
                    x: min(max(binding.x - binding.radius * 0.8, 0), 1),
                    y: min(max(binding.y - binding.radius * 0.8, 0), 1)
                )
        case .right:
            return binding.joystickSprintRightPoint
                ?? JoystickSprintPoint(
                    x: min(max(binding.x + binding.radius * 0.8, 0), 1),
                    y: min(max(binding.y - binding.radius * 0.8, 0), 1)
                )
        }
    }

    private var shortcut: String {
        let keys = binding.joystickKeys ?? .wasd
        switch kind {
        case .forward: return "⇧\(keys.up.uppercased())"
        case .left: return "⇧\(keys.up.uppercased())+\(keys.left.uppercased())"
        case .right: return "⇧\(keys.up.uppercased())+\(keys.right.uppercased())"
        }
    }

    private var markerColor: Color {
        switch kind {
        case .forward: return .mint
        case .left: return .indigo
        case .right: return .blue
        }
    }

    private let markerSize = CGSize(width: 132, height: 34)

    var body: some View {
        Label("\(shortcut) Sprint", systemImage: "figure.run")
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(width: markerSize.width, height: markerSize.height)
            .background(markerColor.opacity(0.88), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(model.selectedBindingID == binding.id ? .white : markerColor, lineWidth: 2)
            }
            .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
            .contentShape(Capsule())
            .onTapGesture { model.selectedBindingID = binding.id }
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .named("mappingCanvas"))
                    .onChanged { value in
                        let x = Double(value.location.x / canvasSize.width)
                        let y = Double(value.location.y / canvasSize.height)
                        switch kind {
                        case .forward:
                            model.moveJoystickSprint(bindingID: binding.id, x: x, y: y)
                        case .left:
                            model.moveJoystickSprintDirection(bindingID: binding.id, direction: .left, x: x, y: y)
                        case .right:
                            model.moveJoystickSprintDirection(bindingID: binding.id, direction: .right, x: x, y: y)
                        }
                    }
            )
            .position(x: canvasSize.width * point.x, y: canvasSize.height * point.y)
            .help("Drag to place the \(shortcut) sprint target")
    }
}

private struct BindingCircle: View {
    @EnvironmentObject private var model: AndroidMirrorModel
    let binding: TouchBinding
    let canvasSize: CGSize

    private var diameter: CGFloat {
        CGFloat(binding.radius) * min(canvasSize.width, canvasSize.height) * 2
    }

    private var color: Color {
        switch binding.kind {
        case .tap: return .cyan
        case .drag: return .orange
        case .joystick: return .green
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.14))
            Circle()
                .stroke(color, lineWidth: model.selectedBindingID == binding.id ? 3.5 : 2)
            Circle()
                .stroke(.white.opacity(0.72), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .padding(5)
            if binding.kind == .joystick {
                joystickLabels
            } else {
                Text(binding.kind == .drag ? "⌥ Drag" : binding.key.uppercased())
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.65), in: Capsule())
            }
            Circle()
                .fill(color)
                .frame(width: 13, height: 13)
                .overlay(Circle().stroke(.white, lineWidth: 1))
                .offset(x: diameter * 0.34, y: diameter * 0.34)
                .highPriorityGesture(resizeGesture)
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .onTapGesture { model.selectedBindingID = binding.id }
        .gesture(moveGesture)
    }

    private var joystickLabels: some View {
        let keys = binding.joystickKeys ?? .wasd
        return ZStack {
            joystickKeyLabel(keys.up).offset(y: -diameter * 0.28)
            joystickKeyLabel(keys.left).offset(x: -diameter * 0.28)
            joystickKeyLabel(keys.down).offset(y: diameter * 0.28)
            joystickKeyLabel(keys.right).offset(x: diameter * 0.28)
            Image(systemName: "circle.fill")
                .font(.system(size: 7))
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    private func joystickKeyLabel(_ key: String) -> some View {
        Text(key.uppercased())
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .frame(minWidth: 22, minHeight: 19)
            .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 5))
    }

    private var moveGesture: some Gesture {
        DragGesture(coordinateSpace: .named("mappingCanvas"))
            .onChanged { value in
                model.selectedBindingID = binding.id
                model.moveBinding(
                    id: binding.id,
                    x: Double(value.location.x / canvasSize.width),
                    y: Double(value.location.y / canvasSize.height)
                )
            }
    }

    private var resizeGesture: some Gesture {
        DragGesture(coordinateSpace: .named("mappingCanvas"))
            .onChanged { value in
                let center = CGPoint(
                    x: canvasSize.width * binding.x,
                    y: canvasSize.height * binding.y
                )
                let distance = hypot(value.location.x - center.x, value.location.y - center.y)
                model.selectedBindingID = binding.id
                model.resizeBinding(id: binding.id, radius: Double(distance / min(canvasSize.width, canvasSize.height)))
            }
    }
}

private struct MappingInspector: View {
    @EnvironmentObject private var model: AndroidMirrorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Bindings")
                    .font(.title3.weight(.semibold))
                Spacer()
                Menu {
                    Button("Tap area") { model.beginPlacement(kind: .tap) }
                    Button("Drag area") { model.beginPlacement(kind: .drag) }
                    Button("Joystick area") { model.beginPlacement(kind: .joystick) }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .help("Add mapping area")

                Button(action: model.removeSelectedBinding) {
                    Image(systemName: "trash")
                }
                .help("Remove selected area")
                .disabled(model.selectedBindingID == nil)
            }

            if model.placementKind != nil {
                HStack(spacing: 8) {
                    Text("Click the preview to place it")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel", action: model.cancelPlacement)
                        .controlSize(.small)
                }
            }

            List(selection: $model.selectedBindingID) {
                ForEach(model.bindings) { binding in
                    HStack(spacing: 9) {
                        Image(systemName: bindingIcon(binding.kind))
                            .foregroundStyle(bindingColor(binding.kind))
                        Text(bindingTitle(binding))
                            .font(.body.monospaced())
                        Spacer()
                        Text(binding.kind.rawValue)
                            .foregroundStyle(.secondary)
                    }
                    .tag(binding.id)
                }
            }
            .frame(minHeight: 180)

            if let binding = selectedBinding {
                BindingInspector(binding: binding)
                    .id(binding.id)
            }
            Spacer()
        }
        .padding(14)
    }

    private var selectedBinding: TouchBinding? {
        model.bindings.first { $0.id == model.selectedBindingID }
    }

    private func bindingIcon(_ kind: TouchBindingKind) -> String {
        switch kind {
        case .tap: return "hand.tap"
        case .drag: return "arrow.left.and.right"
        case .joystick: return "circle.grid.cross"
        }
    }

    private func bindingColor(_ kind: TouchBindingKind) -> Color {
        switch kind {
        case .tap: return .cyan
        case .drag: return .orange
        case .joystick: return .green
        }
    }

    private func bindingTitle(_ binding: TouchBinding) -> String {
        switch binding.kind {
        case .tap: return binding.key.uppercased()
        case .drag: return "⌥ Drag"
        case .joystick: return "Joystick"
        }
    }
}

private struct BindingInspector: View {
    @EnvironmentObject private var model: AndroidMirrorModel
    @State private var binding: TouchBinding

    init(binding: TouchBinding) {
        _binding = State(initialValue: binding)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if binding.kind == .tap {
                TextField("Key", text: $binding.key)
                Text("Press this key outside the editor to tap the center of the circle.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if binding.kind == .drag {
                Label("Press Option to toggle mouse lock for this drag area.", systemImage: "option")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("The selected Drag area is used; if none is selected, the first Drag area is used.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Each touch starts at a random point inside the inner 30%; at the edge it restarts at another random inner point and continues.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                joystickKeyFields
                Text("Directions share one persistent touch. Two perpendicular keys move it to a diagonal point at the same radius.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Shift + Up, Shift + Up + Left, and Shift + Up + Right each have an independently draggable Sprint marker.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Text("Diameter \(Int(binding.radius * 200))%")
                Slider(value: $binding.radius, in: 0.03...0.45)
            }
        }
        .textFieldStyle(.roundedBorder)
        .onChange(of: binding) { updated in
            model.updateBinding(updated)
        }
    }

    private var joystickKeyFields: some View {
        let keys = Binding<JoystickKeys>(
            get: { binding.joystickKeys ?? .wasd },
            set: { binding.joystickKeys = $0 }
        )
        return Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 7) {
            GridRow {
                Text("Up")
                TextField("W", text: keys.up)
                Text("Down")
                TextField("S", text: keys.down)
            }
            GridRow {
                Text("Left")
                TextField("A", text: keys.left)
                Text("Right")
                TextField("D", text: keys.right)
            }
        }
    }
}

struct AndroidMirrorSettingsView: View {
    @EnvironmentObject private var model: AndroidMirrorModel

    var body: some View {
        Form {
            Section("Android Audio") {
                HStack {
                    Text("Playback volume")
                    Slider(value: $model.audioVolume, in: 0...1)
                    Text("\(Int((model.audioVolume * 100).rounded()))%")
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }
                Text("Audio is forwarded as low-latency raw PCM while the mirror is streaming.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Mouse Lock") {
                HStack {
                    Text("Sensitivity")
                    Slider(value: $model.mouseSensitivity, in: 0.25...3.0, step: 0.05)
                    Text(String(format: "%.2fx", model.mouseSensitivity))
                        .monospacedDigit()
                        .frame(width: 52, alignment: .trailing)
                }
                Text("Controls relative mouse movement while Option mouse lock is enabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Reset to 1.00x") {
                    model.mouseSensitivity = 1.0
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 480, height: 320)
    }
}

private struct DeviceScreenView: View {
    @EnvironmentObject private var model: AndroidMirrorModel
    let image: NSImage?
    let status: String

    var body: some View {
        GeometryReader { proxy in
            let imageAspect = image.map { max($0.size.width / $0.size.height, 0.01) } ?? (9.0 / 16.0)
            let canvasSize = fittedSize(in: proxy.size, aspect: imageAspect)

            ZStack {
                Color.black

                ZStack {
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.none)
                            .scaledToFill()
                            .frame(width: canvasSize.width, height: canvasSize.height)
                            .clipped()
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "iphone.and.arrow.forward")
                                .font(.system(size: 38))
                            Text(status)
                                .font(.callout)
                        }
                        .foregroundStyle(.white.opacity(0.7))
                    }

                    PreviewMouseCaptureView()

                    VStack {
                        Spacer()
                        Label("Click or drag directly on the phone screen", systemImage: "cursorarrow.click")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.black.opacity(0.62), in: Capsule())
                            .padding(12)
                    }
                    .allowsHitTesting(false)
                }
                .frame(width: canvasSize.width, height: canvasSize.height)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .onDisappear(perform: model.endDirectMouseTouch)
    }

    private func fittedSize(in size: CGSize, aspect: CGFloat) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }
        if size.width / size.height > aspect {
            return CGSize(width: size.height * aspect, height: size.height)
        }
        return CGSize(width: size.width, height: size.width / aspect)
    }

}

/// A persistent AppKit responder keeps a mouse drag alive while SwiftUI swaps
/// in freshly decoded video frames underneath it.
private struct PreviewMouseCaptureView: NSViewRepresentable {
    @EnvironmentObject private var model: AndroidMirrorModel

    func makeNSView(context: Context) -> PreviewMouseCaptureNSView {
        let view = PreviewMouseCaptureNSView()
        view.model = model
        return view
    }

    func updateNSView(_ nsView: PreviewMouseCaptureNSView, context: Context) {
        nsView.model = model
    }
}

private final class PreviewMouseCaptureNSView: NSView {
    weak var model: AndroidMirrorModel?
    private var dragSize: NSSize?
    override var acceptsFirstResponder: Bool { true }

    // Silently consume key events so AppKit does not play the alert sound
    // for keys that have no built-in meaning (or for a second key pressed
    // while one is already held).  The global event monitor in the model
    // handles the actual key-to-touch mapping.
    override func keyDown(with event: NSEvent) {}
    override func keyUp(with event: NSEvent) {}

    override func mouseDown(with event: NSEvent) {
        handleMouseDown(event)
    }

    override func rightMouseDown(with event: NSEvent) {
        handleMouseDown(event)
    }

    override func otherMouseDown(with event: NSEvent) {
        handleMouseDown(event)
    }

    private func handleMouseDown(_ event: NSEvent) {
        let button = mouseButtonName(event)
        window?.makeFirstResponder(self)

        // In mouse-lock mode, buttons are independent keymapped contacts.
        // They must never start a direct screen touch, which would terminate
        // the locked drag contact.
        if model?.isOptionDragLocked == true {
            model?.beginMouseButtonTouch(button: button)
            return
        }

        // Direct interaction with the preview is left-button only.
        guard button == "mouse1" else { return }

        let snapshot = bounds.size
        guard snapshot.width >= 100, snapshot.height >= 100 else {
            TouchTraceLogger.log("MOUSE DOWN rejected unstable bounds=\(bounds)")
            resetDragGeometry()
            return
        }
        dragSize = snapshot

        sendPoint(event, label: "MOUSE DOWN", action: .begin)
    }

    override func mouseDragged(with event: NSEvent) {
        guard model?.isOptionDragLocked != true else { return }
        sendPoint(event, label: "MOUSE DRAG", action: .move)
    }

    override func mouseUp(with event: NSEvent) {
        handleMouseUp(event)
    }

    override func rightMouseUp(with event: NSEvent) {
        handleMouseUp(event)
    }

    override func otherMouseUp(with event: NSEvent) {
        handleMouseUp(event)
    }

    private func handleMouseUp(_ event: NSEvent) {
        let button = mouseButtonName(event)
        // Always release a mapped button contact, even if Option was pressed
        // to leave mouse lock while the physical button was still held.
        model?.endMouseButtonTouch(button: button)
        if model?.isOptionDragLocked != true, button == "mouse1" {
            model?.endDirectMouseTouch()
        }
        TouchTraceLogger.log("MOUSE UP")
        resetDragGeometry()
    }

    private enum MouseTouchAction {
        case begin
        case move
    }

    private func sendPoint(_ event: NSEvent, label: String, action: MouseTouchAction) {
        guard let snapshot = dragSize,
              snapshot.width >= 100, snapshot.height >= 100 else {
            TouchTraceLogger.log("\(label) rejected without stable drag geometry")
            return
        }

        // convert(_:from: nil) resolves the event into this view's local
        // coordinate space, accounting for wherever SwiftUI has positioned
        // the view in the window at this exact moment.  Only the
        // normalisation divisor is frozen from mouseDown, so a mid-drag
        // SwiftUI resize cannot change the coordinate scale.
        let localPoint = convert(event.locationInWindow, from: nil)
        let rawX = Double(localPoint.x / snapshot.width)
        let rawY = Double(1 - localPoint.y / snapshot.height)

        // Reject out-of-range values instead of clamping them.  Clamping a
        // cursor excursion to 0 or 1 turns it into a full-screen spike.
        guard rawX.isFinite, rawY.isFinite,
              (0...1).contains(rawX), (0...1).contains(rawY) else {
            TouchTraceLogger.log("\(label) rejected outside bounds local=\(localPoint) dragSize=\(snapshot) raw=(\(rawX),\(rawY)) currentBounds=\(bounds)")
            return
        }

        let point = CGPoint(x: rawX, y: rawY)

        TouchTraceLogger.log("\(label) local=\(localPoint) dragSize=\(snapshot) normalized=(\(point.x),\(point.y)) delta=(\(event.deltaX),\(event.deltaY)) currentBounds=\(bounds)")
        switch action {
        case .begin:
            model?.beginDirectMouseTouch(x: point.x, y: point.y)
        case .move:
            model?.moveDirectMouseTouch(x: point.x, y: point.y)
        }
    }

    private func resetDragGeometry() {
        dragSize = nil
    }

    private func mouseButtonName(_ event: NSEvent) -> String {
        "mouse\(event.buttonNumber + 1)"
    }
}

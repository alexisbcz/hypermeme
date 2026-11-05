import SwiftUI

/// The live meme, with its text boxes to drag, resize and click on.
struct MemeCanvas: View {
    @Bindable var editor: MemeEditor

    var body: some View {
        if let preview = editor.preview {
            Image(decorative: preview, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .overlay {
                    GeometryReader { proxy in
                        ForEach($editor.document.boxes) { $box in
                            BoxHandle(
                                box: $box,
                                canvas: proxy.size,
                                isSelected: editor.selection == box.id,
                                select: { editor.selection = box.id }
                            )
                        }
                    }
                }
                .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
                .overlay(alignment: .bottomLeading) {
                    if editor.template.isVideo {
                        VideoBadge(duration: editor.template.duration)
                            .help("A video: the captions are drawn on every frame")
                    }
                }
        } else if editor.failed {
            ContentUnavailableView {
                Label("Couldn't Load the Image", systemImage: "wifi.exclamationmark")
            } actions: {
                Button("Try Again") { Task { await editor.load() } }
            }
        } else {
            ProgressView()
        }
    }
}

private struct BoxHandle: View {
    @Binding var box: TextBox
    let canvas: CGSize
    let isSelected: Bool
    let select: () -> Void

    @State private var start: TextBox?
    @State private var isHovered = false

    private var width: Double { box.width * canvas.width }
    private var height: Double { box.height * canvas.height }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.white.opacity(0.001))
                .gesture(move)
                .onTapGesture(perform: select)
            if isSelected || isHovered {
                Rectangle()
                    .strokeBorder(style: StrokeStyle(lineWidth: isSelected ? 1.5 : 1, dash: [5, 3]))
                    .foregroundStyle(isSelected ? Color.accentColor : .white.opacity(0.85))
                    .shadow(color: .black.opacity(0.5), radius: 1)
                    .allowsHitTesting(false)
            }
            if isSelected {
                ForEach(Corner.allCases) { corner in
                    Circle()
                        .fill(.white)
                        .stroke(Color.accentColor, lineWidth: 1.5)
                        .frame(width: 11, height: 11)
                        .padding(6)
                        .contentShape(.rect)
                        .offset(x: corner.x * width / 2, y: corner.y * height / 2)
                        .gesture(resize(corner))
                        .pointerStyle(.frameResize(position: corner.position))
                }
            }
        }
        .frame(width: max(width, 1), height: max(height, 1))
        .rotationEffect(.degrees(box.rotation))
        .position(x: (box.x + box.width / 2) * canvas.width, y: (box.y + box.height / 2) * canvas.height)
        .onHover { isHovered = $0 }
    }

    private var move: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                select()
                let origin = start ?? box
                start = origin
                box.x = min(max(origin.x + value.translation.width / canvas.width, -origin.width / 2), 1 - origin.width / 2)
                box.y = min(max(origin.y + value.translation.height / canvas.height, -origin.height / 2), 1 - origin.height / 2)
            }
            .onEnded { _ in start = nil }
    }

    private func resize(_ corner: Corner) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                let origin = start ?? box
                start = origin
                // The drag in the box's own axes, so rotated boxes follow the pointer.
                let radians = -origin.rotation * .pi / 180
                let dx = value.translation.width * cos(radians) - value.translation.height * sin(radians)
                let dy = value.translation.width * sin(radians) + value.translation.height * cos(radians)
                let minimum = 0.05
                let newWidth = max(origin.width + corner.x * dx / canvas.width, minimum)
                let newHeight = max(origin.height + corner.y * dy / canvas.height, minimum)
                box.width = newWidth
                box.height = newHeight
                if corner.x < 0 { box.x = origin.x + origin.width - newWidth } else { box.x = origin.x }
                if corner.y < 0 { box.y = origin.y + origin.height - newHeight } else { box.y = origin.y }
            }
            .onEnded { _ in start = nil }
    }
}

private enum Corner: CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight

    var id: Self { self }
    var x: Double { self == .topLeft || self == .bottomLeft ? -1 : 1 }
    var y: Double { self == .topLeft || self == .topRight ? -1 : 1 }

    var position: FrameResizePosition {
        switch self {
        case .topLeft: .topLeading
        case .topRight: .topTrailing
        case .bottomLeft: .bottomLeading
        case .bottomRight: .bottomTrailing
        }
    }
}

/// Every field for one text box.
struct BoxInspector: View {
    @Binding var box: TextBox
    let label: String
    let isSelected: Bool
    var focus: FocusState<TextBox.ID?>.Binding
    let select: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(label, text: $box.text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1 ... 4)
                .focused(focus, equals: box.id)
                .onChange(of: focus.wrappedValue) { _, new in
                    if new == box.id { select() }
                }
            if isSelected {
                HStack(spacing: 8) {
                    Picker("Font", selection: $box.font) {
                        ForEach(MemeFont.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 120)
                    ColorPicker("Text color", selection: hex(\.color), supportsOpacity: false)
                        .labelsHidden()
                        .help("Text color")
                    ColorPicker("Outline color", selection: hex(\.outline), supportsOpacity: false)
                        .labelsHidden()
                        .help("Outline color")
                    Toggle(isOn: $box.allCaps) { Image(systemName: "textformat.size.larger") }
                        .toggleStyle(.button)
                        .help("All capitals")
                    Toggle(isOn: $box.shadow) { Image(systemName: "shadow") }
                        .toggleStyle(.button)
                        .help("Soft shadow")
                    Spacer()
                    Button(role: .destructive, action: remove) { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Remove this text")
                }
                HStack(spacing: 8) {
                    Picker("Alignment", selection: $box.align) {
                        Image(systemName: "text.alignleft").tag(HorizontalAlign.left)
                        Image(systemName: "text.aligncenter").tag(HorizontalAlign.center)
                        Image(systemName: "text.alignright").tag(HorizontalAlign.right)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Picker("Vertical alignment", selection: $box.verticalAlign) {
                        Image(systemName: "arrow.up.to.line").tag(VerticalAlign.top)
                        Image(systemName: "arrow.up.and.down").tag(VerticalAlign.middle)
                        Image(systemName: "arrow.down.to.line").tag(VerticalAlign.bottom)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Image(systemName: "rotate.right")
                        .foregroundStyle(Color.subdued)
                    Slider(value: rotation, in: -180 ... 180)
                        .controlSize(.small)
                        .help("Rotation")
                }
            }
        }
    }

    /// Shown from -180 to 180; imgflip's layouts use 0 to 360.
    private var rotation: Binding<Double> {
        Binding(
            get: { box.rotation > 180 ? box.rotation - 360 : box.rotation },
            set: { box.rotation = abs($0) < 2 ? 0 : $0 }
        )
    }

    private func hex(_ path: WritableKeyPath<TextBox, String>) -> Binding<Color> {
        Binding(
            get: {
                let value = UInt32(box[keyPath: path].dropFirst(), radix: 16) ?? 0
                return Color(red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
            },
            set: { color in
                let resolved = color.resolve(in: EnvironmentValues())
                let channel = { (value: Float) in Int((min(max(value, 0), 1) * 255).rounded()) }
                box[keyPath: path] = String(format: "#%02X%02X%02X", channel(resolved.red), channel(resolved.green), channel(resolved.blue))
            }
        )
    }
}

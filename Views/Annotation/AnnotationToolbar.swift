import SwiftUI

struct AnnotationToolbar: View {
    @Binding var annotationState: AnnotationState
    let onSave: () -> Void
    let onSaveWithoutAnnotation: () -> Void
    let onCancel: () -> Void

    private let colors: [Color] = [.red, .orange, .yellow, .green, .blue, .purple, .white, .black]
    private let lineWidths: [CGFloat] = [1, 2, 3, 5, 8]

    var body: some View {
        HStack(spacing: 0) {
            toolButtons
            Divider().frame(height: 28).padding(.horizontal, 8)
            colorButtons
            Divider().frame(height: 28).padding(.horizontal, 8)
            lineWidthButtons
            Divider().frame(height: 28).padding(.horizontal, 8)
            undoRedoButtons

            if annotationState.currentTool == .text {
                Divider().frame(height: 28).padding(.horizontal, 8)
                textInput
            }

            Spacer()

            actionButtons
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var toolButtons: some View {
        HStack(spacing: 4) {
            ForEach(AnnotationTool.allCases) { tool in
                Button {
                    annotationState.currentTool = tool
                } label: {
                    Image(systemName: tool.iconName)
                        .font(.system(size: 14))
                        .frame(width: 28, height: 28)
                        .background(annotationState.currentTool == tool ? Color.accentColor.opacity(0.2) : Color.clear)
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .help(tool.rawValue)
            }
        }
    }

    private var colorButtons: some View {
        HStack(spacing: 3) {
            ForEach(colors, id: \.self) { color in
                Circle()
                    .fill(color)
                    .frame(width: 18, height: 18)
                    .overlay(
                        Circle()
                            .stroke(annotationState.currentColor == color ? Color.primary : Color.clear, lineWidth: 2)
                    )
                    .overlay(
                        Circle()
                            .stroke(Color.gray.opacity(0.3), lineWidth: 0.5)
                    )
                    .onTapGesture {
                        annotationState.currentColor = color
                    }
            }
        }
    }

    private var lineWidthButtons: some View {
        HStack(spacing: 4) {
            ForEach(lineWidths, id: \.self) { width in
                Circle()
                    .fill(Color.primary)
                    .frame(width: width + 4, height: width + 4)
                    .frame(width: 24, height: 24)
                    .background(annotationState.currentLineWidth == width ? Color.accentColor.opacity(0.2) : Color.clear)
                    .cornerRadius(6)
                    .onTapGesture {
                        annotationState.currentLineWidth = width
                    }
            }
        }
    }

    private var undoRedoButtons: some View {
        HStack(spacing: 4) {
            Button {
                annotationState.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 14))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(!annotationState.canUndo)
            .help("Undo")

            Button {
                annotationState.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
                    .font(.system(size: 14))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(!annotationState.canRedo)
            .help("Redo")

            Button {
                annotationState.clearAll()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(!annotationState.canUndo)
            .help("Clear all")
        }
    }

    private var textInput: some View {
        TextField("Enter text...", text: $annotationState.currentText)
            .textFieldStyle(.roundedBorder)
            .frame(width: 150)
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            Button("Cancel") {
                onCancel()
            }
            .buttonStyle(.bordered)

            if !annotationState.items.isEmpty {
                Button("Save Original") {
                    onSaveWithoutAnnotation()
                }
                .buttonStyle(.bordered)
            }

            Button("Save") {
                onSave()
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

struct AnnotationEditorView: View {
    let image: NSImage
    @Binding var annotationState: AnnotationState
    let onSave: (NSImage) -> Void
    let onSaveOriginal: () -> Void
    let onCancel: () -> Void

    @State private var canvasDisplaySize: CGSize = .zero

    var body: some View {
        VStack(spacing: 0) {
            AnnotationToolbar(
                annotationState: $annotationState,
                onSave: {
                    if annotationState.items.isEmpty {
                        onSave(image)
                    } else {
                        let annotatedImage = AnnotationCanvasView.renderAnnotatedImage(
                            image: image,
                            annotationState: annotationState,
                            canvasSize: canvasDisplaySize
                        )
                        onSave(annotatedImage)
                    }
                },
                onSaveWithoutAnnotation: onSaveOriginal,
                onCancel: onCancel
            )

            AnnotationCanvasView(
                image: image,
                annotationState: $annotationState,
                canvasDisplaySize: $canvasDisplaySize
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

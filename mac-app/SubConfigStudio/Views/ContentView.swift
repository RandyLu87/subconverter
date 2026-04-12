import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 16) {
            SourcesPanel(model: model)
                .frame(minWidth: 360, maxWidth: 420)

            PresetPanel(model: model)
                .frame(minWidth: 260, maxWidth: 300)

            PreviewPanel(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(16)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $model.showingAddSubscriptionSheet) {
            AddSubscriptionSheet(model: model)
                .frame(width: 460)
                .padding(20)
        }
    }
}

private struct SourcesPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            List {
                ForEach(model.sortedSources) { source in
                    SourceRow(
                        source: source,
                        isFirst: source.order == 0,
                        isLast: source.order == model.sortedSources.count - 1,
                        onToggle: { enabled in
                            var updated = source
                            updated.enabled = enabled
                            model.updateSource(updated)
                        },
                        onMoveUp: { model.moveSource(source, offset: -1) },
                        onMoveDown: { model.moveSource(source, offset: 1) },
                        onDelete: { model.removeSource(source) }
                    )
                }
            }
            .listStyle(.inset)

            HStack {
                Button("Add Subscription") {
                    model.showingAddSubscriptionSheet = true
                }

                Button("Import YAML") {
                    Task {
                        await model.openImportPanel()
                    }
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sources")
                .font(.title2.weight(.semibold))
            Text("Mix subscription URLs and local Clash YAML files. Order is preserved during merge.")
                .foregroundStyle(.secondary)
        }
    }
}

private struct SourceRow: View {
    let source: SourceItem
    let isFirst: Bool
    let isLast: Bool
    let onToggle: (Bool) -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Toggle("", isOn: Binding(
                    get: { source.enabled },
                    set: onToggle
                ))
                .labelsHidden()

                VStack(alignment: .leading, spacing: 4) {
                    Text(source.name)
                        .font(.headline)
                    Text(source.kind.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                statusBadge
            }

            Text(source.displayValue)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if let lastError = source.lastError, source.lastStatus == .error {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            HStack {
                Button {
                    onMoveUp()
                } label: {
                    Image(systemName: "arrow.up")
                }
                .disabled(isFirst)

                Button {
                    onMoveDown()
                } label: {
                    Image(systemName: "arrow.down")
                }
                .disabled(isLast)

                Spacer()

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 6)
    }

    private var statusBadge: some View {
        Text(source.lastStatus.title)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch source.lastStatus {
        case .idle:
            return .secondary
        case .ready:
            return .green
        case .error:
            return .red
        }
    }
}

private struct PresetPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Preset")
                .font(.title2.weight(.semibold))

            Text("Built-in direct rules for private, mainland domains, and mainland IP ranges are always enabled.")
                .foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Country Auto Groups")
                    .font(.headline)
                ForEach(CountryBucket.allCases, id: \.self) { bucket in
                    Label(bucket.groupName, systemImage: "flag.2.crossed")
                        .font(.subheadline)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Core Groups")
                    .font(.headline)
                ForEach(PresetBuilder.policyGroups, id: \.self) { group in
                    Label(group, systemImage: "checkmark.seal")
                        .font(.subheadline)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Routing Model")
                    .font(.headline)
                Text("Core groups")
                Text("Other")
                Text("Default")
                Text("Country auto groups")
                Text("Each policy group: Default -> DIRECT -> country auto groups -> all proxies")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            Spacer()

            if let lastGeneratedProxyCount = model.lastGeneratedProxyCount {
                Text("Last generated proxies: \(lastGeneratedProxyCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct PreviewPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Preview & Export")
                        .font(.title2.weight(.semibold))
                    Text(model.statusMessage)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Generate") {
                    Task {
                        await model.generate()
                    }
                }
                .disabled(!model.canGenerate || model.isGenerating)

                Button("Export YAML") {
                    model.exportPreview()
                }
                .disabled(model.previewText.isEmpty)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))

                if model.previewText.isEmpty {
                    Text("Generate a configuration to preview the final Clash YAML.")
                        .foregroundStyle(.secondary)
                } else {
                    CodePreviewTextView(text: model.previewText)
                        .padding(8)
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct CodePreviewTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.string = text

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else {
            return
        }

        if textView.string != text {
            textView.string = text
        }
    }
}

private struct AddSubscriptionSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Subscription")
                .font(.title3.weight(.semibold))

            TextField("Display name", text: $model.newSubscriptionName)
            TextField("Subscription URL", text: $model.newSubscriptionURL, axis: .vertical)
                .lineLimit(3...6)

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button("Save") {
                    model.addSubscription()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

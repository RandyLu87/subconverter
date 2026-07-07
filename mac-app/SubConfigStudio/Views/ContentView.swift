import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            Picker("", selection: $model.appMode) {
                Text("生成 (订阅→Clash)").tag(AppMode.generate)
                Text("转换 (Clash→sing-box)").tag(AppMode.convert)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 440)

            if model.appMode == .generate {
                HStack(spacing: 16) {
                    SourcesPanel(model: model)
                        .frame(minWidth: 360, maxWidth: 420)

                    PresetPanel(model: model)
                        .frame(minWidth: 260, maxWidth: 300)

                    PreviewPanel(model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ConversionView(model: model)
            }
        }
        .padding(16)
        .background(Color(nsColor: .windowBackgroundColor))
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

            Button("Import YAML") {
                Task {
                    await model.openImportPanel()
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
            Text("Import local Clash YAML files. Order is preserved during merge.")
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
            ScrollView {
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
                        Text("Direct Overrides")
                            .font(.headline)
                        Text("One entry per line. Bare domains default to DOMAIN-SUFFIX,<domain>,DIRECT.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        TextEditor(text: Binding(
                            get: { model.customDirectRulesText },
                            set: { model.updateCustomDirectRulesText($0) }
                        ))
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 120)
                        .padding(8)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                        Text("Examples: appykt.com, DOMAIN,foo.example,DIRECT, DOMAIN-SUFFIX,bar.com,DIRECT")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
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
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

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

private struct ConversionView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 16) {
            inputPanel
                .frame(minWidth: 360, maxWidth: 460)
            outputPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var inputPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Clash 配置输入")
                        .font(.title2.weight(.semibold))
                    Text("导入或粘贴一份 Clash / Mihomo YAML。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            TextEditor(text: $model.conversionInput)
                .font(.system(.caption, design: .monospaced))
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack {
                Button("导入 Clash YAML") {
                    model.importClashForConversion()
                }
                Spacer()
                Button("转换") {
                    Task { await model.convert() }
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(model.isConverting || model.conversionInput.isEmpty)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var outputPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("sing-box 输出")
                        .font(.title2.weight(.semibold))
                    Text(model.statusMessage)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("导出") {
                    model.exportConversion()
                }
                .disabled(model.conversionOutput.isEmpty)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
                if model.conversionOutput.isEmpty {
                    Text("转换后在此预览 sing-box config.json。")
                        .foregroundStyle(.secondary)
                } else {
                    CodePreviewTextView(text: model.conversionOutput)
                        .padding(8)
                }
            }
            .frame(maxHeight: .infinity)

            if !model.conversionMessages.isEmpty {
                reportView
                    .frame(height: 150)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var reportView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("转换报告")
                .font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.conversionMessages) { message in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: icon(for: message.level))
                                .foregroundStyle(color(for: message.level))
                            Text(message.text)
                                .font(.caption)
                                .textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func icon(for level: ConversionLevel) -> String {
        switch level {
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle"
        }
    }

    private func color(for level: ConversionLevel) -> Color {
        switch level {
        case .error: return .red
        case .warning: return .orange
        case .info: return .secondary
        }
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


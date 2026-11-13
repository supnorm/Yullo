import SwiftUI
import Translation

@MainActor struct AppleTranslationAssetsView: View {
    @StateObject private var model: AppleTranslationAssets
    private let localizedLanguageNames: Bool
    private let close: () -> Void
    private let systemDownloadsEnabled: Bool
    @State private var search = ""
    @State private var selectedTarget: String?
    @State private var visibleLanguages: [AppleTranslationAssetLanguage] = []

    init(source: String, target: String, localizedLanguageNames: Bool, close: @escaping () -> Void) {
        _model = StateObject(wrappedValue: AppleTranslationAssets(source: source, target: target))
        self.localizedLanguageNames = localizedLanguageNames
        self.close = close
        systemDownloadsEnabled = true
    }

    #if YULLO_TESTING
        init(model: AppleTranslationAssets, localizedLanguageNames: Bool = true, close: @escaping () -> Void = {}) {
            _model = StateObject(wrappedValue: model)
            self.localizedLanguageNames = localizedLanguageNames
            self.close = close
            systemDownloadsEnabled = false
        }
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L10n.tr("Apple translation languages")).font(.system(size: 22, weight: .semibold))
                Spacer(minLength: 12)
                Button(L10n.tr("Refresh"), action: model.refresh)
                    .disabled(model.loadingCatalog || model.downloadRequest != nil)
                    .accessibilityIdentifier("apple-assets-refresh")
            }
            Text(L10n.tr("For offline translation. Your settings don’t change."))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Text(L10n.tr("Translate from")).fontWeight(.medium)
                Spacer(minLength: 12)
                Picker(
                    L10n.tr("Translate from"),
                    selection: Binding(get: { model.source }, set: { model.selectSource($0) })
                ) {
                    Text(L10n.tr("Choose a source language")).tag(Optional<String>.none)
                    ForEach(model.languages) { language in
                        Text(name(language.id)).tag(Optional(language.id))
                    }
                }.labelsHidden().frame(maxWidth: 260)
                    .disabled(model.loadingCatalog || model.downloadRequest != nil)
                    .accessibilityIdentifier("apple-assets-source")
                    .assetBounds("source")
            }
            if let request = model.downloadRequest {
                if systemDownloadsEnabled {
                    AppleTranslationAssetDownloadHost(model: model, request: request) {
                        operation(request)
                    }.id(request.id)
                } else {
                    operation(request)
                }
            } else if let feedback = model.feedback {
                feedbackCard(feedback)
            }
            TextField(L10n.tr("Search target languages"), text: $search).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("apple-assets-search")
                .disabled(model.source == nil || model.loadingCatalog)
            List(selection: $selectedTarget) {
                ForEach(model.source == nil ? [] : visibleLanguages) { language in
                    row(language).tag(language.id)
                }
            }.listStyle(.inset).overlay {
                if model.loadingCatalog {
                    ProgressView(L10n.tr("Checking available languages…"))
                } else if let error = model.catalogError {
                    VStack(spacing: 10) {
                        Text(L10n.tr("Couldn’t load Apple translation languages."))
                        if !error.isEmpty { Text(error).font(.system(size: 12)).foregroundStyle(.secondary) }
                        Button(L10n.tr("Retry"), action: model.reloadCatalog)
                    }.padding(20)
                } else if model.source == nil {
                    Text(L10n.tr("Choose a source language to see translation pairs."))
                        .foregroundStyle(.secondary).padding(20)
                } else if visibleLanguages.isEmpty {
                    Text(L10n.tr("No matching languages.")).foregroundStyle(.secondary).padding(20)
                }
            }.accessibilityIdentifier("apple-assets-list").assetBounds("list")
            HStack(alignment: .center, spacing: 14) {
                Text(L10n.tr("Status is per direction. macOS shares these with other apps."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(L10n.tr("Done"), action: close).keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("apple-assets-done")
                    .assetBounds("done")
            }
        }.font(.system(size: 13)).padding(24)
            .frame(minWidth: 560, idealWidth: 660, maxWidth: 820, minHeight: 440, idealHeight: 560, maxHeight: 760)
            .environment(\.locale, L10n.locale)
            .onAppear {
                model.activate()
                selectedTarget = model.preferredTarget
            }
            .onDisappear { model.deactivate() }
            .onChange(of: model.preferredTarget) { _, target in selectedTarget = target }
            .task(
                id: AssetFilterRequest(
                    languages: model.languages, source: model.source, target: model.preferredTarget,
                    search: search, localized: localizedLanguageNames, interface: L10n.language)
            ) {
                await Task.yield()
                guard !Task.isCancelled else { return }
                updateVisibleLanguages()
            }
    }

    private func name(_ id: String) -> String {
        AppleTranslationAssetLanguage(id: id).name(localized: localizedLanguageNames)
    }
    private func updateVisibleLanguages() {
        guard model.source != nil else {
            visibleLanguages = []
            return
        }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let values = model.languages.map { ($0, name($0.id)) }.filter {
            query.isEmpty || $0.1.localizedStandardContains(query) || $0.0.id.localizedStandardContains(query)
        }.sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }.map(\.0)
        guard let target = model.preferredTarget, let preferred = values.first(where: { $0.id == target }) else {
            visibleLanguages = values
            return
        }
        visibleLanguages = [preferred] + values.filter { $0.id != target }
    }
    private func pairTitle(_ pair: AppleTranslationAssetPair) -> String {
        "\(name(pair.source)) → \(name(pair.target))"
    }

    private func row(_ language: AppleTranslationAssetLanguage) -> some View {
        let pair = AppleTranslationAssetPair(source: model.source ?? "", target: language.id)
        let status = model.statuses[language.id] ?? .checking
        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(name(pair.source)).lineLimit(1)
                    Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(name(pair.target)).fontWeight(.medium).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .environment(\.layoutDirection, .leftToRight)
                    .accessibilityElement(children: .ignore).accessibilityLabel(pairTitle(pair))
                Label(statusTitle(status), systemImage: statusSymbol(status))
                    .font(.system(size: 12)).foregroundStyle(status == .installed ? Color.green : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            switch status {
            case .supported:
                Button(L10n.tr("Download")) { _ = model.beginDownload(language.id) }
                    .buttonStyle(.link).disabled(model.downloadRequest != nil)
                    .accessibilityLabel(L10n.format("Download %@", pairTitle(pair)))
                    .accessibilityIdentifier("apple-assets-download-" + language.id)
            case .unavailable(let error):
                Button(L10n.tr("Retry")) { model.retry(language.id) }.buttonStyle(.link)
                    .disabled(model.downloadRequest != nil).help(error)
                    .accessibilityLabel(L10n.format("Check %@", pairTitle(pair)))
            case .checking:
                ProgressView().controlSize(.small).accessibilityLabel(L10n.tr("Checking download status…"))
            case .installed, .unsupported: EmptyView()
            }
        }.padding(.vertical, 6)
    }

    private func statusTitle(_ status: AppleTranslationAssetStatus) -> String {
        switch status {
        case .checking: return L10n.tr("Checking…")
        case .installed: return L10n.tr("Downloaded")
        case .supported: return L10n.tr("Download available")
        case .unsupported: return L10n.tr("This direction isn’t supported")
        case .unavailable: return L10n.tr("Couldn’t check download status")
        }
    }
    private func statusSymbol(_ status: AppleTranslationAssetStatus) -> String {
        switch status {
        case .installed: return "checkmark.circle.fill"
        case .supported: return "arrow.down.circle"
        case .checking: return "clock"
        case .unsupported: return "minus.circle"
        case .unavailable: return "exclamationmark.circle"
        }
    }
    private func operation(_ request: AppleTranslationAssetDownloadRequest) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(pairTitle(request.pair)).fontWeight(.medium)
                        Text(
                            L10n.tr(
                                model.verifyingDownload ? "Checking download status…" : "Requesting language download…")
                        )
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Button(L10n.tr("Cancel"), action: model.cancelDownload)
                }
                Text(
                    L10n.tr(
                        "macOS asks before downloading. Closing this request may leave an approved download running.")
                )
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
        }.accessibilityIdentifier("apple-assets-operation").assetBounds("operation")
    }
    private func feedbackCard(_ feedback: AppleTranslationAssetFeedback) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text(pairTitle(feedback.pair)).fontWeight(.medium)
                switch feedback.outcome {
                case .installed:
                    Label(
                        L10n.tr("Downloaded and ready for offline translation."), systemImage: "checkmark.circle.fill")
                case .notReady:
                    Text(L10n.tr("Not downloaded yet. macOS may still be downloading it. Refresh to check again."))
                case .failed(let message):
                    Text(L10n.tr("The language download couldn’t be completed."))
                    if !message.isEmpty {
                        ScrollView {
                            Text(message).foregroundStyle(.secondary).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 56)
                    }
                case .cancelled:
                    Text(L10n.tr("Request closed. An approved download may continue in macOS."))
                }
            }.font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
        }.accessibilityIdentifier("apple-assets-feedback").assetBounds("feedback")
    }
}

private struct AssetFilterRequest: Equatable {
    let languages: [AppleTranslationAssetLanguage]
    let source: String?
    let target: String?
    let search: String
    let localized: Bool
    let interface: String
}

private extension View {
    @ViewBuilder func assetBounds(_ name: String) -> some View {
        #if YULLO_TESTING
            background(AppleAssetBoundsProbe(name: name))
        #else
            self
        #endif
    }
}

#if YULLO_TESTING
    private struct AppleAssetBoundsProbe: NSViewRepresentable {
        let name: String
        final class Probe: NSView { override func hitTest(_ point: NSPoint) -> NSView? { nil } }
        func makeNSView(context: Context) -> NSView {
            let view = Probe(frame: .zero)
            view.identifier = NSUserInterfaceItemIdentifier("apple-assets-bound-" + name)
            view.setAccessibilityElement(false)
            return view
        }
        func updateNSView(_ view: NSView, context: Context) {}
    }
#endif

@MainActor private struct AppleTranslationAssetDownloadHost<Content: View>: View {
    @ObservedObject var model: AppleTranslationAssets
    let request: AppleTranslationAssetDownloadRequest
    let content: () -> Content
    var body: some View {
        content().translationTask(
            TranslationSession.Configuration(
                source: Locale.Language(identifier: request.pair.source),
                target: Locale.Language(identifier: request.pair.target))
        ) { session in
            guard model.owns(request) else {
                session.cancel()
                return
            }
            await withTaskCancellationHandler {
                do {
                    try await session.prepareTranslation()
                    try Task.checkCancellation()
                    model.prepared(request)
                } catch {
                    guard !Task.isCancelled else { return }
                    model.failed(request, error: error)
                }
            } onCancel: {
                session.cancel()
            }
        }
    }
}

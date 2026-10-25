import SwiftUI

/// The device-sync audit trail: what this phone has sent to the brain, read back
/// FROM the brain. Summary counts per source + a paged recent log. Backed by
/// `GET /v1/ingest/status` / `/v1/ingest/recent`; shows a clear "not on this
/// node yet" state when an older node answers 404.
struct SyncHistoryView: View {
    let connection: Connection

    @State private var summary: [HearthAPI.IngestSummary] = []
    @State private var log: [HearthAPI.IngestLogEntry] = []
    @State private var offset = 0
    @State private var loading = false
    @State private var canLoadMore = true
    @State private var pending = false
    @State private var error: String?
    @State private var loadedOnce = false

    private var api: HearthAPI { HearthAPI(baseURL: connection.baseURL) }
    private let pageSize = 50

    var body: some View {
        List {
            if pending {
                Section {
                    Label("This node doesn’t keep a sync history yet (GET /v1/ingest/status). Update the node and this screen fills in.",
                          systemImage: "clock.badge")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.red)
            }
            if !summary.isEmpty {
                Section("Landed in your brain") {
                    ForEach(summary) { s in
                        LabeledContent(label(s.source)) {
                            VStack(alignment: .trailing) {
                                Text("\(s.count)")
                                Text(s.lastIngestAt.map { "last " + DeviceSync.relative(iso($0)) } ?? "—")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if !log.isEmpty {
                Section("Recent batches") {
                    ForEach(log) { e in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(label(e.source)).font(.subheadline)
                                Spacer()
                                Text(DeviceSync.relative(iso(e.ts))).font(.caption2).foregroundStyle(.secondary)
                            }
                            Text("\(e.kind) · \(e.count) · \(e.ref)")
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .onAppear { if e.id == log.last?.id { Task { await loadMore() } } }
                    }
                    if loading { HStack { Spacer(); ProgressView(); Spacer() } }
                }
            }
        }
        .navigationTitle("Sync history")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await reload() }
        .task { if !loadedOnce { loadedOnce = true; await reload() } }
        .tint(HearthTheme.accent)
    }

    private func reload() async {
        error = nil; pending = false; offset = 0; canLoadMore = true; log = []
        do {
            summary = try await api.ingestStatus(pat: connection.deviceToken)
            await loadMore()
        } catch is HearthAPI.SyncStatusUnavailable {
            pending = true
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func loadMore() async {
        guard canLoadMore, !loading, !pending else { return }
        loading = true; defer { loading = false }
        do {
            let page = try await api.ingestRecent(pat: connection.deviceToken, offset: offset, limit: pageSize)
            log.append(contentsOf: page)
            offset += page.count
            canLoadMore = page.count == pageSize
        } catch is HearthAPI.SyncStatusUnavailable {
            pending = true; canLoadMore = false
        } catch { canLoadMore = false }
    }

    private func label(_ source: String) -> String {
        switch source {
        case "apple-health": return "Apple Health"
        case "photos": return "Photo locations"
        default: return source
        }
    }

    private func iso(_ s: String) -> Date? {
        let f = ISO8601DateFormatter(); return f.date(from: s)
    }
}

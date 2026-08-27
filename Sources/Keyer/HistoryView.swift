import SwiftUI
import WaveCore

@MainActor
private final class HistoryStore: ObservableObject {
    @Published var records: [TranscriptArchiveRecord] = []
    @Published var isLoading = false
    @Published var message = ""

    private let remote = RemoteTranscriptStore()

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            records = try await remote.records().sorted { $0.createdAt > $1.createdAt }
            message = ""
        } catch {
            message = "Couldn’t load history"
        }
    }
}

private enum HistorySection: String, CaseIterable, Identifiable {
    case meetings
    case dictations

    var id: Self { self }
    var title: String { rawValue.capitalized }
    var icon: String { self == .meetings ? "video" : "waveform" }
    var kind: TranscriptArchiveRecord.Kind { self == .meetings ? .meeting : .dictation }
}

struct HistoryView: View {
    @StateObject private var store = HistoryStore()
    @State private var section: HistorySection? = .meetings
    @State private var selection: UUID?
    @State private var search = ""

    var body: some View {
        NavigationSplitView {
            List(HistorySection.allCases, selection: $section) { item in
                Label(item.title, systemImage: item.icon).tag(item)
            }
            .navigationTitle("Keyer")
            .navigationSplitViewColumnWidth(min: 160, ideal: 190, max: 240)
        } content: {
            Group {
                if store.isLoading && store.records.isEmpty {
                    ProgressView()
                } else if !store.message.isEmpty {
                    ContentUnavailableView(
                        store.message,
                        systemImage: "exclamationmark.triangle",
                        description: Text("Check the server connection and try again.")
                    )
                } else if filteredRecords.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else {
                    List(selection: $selection) {
                        ForEach(filteredRecords, id: \.id) { record in
                            HistoryRow(record: record)
                                .tag(record.id)
                        }
                    }
                }
            }
            .navigationTitle(section?.title ?? "History")
            .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 440)
        } detail: {
            if let record = selectedRecord {
                HistoryDetail(record: record)
            } else {
                ContentUnavailableView("Select a recording", systemImage: "doc.text")
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search history")
        .toolbar {
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await store.load() } }
            }
        }
        .task { await store.load() }
        .onChange(of: section) { _, _ in selection = filteredRecords.first?.id }
        .onChange(of: store.records) { _, _ in
            if selection == nil { selection = filteredRecords.first?.id }
        }
        .frame(minWidth: 760, minHeight: 480)
    }

    private var filteredRecords: [TranscriptArchiveRecord] {
        guard let section else { return [] }
        let records = store.records.filter { $0.kind == section.kind }
        guard !search.isEmpty else { return records }
        return records.filter {
            $0.historyTitle.localizedCaseInsensitiveContains(search)
                || $0.finalText.localizedCaseInsensitiveContains(search)
                || $0.originalText.localizedCaseInsensitiveContains(search)
        }
    }

    private var selectedRecord: TranscriptArchiveRecord? {
        store.records.first { $0.id == selection }
    }
}

private struct HistoryRow: View {
    let record: TranscriptArchiveRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(record.historyTitle).font(.headline).lineLimit(2)
            Text(record.historyPreview).foregroundStyle(.secondary).lineLimit(2)
            HStack(spacing: 6) {
                Text(record.createdAt, format: .relative(presentation: .named))
                Text("·")
                Text(record.createdAt, format: .dateTime.hour().minute())
                if record.audioDurationSeconds > 0 {
                    Spacer()
                    Label(record.durationText, systemImage: record.kind == .meeting ? "waveform" : "mic")
                        .labelStyle(.titleAndIcon)
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5)
    }
}

private struct HistoryDetail: View {
    let record: TranscriptArchiveRecord
    @State private var meetingPage = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(record.createdAt, format: .dateTime.weekday(.wide).month(.wide).day().hour().minute())
                        .foregroundStyle(.secondary)
                    Text(record.historyTitle).font(.largeTitle.bold()).textSelection(.enabled)
                }

                if record.kind == .meeting {
                    Picker("View", selection: $meetingPage) {
                        Text("Summary").tag(0)
                        Text("Transcript").tag(1)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }

                Text(.init(displayedText))
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: 720, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(32)
        }
        .navigationTitle(record.kind.displayName)
    }

    private var displayedText: String {
        if record.kind == .meeting, meetingPage == 1 { return record.originalText }
        return record.kind == .meeting ? record.meetingSummary : record.finalText
    }
}

private extension TranscriptArchiveRecord {
    var historyTitle: String {
        if kind == .meeting,
           let heading = finalText.split(separator: "\n").first(where: { $0.hasPrefix("# ") }) {
            return String(heading.dropFirst(2))
        }
        let line = finalText.split(whereSeparator: \.isNewline).first.map(String.init) ?? kind.displayName
        return line.count > 80 ? String(line.prefix(77)) + "…" : line
    }

    var historyPreview: String {
        let source = kind == .meeting ? meetingSummary : finalText
        return source.replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var meetingSummary: String {
        let withoutTitle = finalText.split(separator: "\n", omittingEmptySubsequences: false)
            .drop(while: { $0.hasPrefix("# ") || $0.isEmpty })
        if let transcriptIndex = withoutTitle.firstIndex(where: { $0 == "## Transcript" }) {
            return withoutTitle[..<transcriptIndex].joined(separator: "\n")
        }
        return withoutTitle.joined(separator: "\n")
    }

    var durationText: String {
        let seconds = max(0, Int(audioDurationSeconds.rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

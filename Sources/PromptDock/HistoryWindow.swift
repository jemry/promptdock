import PromptDockCore
import SwiftUI

/// 调用历史查看窗口（spec 10）：最近 200 条成功动作，展开看输入/输出全文，可复制、清空。
struct HistoryView: View {
    let entries: [HistoryEntry]
    var onCopy: (String) -> Void
    var onClear: () -> Void

    var body: some View {
        Group {
            if entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath").font(.title).foregroundStyle(.secondary)
                    Text("还没有调用历史").foregroundStyle(.secondary)
                    Text("在 prompts.yaml 里设 keep_history: true 开启记录（会保存输入与输出全文）")
                        .font(.caption).foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(entries) { entry in
                    DisclosureGroup {
                        historyDetail(entry)
                    } label: {
                        historyLabel(entry)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .tint(Color.dockAccent)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive, action: onClear) { Label("清空", systemImage: "trash") }
                    .disabled(entries.isEmpty)
            }
        }
    }

    private func historyLabel(_ entry: HistoryEntry) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).font(.system(size: 13, weight: .medium))
                Text(entry.input.prefix(60).replacingOccurrences(of: "\n", with: " ⏎ "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Self.timeFormatter.string(from: entry.createdAt))
                    .font(.caption).foregroundStyle(.secondary)
                Text(entry.target).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private func historyDetail(_ entry: HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            labeled("输入", entry.input)
            Divider()
            HStack {
                Text("输出").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { onCopy(entry.output) } label: { Label("复制输出", systemImage: "doc.on.doc") }
                    .controlSize(.small)
            }
            ScrollView {
                Text(entry.output)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: 260)
        }
        .padding(.vertical, 4)
    }

    private func labeled(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.3)))
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}

/// 历史窗口控制器：单例复用，每次打开重新读取最近记录。
@MainActor
final class HistoryWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    let host: NSHostingView<HistoryView>
    private(set) var isVisible = false

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "调用历史"
        window.isReleasedWhenClosed = false
        host = NSHostingView(rootView: HistoryView(entries: [], onCopy: { _ in }, onClear: {}))
        window.contentView = host
        super.init()
        window.delegate = self
        window.center()
    }

    func show(entries: [HistoryEntry], onCopy: @escaping (String) -> Void, onClear: @escaping () -> Void) {
        host.rootView = HistoryView(entries: entries, onCopy: onCopy, onClear: onClear)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        isVisible = true
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { isVisible = false }
    }
}

import SwiftUI

struct ContentView: View {
    @StateObject private var controller = WriteController()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    FramePreview(frame: controller.preview)
                } header: {
                    Text("書き込む画像（400×300）")
                }

                Section {
                    Button {
                        controller.start()
                    } label: {
                        Label("EZ Sign に書き込む", systemImage: "wave.3.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.phase.isRunning)

                    Text(controller.phase.title)
                        .foregroundStyle(statusColor)
                    if case let .sending(sent, total) = controller.phase {
                        ProgressView(value: Double(sent), total: Double(total))
                    }
                }

                Section {
                    Picker("画素の並び", selection: $controller.layout) {
                        ForEach(PixelLayout.allCases) { layout in
                            Text(layout.rawValue).tag(layout)
                        }
                    }
                    Toggle("切れたらつなぎ直す", isOn: $controller.reconnectOnLoss)
                    Toggle("接続 17 秒で先につなぎ直す", isOn: $controller.reconnectBeforeLimit)
                } header: {
                    Text("設定")
                } footer: {
                    Text("4.2 インチは row-mirror で正しく表示されることを確認済みです。"
                         + "iPhone は接続を約 20 秒で切るので、描画の途中でつなぎ直します。")
                }
                .disabled(controller.phase.isRunning)

                Section {
                    Button("ログをコピー") {
                        controller.copyLog()
                    }
                    .disabled(controller.log.isEmpty)
                    ForEach(Array(controller.log.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                    }
                } header: {
                    Text("ログ")
                }
            }
            .navigationTitle("EZ Sign 書き込みテスト")
        }
    }

    private var statusColor: Color {
        switch controller.phase {
        case .failed: return .red
        case .done: return .green
        default: return .primary
        }
    }
}

/// Frame をそのままの画素で表示する（拡大してもぼかさない）。
struct FramePreview: View {
    let frame: Frame

    var body: some View {
        if let image = frame.makeCGImage() {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .aspectRatio(CGFloat(frame.width) / CGFloat(frame.height), contentMode: .fit)
                .border(Color.secondary)
        }
    }
}

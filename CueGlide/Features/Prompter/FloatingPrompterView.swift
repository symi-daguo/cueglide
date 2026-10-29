import SwiftUI
import AVFoundation
import SwiftData

/// 悬浮提词入口。启动后浮窗会盖在其他应用之上，可以边看稿边用系统相机拍摄。
struct FloatingPrompterView: View {

    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Query(sort: [SortDescriptor(\Script.updatedAt, order: .reverse)]) private var scripts: [Script]

    @State private var controller = FloatingPrompterController()
    @State private var selected: Script?

    private var current: Script? { selected ?? scripts.first }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    explainer
                    preview
                    scriptRow
                    if case .failed(let message) = controller.state {
                        errorBanner(message)
                    }
                    actionButton
                    tips
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 40)
            }
            .background(Theme.canvas)
            .navigationTitle("悬浮提词")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        controller.stop()
                        dismiss()
                    }
                }
            }
            .onAppear {
                if let current {
                    controller.prepare(
                        script: current,
                        display: settings.display,
                        scroll: settings.scroll
                    )
                }
            }
            .task {
                guard ProcessInfo.processInfo.arguments.contains("-autoPiP") else { return }
                try? await Task.sleep(for: .milliseconds(600))
                controller.start()
            }
            .onDisappear {
                controller.stop()
            }
        }
    }

    // MARK: - 说明

    private var explainer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("把提词浮在相机之上")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("启动后会出现一个小浮窗，切换到系统相机或其他拍摄应用时它仍然可见。读稿时不用来回切应用。")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    // MARK: - 预览

    private var preview: some View {
        ZStack {
            Color.black
            LayerHost(layer: controller.displayLayer)
                .aspectRatio(9.0 / 16.0, contentMode: .fit)
        }
        .frame(height: 320)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 0.5)
        }
        .overlay(alignment: .topLeading) {
            Text("浮窗画面预览")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .padding(10)
        }
    }

    // MARK: - 台本

    private var scriptRow: some View {
        Menu {
            ForEach(scripts) { script in
                Button(script.title.isEmpty ? "未命名台本" : script.title) {
                    selected = script
                    controller.prepare(
                        script: script,
                        display: settings.display,
                        scroll: settings.scroll
                    )
                }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.brand)
                    .padding(8)
                    .background(Theme.brandSoft, in: .rect(cornerRadius: 9))

                VStack(alignment: .leading, spacing: 3) {
                    Text(current?.title.isEmpty == false ? current!.title : "未命名台本")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(current.map { "\(Format.count($0.characterCount)) 字" } ?? "还没有台本")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }

                Spacer()

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(14)
            .background(Theme.surface, in: .rect(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Theme.hairline, lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 操作

    private var actionButton: some View {
        Button {
            if controller.state.isRunning {
                controller.stop()
            } else {
                controller.start()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: controller.state.isRunning ? "stop.fill" : "pip.fill")
                    .font(.system(size: 14, weight: .semibold))
                Text(controller.state.isRunning ? "停止悬浮" : "开始悬浮提词")
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(
                controller.state.isRunning ? Theme.danger : Theme.brand,
                in: .rect(cornerRadius: 14, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(current == nil)
        .opacity(current == nil ? 0.5 : 1)
    }

    private var tips: some View {
        VStack(alignment: .leading, spacing: 8) {
            tipRow("1", "点开始后，浮窗会先出现在本应用里")
            tipRow("2", "按下 Home 或切换到相机应用，浮窗继续跟随")
            tipRow("3", "浮窗内可暂停、快进，也可以在系统里拖动位置")
        }
        .padding(.top, 4)
    }

    private func tipRow(_ index: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(index)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.brand)
                .frame(width: 16, height: 16)
                .background(Theme.brandSoft, in: .circle)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
            Text(message)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Theme.danger)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.danger.opacity(0.1), in: .rect(cornerRadius: 12))
    }
}

/// 承载画中画用的 AVSampleBufferDisplayLayer。
private struct LayerHost: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> UIView {
        let view = LayerContainerView()
        view.backgroundColor = .black
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        view.hosted = layer
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard let container = uiView as? LayerContainerView else { return }
        container.hosted = layer
        if layer.superlayer !== container.layer {
            layer.removeFromSuperlayer()
            container.layer.addSublayer(layer)
        }
        layer.frame = container.bounds
    }
}

private final class LayerContainerView: UIView {
    var hosted: CALayer?

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hosted?.frame = bounds
        CATransaction.commit()
    }
}

#Preview {
    FloatingPrompterView()
        .environment(AppSettings())
        .modelContainer(for: Script.self, inMemory: true)
}

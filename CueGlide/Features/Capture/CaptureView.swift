import SwiftUI
import AVFoundation

/// 提词拍摄。相机画面在下，提词文字浮在上面，录出来的视频只有画面不含字幕。
struct CaptureView: View {

    @State private var viewModel: CaptureViewModel
    @Environment(\.dismiss) private var dismiss

    init(script: Script, display: DisplayConfig, scroll: ScrollConfig) {
        _viewModel = State(
            initialValue: CaptureViewModel(script: script, display: display, scroll: scroll)
        )
    }

    private var prompter: PrompterViewModel { viewModel.prompter }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.ignoresSafeArea()

                if viewModel.isAvailable {
                    CameraPreview(session: viewModel.camera.session)
                        .ignoresSafeArea()
                } else {
                    Color.black.ignoresSafeArea()
                }

                // 相机不可用时提词器本身仍然可用，只是录不了，所以文字层不藏
                promptLayer

                overlayChrome
            }
            .onAppear {
                prompter.configureVoice(localeIdentifier: "")
                prompter.updateViewport(proxy.size)
                UIApplication.shared.isIdleTimerDisabled = true
                Task { await viewModel.prepare() }
            }
            .onDisappear {
                viewModel.teardown()
                UIApplication.shared.isIdleTimerDisabled = false
            }
            .onChange(of: proxy.size) { _, newValue in
                prompter.updateViewport(newValue)
            }
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }

    // MARK: - 提词层

    private var promptLayer: some View {
        PrompterHostViewRepresentable(renderer: prompter.renderer)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                // 只在底部压暗，给控制条让出对比度；顶部保持全亮，首行才看得清
                LinearGradient(
                    colors: [.clear, .black.opacity(0.75)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 220)
                .allowsHitTesting(false)
            }
            .allowsHitTesting(false)
    }

    // MARK: - 相机不可用

    private var unavailableNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "camera.metering.unknown")
                .font(.system(size: 14, weight: .medium))
            VStack(alignment: .leading, spacing: 2) {
                Text("相机用不了，仍可读稿")
                    .font(.system(size: 12, weight: .semibold))
                if case .failed(let message) = viewModel.phase {
                    Text(message)
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                        .opacity(0.8)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(12)
        .background(.black.opacity(0.78), in: .rect(cornerRadius: 12))
        .padding(.horizontal, 16)
    }

    // MARK: - 顶部与底部

    private var overlayChrome: some View {
        VStack {
            HStack(spacing: 12) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular, in: .circle)
                .accessibilityLabel("关闭拍摄")

                if viewModel.isRecording {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(.red)
                            .frame(width: 8, height: 8)
                        Text(viewModel.elapsedLabel)
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(.black.opacity(0.45), in: .capsule)
                }

                Spacer()

                Button {
                    Task { await viewModel.switchCamera() }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular, in: .circle)
                .accessibilityLabel("切换前后摄像头")
                .opacity(viewModel.isRecording ? 0.4 : 1)
                .disabled(viewModel.isRecording)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.top, 54)

            Spacer()

            if !viewModel.isAvailable {
                unavailableNotice
                    .padding(.bottom, 10)
            }

            if let message = viewModel.lastSavedMessage {
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .background(.black.opacity(0.55), in: .capsule)
                    .padding(.bottom, 10)
            }

            bottomBar
                .padding(.horizontal, 16)
                .padding(.bottom, 44)
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                Text(viewModel.script.title.isEmpty ? "未命名台本" : viewModel.script.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(prompter.progressLabel)
                    .font(.system(size: 11).monospacedDigit())
                    .opacity(0.7)
            }
            .foregroundStyle(.white)

            HStack(alignment: .center, spacing: 20) {
                smallButton(
                    prompter.engine.isRunning ? "pause.fill" : "play.fill",
                    label: prompter.engine.isRunning ? "暂停提词" : "播放提词"
                ) {
                    prompter.togglePlayback()
                }

                recordButton

                smallButton("character", label: "放大字号") {
                    prompter.adjustFontSize(4)
                }
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    private var recordButton: some View {
        Button {
            viewModel.toggleRecording()
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(.white.opacity(0.85), lineWidth: 3)
                    .frame(width: 68, height: 68)
                if viewModel.isRecording {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.red)
                        .frame(width: 26, height: 26)
                } else {
                    Circle()
                        .fill(.red)
                        .frame(width: 54, height: 54)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(viewModel.isRecording ? "停止录制" : "开始录制")
        .accessibilityValue(viewModel.isRecording ? viewModel.elapsedLabel : "")
        .disabled(viewModel.phase == .saving || !viewModel.isAvailable)
        .opacity((viewModel.phase == .saving || !viewModel.isAvailable) ? 0.4 : 1)
    }

    private func smallButton(
        _ symbol: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - 宿主视图

private struct PrompterHostViewRepresentable: UIViewRepresentable {
    let renderer: PrompterRenderer

    func makeUIView(context: Context) -> PrompterHostView {
        renderer.hostView
    }

    func updateUIView(_ uiView: PrompterHostView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PrompterHostView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewContainer {
        let view = PreviewContainer()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(view.previewLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewContainer, context: Context) {
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
            uiView.setNeedsLayout()
        }
    }
}

private final class PreviewContainer: UIView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()
    }
}

import SwiftUI
import AVFoundation
import UIKit

/// 提词拍摄。相机画面在下，提词文字浮在上面，录出来的视频只有画面不含字幕。
struct CaptureView: View {

    @State private var viewModel: CaptureViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var appSettings
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// 手动锁定的拍摄方向。为 nil 时跟随界面方向。
    @State private var forcedOrientation: UIInterfaceOrientation?

    init(script: Script, display: DisplayConfig, scroll: ScrollConfig) {
        _viewModel = State(
            initialValue: CaptureViewModel(script: script, display: display, scroll: scroll)
        )
    }

    private var prompter: PrompterViewModel { viewModel.prompter }

    /// 紧凑高度＝横屏。按钮内边距按它收，横屏时才不会压掉画面。
    private var isCompactHeight: Bool { verticalSizeClass == .compact }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.ignoresSafeArea()

                if viewModel.isAvailable {
                    CameraPreview(
                        controller: viewModel.camera,
                        forcedOrientation: forcedOrientation
                    )
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
                UIApplication.shared.isIdleTimerDisabled = appSettings.keepScreenAwake
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
            // 控制区必须完全盖住：`.mask` 对 UIViewRepresentable 内部渲染不生效，
            // 只能靠叠加层。渐变的尾部直接到纯黑，最下面几行文字彻底隐去，
            // 按钮区才是干净的——拍摄时看的本来就是阅读线附近，底部几行不在视野里。
            .overlay(alignment: .bottom) {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black.opacity(0.9), location: 0.34),
                        .init(color: .black, location: 0.48)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 300)
                .allowsHitTesting(false)
            }
            .allowsHitTesting(false)
    }

    // MARK: - 相机不可用

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

                // 横竖切换：不点它时跟随界面方向，点一次锁到横屏，再点恢复
                Button {
                    forcedOrientation = forcedOrientation == nil ? .landscapeRight : nil
                } label: {
                    Image(systemName: forcedOrientation == nil ? "rectangle.portrait" : "rectangle")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular, in: .circle)
                .accessibilityLabel(forcedOrientation == nil ? "锁定横屏拍摄" : "恢复跟随界面方向")

                if !viewModel.isAvailable {
                    HStack(spacing: 5) {
                        Image(systemName: "camera.metering.unknown")
                            .font(.system(size: 11, weight: .medium))
                        Text("相机不可用")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(.black.opacity(0.5), in: .capsule)
                    .accessibilityLabel("相机不可用，仍可读稿但不能录制")
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
            .padding(.top, isCompactHeight ? 16 : 54)

            Spacer()

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
                // 横屏下屏宽接近 900pt，控制条拉满会显得松散；
                // 限宽居中，和提词列宽的处理保持一致。
                .frame(maxWidth: isCompactHeight ? 460 : .infinity)
                .padding(.horizontal, 16)
                .padding(.bottom, isCompactHeight ? 10 : 24)
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                stepChip(
                    title: "字号",
                    value: "\(Int(prompter.display.fontSize))",
                    minus: { prompter.adjustFontSize(-4) },
                    plus: { prompter.adjustFontSize(4) }
                )
                stepChip(
                    title: "语速",
                    value: prompter.scroll.speedLabel,
                    minus: { prompter.stepSpeed(-1) },
                    plus: { prompter.stepSpeed(1) }
                )
            }

            mainRow
        }
    }

    /// 字号与语速各是一个独立胶囊：减号、当前值、加号。
    /// 不做成滑块，拍摄时手在动，点按比拖拽可靠。
    private func stepChip(
        title: String,
        value: String,
        minus: @escaping () -> Void,
        plus: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 0) {
            chipButton("minus", label: "减小\(title)", action: minus)

            VStack(spacing: 1) {
                Text(value)
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                Text(title)
                    .font(.system(size: 9))
                    .opacity(0.55)
            }
            .frame(minWidth: 44)

            chipButton("plus", label: "增大\(title)", action: plus)
        }
        .foregroundStyle(.white)
        .frame(height: 40)
        .background(.black.opacity(0.62), in: .capsule)
        .background(.ultraThinMaterial, in: .capsule)
        .overlay {
            Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 0.5)
        }
    }

    private func chipButton(
        _ symbol: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// 主操作区只放三样：播控、快门、切换镜头。
    /// 参数调节在上一行，视觉上有主次，不会像之前那样六个图标挤成一排。
    private var mainRow: some View {
        HStack(spacing: 26) {
            iconButton(
                viewModel.isVoiceActive ? "waveform.circle.fill" : "waveform.circle",
                label: viewModel.isVoiceActive ? "关闭语音跟读" : "开启语音跟读"
            ) {
                viewModel.toggleVoice()
            }

            iconButton(
                prompter.engine.isRunning ? "pause.fill" : "play.fill",
                label: prompter.engine.isRunning ? "暂停提词" : "播放提词"
            ) {
                prompter.togglePlayback()
            }

            shutterButton

            iconButton("arrow.triangle.2.circlepath.camera", label: "切换前后摄像头") {
                Task { await viewModel.switchCamera() }
            }
            .opacity(viewModel.isRecording ? 0.35 : 1)
            .disabled(viewModel.isRecording)
        }
    }

    /// 快门沿用系统相机的视觉：白色圆环 + 内圆，录制中内圆收成红色方块。
    private var shutterButton: some View {
        Button {
            viewModel.toggleRecording()
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(.white, lineWidth: 4)
                    .frame(width: 72, height: 72)
                if viewModel.isRecording {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(.red)
                        .frame(width: 30, height: 30)
                } else {
                    Circle()
                        .fill(.red)
                        .frame(width: 58, height: 58)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(viewModel.isRecording ? "停止录制" : "开始录制")
        .accessibilityValue(viewModel.isRecording ? viewModel.elapsedLabel : "")
        .disabled(viewModel.phase == .saving || !viewModel.isAvailable)
        .opacity((viewModel.phase == .saving || !viewModel.isAvailable) ? 0.4 : 1)
    }

    private func iconButton(
        _ symbol: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 50, height: 50)
                .contentShape(Rectangle())
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
    let controller: CameraController
    let forcedOrientation: UIInterfaceOrientation?

    func makeUIView(context: Context) -> PreviewContainer {
        let view = PreviewContainer()
        view.controller = controller
        view.apply(forcedOrientation: forcedOrientation)
        view.previewLayer.session = controller.session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(view.previewLayer)
        // 预览层要交给控制器：RotationCoordinator 的预览角度依赖它，
        // 不传的话横过来预览还是竖的。
        controller.attachPreviewLayer(view.previewLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewContainer, context: Context) {
        if uiView.previewLayer.session !== controller.session {
            uiView.previewLayer.session = controller.session
            uiView.setNeedsLayout()
        }
        uiView.apply(forcedOrientation: forcedOrientation)
    }
}

private final class PreviewContainer: UIView {
    let previewLayer = AVCaptureVideoPreviewLayer()
    weak var controller: CameraController?
    private var forcedOrientation: UIInterfaceOrientation?
    private var lastApplied: UIInterfaceOrientation?

    /// 手动锁定方向。传 nil 恢复跟随界面。
    func apply(forcedOrientation: UIInterfaceOrientation?) {
        guard self.forcedOrientation != forcedOrientation else { return }
        self.forcedOrientation = forcedOrientation
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()

        // 手动锁定优先；否则跟随界面方向。iOS 26 起 interfaceOrientation 废弃，
        // 用 effectiveGeometry 反映实际生效的方向（含分屏与方向锁定后的结果）。
        let target = forcedOrientation
            ?? window?.windowScene?.effectiveGeometry.interfaceOrientation
        guard let target, target != lastApplied else { return }
        lastApplied = target
        controller?.updateRotation(interfaceOrientation: target)
    }
}

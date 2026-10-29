import SwiftUI
import UIKit

/// 提词页。全屏沉浸，文字层可镜像，控制层永远正向。
struct PrompterView: View {

    @State private var viewModel: PrompterViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var dragStartToken: Int = 0

    init(script: Script, display: DisplayConfig, scroll: ScrollConfig) {
        _viewModel = State(initialValue: PrompterViewModel(script: script, display: display, scroll: scroll))
    }

    private var background: Color {
        Color(uiColor: viewModel.display.palette.background)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                background.ignoresSafeArea()

                PrompterTextHost(renderer: viewModel.renderer)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .scaleEffect(
                        x: viewModel.display.mirror.flipsHorizontally ? -1 : 1,
                        y: viewModel.display.mirror.flipsVertically ? -1 : 1
                    )
                    .clipped()

                fadeMasks

                gestureLayer

                if viewModel.display.showsReadingGuide {
                    readingGuide(in: proxy.size)
                }

                overlayChrome(in: proxy.size)

                countdownOverlay
            }
            .onAppear {
                viewModel.updateViewport(proxy.size)
                UIApplication.shared.isIdleTimerDisabled = true
                if ProcessInfo.processInfo.arguments.contains("-autoPlay") {
                    viewModel.togglePlayback()
                }
            }
            .onDisappear {
                viewModel.saveProgress()
                UIApplication.shared.isIdleTimerDisabled = false
            }
            .onChange(of: proxy.size) { _, newSize in
                viewModel.updateViewport(newSize)
            }
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }

    // MARK: - 渐隐

    private var fadeMasks: some View {
        Color.clear
            .overlay(alignment: .top) {
                LinearGradient(
                    stops: [
                        .init(color: background, location: 0),
                        .init(color: background, location: 0.68),
                        .init(color: background.opacity(0), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 122)
            }
            .overlay(alignment: .bottom) {
                LinearGradient(
                    stops: [
                        .init(color: background.opacity(0), location: 0),
                        .init(color: background, location: 0.38),
                        .init(color: background, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(maxWidth: .infinity)
                .frame(height: 260)
            }
            .allowsHitTesting(false)
    }

    // MARK: - 手势

    private var gestureLayer: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                viewModel.togglePlayback()
            }
            .onTapGesture {
                if viewModel.controlsVisible {
                    withAnimation(.smooth(duration: 0.22)) {
                        viewModel.controlsVisible = false
                    }
                } else {
                    viewModel.showControls()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 14)
                    .onChanged { value in
                        let perToken = max(viewModel.renderer.metrics.pointsPerToken, 4)
                        let deltaTokens = Double(value.translation.height) / perToken
                        viewModel.seekToStartOfScreen(atViewportY: value.startLocation.y)
                        viewModel.nudge(tokens: -deltaTokens)
                    }
            )
    }

    // MARK: - 阅读线

    private func readingGuide(in size: CGSize) -> some View {
        let y = size.height * viewModel.display.readingLine.viewportRatio
        return Rectangle()
            .fill(Color(uiColor: viewModel.display.palette.highlight).opacity(0.35))
            .frame(height: 0.5)
            .offset(y: y - size.height / 2)
            .allowsHitTesting(false)
    }

    // MARK: - 顶部与底部

    private func overlayChrome(in size: CGSize) -> some View {
        VStack {
            HStack(spacing: 12) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 38, height: 38)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular, in: .circle)

                Spacer()

                Button {
                    var next = viewModel.display
                    next.mirror = next.mirror == .none ? .horizontal : .none
                    viewModel.applyDisplay(next)
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 38, height: 38)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular, in: .circle)
            }
            .padding(.horizontal, 16)
            .padding(.top, 46)

            Spacer()

            if viewModel.controlsVisible {
                controlBar
                    .padding(.horizontal, 16)
                    .padding(.bottom, 44)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .foregroundStyle(Color(uiColor: viewModel.display.palette.foreground))
    }

    private var controlBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Text(viewModel.script.title.isEmpty ? "未命名台本" : viewModel.script.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .layoutPriority(1)
                Text("·")
                    .opacity(0.4)
                Text(viewModel.progressLabel)
                    .font(.system(size: 11).monospacedDigit())
                Spacer(minLength: 4)
                Text("剩余 \(formatted(viewModel.remainingSeconds))")
                    .font(.system(size: 11).monospacedDigit())
                    .opacity(0.7)
            }
            .padding(.horizontal, 2)

            ProgressView(value: viewModel.engine.progress)
                .tint(Color(uiColor: viewModel.display.palette.highlight))
                .progressViewStyle(.linear)

            HStack(spacing: 8) {
                controlButton("backward.end.fill") {
                    viewModel.restart()
                }
                controlButton(viewModel.engine.isRunning ? "pause.fill" : "play.fill", prominent: true) {
                    viewModel.togglePlayback()
                }
                controlButton("minus") {
                    viewModel.adjustFontSize(-4)
                }
                controlButton("plus") {
                    viewModel.adjustFontSize(4)
                }
                controlButton("slider.horizontal.3") {
                    viewModel.showsSettings = true
                }
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .sheet(isPresented: $viewModel.showsSettings) {
            PrompterSettingsSheet(viewModel: viewModel)
                .presentationDetents([.medium, .large])
                .presentationBackground(.regularMaterial)
        }
    }

    private func controlButton(_ symbol: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: prominent ? 20 : 16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background {
                    if prominent {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(uiColor: viewModel.display.palette.highlight))
                    }
                }
                .foregroundStyle(
                    prominent
                        ? Color(uiColor: viewModel.display.palette.background)
                        : Color(uiColor: viewModel.display.palette.foreground)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 倒计时

    @ViewBuilder
    private var countdownOverlay: some View {
        if viewModel.engine.countdownRemaining > 0 {
            Text("\(viewModel.engine.countdownRemaining)")
                .font(.system(size: 120, weight: .bold, design: .rounded))
                .foregroundStyle(Color(uiColor: viewModel.display.palette.highlight))
                .transition(.scale.combined(with: .opacity))
                .allowsHitTesting(false)
        }
    }

    private func formatted(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - UIKit 宿主

private struct PrompterTextHost: UIViewRepresentable {
    let renderer: PrompterRenderer

    func makeUIView(context: Context) -> PrompterHostView {
        renderer.hostView
    }

    func updateUIView(_ uiView: PrompterHostView, context: Context) {}

    /// UIViewRepresentable 没有固有尺寸，不显式声明的话 SwiftUI 可能给 0 高度。
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PrompterHostView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}

// MARK: - 参数面板

private struct PrompterSettingsSheet: View {
    @Bindable var viewModel: PrompterViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("显示") {
                    Picker("配色", selection: paletteBinding) {
                        ForEach(PromptPalette.allCases, id: \.self) { palette in
                            Text(palette.displayName).tag(palette)
                        }
                    }
                    Picker("镜像", selection: mirrorBinding) {
                        ForEach(MirrorMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    Picker("阅读线", selection: readingLineBinding) {
                        ForEach(ReadingLinePosition.allCases) { pos in
                            Text(pos.displayName).tag(pos)
                        }
                    }
                    Toggle("显示阅读参考线", isOn: readingGuideBinding)
                }

                Section("滚动") {
                    Picker("模式", selection: modeBinding) {
                        ForEach(ScrollMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    if viewModel.scroll.mode == .constant {
                        slider(
                            title: "速度",
                            value: $viewModel.scroll.pointsPerSecond,
                            range: 8...300,
                            unit: "pt/s",
                            format: "%.0f"
                        )
                    }
                    if viewModel.scroll.mode == .wpm {
                        slider(
                            title: "语速",
                            value: $viewModel.scroll.wordsPerMinute,
                            range: 80...480,
                            unit: "字/分",
                            format: "%.0f"
                        )
                    }
                    if viewModel.scroll.mode == .timed {
                        slider(
                            title: "总时长",
                            value: $viewModel.scroll.targetDuration,
                            range: 15...1800,
                            unit: "秒",
                            format: "%.0f"
                        )
                    }
                    Stepper("倒计时 \(viewModel.scroll.countdown) 秒", value: $viewModel.scroll.countdown, in: 0...10)
                }
            }
            .navigationTitle("提词设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .onChange(of: viewModel.scroll) { _, newValue in
                viewModel.applyScroll(newValue)
            }
        }
    }

    private func slider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        unit: String,
        format: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format) + " " + unit)
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    private var paletteBinding: Binding<PromptPalette> {
        Binding(
            get: { viewModel.display.palette },
            set: { new in
                var next = viewModel.display
                next.palette = new
                viewModel.applyDisplay(next)
            }
        )
    }

    private var mirrorBinding: Binding<MirrorMode> {
        Binding(
            get: { viewModel.display.mirror },
            set: { new in
                var next = viewModel.display
                next.mirror = new
                viewModel.applyDisplay(next)
            }
        )
    }

    private var readingLineBinding: Binding<ReadingLinePosition> {
        Binding(
            get: { viewModel.display.readingLine },
            set: { new in
                var next = viewModel.display
                next.readingLine = new
                viewModel.applyDisplay(next)
            }
        )
    }

    private var readingGuideBinding: Binding<Bool> {
        Binding(
            get: { viewModel.display.showsReadingGuide },
            set: { new in
                var next = viewModel.display
                next.showsReadingGuide = new
                viewModel.applyDisplay(next)
            }
        )
    }

    private var modeBinding: Binding<ScrollMode> {
        Binding(
            get: { viewModel.scroll.mode },
            set: { new in
                var next = viewModel.scroll
                next.mode = new
                viewModel.applyScroll(next)
            }
        )
    }
}

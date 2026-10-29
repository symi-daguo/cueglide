import SwiftUI
import UIKit

/// 提词页。全屏沉浸，文字层可镜像，控制层永远正向。
struct PrompterView: View {

    @State private var viewModel: PrompterViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var appSettings
    @State private var dragStartToken: Int = 0
    private let autoStartVoice: Bool

    init(script: Script, display: DisplayConfig, scroll: ScrollConfig, autoStartVoice: Bool = false) {
        _viewModel = State(initialValue: PrompterViewModel(script: script, display: display, scroll: scroll))
        self.autoStartVoice = autoStartVoice
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
                viewModel.onRequestExit = { dismiss() }
                viewModel.configureVoice(localeIdentifier: appSettings.speechLocaleIdentifier)
                viewModel.updateViewport(proxy.size)
                UIApplication.shared.isIdleTimerDisabled = true
                if ProcessInfo.processInfo.arguments.contains("-autoPlay") {
                    viewModel.togglePlayback()
                }
                if autoStartVoice || ProcessInfo.processInfo.arguments.contains("-autoVoice") {
                    viewModel.toggleVoice()
                }
                if ProcessInfo.processInfo.arguments.contains("-adjustFont") {
                    viewModel.adjustTarget = .fontSize
                } else if ProcessInfo.processInfo.arguments.contains("-adjustSpeed") {
                    viewModel.adjustTarget = .speed
                }
            }
            .onDisappear {
                viewModel.saveProgress()
                viewModel.stopRemote()
                UIApplication.shared.isIdleTimerDisabled = false
            }
            .onChange(of: proxy.size) { _, newSize in
                viewModel.updateViewport(newSize)
            }
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .alert(
            "语音跟读不可用",
            isPresented: Binding(
                get: { viewModel.voiceAlert != nil },
                set: { if !$0 { viewModel.voiceAlert = nil } }
            )
        ) {
            Button("知道了") { viewModel.voiceAlert = nil }
        } message: {
            Text(viewModel.voiceAlert ?? "")
        }
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
            .accessibilityElement()
            .accessibilityLabel("提词内容区")
            .accessibilityHint("双击播放或暂停，上下轻扫手动滚动")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                viewModel.togglePlayback()
            }
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
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular, in: .circle)
                .accessibilityLabel("关闭提词")

                Spacer()

                Button {
                    var next = viewModel.display
                    next.mirror = next.mirror == .none ? .horizontal : .none
                    viewModel.applyDisplay(next)
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular, in: .circle)
                .accessibilityLabel(viewModel.display.mirror == .none ? "开启水平镜像" : "关闭镜像")
                .accessibilityAddTraits(viewModel.display.mirror == .none ? [] : .isSelected)
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
        VStack(spacing: 9) {
            HStack(spacing: 6) {
                Text(viewModel.script.title.isEmpty ? "未命名台本" : viewModel.script.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .layoutPriority(1)
                Text("·").opacity(0.4)
                Text(viewModel.progressLabel)
                    .font(.system(size: 11).monospacedDigit())
                Spacer(minLength: 4)
                if viewModel.remote.isConnected {
                    Image(systemName: "keyboard")
                        .font(.system(size: 10, weight: .medium))
                        .opacity(0.7)
                        .accessibilityLabel("已连接外接遥控")
                }
                Text("剩余 \(formatted(viewModel.remainingSeconds))")
                    .font(.system(size: 11).monospacedDigit())
                    .opacity(0.7)
            }
            .padding(.horizontal, 2)

            progressBar

            if viewModel.isVoiceActive {
                voiceStatusRow
            }

            if viewModel.adjustTarget == .fontSize {
                fontSizeSlider
            }

            if viewModel.adjustTarget == .speed {
                speedSlider
            }

            HStack(spacing: 8) {
                controlButton("backward.end.fill", caption: "回顶") {
                    viewModel.restart()
                }
                .accessibilityLabel("回到开头")
                controlButton(
                    viewModel.engine.isRunning ? "pause.fill" : "play.fill",
                    prominent: true
                ) {
                    viewModel.togglePlayback()
                }
                .accessibilityLabel(viewModel.engine.isRunning ? "暂停" : "播放")
                .opacity(viewModel.scroll.mode == .voice ? 0.4 : 1)
                .disabled(viewModel.scroll.mode == .voice)
                controlButton("waveform", caption: "跟读", active: viewModel.isVoiceActive) {
                    viewModel.toggleVoice()
                }
                .accessibilityLabel(viewModel.isVoiceActive ? "关闭语音跟读" : "开启语音跟读")
                controlButton(
                    "character",
                    caption: "\(Int(viewModel.display.fontSize))",
                    active: viewModel.adjustTarget == .fontSize
                ) {
                    toggleAdjust(.fontSize)
                }
                .accessibilityLabel("调整字号，当前 \(Int(viewModel.display.fontSize)) 磅")
                controlButton(
                    "speedometer",
                    caption: viewModel.scroll.speedLabel,
                    active: viewModel.adjustTarget == .speed
                ) {
                    toggleAdjust(.speed)
                }
                .accessibilityLabel("调整速度，当前 \(viewModel.scroll.speedLabel)")
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .animation(.smooth(duration: 0.2), value: viewModel.adjustTarget)
        .animation(.smooth(duration: 0.2), value: viewModel.isVoiceActive)
        .sheet(isPresented: $viewModel.showsSettings) {
            PrompterSettingsSheet(viewModel: viewModel)
                .presentationDetents([.medium, .large])
                .presentationBackground(.regularMaterial)
        }
    }

    /// 细进度条，整行都可点可拖。系统 Slider 太粗，会把控制条撑高。
    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(uiColor: viewModel.display.palette.foreground).opacity(0.18))
                    .frame(height: 5)
                Capsule()
                    .fill(Color(uiColor: viewModel.display.palette.highlight))
                    .frame(width: max(geo.size.width * viewModel.engine.progress, 5), height: 5)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        viewModel.handleScrub(true)
                        viewModel.seek(toProgress: value.location.x / max(geo.size.width, 1))
                    }
                    .onEnded { _ in
                        viewModel.handleScrub(false)
                    }
            )
        }
        .frame(height: 26)
        .accessibilityElement()
        .accessibilityLabel("阅读进度")
        .accessibilityValue("\(Int(viewModel.engine.progress * 100)) %")
        .accessibilityAdjustableAction { direction in
            let step = 0.05
            switch direction {
            case .increment:
                viewModel.seek(toProgress: viewModel.engine.progress + step)
            case .decrement:
                viewModel.seek(toProgress: viewModel.engine.progress - step)
            @unknown default:
                break
            }
        }
    }

    private var voiceStatusRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform")
                .font(.system(size: 10, weight: .semibold))
                .symbolEffect(.variableColor.iterative, isActive: true)
            Text(viewModel.voiceHint)
                .font(.system(size: 10))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color(uiColor: viewModel.display.palette.highlight))
        .padding(.horizontal, 2)
    }

    private var fontSizeSlider: some View {
        HStack(spacing: 10) {
            Text("字号")
                .font(.system(size: 10))
                .frame(width: 24, alignment: .leading)
            Slider(
                value: Binding(
                    get: { viewModel.display.fontSize },
                    set: { newValue in
                        var next = viewModel.display
                        next.fontSize = newValue
                        viewModel.applyDisplay(next)
                    }
                ),
                in: 20...96,
                step: 2
            )
            .tint(Color(uiColor: viewModel.display.palette.highlight))
            .accessibilityLabel("字号")
            .accessibilityValue("\(Int(viewModel.display.fontSize)) 磅")
            Text("\(Int(viewModel.display.fontSize))")
                .font(.system(size: 11).monospacedDigit())
                .frame(width: 26, alignment: .trailing)
        }
        .padding(.horizontal, 2)
    }

    private var speedSlider: some View {
        HStack(spacing: 10) {
            Text("速度")
                .font(.system(size: 10))
                .frame(width: 24, alignment: .leading)
            Slider(
                value: Binding(
                    get: { viewModel.scroll.speedValue },
                    set: { newValue in
                        var next = viewModel.scroll
                        next.setSpeed(newValue)
                        viewModel.applyScroll(next)
                    }
                ),
                in: viewModel.scroll.speedRange,
                step: viewModel.scroll.speedStep
            )
            .tint(Color(uiColor: viewModel.display.palette.highlight))
            .disabled(viewModel.scroll.mode == .voice)
            .accessibilityLabel("滚动速度")
            .accessibilityValue("\(viewModel.scroll.speedLabel) \(viewModel.scroll.speedUnit)")
            Text(viewModel.scroll.speedUnit.isEmpty ? viewModel.scroll.speedLabel : viewModel.scroll.speedUnit)
                .font(.system(size: 11))
                .frame(width: 42, alignment: .trailing)
                .opacity(0.7)
        }
        .padding(.horizontal, 2)
    }

    private func toggleAdjust(_ target: PrompterViewModel.AdjustTarget) {
        withAnimation(.smooth(duration: 0.2)) {
            viewModel.adjustTarget = viewModel.adjustTarget == target ? .none : target
        }
        viewModel.showControls()
    }

    private func controlButton(
        _ symbol: String,
        caption: String? = nil,
        active: Bool = false,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                    .font(.system(size: prominent ? 19 : 15, weight: .semibold))
                if let caption {
                    Text(caption)
                        .font(.system(size: 9, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .foregroundStyle(foreground(prominent: prominent, active: active))
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(background(prominent: prominent, active: active))
            }
        }
        .buttonStyle(.plain)
    }

    private func foreground(prominent: Bool, active: Bool) -> Color {
        if prominent {
            return Color(uiColor: viewModel.display.palette.background)
        }
        if active {
            return Color(uiColor: viewModel.display.palette.highlight)
        }
        return Color(uiColor: viewModel.display.palette.foreground)
    }

    private func background(prominent: Bool, active: Bool) -> Color {
        if prominent {
            return Color(uiColor: viewModel.display.palette.highlight)
        }
        if active {
            return Color(uiColor: viewModel.display.palette.highlight).opacity(0.18)
        }
        return .clear
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
                if new == .voice {
                    if viewModel.isVoiceActive {
                        var next = viewModel.scroll
                        next.mode = .voice
                        viewModel.applyScroll(next)
                    } else {
                        viewModel.toggleVoice()
                    }
                    return
                }
                var next = viewModel.scroll
                next.mode = new
                viewModel.applyScroll(next)
            }
        )
    }
}

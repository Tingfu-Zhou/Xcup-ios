//
//  ManualControlView.swift
//  Xcup
//
//  手动电子菜单 —— 在 App 上直接选择变频模式与马达强度，
//  免去在飞机杯实体按键上轮询换档的麻烦。
//
//  下发帧：SetPattern(0x04)，payload = PATTERN_ID, INT_LEVEL, DURATION_MS=0, FLAGS=1
//  即 buildSetPatternFrame(PATTERN, LEVEL, 0, 1)：DURATION=0 持续、FLAGS bit0=1 循环。
//    · PATTERN_ID：变频模式 1...3（BLE 协议 §9.1）
//    · INT_LEVEL ：马达强度 0...10，0 为停止（BLE 协议 §9.2）
//
//  变频模式的选择同时作用于视频分析模式：分析链路只决定「转 / 不转」与强度档位，
//  「怎么转」以本页面的选择为准，两边共用 BluetoothManager.patternDefaultsKey 这一份存储。
//

import SwiftUI
import UIKit
import QuartzCore

struct ManualControlView: View {

    // MARK: - 协议表（§9.1 / §9.2）

    /// 变频模式说明
    private static let patternDescriptions: [UInt8: String] = [
        1: "只有正转，持续同向抽送",
        2: "1200ms 反转 → 600ms 正转 → 1100ms 反转",
        3: "2000ms 反转 → 3000ms 正转"
    ]

    /// 各强度档位对应的转速（RPM）
    private static let levelRpm: [Int] = [0, 190, 220, 240, 270, 280, 290, 295, 300, 310, 320]

    /// 各强度档位对应的伸缩频率（Hz）
    private static let levelHz: [Double] = [0, 1.06, 1.22, 1.33, 1.50, 1.56, 1.61, 1.64, 1.67, 1.72, 1.78]

    /// 拖动滑杆时的最小下发间隔
    private static let sendThrottleInterval: TimeInterval = 0.15

    // 只记忆上次选择的模式；强度一律从 0 开始，避免一进页面就意外启动。
    // 持久化键定义在 BluetoothManager.patternDefaultsKey，视频分析链路读的是同一份。

    private static let patternIds: [UInt8] = Array(BluetoothManager.PATTERN_MIN...BluetoothManager.PATTERN_MAX)

    // MARK: - 状态

    @Environment(\.dismiss) private var dismiss

    @State private var patternId: UInt8 = BluetoothManager.PATTERN_MIN
    @State private var level: Double = 0
    @State private var isConnected      = BluetoothManager.shared.isConnected
    @State private var isPausedByLocal  = BluetoothManager.shared.isPausedByLocal
    @State private var statusText       = "尚未下发指令"

    @State private var observerToken: UUID?
    @State private var lastSendTime: TimeInterval = 0
    @State private var pendingSend: DispatchWorkItem?

    /// 未连接或处于本地按键锁定时，模式/强度控件置灰（紧急停止只要连接就可用）
    private var controlsDisabled: Bool { !isConnected || isPausedByLocal }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // 顶栏：仅返回箭头，无标题
            MD3TopAppBar("", onBack: { dismiss() })

            ScrollView {
                VStack(spacing: 16) {
                    connectionCard

                    if isPausedByLocal {
                        localHoldCard
                    }

                    patternSection
                    levelSection

                    Button(action: emergencyStop) {
                        Label("紧急停止", systemImage: "stop.circle.fill")
                    }
                    .buttonStyle(MD3ErrorFilledButtonStyle())
                    .disabled(!isConnected)

                    statusFooter
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
        }
        .background(Color.md3Background.ignoresSafeArea())
        .overlay(
            // 隐藏系统导航栏后重新启用左滑返回手势
            InteractivePopGestureEnabler()
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        )
        .navigationBarHidden(true)
        .onAppear { handleAppear() }
        .onDisappear { handleDisappear() }
    }

    // MARK: - 蓝牙状态卡

    private var connectionCard: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isConnected ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 14))
                .foregroundColor(isConnected ? .md3Primary : .md3Error)
                .padding(.top, 1)
            Text(isConnected ? "已连接，调节模式或强度后立即下发" : "蓝牙未连接，请先返回主页面连接设备")
                .font(MD3Typography.bodySmall)
                .foregroundColor(.md3OnSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.md3Surface)
        )
    }

    // MARK: - 本地锁定提示卡

    private var localHoldCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.md3OnErrorContainer)
                Text("设备正在本地按键控制")
                    .font(MD3Typography.titleMedium)
                    .foregroundColor(.md3OnErrorContainer)
            }
            Text("按下飞机杯上的实体按键后，设备会暂停响应 App 指令，点击下方按钮恢复 App 控制。")
                .font(MD3Typography.bodySmall)
                .foregroundColor(Color.md3OnErrorContainer.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            Button(action: resumeAppControl) {
                Text("恢复控制")
            }
            .buttonStyle(MD3ErrorFilledButtonStyle())
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.md3ErrorContainer)
        )
    }

    // MARK: - 变频模式

    private var patternSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("变频模式")
                .font(MD3Typography.titleMedium)
                .foregroundColor(.md3OnSurface)

            HStack(spacing: 0) {
                ForEach(Self.patternIds, id: \.self) { id in
                    if id != BluetoothManager.PATTERN_MIN {
                        Rectangle()
                            .fill(Color.md3Outline)
                            .frame(width: 1)
                    }
                    patternSegment(id)
                }
            }
            .frame(height: 44)
            .clipShape(RoundedRectangle(cornerRadius: MD3Shape.buttonCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: MD3Shape.buttonCornerRadius, style: .continuous)
                    .stroke(Color.md3Outline, lineWidth: 1)
            )

            Text(Self.patternDescriptions[patternId] ?? "")
                .font(MD3Typography.bodySmall)
                .foregroundColor(.md3OnSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)

            Text("该模式同时用于视频分析模式：分析只决定「转 / 不转」与强度档位，转动方式（正转 / 反转节拍）以这里的选择为准。")
                .font(MD3Typography.bodySmall)
                .foregroundColor(.md3OnSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.md3Surface)
        )
    }

    private func patternSegment(_ id: UInt8) -> some View {
        let selected = (patternId == id)
        let fg: Color = controlsDisabled
            ? .md3OnSurface.opacity(0.38)
            : (selected ? .md3OnSecondaryContainer : .md3OnSurfaceVariant)
        let bg: Color = selected
            ? (controlsDisabled ? .md3OnSurface.opacity(0.12) : .md3SecondaryContainer)
            : .clear

        return Button(action: { selectPattern(id) }) {
            HStack(spacing: 4) {
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                }
                Text("模式 \(id)")
                    .font(MD3Typography.titleMedium)
            }
            .foregroundColor(fg)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(bg)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(controlsDisabled)
    }

    // MARK: - 马达强度

    private var levelSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("马达强度")
                .font(MD3Typography.titleMedium)
                .foregroundColor(.md3OnSurface)

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(Int(level))")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundColor(controlsDisabled ? Color.md3OnSurface.opacity(0.38) : Color.md3Primary)
                Text(levelDetailText)
                    .font(MD3Typography.bodySmall)
                    .foregroundColor(.md3OnSurfaceVariant)
                Spacer()
            }

            Slider(
                value: levelBinding,
                in: Double(BluetoothManager.LEVEL_MIN)...Double(BluetoothManager.LEVEL_MAX),
                step: 1,
                onEditingChanged: { editing in
                    // 松手时取消排队并补发最终值，保证 UI 与设备一致
                    if !editing { flushPendingSend() }
                }
            )
            .tint(.md3Primary)
            .disabled(controlsDisabled)

            HStack {
                Text("0 停止")
                Spacer()
                Text("10 最强")
            }
            .font(MD3Typography.bodySmall)
            .foregroundColor(.md3OnSurfaceVariant)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.md3Surface)
        )
    }

    private var levelDetailText: String {
        let index = levelIndex
        guard index > 0 else { return "停止" }
        let hz = String(format: "%.2f", Self.levelHz[index])
        return "转速 \(Self.levelRpm[index]) RPM · 伸缩 \(hz) Hz"
    }

    private var levelIndex: Int {
        min(max(Int(level.rounded()), Int(BluetoothManager.LEVEL_MIN)), Int(BluetoothManager.LEVEL_MAX))
    }

    /// 自定义 Binding：只有用户拖动滑杆才触发下发，
    /// 程序内部直接改 `level`（如紧急停止归零）不会走这里，因此不会重复发帧
    private var levelBinding: Binding<Double> {
        Binding(
            get: { self.level },
            set: { newValue in
                let snapped = newValue.rounded()
                guard snapped != self.level else { return }
                self.level = snapped
                self.scheduleSend()
            }
        )
    }

    // MARK: - 状态行

    private var statusFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(statusText)
                .font(MD3Typography.bodySmall)
                .foregroundColor(.md3OnSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
            Text("离开本页面不会自动停机，如需停止请点击「紧急停止」或将强度调至 0。")
                .font(MD3Typography.bodySmall)
                .foregroundColor(.md3OnSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 生命周期

    private func handleAppear() {
        // 只从本地存储恢复上次选的模式（与视频分析模式共用同一份选择）
        let saved = UserDefaults.standard.integer(forKey: BluetoothManager.patternDefaultsKey)
        patternId = BluetoothManager.clampPattern(UInt8(clamping: saved))
        // 兜底：把恢复出来的模式同步给 BLE 层，保证视频分析链路用的是同一个选择
        BluetoothManager.shared.setAnalysisPattern(patternId)
        // 强度一律从 0 开始，避免一进页面就意外启动
        level = 0

        isConnected     = BluetoothManager.shared.isConnected
        isPausedByLocal = BluetoothManager.shared.isPausedByLocal

        // 登记为附加观察者，不覆盖主页面的 stateObserver
        guard observerToken == nil else { return }
        observerToken = BluetoothManager.shared.addStateObserver(
            BluetoothStateObserver(
                onConnect: {
                    self.isConnected = true
                    self.statusText  = "设备已连接"
                },
                onDisconnect: {
                    self.cancelPendingSend()
                    self.isConnected     = false
                    self.isPausedByLocal = false
                    self.level           = 0
                    self.statusText      = "设备已断开连接"
                },
                onPause: {
                    self.cancelPendingSend()
                    self.isPausedByLocal = true
                    self.statusText      = "设备正在本地按键控制，已暂停 App 下发"
                },
                onResume: {
                    self.isPausedByLocal = false
                    self.statusText      = "已恢复 App 控制"
                }
            )
        )
    }

    private func handleDisappear() {
        // 刻意不自动停机：离开本页面后设备保持当前模式与强度
        cancelPendingSend()
        if let token = observerToken {
            BluetoothManager.shared.removeStateObserver(token)
            observerToken = nil
        }
    }

    // MARK: - 操作

    private func selectPattern(_ id: UInt8) {
        guard id != patternId else { return }
        patternId = id
        UserDefaults.standard.set(Int(id), forKey: BluetoothManager.patternDefaultsKey)

        // 当前强度为 0 时只更新界面不下发，避免在停止状态下唤醒马达
        let sendsManually = levelIndex > 0
        if sendsManually {
            flushPendingSend()
        }

        // 同步给视频分析链路。放在手动下发之后：手动下发已把「分析正在转」的标记清零，
        // 这里就不会为同一次切换重复补发一帧。
        // 反过来，本页强度为 0（刚进页面）而分析正在驱动转动时，由这里补发让新模式立刻生效。
        let analysisResent = BluetoothManager.shared.setAnalysisPattern(id)

        if !sendsManually {
            statusText = analysisResent
                ? "已切换到模式 \(id)，视频分析正在运行，已即时生效"
                : "已切换到模式 \(id)（强度为 0，未下发）"
        }
    }

    private func emergencyStop() {
        cancelPendingSend()
        let sent = BluetoothManager.shared.sendStopAll()
        // 归零只同步界面，不触发下发（避免重复发帧）
        level = 0
        statusText = sent ? "已发送紧急停止" : "紧急停止发送失败：蓝牙未连接"
    }

    private func resumeAppControl() {
        BluetoothManager.shared.resumeAppControl()
        statusText = "已发送恢复控制命令，等待设备确认…"
    }

    // MARK: - 下发节流（最小间隔 150ms，排队式）

    private func scheduleSend() {
        // 已有待发任务就不再排新的，落地时读最新值
        guard pendingSend == nil else { return }

        let elapsed = CACurrentMediaTime() - lastSendTime
        if elapsed >= Self.sendThrottleInterval {
            sendCurrentSetting()
            return
        }

        let item = DispatchWorkItem {
            self.pendingSend = nil
            self.sendCurrentSetting()
        }
        pendingSend = item
        DispatchQueue.main.asyncAfter(deadline: .now() + (Self.sendThrottleInterval - elapsed), execute: item)
    }

    private func flushPendingSend() {
        cancelPendingSend()
        sendCurrentSetting()
    }

    private func cancelPendingSend() {
        pendingSend?.cancel()
        pendingSend = nil
    }

    private func sendCurrentSetting() {
        lastSendTime = CACurrentMediaTime()

        let intLevel = UInt8(levelIndex)
        let sent = BluetoothManager.shared.sendManualPattern(patternId: patternId, intLevel: intLevel)

        if sent {
            statusText = intLevel == 0
                ? "已下发：模式 \(patternId) · 强度 0（停止）"
                : "已下发：模式 \(patternId) · 强度 \(intLevel)"
        } else if !BluetoothManager.shared.isConnected {
            statusText = "下发失败：蓝牙未连接"
        } else if BluetoothManager.shared.isPausedByLocal {
            statusText = "下发失败：设备正在本地按键控制"
        } else {
            statusText = "下发失败：参数无效"
        }
    }
}

// MARK: - 左滑返回手势

/// 页面隐藏了系统导航栏，UIKit 会随之停用左滑返回手势；
/// 这里重新接管手势代理，使「返回箭头」与「系统返回手势」都能回到主页面。
private struct InteractivePopGestureEnabler: UIViewControllerRepresentable {

    func makeUIViewController(context: Context) -> PopGestureEnablerController {
        PopGestureEnablerController()
    }

    func updateUIViewController(_ uiViewController: PopGestureEnablerController, context: Context) {}
}

private final class PopGestureEnablerController: UIViewController, UIGestureRecognizerDelegate {

    private weak var host: UINavigationController?
    private weak var previousDelegate: UIGestureRecognizerDelegate?
    private var didTakeOver = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didTakeOver,
              let nav = navigationController,
              let gesture = nav.interactivePopGestureRecognizer,
              gesture.delegate !== self else { return }

        host = nav
        previousDelegate = gesture.delegate
        gesture.delegate = self
        gesture.isEnabled = true
        didTakeOver = true
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard didTakeOver else { return }
        // 页面已完成退场，把手势代理还给系统
        host?.interactivePopGestureRecognizer?.delegate = previousDelegate
        previousDelegate = nil
        host = nil
        didTakeOver = false
    }

    // 只有栈内还有上一页时才允许返回，避免根页面滑动卡死
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        let stackDepth = (host ?? navigationController)?.viewControllers.count ?? 0
        return stackDepth > 1
    }
}

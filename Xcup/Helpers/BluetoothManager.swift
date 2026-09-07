//
//  BluetoothManager.swift
//  Xcup
//
//  蓝牙管理器 - 从蓝牙测试app移植的真实BLE通信
//

import Foundation
import CoreBluetooth

// MARK: - 蓝牙状态委托协议
protocol BluetoothManagerDelegate: AnyObject {
    func bluetoothDidConnect()
    func bluetoothDidDisconnect()
    func bluetoothDidPause() // 新增：设备暂停App控制
    func bluetoothDidResume() // 新增：恢复App控制
}

// [新增] 蓝牙状态观察者 - 使用闭包替代委托，解决SwiftUI struct的weak引用问题
struct BluetoothStateObserver {
    var onConnect: (() -> Void)?
    var onDisconnect: (() -> Void)?
    var onPause: (() -> Void)?
    var onResume: (() -> Void)?
}

class BluetoothManager: NSObject {
    
    // MARK: - 单例
    static let shared = BluetoothManager()
    
    // MARK: - BLE UUIDs (与Android保持一致)
    private let SERVICE_UUID = CBUUID(string: "e43c4cbf-9e30-44cc-b8ea-83561908a4e5")
    private let RX_CHAR_UUID = CBUUID(string: "71cd6e15-8ed6-4727-b306-42a0e20fe7b6") // App->Dev
    private let TX_CHAR_UUID = CBUUID(string: "2cbb355f-d59a-4be6-aaab-fcfe27abcec4") // Dev->App
    
    // MARK: - 设备识别
    private let TARGET_NAME_PREFIX = "XCUP-A1B2"
    
    // MARK: - 协议常量
    private let VER: UInt8 = 0x01
    private let CMD_SET_PATTERN: UInt8 = 0x04
    private let CMD_STOP_ALL: UInt8 = 0x02
    private let CMD_QUERY_STATE: UInt8 = 0x03
    private let CMD_STATE_RPT: UInt8 = 0x83
    private let CMD_HEARTBEAT: UInt8 = 0x06
    private let CMD_RESUME_APP: UInt8 = 0x12  // [NEW] 恢复App控制
    
    // [NEW] StateReport扩展解析用常量
    private let SRC_FW: UInt8 = 0
    private let SRC_APP: UInt8 = 1
    private let SRC_BUTTON: UInt8 = 2
    private let SRC_SAFETY: UInt8 = 3
    
    private let OWNER_IDLE: UInt8 = 0
    private let OWNER_APP: UInt8 = 1
    private let OWNER_LOCAL: UInt8 = 2
    
    private let HOLD_NONE: UInt8 = 0
    private let HOLD_TIMED: UInt8 = 1
    private let HOLD_MANUAL: UInt8 = 2
    
    // 模式和强度定义
    private let PATTERN_1: UInt8 = 1
    private let PATTERN_2: UInt8 = 2
    private let PATTERN_3: UInt8 = 3
    
    // [NEW] 手动控制边界常量（协议 §9.1 / §9.2）
    static let PATTERN_MIN: UInt8 = 1
    static let PATTERN_MAX: UInt8 = 3
    static let LEVEL_MIN:   UInt8 = 0
    static let LEVEL_MAX:   UInt8 = 10
    
    /// [NEW] 变频模式的持久化键。手动电子菜单与视频分析模式共用同一份选择，
    /// 用户只需在一个地方选「怎么转」，两条链路语义一致。
    static let patternDefaultsKey = "manual_control_pattern_id"
    
    /// [NEW] 把变频模式号钳制到 1...3（协议 §9.1）
    static func clampPattern(_ patternId: UInt8) -> UInt8 {
        return min(max(patternId, PATTERN_MIN), PATTERN_MAX)
    }
    
    //private let LEVEL_STOP: UInt8 = 0
    //private let LEVEL_L: UInt8 = 1
    //private let LEVEL_M: UInt8 = 2
    //private let LEVEL_H: UInt8 = 3
    
    // MARK: - BLE Properties
    private var centralManager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rxCharacteristic: CBCharacteristic?
    private var txCharacteristic: CBCharacteristic?
    
    // MARK: - State
    var isConnected = false { // 修改为public以供外部查询
        didSet {
            if isConnected {
                delegate?.bluetoothDidConnect()
                notifyObservers(.connect)
            } else {
                delegate?.bluetoothDidDisconnect()
                notifyObservers(.disconnect)
            }
        }
    }
    private var isScanning = false
    var isPausedByLocal = false { // 修改为public以供外部查询
        didSet {
            if isPausedByLocal {
                delegate?.bluetoothDidPause()
                notifyObservers(.pause)
            } else {
                delegate?.bluetoothDidResume()
                notifyObservers(.resume)
            }
        }
    }
    private var seq: UInt8 = 0
    
    // MARK: - [NEW] 视频分析模式使用的变频模式
    //
    // 视频分析链路只决定「转 / 不转」与强度档位，「怎么转」由用户在手动电子菜单里选，
    // 两个页面读写同一份 UserDefaults，所以选一次即同时生效。
    //
    // 线程：分析链路的 sendAction 主要跑在融合循环（主线程），但暂停逻辑可能在
    // Darwin 通知线程调用，而 setter 来自 SwiftUI 主线程，因此下面两个字段统一加锁访问。
    private let analysisLock = NSLock()
    private var _analysisPattern: UInt8 = BluetoothManager.PATTERN_MIN
    /// 最近一次 sendAction（视频分析链路）下发的是否为「转」；手动下发 / StopAll / 断开会清零
    private var _analysisRunning = false
    
    // MARK: - Delegate
    weak var delegate: BluetoothManagerDelegate?
    
    // [新增] 使用闭包替代委托模式，避免 SwiftUI struct 的 weak 引用问题
    // 主观察者：由主页面（ContentView）持有
    var stateObserver: BluetoothStateObserver?
    
    // [NEW] 附加观察者列表：手动电子菜单等二级页面在此登记，
    // 避免直接覆盖 stateObserver 把主页面的监听顶掉
    private let observerLock = NSLock()
    private var extraObservers: [UUID: BluetoothStateObserver] = [:]
    
    // MARK: - Timer
    private var scanTimeoutTimer: Timer?
    
    // MARK: - Initialization
    private override init() {
        super.init()
        // [NEW] 从手动电子菜单同一份持久化存储读取，缺省 0 会被钳制为模式 1（只有正转），
        // 全新安装时行为与改动前完全一致。
        let saved = UserDefaults.standard.integer(forKey: BluetoothManager.patternDefaultsKey)
        _analysisPattern = BluetoothManager.clampPattern(UInt8(clamping: saved))
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }
    
    // MARK: - Public Methods
    
    /// 开始扫描并连接
    func startScanAndConnect() {
        guard centralManager.state == .poweredOn else {
            print("蓝牙未开启")
            return
        }
        
        if isScanning {
            return
        }
        
        isScanning = true
        print("开始扫描蓝牙设备...")
        
        // 扫描指定服务UUID的设备
        centralManager.scanForPeripherals(withServices: [SERVICE_UUID], options: nil)
        
        // 20秒超时
        scanTimeoutTimer?.invalidate()
        scanTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 20.0, repeats: false) { _ in
            self.stopScan()
            print("扫描超时")
        }
    }
    
    /// 断开连接
    func disconnect() {
        if let peripheral = peripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        isConnected = false
        rxCharacteristic = nil
        txCharacteristic = nil
        isPausedByLocal = false  // [NEW] 断开时清除暂停状态
        setAnalysisRunning(false)  // [NEW] 断开后分析链路不再驱动转动
    }
    
    var LEVEL: UInt8 = 0
    /// 发送动作数据（从VideoProcessViewController调用）
    func sendAction(_ action: String, _ finalFreq: Int) {
        LEVEL = UInt8(finalFreq)
        // 如果被本地暂停，不发送
        guard !isPausedByLocal else {
            print("⚠️ 设备已暂停App控制，忽略动作: \(action)")
            return
        }
        
        guard isConnected, let rxChar = rxCharacteristic else {
            print("❌ 未连接到设备或未发现写入特征")
            return
        }
        
        if let frame = buildFrameForAction(action) {
            writeToRx(data: frame)
            // [NEW] 记录分析链路当前是否正在驱动转动，供切换变频模式时判断要不要补发
            setAnalysisRunning(action != "Noise")
            print("✅ 发送动作: \(action), pattern=\(analysisPattern), level=\(LEVEL)")
        }
    }
    
    /// 恢复App控制（从主界面调用）
    func resumeAppControl() {
        guard isConnected, rxCharacteristic != nil else { return }
        
        let frame = buildResumeFrame()
        writeToRx(data: frame)
        print("发送恢复App控制命令")
        // 等待ACK或StateReport确认恢复
    }
    
    // MARK: - [NEW] 手动控制（手动电子菜单页面调用）
    
    /// 手动下发「变频模式 + 马达强度」
    /// 帧：SetPattern(0x04)，payload = PATTERN_ID, INT_LEVEL, DURATION_MS=0(持续), FLAGS=1(循环)
    /// - Parameters:
    ///   - patternId: 预置模式 1...3（协议 §9.1），越界直接拒绝
    ///   - intLevel:  强度档位 0...10（协议 §9.2），越界 clamp 而不拒绝
    /// - Returns: 是否已下发
    @discardableResult
    func sendManualPattern(patternId: UInt8, intLevel: UInt8) -> Bool {
        // 1) 未连接 → 拦下
        guard isConnected, rxCharacteristic != nil else {
            print("❌ 手动控制：未连接到设备或未发现写入特征")
            return false
        }
        
        // 2) 本地按键锁定期内设备只会回 BUSY，客户端先拦下
        guard !isPausedByLocal else {
            print("⚠️ 手动控制：设备正在本地按键控制，忽略下发")
            return false
        }
        
        // 3) 模式越界 → 拒绝；强度 clamp 到 0...10
        guard patternId >= BluetoothManager.PATTERN_MIN,
              patternId <= BluetoothManager.PATTERN_MAX else {
            print("❌ 手动控制：模式越界 patternId=\(patternId)")
            return false
        }
        let level = min(max(intLevel, BluetoothManager.LEVEL_MIN), BluetoothManager.LEVEL_MAX)
        
        let frame = buildSetPatternFrame(patternId: patternId, intLevel: level, durationMs: 0, flags: 1)
        writeToRx(data: frame)
        // [NEW] 手动接管后清零，避免分析链路的补发逻辑再插一脚
        setAnalysisRunning(false)
        print("✅ 手动下发: pattern=\(patternId) level=\(level)")
        return true
    }
    
    /// 紧急停止：协议规定 StopAll 任何时刻都必须 OK（最高优先），因此不检查本地锁定状态
    /// - Returns: 是否已下发
    @discardableResult
    func sendStopAll() -> Bool {
        guard isConnected, rxCharacteristic != nil else {
            print("❌ 紧急停止：未连接到设备或未发现写入特征")
            return false
        }
        
        writeToRx(data: buildStopAllFrame())
        setAnalysisRunning(false)  // [NEW] 已停机，分析链路不再驱动转动
        print("🛑 已发送紧急停止(StopAll)")
        return true
    }
    
    // MARK: - [NEW] 视频分析模式的变频模式
    
    /// 视频分析模式当前使用的变频模式（1...3）
    var analysisPattern: UInt8 {
        analysisLock.lock()
        defer { analysisLock.unlock() }
        return _analysisPattern
    }
    
    /// 设置视频分析模式使用的变频模式（手动电子菜单选择后调用）
    /// - Parameter patternId: 预置模式，越界 clamp 到 1...3
    /// - Returns: 是否为了让新模式立即生效而补发了一帧
    @discardableResult
    func setAnalysisPattern(_ patternId: UInt8) -> Bool {
        let p = BluetoothManager.clampPattern(patternId)
        
        analysisLock.lock()
        if p == _analysisPattern {
            analysisLock.unlock()
            return false
        }
        _analysisPattern = p
        let running = _analysisRunning
        analysisLock.unlock()
        
        // 只有当前正由视频分析驱动转动，才立即补发一帧让新模式生效；
        // 不转时只记下来，下一次发送自然带上，避免在停机状态下把马达唤醒。
        // 本地按键锁定期内设备只会回 BUSY，所以也要带上「未被锁定」这个条件。
        let canResend =
            running && LEVEL > 0 &&
            isConnected && !isPausedByLocal &&
            rxCharacteristic != nil && peripheral != nil
        guard canResend else { return false }
        
        // 与分析链路的「转」帧保持一致：DURATION=0 持续、FLAGS bit0=1 循环
        writeToRx(data: buildSetPatternFrame(patternId: p, intLevel: LEVEL, durationMs: 0, flags: 1))
        print("✅ 视频分析变频模式切换，已补发: pattern=\(p) level=\(LEVEL)")
        return true
    }
    
    /// 记录分析链路当前是否正在驱动转动
    private func setAnalysisRunning(_ running: Bool) {
        analysisLock.lock()
        _analysisRunning = running
        analysisLock.unlock()
    }
    
    // MARK: - [NEW] 状态观察者管理
    
    /// 登记一个附加观察者（二级页面使用），返回用于注销的令牌
    @discardableResult
    func addStateObserver(_ observer: BluetoothStateObserver) -> UUID {
        let token = UUID()
        observerLock.lock()
        extraObservers[token] = observer
        observerLock.unlock()
        return token
    }
    
    /// 注销附加观察者
    func removeStateObserver(_ token: UUID) {
        observerLock.lock()
        extraObservers.removeValue(forKey: token)
        observerLock.unlock()
    }
    
    // MARK: - Private Methods
    
    // [NEW] 蓝牙状态事件：统一分发给主观察者与全部附加观察者（均切主线程）
    private enum StateEvent {
        case connect, disconnect, pause, resume
    }
    
    private func notifyObservers(_ event: StateEvent) {
        observerLock.lock()
        let observers = [stateObserver].compactMap { $0 } + Array(extraObservers.values)
        observerLock.unlock()
        
        guard !observers.isEmpty else { return }
        
        DispatchQueue.main.async {
            for observer in observers {
                switch event {
                case .connect:    observer.onConnect?()
                case .disconnect: observer.onDisconnect?()
                case .pause:      observer.onPause?()
                case .resume:     observer.onResume?()
                }
            }
        }
    }
    
    private func stopScan() {
        if isScanning {
            centralManager.stopScan()
            isScanning = false
            scanTimeoutTimer?.invalidate()
        }
    }
    
    private func writeToRx(data: Data) {
        guard let peripheral = peripheral,
              let rxChar = rxCharacteristic else { return }
        
        // 使用Write Without Response以减少延迟
        let writeType: CBCharacteristicWriteType = rxChar.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        
        peripheral.writeValue(data, for: rxChar, type: writeType)
        print("发送数据: \(data.hexString)")
    }
    
    // MARK: - Frame Building
    
    private func buildFrameForAction(_ action: String) -> Data? {
        // [NEW] PATTERN_ID 取用户在手动电子菜单里选的变频模式，不再写死：
        // 分析只决定「转 / 不转」与强度档位，转动方式以用户的选择为准。
        let pattern = analysisPattern
        switch action {
        case "oral": // 映射为"001": 插定-低，持续2s
            return buildSetPatternFrame(patternId: pattern, intLevel: LEVEL, durationMs: 2000, flags: 0)
        //case "dofast": // 映射为"002": 脉冲-中，持续2s
            //return buildSetPatternFrame(patternId: PATTERN_2, intLevel: LEVEL, durationMs: 2000, flags: 0)
        case "do": // 映射为"003": 波形-中，循环
            return buildSetPatternFrame(patternId: pattern, intLevel: LEVEL, durationMs: 0, flags: 1)
        case "Noise": // 映射为"004": 停止
            return buildStopAllFrame()  // Noise 走 StopAll，pattern 无意义
        default:
            return nil
        }
    }
    
    private func buildSetPatternFrame(patternId: UInt8, intLevel: UInt8, durationMs: UInt16, flags: UInt8) -> Data {
        var payload = Data()
        payload.append(patternId)
        payload.append(intLevel)
        payload.append(contentsOf: durationMs.littleEndianBytes)
        payload.append(flags)
        
        return buildFrame(cmd: CMD_SET_PATTERN, payload: payload)
    }
    
    private func buildStopAllFrame() -> Data {
        return buildFrame(cmd: CMD_STOP_ALL, payload: Data())
    }
    
    // [NEW] 构建恢复控制帧
    private func buildResumeFrame() -> Data {
        return buildFrame(cmd: CMD_RESUME_APP, payload: Data())
    }
    
    private func buildFrame(cmd: UInt8, payload: Data) -> Data {
        var frame = Data()
        
        // SOF
        frame.append(0xAA)
        frame.append(0x55)
        
        // VER
        frame.append(VER)
        
        // CMD
        frame.append(cmd)
        
        // SEQ
        frame.append(seq)
        
        // LEN (小端)
        let len = UInt16(payload.count)
        frame.append(contentsOf: len.littleEndianBytes)
        
        // PAYLOAD
        frame.append(payload)
        
        // CRC计算 (覆盖 VER..PAYLOAD)
        var crcData = Data()
        crcData.append(VER)
        crcData.append(cmd)
        crcData.append(seq)
        crcData.append(contentsOf: len.littleEndianBytes)
        crcData.append(payload)
        
        let crc = calculateCRC16CCITT(data: crcData)
        frame.append(contentsOf: crc.littleEndianBytes)
        
        seq = seq &+ 1 // 自增，溢出后自动回0
        
        return frame
    }
    
    // MARK: - CRC16-CCITT
    private func calculateCRC16CCITT(data: Data) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        
        for byte in data {
            crc ^= UInt16(byte) << 8
            
            for _ in 0..<8 {
                if (crc & 0x8000) != 0 {
                    crc = (crc << 1) ^ 0x1021
                } else {
                    crc <<= 1
                }
                crc &= 0xFFFF
            }
        }
        
        return crc
    }
    
    // MARK: - Frame Parsing
    private func parseIncomingFrame(data: Data) {
        guard data.count >= 9 else { return } // 最小帧长度
        
        var index = 0
        
        // SOF
        guard data[index] == 0xAA, data[index + 1] == 0x55 else { return }
        index += 2
        
        // VER
        let ver = data[index]
        index += 1
        
        // CMD
        let cmd = data[index]
        index += 1
        
        // SEQ
        let rseq = data[index]
        index += 1
        
        // LEN (小端)
        let len = UInt16(data[index]) | (UInt16(data[index + 1]) << 8)
        index += 2
        
        // 检查数据长度
        guard data.count >= index + Int(len) + 2 else { return }
        
        // PAYLOAD
        let payload = data.subdata(in: index..<(index + Int(len)))
        index += Int(len)
        
        // CRC (小端)
        let receivedCrc = UInt16(data[index]) | (UInt16(data[index + 1]) << 8)
        
        // 验证CRC
        var crcData = Data()
        crcData.append(ver)
        crcData.append(cmd)
        crcData.append(rseq)
        crcData.append(contentsOf: len.littleEndianBytes)
        crcData.append(payload)
        
        let calculatedCrc = calculateCRC16CCITT(data: crcData)
        
        guard receivedCrc == calculatedCrc else {
            print("CRC校验失败")
            return
        }
        
        // 处理命令
        if cmd == (0x80 + CMD_SET_PATTERN) ||
           cmd == (0x80 + CMD_STOP_ALL) ||
           cmd == (0x80 + CMD_RESUME_APP) {
            // ACK
            if payload.count >= 2 {
                let ackSeq = payload[0]
                let status = payload[1]
                print("收到ACK: cmd=0x\(String(format: "%02X", cmd)) seq=\(ackSeq) status=\(status)")
                
                // [NEW] 锁定期：ACK=BUSY -> 进入暂停并提示
                if status == 1 { // BUSY
                    isPausedByLocal = true
                }
                
                // [NEW] 恢复命令成功 -> 清暂停
                if cmd == (0x80 + CMD_RESUME_APP) && status == 0 {
                    isPausedByLocal = false
                }
            }
        } else if cmd == CMD_STATE_RPT {
            print("收到状态报告，长度=\(payload.count)")
            parseStateReport(payload: payload)  // [NEW]
        } else {
            print("收到命令: 0x\(String(format: "%02X", cmd)) 长度=\(len)")
        }
    }
    
    // [NEW] 解析StateReport扩展字段
    private func parseStateReport(payload: Data) {
        guard payload.count >= 12 else { return }
        
        var offset = 0
        
        // 跳过基础字段
        offset += 2 // FW_VER
        offset += 2 // BAT_mV
        offset += 2 // TEMP_dC
        offset += 1 // CH_CNT
        offset += 1 // CUR_PATTERN
        offset += 1 // CUR_INTLVL
        offset += 2 // RUN_REMAIN
        offset += 1 // FLAGS
        
        // 解析扩展字段（至少9字节）
        guard payload.count >= offset + 9 else { return }
        
        let rev = UInt16(payload[offset]) | (UInt16(payload[offset + 1]) << 8)
        offset += 2
        
        let src = payload[offset]
        offset += 1
        
        let chgMask = payload[offset]
        offset += 1
        
        let owner = payload[offset]
        offset += 1
        
        let holdMode = payload[offset]
        offset += 1
        
        let holdTtl = UInt16(payload[offset]) | (UInt16(payload[offset + 1]) << 8)
        offset += 2
        
        let btnCode = payload[offset]
        offset += 1
        
        print("StateReport: src=\(src) owner=\(owner) holdMode=\(holdMode) holdTtl=\(holdTtl)")
        
        // 根据状态更新暂停标志
        if src == SRC_BUTTON && holdMode == HOLD_MANUAL {
            // 本地按键触发手动锁定
            isPausedByLocal = true
        }
        
        if holdMode == HOLD_NONE {
            // 无锁定，恢复正常
            isPausedByLocal = false
        }
    }
}

// MARK: - CBCentralManagerDelegate
extension BluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            print("蓝牙已开启")
        case .poweredOff:
            print("蓝牙已关闭")
        default:
            break
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? ""
        
        if name.hasPrefix(TARGET_NAME_PREFIX) {
            print("发现目标设备: \(name)")
            self.peripheral = peripheral
            stopScan()
            centralManager.connect(peripheral, options: nil)
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("已连接到设备")
        isConnected = true
        peripheral.delegate = self
        
        // 请求更大的MTU (iOS会自动协商，这里只是触发)
        peripheral.discoverServices([SERVICE_UUID])
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("连接失败: \(error?.localizedDescription ?? "")")
        isConnected = false
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        print("设备断开连接")
        isConnected = false
        rxCharacteristic = nil
        txCharacteristic = nil
        self.peripheral = nil
        isPausedByLocal = false  // [NEW] 断开时清除暂停状态
        setAnalysisRunning(false)  // [NEW] 断开后分析链路不再驱动转动
    }
}

// MARK: - CBPeripheralDelegate
extension BluetoothManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services else {
            print("发现服务失败")
            return
        }
        
        for service in services {
            if service.uuid == SERVICE_UUID {
                print("发现目标服务")
                peripheral.discoverCharacteristics([RX_CHAR_UUID, TX_CHAR_UUID], for: service)
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, let characteristics = service.characteristics else {
            print("发现特征失败")
            return
        }
        
        for characteristic in characteristics {
            if characteristic.uuid == RX_CHAR_UUID {
                rxCharacteristic = characteristic
                print("发现RX特征")
            } else if characteristic.uuid == TX_CHAR_UUID {
                txCharacteristic = characteristic
                print("发现TX特征")
                
                // 订阅通知
                if characteristic.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            }
        }
        
        if rxCharacteristic != nil && txCharacteristic != nil {
            print("蓝牙连接完全就绪")
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic.uuid == TX_CHAR_UUID {
            if characteristic.isNotifying {
                print("已开启TX通知")
            } else {
                print("TX通知已关闭")
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic.uuid == TX_CHAR_UUID, let data = characteristic.value {
            print("收到数据: \(data.hexString)")
            parseIncomingFrame(data: data)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("写入失败: \(error.localizedDescription)")
        } else {
            print("写入成功")
        }
    }
}

// MARK: - Helper Extensions
extension UInt16 {
    var littleEndianBytes: [UInt8] {
        return [UInt8(self & 0xFF), UInt8((self >> 8) & 0xFF)]
    }
}

extension Data {
    var hexString: String {
        return map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

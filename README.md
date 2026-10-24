# Xcup iOS

一个运行在 iOS 端的实时视频理解与 BLE 联动项目。

Xcup iOS 会从本地视频或在线/直播画面中提取图像与音频，在设备端识别动作状态和节律强度，经过融合仲裁与状态管理后，将控制指令发送给兼容的 BLE 硬件。

本项目由 [Xcup Android](https://github.com/Tingfu-Zhou/xcup-android) 移植而来，保留了 Android 版的端侧推理、多模态融合、播放同步和 BLE 控制逻辑，并使用 AVFoundation、CoreBluetooth、Swift 与 GCD 等 Apple 平台技术重新实现。

> 本项目涉及成人内容识别场景，仅面向成年人。请在遵守当地法律、内容授权、隐私保护和第三方平台规则的前提下使用。

## 功能概览

- 本地视频分析：从系统照片或文件选择器载入视频，播放过程中同步分析画面与音频。
- 在线/直播分析：提供与 Android 在线模式对应的实时画面分析能力。
- 端侧视觉推理：使用 MobileNetV3Small TFLite 模型识别剧情、口部动作和性交动作三类画面。
- 端侧音频推理：使用 YAMNet 与自定义分类器识别动作类别；同一次推理还读取 YAMNet 自带的 AudioSet 521 类分数，判断这一刻音频靠不靠得住（音频线索：对白、音乐、安静、听不出、人声、拍打等）。
- 节律强度估计：根据 PCM 音频生成离散强度档位，并与动作状态一同发送给硬件。
- 多模态融合（融合仲裁 v2）：把马达的启动、维持、停止分开判断，证据按新推理结果计数；启动要两路佐证或持续的音频证据，维持只要任一路有支持，降低单模态误判造成的误转和动作中误停。启动时还参考音频线索：音频被背景音乐盖住、连续听不出时允许视频单独启动；视频确定是剧情时，对白引起的音频误判不算启动证据。
- BLE 控制：使用 CoreBluetooth 实现自动扫描、连接、协议帧构建、CRC 校验、状态解析和指令发送。
- 手动电子菜单：在 App 内直接选择变频模式（1-3）与马达强度（0-10 档），无需在设备上轮询实体按键。要先在主页连上蓝牙设备才能进入，没连上时入口置灰，点击只提示。
- 定时加档（在手动电子菜单里打开，默认关闭）：视频分析累计播放满设定时间（1-30 分钟）后，发给设备的档位自动 +1 / +2，模拟临近高潮；0 档仍为停止，最高 10 档。暂停、静音时不计时，退出当前模式或视频播完后重新计时。
- 本地按键优先：硬件按键可暂停 App 控制，暂停时屏幕底部弹出提示；用户可在手动电子菜单页点「恢复控制」手动恢复（主界面的恢复按钮已隐藏）。
- 播放同步：支持播放、暂停、Seek、播放结束恢复和横竖屏切换；Seek 后会重置历史状态并重新同步分析链路。
- 应用更新检查：通过远端版本配置判断推荐更新或强制更新，并跳转 App Store。
- 多语言界面：中文、日语与英语，按系统语言自动切换；也可以在「设置 → Xcup → 语言」里单独为本 App 选择语言。

## 与 Android 版的关系

| 能力 | Android | iOS |
| --- | --- | --- |
| 本地视频分析 | 支持 | 支持 |
| 在线/直播分析 | 支持 | 支持 |
| 网页视频模式 | 已移除 | 不支持 |
| 端侧视觉推理 | TensorFlow Lite | TensorFlow Lite |
| 端侧音频推理 | YAMNet + 自定义分类器 | YAMNet + 自定义分类器 |
| BLE | Android BLE API | CoreBluetooth |
| 播放器 | VideoView | AVPlayer |

Android 版是本项目的上游实现参考。两端尽量保持模型输入、融合逻辑、动作映射和 BLE 行为一致，但受平台 API 与多媒体架构差异影响，部分实现并非逐行对应。

## 工作原理

```mermaid
flowchart TB
    A["输入源<br/>本地视频 / 在线画面"] --> B["采集与解码<br/>视频帧 + PCM 音频"]
    B --> C["视觉分类<br/>MobileNetV3Small"]
    B --> D["音频分类<br/>YAMNet + 自定义分类器"]
    B --> E["节律估计<br/>PCM → 档位"]
    C --> F["融合仲裁"]
    D --> F
    F --> G["BLE 状态管理"]
    E --> G
    G --> H["兼容硬件"]
```

系统主要由三个并行工作链路组成：

1. 视频链路按播放时间提取帧，维护 12 帧时序窗口，并周期性执行 MobileNetV3Small 推理。
2. 音频链路把音频统一处理为 16 kHz PCM，从环形缓冲区读取最近约 2 秒、共 32,000 个采样点的数据并执行 YAMNet 推理，用同一次推理的 AudioSet 分数判音频线索（`AudioCue`），同时估计节律强度。
3. 融合链路每 500ms 读取最新结果（音频结果附带线索），过滤过期数据，由融合仲裁 `FusionArbiter` 决定本 tick 的动作（启动、维持、停止分开判断），连同音频响度档位交给 BLE 状态管理器发送。

视频和音频推理运行在独立后台队列中；UI 更新、融合结果消费和用户交互由主线程协调。共享结果通过线程安全容器、`DispatchQueue` barrier 等机制管理，避免 PCM 缓冲与分析状态发生并发读写冲突。

## Android 到 iOS 的主要映射

| Android 实现 | iOS 实现 |
| --- | --- |
| `VideoProcessActivity.java` | `VideoProcessViewController.swift` |
| VideoView / ExoPlayer | AVPlayer |
| MediaExtractor + MediaCodec（音频解码） | AVAssetReader + AVAssetReaderTrackOutput |
| `VideoFrameExtractor.java` + `EGLRenderer.java`（抽帧） | `VideoFrameExtractor.swift`：AVPlayerItemVideoOutput + vImage |
| `FramePreprocessor.java` | `FramePreprocessor.swift`（逐行移植，`XcupTests` 用 Android 的对拍数据逐位校验） |
| `ScreenCropper.java` | `ScreenCropper.swift`（逐行移植，`XcupTests` 用 Android 的对拍数据逐帧校验） |
| `OnlineAnalysisService.java`（MediaProjection 录屏） | `XcupBroadcast` 广播上传扩展（ReplayKit）：按 `RPVideoSampleOrientationKey` 转正，画面连同方向经 App Group 传给主 App |
| Handler / Runnable | DispatchQueue、DispatchSourceTimer、CADisplayLink |
| `PcmCircularBuffer.java` | `PcmCircularBuffer.swift` |
| `FusionArbiter.java` | `FusionArbiter.swift`（逐行移植，`XcupTests` 用 Android 的对拍数据逐 tick 校验） |
| `AudioCue.java` | `AudioCue.swift`（逐行移植，`XcupTests` 用 Android 的对拍数据逐位校验分组分数和线索） |
| `LevelBoost.java` | `LevelBoost.swift`（逐行移植，`XcupTests/LevelBoostTests` 与 Android `LevelBoostTest` 一一对应） |
| `AudioInferenceHelper.java` | `AudioInferenceHelper.swift` |
| Android BLE API | `BluetoothManager.swift` + CoreBluetooth |
| `synchronized` / 原子变量 | DispatchQueue barrier、同步读取和线程安全结果容器 |

## 核心组件

| 组件 | 作用 |
| --- | --- |
| `ContentView.swift` | 主界面、视频选择、BLE 状态、在线分析入口和导航 |
| `VideoProcessViewController.swift` | 视频播放、音视频分析、结果融合、UI 更新和 BLE 控制 |
| `VideoFrameExtractor.swift` | 用 AVPlayerItemVideoOutput 取播放器此刻显示的那一帧，居中裁正方形、vImage 缩到 672×672 后交给 FramePreprocessor，并按 preferredTransform 转正 |
| `FramePreprocessor.swift` | 视频模型输入的预处理（居中裁正方形、面积平均缩小到 160×160），与训练素材的处理一致，离线、在线两种模式共用 |
| `ScreenCropper.swift` | 在线模式：在截屏里找出视频画面（去掉四周对称的黑边），再交给 `FramePreprocessor` 取视频画面的居中正方形 |
| `AudioDecoder.swift` | 使用 AVAssetReader 解码音频、限速、Seek 并写入 PCM 缓冲区 |
| `PcmCircularBuffer.swift` | 管理 PCM 环形缓冲、时间窗口读取和并发访问 |
| `AudioInferenceHelper.swift` | YAMNet 特征提取与自定义音频分类器推理；同一次推理取 AudioSet 521 类分数 |
| `AudioCue.swift` | 音频线索：AudioSet 分数按含义分组求和，判对白 / 音乐 / 安静 / 听不出 / 人声 / 拍打 / 其它，交给融合仲裁的启动判断 |
| `ThreadSafeAnalysisResults.swift` | 在线程之间安全保存和读取分析结果 |
| `FusionArbiter.swift` | 融合仲裁：根据两路的新推理结果（音频带线索）决定马达的启动、维持与停止，离线模式与在线模式共用 |
| `LevelBoost.swift` | 定时加档：只累计分析在跑的时间，到点后发给设备的档位加 1 / 2 档（分析档位不变）；设置的键名与读取在 `LevelBoostSettings` |
| `ManualControlView.swift` | 手动电子菜单：模式选择、强度滑杆、紧急停止与下发节流；定时加档的设置 |
| `BluetoothManager.swift` | BLE 扫描、连接、协议帧编解码、CRC 校验和状态管理 |

## 模型规格

### 视频模型

- 骨干网络：MobileNetV3Small + Temporal Average Pooling + 三分类器
- 模型文件：`mobilenetv3small_tap_3class_float32.tflite`
- 输入：`[1, 12, 160, 160, 3]`，`float32`，NHWC，RGB；12 帧是最近 3 秒里间隔 250ms 的 12 个不同时刻
- 像素范围：`0-255`，模型内部包含 Rescaling，不应再次归一化
- 每帧的预处理与训练素材一致：先转正，再居中裁正方形（边长 = 短边），面积平均缩到 224，再缩到 160（`FramePreprocessor`）；在线模式先去掉截屏里视频四周的黑边（`ScreenCropper`），取的是视频画面的居中正方形
- 输出：`normal_plot`、`oral`、`sex` 三类 softmax 概率

### 音频模型

- 特征提取：预训练 YAMNet
- 分类器：面向当前任务微调的三分类模型
- 输入：2 秒、16 kHz、单声道 PCM，共 32,000 个 `Float` 采样点
- 输出：动作类别、置信度与时间戳；另有 YAMNet 自带的 AudioSet 521 类分数（4 帧平均），用来判音频线索
- iOS 注意事项：YAMNet 输入张量可能使用动态长度，复制 32,000 个采样点前应先将输入张量调整为正确形状，再分配张量内存
- YAMNet 有 3 个输出（`[帧, 521]` AudioSet 分数、`[帧, 1024]` embedding、频谱图），代码按最后一维认输出，不写死下标；动态长度输入的输出张量要 invoke 之后才有数据，所以在第一次推理后认一次。模型里没有 521 维输出时线索一直是未知，融合仲裁退回 v1 的行为

第三方预训练模型与相关资源仍受各自许可证和使用条款约束。自定义模型是否随仓库提供，请以 Xcode 工程中实际加入 App Target 的资源文件为准。

## 网页视频模式

两端都不提供网页视频模式：Android 版已在上架 Google Play 前移除（最后一版代码在 xcup-android 的 tag `web-video-archive`），iOS 版一直没有移植。下面是当初 iOS 没有移植的原因，留作参考。

本地 MP4 和渐进式下载 MP4 可以通过 AVAssetReader 等公开 API 取得解码后的音频数据，满足 YAMNet 所需的 PCM 输入。对于 HLS 自适应码流，AVPlayer/CoreMedia 负责清单解析、码流选择、分片加载和解码；在本项目采用的公开 API 与播放架构下，无法像 Android ExoPlayer 一样，在完整 HLS 音频链路中稳定取得可供实时推理的 PCM 数据。

我们评估过 `MTAudioProcessingTap` 方案，但它不能为当前 HLS 多码率播放链路提供稳定、通用的 PCM 接入点。因此，为避免出现视频能够播放但音频分析不可用或结果不一致的情况，iOS 版暂不开放网页视频模式。

这属于当前实现与平台公开接口的边界，并不表示 iOS 在任何架构下都无法分析 HLS。若未来引入自定义 HLS 下载、解复用与解码链路，可重新评估该功能。

参考资料：

- [Apple HTTP Live Streaming](https://developer.apple.com/streaming/)
- [Apple MTAudioProcessingTap](https://developer.apple.com/documentation/mediatoolbox/mtaudioprocessingtap)
- [Android Media3 ExoPlayer](https://developer.android.com/media/media3/exoplayer)

## 开始使用

### 环境要求

- macOS 与项目所需版本的 Xcode
- 项目 Deployment Target 支持的 iOS/iPadOS 真机
- 有效的 Apple Developer 签名配置
- 支持 BLE 的 iPhone 或 iPad
- CocoaPods，以及项目所需的 TensorFlow Lite、ML Kit 等依赖
- 与目标硬件一致的 BLE 服务、特征 UUID 和协议帧格式

模拟器不适合完整验证 CoreBluetooth、实体设备控制、视频性能和真机生命周期行为，建议使用真机调试。

### 1. 获取代码

将本仓库克隆或下载到本地。

### 2. 安装依赖

如果仓库包含 `Podfile`，在项目目录执行：

```bash
pod install
```

完成后打开 `.xcworkspace`，不要直接打开 `.xcodeproj`。

### 3. 准备模型

确认视频模型、YAMNet 和自定义音频分类器已经加入 Xcode 工程，并勾选正确的 App Target。模型文件必须被复制到最终 App Bundle，且文件名应与代码中的加载路径一致。

### 4. 配置 BLE

在 `BluetoothManager.swift` 或对应配置文件中确认：

- 目标设备名称前缀
- Service UUID
- RX/TX Characteristic UUID
- 指令帧、CRC 与状态解析规则
- 动作和强度档位映射

仓库中的默认值未必适用于其他硬件。错误的协议、方向或档位映射可能导致设备行为异常，请先在低强度和空载状态下测试。

### 5. 配置权限与签名

在 Target 的 Signing & Capabilities 以及 `Info.plist` 中确认蓝牙、照片/文件访问及在线模式所需权限。蓝牙用途说明至少应与实际功能一致，例如：

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>本应用需要使用蓝牙连接和控制智能设备。</string>
```

请根据实际 Deployment Target 判断是否仍需兼容旧版蓝牙权限键，不要添加与功能无关的权限。

### 6. 构建与运行

1. 在 Xcode 中选择正确的 App Target。
2. 设置 Team、Bundle Identifier、Version 和 Build。
3. 连接 iPhone 或 iPad 真机。
4. 执行 Build & Run。

## 多语言

界面文字支持中文、日语和英语，按系统语言自动切换：按「设置 → 通用 → 语言与地区」里首选语言的顺序，取第一个本 App 支持的语言；三种都不在列表里时显示中文（工程的开发语言是简体中文）。用户也可以在「设置 → Xcup → 语言」里单独为本 App 选择语言。

- `Xcup/Localizable.xcstrings`：界面文字。键就是代码里的中文原文，日语、英语译文分别写在 `ja`、`en` 下
- `Xcup/InfoPlist.xcstrings`：蓝牙、相册、麦克风等权限说明的日语、英语译文（中文原文仍在 Build Settings 的 `INFOPLIST_KEY_*` 里）

新增界面文字时：SwiftUI 的 `Text("中文")`、`Label("中文", systemImage:)` 等在编译时会自动收进 `Localizable.xcstrings`，在 Xcode 里补上日语和英语即可；UIKit 控件的文字、或先存进 `String` 变量再显示的文字，要写成 `String(localized: "中文")`，否则不会被翻译。带插值的文字（如 `"\(n) 分钟后"`）在表里显示为 `%lld 分钟后`，日语、英语译文保留同样的占位符。只在调试悬浮窗和日志里出现的文字不需要翻译。

英文按北美用法：按钮和标题用 Title Case（如 Emergency Stop），提示句只有句首大写；撇号和引号用 ’ “ ”。

更新弹窗的说明来自 `version.json` 的 `ios` 段：可以加 `notes_ja`、`notes_en`。界面是日文时显示 `notes_ja`，没填就显示 `notes`；界面是英文时显示 `notes_en`，没填就显示弹窗自带的英文默认说明（不显示中文的 `notes`）。

## 使用流程

### 本地视频

1. 在主界面连接 BLE 设备。
2. 从照片或文件选择器中选择视频。
3. 播放视频，应用会启动音视频分析与 BLE 联动。
4. 暂停、Seek 或退出播放时，应用会暂停分析并发送停止状态；恢复后重新同步。

### 在线/直播分析

1. 进入在线分析模式并完成系统要求的授权。开始广播后页面只显示「在线分析已启动」（Debug 构建左上角另有 V / A / Final 三行调试信息，Release 包不显示），不显示录到的画面（录屏也会录到这个页面，再显示出来就是画面里套画面），与 Android 相同。
2. 启动需要分析的实时画面来源。横屏全屏播放时，截到的画面与训练素材的取法一致，识别效果最好。
3. 应用持续执行画面、音频、融合和 BLE 控制链路。截屏里视频四周的黑边（竖屏全屏播放、横屏看竖屏视频）先去掉再居中裁剪；转屏后 12 帧窗口清空重攒，约 3.5 秒后出第一个视频结果。
4. 退出在线模式时停止分析并向硬件发送停止状态。

## 蓝牙协议

本项目通过 BLE 与 Xcup 硬件进行通信。关于第一批 Xcup 硬件使用的 BLE 通信协议、相关资料与参考实现，请参阅：

- [Xcup Bluetooth Protocol](https://github.com/Tingfu-Zhou/Xcup-Bluetooth-protocol)

不同硬件批次或固件版本使用的协议可能存在差异。进行硬件适配时，请以目标设备的实际固件和协议版本为准。

## 已知限制

- 不支持网页视频模式（Android 版也已移除）；网页上的视频可以用「在线视频模式」通过屏幕录制分析。
- Photos 资源的导入行为可能涉及系统转码或临时文件准备，大体积视频的载入时间和内存占用取决于当前实现与设备状态。
- BLE 协议和档位映射与具体硬件绑定，不能直接保证兼容其他设备。
- 模型结果依赖训练数据分布，不应将分类输出视为对内容的绝对判断。
- iOS 后台执行、屏幕采集和音频处理能力受系统生命周期、权限和目标内容保护策略影响。

## 隐私与合规

- 音视频识别链路设计为端侧推理；如二次开发中加入日志上传、统计分析或云端推理，应明确告知用户并取得必要授权。
- 仅分析你有权访问和处理的内容，不得处理涉及未成年人、偷拍、胁迫或其他违法内容。
- 视频导入、屏幕采集和音频处理应遵守当地法律、内容版权、App Store 规则及目标服务的使用条款。
- 接入实体硬件前请增加强度上限、停止指令、连接异常处理和人工中止机制，并充分测试。

## 贡献

欢迎提交 Issue 和 Pull Request。提交改动时建议：

- 说明 Xcode、iOS/iPadOS、设备型号和复现步骤。
- 将模型调整、多媒体链路、BLE 协议和 UI 改动拆分为独立提交。
- 不要提交无权公开的视频、音频、训练数据、证书、Provisioning Profile、密钥或设备唯一标识。
- 对涉及线程、PCM 缓冲、Seek、暂停恢复或 BLE 状态机的改动补充真机测试结果。

## 相关项目

- [Xcup Android](https://github.com/Tingfu-Zhou/xcup-android)：本项目的 Android 上游实现
- [Xcup Bluetooth Protocol](https://github.com/Tingfu-Zhou/Xcup-Bluetooth-protocol)：第一批硬件使用的 BLE 协议资料与参考实现

## 许可证

本项目源代码采用 [Apache License 2.0](LICENSE) 开源。你可以在遵守许可证条款的前提下使用、修改和分发本项目代码，包括将其用于商业项目。

第三方依赖、预训练模型、自定义模型权重、训练数据及其他资源不一定适用 Apache License 2.0，应分别遵守其各自的许可证和使用条款。

Apache License 2.0 不授予对 Xcup 名称、商标、产品图片、Logo 或其他品牌资产的使用权。

## 致谢

- [AVFoundation](https://developer.apple.com/av-foundation/)
- [Core Bluetooth](https://developer.apple.com/documentation/corebluetooth)
- [LiteRT / TensorFlow Lite for iOS](https://ai.google.dev/edge/litert/ios/quickstart)
- [MobileNetV3Small](https://www.tensorflow.org/api_docs/python/tf/keras/applications/MobileNetV3Small)
- [YAMNet](https://www.tensorflow.org/hub/tutorials/yamnet)

---

如果这个项目对你有帮助，欢迎 Star、提交反馈，或分享你的改进方案。我的个人QQ:3247499719

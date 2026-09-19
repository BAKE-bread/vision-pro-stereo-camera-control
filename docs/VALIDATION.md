# 验证范围

## 自动化结果

| 检查 | 结果 |
|---|---|
| Python 3.12.14 服务端、协议及硬件故障注入 | **91 passed**，2 条第三方弃用警告 |
| Xcode 16.4 / visionOS Simulator 2.5 | **24 tests，0 failures，0 skips**；`StereoStudioLocal` scheme |
| visionOS 设备目标 | **BUILD SUCCEEDED**；arm64 / visionOS 2.5 SDK，未签名 |
| 原生 LiveKit 媒体 | 真实本机服务发布，Swift SDK 订阅解码，640×720 帧进入 Core Image/Metal 并生成双目材质 |
| Python LiveKit 媒体 | H.264 链路解码 10 帧，尺寸 640×720，左右半帧内容差异检查通过 |
| 断线恢复 | 强制移除模拟发布者，约 2.24 秒重新入房并发布；再次成功解码 10 帧 |
| 深度与控制联调 | HTTP 快照/点测距；原生 WebSocket 控制连续重启；断连与租约超时释放 |
| 播放器 | AVFoundation 加载真实本机 MP4/HLS；Range 请求；清单持久化、导入、异常及路径校验 |
| GPU 像素测试 | 上半帧红色进入左纹理，下半帧蓝色进入右纹理；无效尺寸及迟到回调拒收 |
| 头姿数学与 API | 非零基准姿态、向右 yaw/向上 pitch、平移隔离、大幅跳变拒收；SDK 声明的权限不含 world sensing |
| 云台故障注入 | 型号/模式/偏移/限位/速度/硬件错误检查；第二轴故障前零写入；扭矩 ACK 丢失关闭；运行故障锁止 |
| ZED 故障注入 | 初始化失败关闭；同次采集、BGRA/RGB、深度类型、内参尺寸、缓冲所有权、返回码和时间戳检查 |
| 资源与语法 | 19 个 Swift 文件、21 个工程文件引用、plist/scheme 检查通过，并完成 SDK 编译 |

## 证据文件

项目本地 `artifacts/hardware-audit/`：

- `pytest.log`：Python 测试结果。
- `NativeTests-verified.xcresult`、`xcode-tests-verified.log`：完整原生测试结果。
- `xcode-device.log`：设备目标构建结果。
- `smoke.json`、`smoke-after-reconnect.json`：真实媒体与控制链路结果。
- `reconnect.json`：发布者断开后的恢复结果。
- `server.log`、`livekit-server.log`：仅回环地址的测试服务日志。
- `reference-sha256.json`：审查时获取的官方接口参考文件校验信息。
- `source-preservation.json`：既有源码文件存在性及原型文件哈希检查。

本地测试文件不随纯源码包导出。LiveKit 服务器 1.13.7 使用 Homebrew 官方 arm64 Sequoia bottle，按公式提供的 SHA-256 校验，直接解压到测试目录。Python 媒体 SDK 为 1.1.19 / API 1.2.1；Swift SDK 为 2.17.0，依赖由工程 `Package.resolved` 固定。

最初的坐标测试使用浮点数精确相等判断，产生约 1e-7 度的舍入差异；验证版本使用 1e-5 度容差。原始失败结果也保留。系统/第三方日志包含模拟器音频会话、关闭 socket、参与者断开竞态及无 AppIntents 元数据的非致命提示；上述通过结果不表示日志完全没有提示。

## 证据边界

没有连接真实 ZED、云台或 Vision Pro，因此以下内容没有设备运行证据：

- ZED 的 CUDA/USB 驱动行为、NEURAL 实测精度、相机校准、真实拔插及长时间运行。
- 具体云台的供电、总线电气类型、安装符号、传动比例、承载、机械限位和扭矩关闭后的重力行为。
- 实际头姿追踪与系统空间重定位、真实左右眼显示、UV 方向、色彩和舒适度。
- 跨设备无线链路、NAT/TURN、防火墙、弱网或端到端延迟。
- 系统文件选择器、iCloud 大文件和完整 AVKit 人工交互流程。
- 应用签名、分发或 App Store 审核。

## 复现

按 [运行指南](RUNBOOK.md) 启动本机 mock API 和 LiveKit，生成 `demo.mp4` / `demo.m3u8`，然后执行：

```bash
bash tools/validate_macos.sh --local
.venv-macos/bin/python tools/smoke_test.py --livekit --output artifacts/smoke-local.json
```

控制测试与其他控制客户端串行执行。没有配置 LiveKit 时，原生媒体联调会明确跳过；没有本机服务时使用不启用本机联调的 `StereoStudio` scheme。测试不能转化为未接入硬件的真机验收结论。

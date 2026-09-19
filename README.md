# Stereo Studio

Stereo Studio 是一套用于 Apple Vision Pro 的视频播放、远程双目观看和深度测量程序，由原生 visionOS App、Python 相机服务和可选的 LiveKit 媒体服务组成。

## 功能

| 功能 | 说明 |
|---|---|
| 视频播放器 | 从“文件”导入视频，保存播放列表与播放进度，播放 HTTP 视频和 HLS；使用系统 AVKit 控件 |
| 远程双目观看 | 通过 LiveKit/WebRTC 接收上下排列的左右目视频，在沉浸空间中按眼别显示 |
| 头部跟随 | 将相对头部转动转换为双轴云台目标角，支持独占控制、限位、限速、超时释放和模拟角度输入 |
| 深度工具 | 显示左目快照、深度热图和近距离提示；对固定快照选点测距，保留最近 20 条会话内记录 |
| 无设备模式 | 使用合成双目图像和解析深度运行服务、浏览器页面与自动化测试，不打开硬件执行器 |

头部控制包含 yaw/pitch 转动，不包含头部平移或六自由度相机运动。播放器使用 AVFoundation 支持的媒体格式；RTSP/RTMP 需要转换为 HLS 或 LiveKit 流。深度近距离提示不承担碰撞检测或机械保护功能。

## 运行环境

| 组件 | 环境与依赖 |
|---|---|
| visionOS App | visionOS 2.0+；Xcode 16.3+；LiveKit Swift 2.17.0，依赖版本由 `Package.resolved` 固定 |
| 模拟相机服务 | Python 3.12；Windows、macOS 或 Linux |
| ZED 相机服务 | Stereolabs 支持的 Windows/Linux 或 Jetson 主机、匹配的 NVIDIA/CUDA 环境、ZED SDK 与对应版本的 `pyzed`；使用 HD720/30、NEURAL 深度模式 |
| 双轴云台 | ROBOTIS Protocol 2.0，XM430-W350 或 XL430-W250，固件版本 45+；匹配的 TTL/RS-485 接口、供电和机械校准 |
| 实时双目传输 | LiveKit 服务；Python `livekit==1.1.19`、`livekit-api==1.2.1` |

macOS 可以运行模拟相机和构建 App，不是该 CUDA 深度采集路径的 ZED 主机。相机适配器使用 USB 双目相机的 HD720 模式；ZED X/X One 的 GMSL/MIPI 采集配置不在此接口范围内。

## 快速启动

在项目根目录执行。macOS/Linux：

```bash
python3.12 -m venv .venv-macos
.venv-macos/bin/python -m pip install -r server/requirements-livekit.txt pytest httpx
.venv-macos/bin/python -m server --host 127.0.0.1 --port 8765
```

Windows PowerShell：

```powershell
py -3.12 -m venv .venv312
.\.venv312\Scripts\python.exe -m pip install -r server/requirements-livekit.txt pytest httpx
.\.venv312\Scripts\python.exe -m server --port 8765
```

浏览器打开 `http://127.0.0.1:8765`；交互式 API 文档位于 `/docs`。默认源为 `mock`，深度快照和浏览器控制不要求 LiveKit。

使用 Xcode 打开 `apple/StereoStudio.xcodeproj`，选择 `StereoStudio` scheme 和 visionOS Simulator 或设备。安装到设备需要配置签名团队。App 的“远程视角”连接相机服务地址；实时沉浸式双目视频还需要配置 LiveKit。模拟器使用“模拟头部角度”。

## 服务配置

| 环境变量 | 用途 | 默认值 |
|---|---|---|
| `STEREO_SOURCE` | `mock` 或 `zed` | `mock` |
| `STEREO_API_TOKEN` | HTTP/WebSocket 访问令牌；监听局域网地址时必填 | 空 |
| `ENABLE_HARDWARE` | `1` 才允许打开 ZED 或云台 | 关闭 |
| `GIMBAL_CALIBRATION` | 云台校准 JSON 路径；仅能与 `zed` 源组合 | 空 |
| `LIVEKIT_URL` | 相机服务连接 LiveKit 的地址 | 空 |
| `LIVEKIT_PUBLIC_URL` | 客户端可访问的 LiveKit 地址 | 空 |
| `LIVEKIT_API_KEY` / `LIVEKIT_API_SECRET` | 服务端签发媒体令牌的凭据 | 空 |

默认每眼 640×360，上下合成 640×720；发布目标为 20 fps、5 Mbps，使用 H.264 单轨道。客户端只取得短期订阅令牌，不持有 LiveKit API secret。跨设备连接使用服务器实际地址；设备上的 `127.0.0.1` 指设备自身。

硬件接入的寄存器条件、校准字段、服务配置与网络端口详见 [运行指南](docs/RUNBOOK.md)。示例校准文件不能代表任何具体机械机构的有效校准。

## 数据与故障行为

- 同次 ZED 采集取得左右目和对齐左目的米制深度；上半帧为左目，下半帧为右目。
- 点测距绑定快照 `frame_id`，不把独立 HTTP 深度叠加到无法精确对应的 WebRTC 帧上。
- 过期图像、追踪中断、控制超时或设备错误会停止继续跟随；视频失败时仍可使用独立深度接口。
- 控制断开时保持最后的指令位置；退出服务会关闭云台扭矩。两者都不等同于独立机械急停。
- 云台按型号检查寄存器条件，先验证两轴，再设置运动参数、目标位置和扭矩。串口失联看门狗为 500 ms；故障不会自动清除并重新驱动。
- 媒体库与播放进度存储在 App 沙盒；测距历史只保留在当前 App 会话内。

## 目录

```text
apple/                  visionOS App、材质、Xcode 工程与原生测试
server/                 相机、云台、HTTP/WebSocket、深度与 LiveKit 发布
web/                    浏览器快照与模拟控制界面
tests/                  服务端协议、硬件接口和故障注入测试
tools/                  工程生成、媒体生成、检查与测试工具
docs/                   运行、协议、架构及接口审查文档
artifacts/              本地媒体、构建产物与测试结果
```

## 验证与技术资料

```bash
.venv-macos/bin/python -m pytest -q
# macOS：Python、原生单元/GPU 测试与无签名设备目标构建
bash tools/validate_macos.sh
```

`StereoStudioLocal` scheme 和 `validate_macos.sh --local` 包含本机 HTTP/WebSocket/AVFoundation 联调，要求先启动模拟服务并生成测试媒体。完整步骤见 [运行指南](docs/RUNBOOK.md)。

自动化测试可验证协议、API 调用参数、故障处理和部分渲染行为，不能替代真实相机精度、机械负载、头显追踪及双眼显示的设备证据。接口适用条件与验证范围见 [硬件与 API 审查](docs/HARDWARE_API_AUDIT.md) 和 [验证范围](docs/VALIDATION.md)。

- [接口协议与坐标约定](docs/PROTOCOL.md)
- [会话与设备架构](docs/ARCHITECTURE.md)

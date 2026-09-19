# 运行与设备配置

## Python 服务

Python 3.12 环境安装 `server/requirements-livekit.txt`，再执行 `python -m server --port 8765`。默认只监听本机且使用模拟源，不访问相机或串口。浏览器页面位于 `/`，OpenAPI 文档位于 `/docs`。

macOS/Linux 可使用 `.venv-macos/bin/python`；Windows 可使用 `.venv312\Scripts\python.exe`。虚拟环境必须在对应操作系统上创建。`server/requirements-macos-lock.txt` 提供包含测试工具的完整依赖版本；其他平台使用功能 requirements，ZED 的 Python 包由匹配的 ZED SDK 提供。

## LiveKit 视频服务

从 [LiveKit 官方发行页面](https://github.com/livekit/livekit/releases) 获取适合部署系统的服务器，或使用已有的 LiveKit 服务。以可执行文件 `livekit-server` 已在 PATH 为例，本机开发配置为：

```bash
livekit-server --dev --bind 127.0.0.1 --node-ip 127.0.0.1
```

另一个终端配置相机服务：

```bash
export LIVEKIT_URL=ws://127.0.0.1:7880
export LIVEKIT_PUBLIC_URL=ws://127.0.0.1:7880
export LIVEKIT_API_KEY=devkey
export LIVEKIT_API_SECRET=secret
.venv-macos/bin/python -m server --port 8765
```

PowerShell 环境变量使用 `$env:LIVEKIT_URL='ws://127.0.0.1:7880'` 形式，其余变量同理。`devkey/secret` 仅用于 LiveKit 本机开发模式。部署服务使用独立凭据及 HTTPS/WSS；API secret 只配置在服务器上。

Python 发布者以 `stereo-camera` 身份发布 `stereo` 轨道。发布使用 H.264、单层视频和保持分辨率策略；网络受限时可以降低帧率，不依赖改变双目帧尺寸。房间连接断开后重新连接，客户端会在没有新鲜有效画面时停止跟随。

## 媒体素材

`ffmpeg` 在 PATH 内时，执行：

```bash
.venv-macos/bin/python tools/make_demo_media.py
```

工具生成原创测试图案与音频的 MP4/HLS；发现已有 `demo*` 文件时退出，不覆盖或删除。生成后重启 API，使其挂载媒体目录。

- MP4：`http://127.0.0.1:8765/media/demo.mp4`
- HLS：`http://127.0.0.1:8765/media/demo.m3u8`

服务支持 HTTP Range。浏览器的 HLS 支持与 AVPlayer 不同；原生播放器也可从系统“文件”导入视频。有限时长媒体每五秒及暂停时保存进度，实时流不保存断点。

## visionOS App

使用 Xcode 16.3+ 打开 `apple/StereoStudio.xcodeproj`，选择 `StereoStudio` scheme。设备安装需配置开发团队和 bundle identifier；模拟器无需设备签名。App 部署目标为 visionOS 2.0。

“远程视角”输入 API 地址及令牌，连接后进入立体视角。真实头部跟随要求沉浸空间已打开且持续收到有效双目视频；ARKit world tracking 不要求 world-sensing 权限。系统追踪不可用或中断时停止跟随。模拟器使用模拟角度输入。

深度页点选后固定所选画面，返回实时画面后可继续选点；测距记录在 App 会话内保留最近 20 条。

## 局域网连接

以服务器地址 `192.168.1.20` 为例：

1. 配置 `STEREO_API_TOKEN`，以 `python -m server --host 0.0.0.0 --port 8765` 启动；App 输入同一令牌。
2. App API 地址使用 `http://192.168.1.20:8765`。真机上的 `127.0.0.1` 不是服务器。
3. `LIVEKIT_URL` 可以是服务器回环地址；`LIVEKIT_PUBLIC_URL` 必须是客户端可访问的地址，例如 `ws://192.168.1.20:7880`。
4. LiveKit 的节点地址必须是可达网卡地址，例如 `--bind 0.0.0.0 --node-ip 192.168.1.20`。
5. 本地开发配置涉及 API 8765/TCP、LiveKit 7880/TCP、7881/TCP 和 7882/UDP；其他部署按 LiveKit 自身配置开放端口。

App 声明局域网访问用途，启用局域网 ATS 和媒体加载例外。若系统拒绝数字 IP 明文请求，使用可解析的 `.local` 主机名或可信 TLS。不关闭证书校验。局域网防火墙、客户端隔离和错误的 ICE 地址都可能导致 API 正常而媒体无法连接。

## ZED 相机

采集主机需具备 Stereolabs 支持的操作系统、NVIDIA/CUDA 和 ZED SDK。使用该 SDK 的安装脚本获得匹配的 `pyzed`，不要用无关同名 PyPI 包代替。macOS 的模拟环境不能执行此 CUDA 深度路径。接口面向支持 HD720 的 USB 双目型号；ZED X/X One 的专用接口配置不在此适配器范围内。

在能成功 `import pyzed.sl` 的环境安装服务依赖，然后配置：

```bash
export STEREO_SOURCE=zed
export ENABLE_HARDWARE=1
python -m server --port 8765
```

相机必须正向安装，图像自动翻转关闭。采集为 HD720/30，输出每眼 640×360；NEURAL 深度、米单位、IMAGE 坐标系、范围 0.2–20 m、置信阈值 50、纹理阈值 80，关闭深度填洞。上述范围是软件筛选范围，不代表各型号都能在整个区间达到可用测量精度。

左右目使用校正图像，深度对齐左目；内参由 SDK 按同一输出尺寸提供。成功 grab 后才提取数据，任何返回码错误、数组异常或不递增的 IMAGE 时间戳都拒绝发布。SDK 异步恢复期间不继续提供旧帧。恢复后仍需新的有效画面和新的控制会话，不自动恢复跟随。

## Dynamixel 双轴云台

适配型号：XM430-W350（型号号 1020）和 XL430-W250（1060），固件版本 45+，Protocol 2.0。TTL/RS-485 类型、总线布线、电源、负载支撑必须与实体设备匹配。SDK 包为 `dynamixel-sdk`。

复制 `server/calibration.example.json` 为 `server/calibration.local.json`，填写每轴实际参数。程序不自动扫描 ID、不修改 EEPROM，不自动改变固件、模式或偏移。

| 字段 | 含义 |
|---|---|
| `port` / `baud` | 串口路径及实际波特率 |
| `confirmed_position_mode` | 机械配置与单圈位置模式经确认才设为 `true` |
| `id` / `model_number` | 唯一的主 ID（0–252）及允许的实际型号号 |
| `min_tick` / `center_tick` / `max_tick` | 机构校准范围，满足 `0 ≤ min < center < max ≤ 4095` |
| `sign` | `1` 或 `-1`，对应 yaw 向右为正、pitch 向上为正 |
| `ticks_per_degree` | 机构输出每度对应的编码器 tick，包含传动比例 |
| `profile_velocity` | 非零速度配置，原始寄存器单位 0.229 rpm，不能超过设备 Velocity Limit |
| `profile_acceleration` | 非零加速度配置，原始寄存器单位 214.577 rev/min² |

示例的角度、速度和加速度值都是占位配置，不能说明具体负载可安全使用这些值。

启动前，两轴都必须满足：Drive Mode=0、Operating Mode=3、Secondary ID=255、Homing Offset=0、Torque Enable=0、Status Return Level=2、Hardware Error Status=0；当前位置在校准范围内，设备自身的位置限位包含校准范围，Bus Watchdog 没有锁存错误。程序拒绝不满足条件的设备，不自动改写这些设置。

所有只读检查通过后，程序配置运动参数及 500 ms 总线看门狗，读取当前位置并先写相同目标，再开启扭矩并检查位置连续性。开启扭矩的应答丢失也会触发对应轴的关闭尝试。运行期间检查扭矩、硬件错误、看门狗及编码器边界。

```bash
export STEREO_SOURCE=zed
export ENABLE_HARDWARE=1
export GIMBAL_CALIBRATION=server/calibration.local.json
python -m server --port 8765
```

网络控制断开保持最后指令位置；进程退出关闭扭矩，失去扭矩后负载可能受重力移动。串口中断时由设备看门狗停止运动。故障后不自动清除错误或重新使能。API 显示的是限速后的指令角度，并非连续编码器遥测或独立机械急停状态。

## 自动化验证

```bash
.venv-macos/bin/python -m pytest -q
.venv-macos/bin/python -m pip install tree-sitter tree-sitter-swift openstep-parser
.venv-macos/bin/python tools/check_apple_sources.py
bash tools/validate_macos.sh
```

- `StereoStudio`：原生会话、播放器、坐标转换及 GPU 测试；跳过本机服务联调。
- `StereoStudioLocal` / `validate_macos.sh --local`：额外执行真实 URLSession、WebSocket 和 AVFoundation 测试；要求模拟服务和 MP4/HLS 已就绪。
- 用 `xcrun simctl list devices available` 查询目标；多个同名模拟器时设置 `STEREO_TEST_DESTINATION='platform=visionOS Simulator,id=设备UUID'`。
- 控制联调必须独占服务；不要同时运行控制客户端和 `tools/smoke_test.py`。
- `python tools/smoke_test.py --livekit` 可检查媒体订阅、深度、控制和播放器素材，要求 LiveKit 也已配置。

测试结果写入独立的 `artifacts/validation-*` 目录。增加 Swift 文件后执行 `python tools/generate_xcode_project.py` 更新源文件引用；工程自定义设置也应维护在该生成脚本中。

# 硬件与 API 接口审查

## 结论与适用范围

Stereo Studio 具备从相机采集、立体视频传输、深度测量到头部姿态和双轴指令的完整软件路径。当前接口检查、故障注入、真实本机 LiveKit 传输、visionOS 原生网络/GPU 测试和设备目标编译均通过。

这一结论以文档中的硬件型号、模式、安装方向和校准条件为前提。没有真实 ZED、云台或 Vision Pro 的运行证据，不能将源码审查与模拟器结果表述为“所有硬件上绝对正确”或“已完成真机验收”。尤其不能从未标明型号、传动比例和安装方向的云台推导出有效校准。

程序对不满足接口条件的设备拒绝启动，对失效数据拒绝继续控制。其状态角是指令估计值，不是连续机械位置遥测；独立机械急停、负载支撑和物理运动安全不由本软件保证。

## ZED 采集与深度

`server/camera.py` 对照 [Stereolabs Python API 参考](https://www.stereolabs.com/docs/api/llms-api-python.txt) 中的 `InitParameters`、`RuntimeParameters`、`grab`、`retrieve_image`、`retrieve_measure`、`get_camera_information` 和 IMAGE 时间戳接口。

| 接口约束 | 程序行为 | 验证方式 |
|---|---|---|
| 同次采集 | 成功 grab 后依次取得 LEFT、RIGHT 和 DEPTH；不在两目之间再次 grab | SDK 替身、提取失败注入、帧号不推进测试 |
| 像素与深度格式 | CPU 图像按 BGRA uint8 校验并转 RGB；深度按 float32 米制 Z 校验 | 通道顺序、形状、类型、无效深度测试 |
| 深度与内参一致 | 采用校正左目内参，按相同输出尺寸请求 calibration；深度与左目对齐 | 缩放参数检查、反投影与轴向/直线距离测试 |
| 坐标和方向 | 显式 IMAGE 坐标系、METER、关闭自动翻转；要求相机正向安装 | 构造参数检查 |
| 数据生命期 | 图像转换和深度复制获得独立数据；无效深度变为 NaN 并在 API 中转 null | 原缓冲改写不改变已发布帧 |
| 数据失效 | SDK 错误、异常形状和不递增时间戳不生成新帧；采集恢复采用异步模式 | 返回码、重复帧和初始化失败测试 |

米制 Z 与到点直线距离不同，测距通过左目内参反投影后计算欧氏距离，符合 [Stereolabs 深度 API 说明](https://docs.stereolabs.com/docs/development/zed-sdk/modules/depth-sensing/using-the-api)。NEURAL 模型、CUDA、驱动、曝光、校准文件和场景纹理会影响实际结果；配置的 0.2–20 m 是软件筛选范围，不是精度承诺。

采集路径使用 HD720 USB 双目模式。macOS 不执行该 CUDA 深度路径；SDK 与 `pyzed` 必须按 [官方 Python 安装说明](https://docs.stereolabs.com/docs/development/api-languages/python) 匹配。官方参考文件自身标记为 SDK 5.5.0；本机没有加载真实 `pyzed` 或 ZED SDK。

## Dynamixel 云台

`server/gimbal.py` 仅接受 XM430-W350（1020）和 XL430-W250（1060），固件 45+，Protocol 2.0。寄存器依据 [XM430-W350 控制表](https://emanual.robotis.com/docs/en/dxl/x/xm430-w350/) 和 [XL430-W250 控制表](https://emanual.robotis.com/docs/en/dxl/x/xl430-w250/)，SDK 的读写返回值依据 [ROBOTIS Protocol 2 Python 实现](https://github.com/ROBOTIS-GIT/DynamixelSDK/blob/master/python/src/dynamixel_sdk/protocol2_packet_handler.py)。

| 检查项 | 程序约束 |
|---|---|
| 寄存器适配 | 先读取型号再访问对应控制表；不以“Protocol 2”或“X 系列”代替具体型号匹配 |
| 启动模式 | Drive Mode=0、Operating Mode=3、Homing Offset=0、Secondary ID=255、Torque Enable=0、Status Return Level=2、Hardware Error Status=0 |
| 位置有效性 | 校准范围必须包含于设备位置限位；拒绝负数编码、越界和多圈位置，不使用取模修补 |
| 两轴启动 | 两轴都通过只读检查后才写入；配置非零速度/加速度，先以当前位置设置目标，再开启扭矩并复查位置 |
| 应答丢失 | 发送使能前记录该轴；即使命令已执行但 ACK 丢失，也尝试关闭该轴 |
| 运行故障 | 检查扭矩、硬件错误、看门狗和当前位置边界；故障后停止写入新目标，不自动清除错误或重新使能 |
| 串口失联 | Bus Watchdog=25，即 500 ms；运动过程由设备非零 Profile Velocity/Acceleration 约束 |
| 关闭行为 | 所有尝试使能的轴均尝试 torque-off；一轴失败不阻止另一轴关闭；最终关闭串口 |

软件独占租约、指令限速和设备内运动参数是不同层次。两轴顺序写入不是原子同步运动；一轴写入成功、另一轴故障时不能撤销前一轴已收到的命令。总线故障后看门狗停止运动，通信不可达时无法保证 torque-off 已送达。退出时失去扭矩也可能使负载受重力移动。

校准示例始终保留 `confirmed_position_mode=false`。没有设备数据时不生成虚构校准，不开放未知型号，也不让 `mock` 源驱动物理云台。

## LiveKit 与网络控制

`server/live_video.py` 使用固定版本 Python SDK；原生客户端使用固定版本 Swift SDK。发布端是一个 640×720 RGB24 源，H.264、上左下右、禁用 simulcast、拥塞时保持分辨率。帧交给 SDK 前验证采集时效；客户端按发布者、轨道名、尺寸和旋转筛选。

[LiveKit Room API](https://docs.livekit.io/reference/python/livekit/rtc/room.html) 的 `isconnected()` 必须作为方法调用。发布循环在断开后退出并重新连接；取消连接时先完成 SDK 的原生回调交接，再断开房间；视频源显式释放。连接使用 SDK 的 10 秒协商超时，错误不会被包装成成功状态。

订阅令牌只允许订阅，期限十分钟，不包含发布权限。HTTP/WebSocket 控制独立于媒体；单指令在途、序号递增、独占租约一秒、控制 I/O 超时、断连释放和失效画面停止均有测试。HTTP 深度绑定自己的 JPEG 快照，不声称与独立 WebRTC 帧精确同步。

真实本机测试包含：Python 发布与订阅解码、visionOS LiveKit 解码到 GPU 纹理、移除发布者后的重新入房与重新发布，以及恢复后再次解码。回环测试不代表跨网段、TURN、弱网、长时间运行或端到端延迟的测量结果。

## Apple 头部追踪与双目渲染

Apple [ARKit 数据访问说明](https://developer.apple.com/documentation/visionos/setting-up-access-to-arkit-data) 明确区分 world tracking 和 world sensing。程序仅请求 `WorldTrackingProvider.requiredAuthorizations`，不把头姿访问绑定到无关的平面/网格权限。每次启动使用新的 session/provider；仅在沉浸空间及有效视频下允许真实跟随。无设备姿态、失去追踪或大幅不连续姿态不会复用旧角度。

相对矩阵使用启动头姿的逆矩阵乘当前头姿，ARKit 前向为 -Z；转换后 yaw 向右、pitch 向上，平移不参与角度控制。数值测试使用非零初始朝向、相对转动和任意平移验证符号与滤波，并拒绝大幅跳变。

左右纹理通过 [Camera Index Switch](https://developer.apple.com/documentation/shadergraph/realitykit/camera-index-switch-%28realitykit%29) 交给对应眼别，结构与 [Apple 双目图像示例](https://developer.apple.com/documentation/visionOS/displaying-a-stereoscopic-image-in-visionos) 一致。Core Image 使用线性半浮点纹理和可抛错渲染，等待 Metal 完成后显示；GPU 测试读回像素确认上半帧进入左纹理、下半帧进入右纹理。

编译和 GPU 测试不证明真实头显的最终眼别、UV 方向、色彩、双眼融合和视觉舒适度。真实头部追踪、系统空间重定位、权限/后台变化及硬件负载没有设备测试证据。

## 验证证据

完整测试结果和可复查文件路径见 [验证范围](VALIDATION.md)。自动化覆盖的是上述有明确输入、输出和故障条件的软件契约，结论不扩展到未连接的真实设备。

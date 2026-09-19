# Stereo Studio 协议 v1

## 通用规则

- HTTP API 根路径 `/api`，JSON UTF-8；客户端先读取 `/api/capabilities`，拒绝不支持的 `protocol` 与 `stereo_layout`。
- 局域网监听必须配置 `STEREO_API_TOKEN`，HTTP 使用 `Authorization: Bearer <token>`。WebSocket 在首条 JSON 中发送 token，避免 token 出现在 URL 日志。
- API token 与 LiveKit 的 API secret 不同：客户端仅持有项目访问 token 及服务端签发的短期订阅 JWT。LiveKit secret 只在服务器端。
- 本机默认绑定 127.0.0.1，可免 token。无 CORS 通配；浏览器控制连接检查 Origin 与 Host 一致。原生客户端没有 Origin。
- 深度/视频采集失败不伪造成功，状态可从 `/api/status` 查询。

## 视频与时间

- LiveKit room 默认 `stereo-studio`，轨道名 `stereo`，一个视频轨道。
- `top-bottom`：上半帧=左目，下半帧=右目。默认每眼 640×360，总帧 640×720；H.264 单层视频，拥塞策略保持分辨率，发布上限配置 20 fps、5 Mbps。这些是配置，不是实测性能指标。
- 两目和深度在同一次采集中形成 `Frame`，仅发布整对，不使用共享消费队列分发两个独立轨道。
- `frame_id` 是进程内单调递增序号，重启后归零重建；不要跨会话复用。
- `captured_at_ms` 是源时间戳：模拟源为 Unix 毫秒，ZED 源为 SDK 的 IMAGE 时间戳。**不通过跨端时钟差判断新鲜度**。
- 服务端以本机 `monotonic` 检查帧年龄，最大 750 ms；快照 `age_ms` 为生成响应时的年龄，不包括之后的网络传输。
- 实时 WebRTC 帧与 HTTP 深度没有跨协议精确帧匹配，因此深度工具绑定**同一响应里的左目 JPEG 快照**；不将独立深度热图覆盖到实时 WebRTC 画面上。

## 深度与坐标

- 单位米。`depth_m` 为左目相机坐标系沿光轴的 Z 深度；无效值序列化为 JSON `null`，不是 0，也不输出 NaN/Infinity。
- 图像坐标：左上角 `(u,v)=(0,0)`，右下角 `(1,1)`；范围之外返回 422。
- 相机坐标：X 向右、Y 向下、Z 向前。像素 `(x,y)` 与内参反投影：
  `X=(x-cx)*Z/fx, Y=(y-cy)*Z/fy`。
- `axial_m` 是 Z，`range_m=sqrt(X²+Y²+Z²)` 是从左相机光心到该点的直线距离。
- 点测距使用原始分辨率深度；80×45 热图使用最近邻降采样，不将无效点插值成有效深度。
- `near_m` 是图像中心约 1/3 区域的有效深度第 10 百分位，有效数量需至少 30%；默认小于 1 m 时给出 `near_warning`。它不是全视场最近距离，也不是安全碰撞判定。

## HTTP

| 方法和路径 | 用途 | 主要错误 |
|---|---|---|
| `GET /api/capabilities` | 协议版本、源、每眼尺寸、深度/控制/LiveKit 能力 | 401 |
| `GET /api/status` | 摄像头、视频和控制器状态 | 401 |
| `POST /api/session`，body `{}` | 签发 10 分钟只订阅 JWT，返回 LiveKit URL | 503：LiveKit 未配置 |
| `GET /api/snapshot` | JPEG、对应深度、frame_id、内参、近端统计 | 409：stale_frame |
| `POST /api/depth/measure` | `{frame_id,u,v}`，测量指定快照 | 409：frame_expired/stale_frame；422：坐标无效 |

服务端保留最近 30 帧；保留时间不代表仍可测量，750 ms 新鲜度约束独立生效。

响应示例：

```json
{"frame_id":12,"u":0.5,"v":0.5,"valid":true,"axial_m":2.0,"range_m":2.0,"point_m":[0,0,2]}
```

## WebSocket 控制

连接 `/api/control` 后三秒内发送：

```json
{"token":"your-project-access-token"}
```

服务端在验证相机新鲜度及硬件可用性后授予独占租约：

```json
{"type":"lease","lease_id":"opaque","ttl_ms":1000,"yaw_deg":0,"pitch_deg":0}
```

客户端以约 20 Hz 发送绝对云台目标角，单位度：

```json
{"sequence":0,"yaw_deg":15,"pitch_deg":-5}
```

- `sequence` 必须严格递增、非负整数；有效命令续租 1 秒。
- yaw 正方向为向右，pitch 正方向为向上；ARKit 的 forward=-Z 在客户端转换，Dynamixel 符号在校准中配置。
- App 将“开启跟随时的头姿”作为零点，加到租约返回的现有云台角度上，避免一开启就回零。
- 单命令在途：App 收到 ack 后再发送下一条，防止网络排队。浏览器模拟为 10 Hz。
- 默认模拟范围 yaw ±70°、pitch ±35°，每秒最多 35°；实机范围从校准 tick 区间计算。
- 断开、显式 `{"type":"release"}`、租约超时、相机过期或驱动故障时冻结目标到当前估计角度。
- “停止”表示停止继续追踪并保持，不等同于断电急停。服务退出时驱动关闭 torque；Dynamixel 总线看门狗为 500 ms，串口失联时停止运动，无法代替机械支撑或独立急停。
- 头部追踪丢失时不发送旧姿态，超过 500 ms 客户端退出跟随；服务端租约独立防护。
- 驱动故障会锁住新控制请求，需检查硬件并重启服务。

典型错误：`control_busy`、`lease_expired`、`out_of_order`、`invalid_or_stale_data`、`gimbal_not_configured`、`camera_unavailable`。

## 客户端接入

- 控制 WebSocket 的标准发送形式为 UTF-8 JSON 文本消息；服务器同时兼容 UTF-8 JSON 二进制消息。每条消息必须是 JSON object，最大 4096 字符/字节，非法内容会释放租约并返回错误。
- `POST /api/session` 返回 `publisher_identity`（当前为 `stereo-camera`）。客户端同时匹配发布者与 `track_name`，并校验 top-bottom 布局及能力声明的单眼尺寸。
- 原生端区分 API、媒体、控制和深度状态。媒体失败不关闭可用的深度接口；超过 750 ms 的实时快照或视频不会用于继续跟随。

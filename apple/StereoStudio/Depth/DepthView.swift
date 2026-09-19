import SwiftUI
import UIKit

struct DepthView: View {
    @EnvironmentObject var depth: DepthSession
    @State private var showHeat = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let frame = depth.displayedSnapshot, let data = Data(base64Encoded: frame.preview_jpeg), let image = UIImage(data: data) {
                        HStack {
                            Text(depth.selection == nil ? "在左目画面上轻点测距" : "已固定测量快照").font(.title2)
                            Spacer()
                            if depth.selection != nil { Button("返回实时画面") { depth.resumeLive() } }
                        }
                        if let selected = depth.selection {
                            Text("\(selected.selectedAt.formatted(date: .omitted, time: .standard)) · \(selected.server) · 帧 \(selected.frame.frame_id)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                            .overlay {
                                GeometryReader { geo in
                                    ZStack {
                                        if showHeat {
                                            Canvas { context, size in
                                                for (index, z) in frame.depth_m.enumerated() {
                                                    guard let z, z.isFinite, z > 0 else { continue }
                                                    let width = size.width/CGFloat(frame.depth_width), height = size.height/CGFloat(frame.depth_height)
                                                    let rect = CGRect(x: CGFloat(index%frame.depth_width)*width,
                                                        y: CGFloat(index/frame.depth_width)*height, width: width+1, height: height+1)
                                                    context.fill(Path(rect), with: .color(Color(hue: min(z/8, 1)*0.61, saturation: 0.8, brightness: 0.95).opacity(0.4)))
                                                }
                                            }.allowsHitTesting(false)
                                        }
                                        Color.clear.contentShape(Rectangle())
                                            .gesture(SpatialTapGesture().onEnded { value in
                                                let u = Double(value.location.x/geo.size.width), v = Double(value.location.y/geo.size.height)
                                                Task { await depth.measure(u: u, v: v, frameID: frame.frame_id) }
                                            })
                                        if let selected = depth.selection, selected.frame.frame_id == frame.frame_id {
                                            Circle().stroke(.white, lineWidth: 3).background(Circle().fill(.black.opacity(0.35)))
                                                .frame(width: 22, height: 22)
                                                .position(x: CGFloat(selected.u) * geo.size.width, y: CGFloat(selected.v) * geo.size.height)
                                                .allowsHitTesting(false)
                                        }
                                    }
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .accessibilityLabel("左目深度画面，轻点位置进行测距")
                        Toggle("显示深度热图（暖色近，冷色远）", isOn: $showHeat)
                        HStack {
                            Button("测量画面中心") { Task { await depth.measure(u: 0.5, v: 0.5, frameID: frame.frame_id) } }.disabled(depth.selection != nil)
                            Text("有效深度 \(Int(frame.valid_fraction*100))% · 帧 \(frame.frame_id)").foregroundStyle(.secondary)
                        }
                        if let near = frame.near_m {
                            Label(String(format: "中心区域近端深度 %.2f m", near), systemImage: frame.near_warning ? "exclamationmark.circle" : "viewfinder")
                                .foregroundStyle(frame.near_warning ? .orange : .primary)
                        } else { Text("中心区域深度不足") }
                        if let m = depth.measurement {
                            if m.valid, let range = m.range_m, let axial = m.axial_m {
                                Text(String(format: "测量帧 %d：直线距离 %.2f m，轴向深度 %.2f m", m.frame_id, range, axial)).font(.headline)
                            } else { Text("选定位置没有可信深度") }
                        } else if depth.selection != nil && depth.selection?.error == nil {
                            ProgressView("正在测量所选位置…")
                        }
                        if let message = depth.selection?.error { Text(message).foregroundStyle(.red) }
                        Text(frame.source == "mock" ? "当前为解析场景生成的模拟深度。" : "深度由相机服务器计算，已过滤低置信度数据。")
                            .foregroundStyle(.secondary)
                        Text("测距基于所选左目快照；不叠加到不同时间的视频帧。近距离提示仅用于实验。")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        ContentUnavailableView("尚无深度数据", systemImage: "ruler", description: Text("先在“远程视角”连接服务器。无设备时可使用模拟源。"))
                    }
                    if let error = depth.error { Text(error).foregroundStyle(.red) }
                    if !depth.history.isEmpty {
                        Divider()
                        Text("本次使用的测量记录（最近 20 条）").font(.headline)
                        ForEach(depth.history) { entry in
                            Button { depth.review(entry) } label: {
                                HStack {
                                    Label("帧 \(entry.frame.frame_id)", systemImage: "scope")
                                    Text(entry.selectedAt.formatted(date: .omitted, time: .shortened))
                                    Spacer()
                                    if let range = entry.result?.range_m {
                                        Text(String(format: "%.2f m", range))
                                    } else { Text("无可信深度") }
                                }
                            }
                        }
                    }
                }.padding(28)
            }.navigationTitle("深度工具")
        }
    }
}

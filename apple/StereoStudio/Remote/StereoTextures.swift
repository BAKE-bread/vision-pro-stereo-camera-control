import CoreImage
import Metal
import RealityKit

@MainActor
final class StereoTextures {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let context: CIContext
    private(set) var left: LowLevelTexture?
    private(set) var right: LowLevelTexture?
    private var dimensions = SIMD2<Int>.zero
    private var materialTemplate: ShaderGraphMaterial?
    private(set) var material: ShaderGraphMaterial?

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw APIError(message: "当前设备无法创建 Metal 渲染器")
        }
        self.device = device; self.queue = queue
        context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
    }

    /// Returns true when the entity needs to bind a new material (first frame / resolution change).
    func update(_ buffer: CVPixelBuffer) async throws -> Bool {
        let width = CVPixelBufferGetWidth(buffer), fullHeight = CVPixelBufferGetHeight(buffer)
        guard width > 0, fullHeight > 1, fullHeight % 2 == 0 else { throw APIError(message: "双目视频尺寸不符合上下布局") }
        let height = fullHeight/2
        var changed = false
        if dimensions != SIMD2(width, height) {
            if materialTemplate == nil {
                guard let url = Bundle.main.url(forResource: "StereoMaterial", withExtension: "usda") else { throw APIError(message: "缺少双目材质资源") }
                materialTemplate = try await ShaderGraphMaterial(named: "/Root/StereoMaterial", from: url)
            }
            // CI's compute path cannot write to an sRGB texture. Linear half-float
            // preserves color precision and is sampled linearly by RealityKit.
            let descriptor = LowLevelTexture.Descriptor(textureType: .type2D, pixelFormat: .rgba16Float,
                                    width: width, height: height, textureUsage: [.shaderRead, .shaderWrite, .renderTarget])
            let l = try LowLevelTexture(descriptor: descriptor), r = try LowLevelTexture(descriptor: descriptor)
            guard var graph = materialTemplate else { throw APIError(message: "材质加载失败") }
            try await graph.setParameter(name: "LeftImage", value: .textureResource(TextureResource(from: l)))
            try await graph.setParameter(name: "RightImage", value: .textureResource(TextureResource(from: r)))
            left = l; right = r; material = graph; dimensions = SIMD2(width, height)
            changed = true
        }
        try await submit(buffer, width: width, height: height)
        return changed
    }

    private func submit(_ buffer: CVPixelBuffer, width: Int, height: Int) async throws {
        guard let command = queue.makeCommandBuffer(), let left, let right else { throw APIError(message: "无法创建视频转换指令") }
        // Core Image performs YUV/RGB conversion on the GPU, respecting the pixel buffer color metadata.
        // CI coordinates are bottom-up: top half is the left eye.
        let image = CIImage(cvPixelBuffer: buffer)
        let leftImage = image.cropped(to: CGRect(x: 0, y: height, width: width, height: height))
            .transformed(by: CGAffineTransform(translationX: 0, y: -CGFloat(height)))
        let rightImage = image.cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        // replace(using:) gives a writable texture with RealityKit synchronization; never write read().
        let leftDestination = CIRenderDestination(mtlTexture: left.replace(using: command), commandBuffer: command)
        let rightDestination = CIRenderDestination(mtlTexture: right.replace(using: command), commandBuffer: command)
        for destination in [leftDestination, rightDestination] {
            destination.colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        }
        // Unlike CIContext.render(), this API reports unsupported destinations.
        let leftTask = try context.startTask(toRender: leftImage, to: leftDestination)
        let rightTask = try context.startTask(toRender: rightImage, to: rightDestination)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            command.addCompletedHandler { completed in
                withExtendedLifetime((buffer, leftTask, rightTask)) {}
                if completed.status == .error {
                    continuation.resume(throwing: APIError(message: completed.error?.localizedDescription ?? "GPU 视频转换失败"))
                } else { continuation.resume() }
            }
            command.commit()
        }
    }
}

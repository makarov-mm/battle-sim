import Foundation
import MetalKit
import simd

struct Uniforms {
    var vp: matrix_float4x4
    var cam: SIMD4<Float>
    var sun: SIMD4<Float>
    var camRight: SIMD4<Float>
    var camUp: SIMD4<Float>
}

final class Renderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue

    private var charPipeline: MTLRenderPipelineState!
    private var groundPipeline: MTLRenderPipelineState!
    private var fxPipeline: MTLRenderPipelineState!
    private var skyPipeline: MTLRenderPipelineState!

    private var depthState: MTLDepthStencilState!
    private var fxDepthState: MTLDepthStencilState!
    private var skyDepthState: MTLDepthStencilState!

    private let soldierMesh: MTLBuffer
    private let soldierCount: Int
    private let tankMesh: MTLBuffer
    private let tankCount: Int
    private let groundMesh: MTLBuffer
    private let groundCount: Int

    private let world = World()
    private var net: Net!

    private var aspect: Float = 16.0 / 9.0
    private var frameLog: UInt64 = 0
    private let debugCam = ProcessInfo.processInfo.environment["DEBUG_CAM"] == "1"

    private func dbgProjView(eye: SIMD3<Float>, look: SIMD3<Float>, up: SIMD3<Float>) -> matrix_float4x4 {
        let view = lookAt(eye: eye, center: look, up: up)
        let proj = perspective(fovyRadians: 58 * Float.pi / 180, aspect: aspect, near: 0.5, far: 2000)
        return proj * view
    }

    init(view: MTKView) {
        device = view.device!
        queue = device.makeCommandQueue()!

        let soldier = MeshBuilder.soldier()
        let tank = MeshBuilder.tank()
        let ground = MeshBuilder.ground()
        soldierCount = soldier.count
        tankCount = tank.count
        groundCount = ground.count

        soldierMesh = device.makeBuffer(bytes: soldier,
                                        length: MemoryLayout<MeshVertex>.stride * soldier.count,
                                        options: .storageModeShared)!
        tankMesh = device.makeBuffer(bytes: tank,
                                     length: MemoryLayout<MeshVertex>.stride * tank.count,
                                     options: .storageModeShared)!
        groundMesh = device.makeBuffer(bytes: ground,
                                       length: MemoryLayout<MeshVertex>.stride * ground.count,
                                       options: .storageModeShared)!

        super.init()

        buildPipelines(view: view)

        let env = ProcessInfo.processInfo.environment
        let host = env["HOST"] ?? "127.0.0.1"
        let port = Int(env["PORT"] ?? "") ?? 4040
        net = Net(world: world, host: host, port: port)
        net.start()
    }

    private func buildPipelines(view: MTKView) {
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Shaders.source, options: nil)
        } catch {
            fatalError("Shader compile failed: \(error)")
        }

        func pipeline(_ vfn: String, _ ffn: String, blend: Bool) -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vfn)
            d.fragmentFunction = library.makeFunction(name: ffn)
            d.rasterSampleCount = view.sampleCount
            d.depthAttachmentPixelFormat = view.depthStencilPixelFormat
            let c = d.colorAttachments[0]!
            c.pixelFormat = view.colorPixelFormat
            if blend {
                c.isBlendingEnabled = true
                c.rgbBlendOperation = .add
                c.alphaBlendOperation = .add
                c.sourceRGBBlendFactor = .sourceAlpha
                c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                c.sourceAlphaBlendFactor = .sourceAlpha
                c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try! device.makeRenderPipelineState(descriptor: d)
        }

        charPipeline = pipeline("v_char", "f_char", blend: false)
        groundPipeline = pipeline("v_ground", "f_ground", blend: false)
        fxPipeline = pipeline("v_fx", "f_fx", blend: true)
        skyPipeline = pipeline("v_sky", "f_sky", blend: false)

        let dd = MTLDepthStencilDescriptor()
        dd.depthCompareFunction = .less
        dd.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: dd)

        // FX: test against depth but don't write, so overlapping quads blend.
        let fd = MTLDepthStencilDescriptor()
        fd.depthCompareFunction = .less
        fd.isDepthWriteEnabled = false
        fxDepthState = device.makeDepthStencilState(descriptor: fd)

        // Sky: always passes, never writes depth (drawn first as a backdrop).
        let sd = MTLDepthStencilDescriptor()
        sd.depthCompareFunction = .always
        sd.isDepthWriteEnabled = false
        skyDepthState = device.makeDepthStencilState(descriptor: sd)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        aspect = Float(size.width / max(size.height, 1))
    }

    func draw(in view: MTKView) {
        guard world.started else { return }
        guard let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }

        let (instances, fxVerts, dirVP, dirCam) = world.buildFrame(aspect: aspect)

        // DEBUG_CAM=1: fixed high orbit bypassing the director (diagnostics).
        let vp: matrix_float4x4
        let cam: SIMD3<Float>
        let camRight: SIMD3<Float>
        let camUp: SIMD3<Float>
        if debugCam {
            let t = Float(CFAbsoluteTimeGetCurrent())
            let ang = t * 0.12
            let eye = SIMD3<Float>(cos(ang) * 160, 100, sin(ang) * 160)
            let look = SIMD3<Float>(0, 0, 0)
            let up = SIMD3<Float>(0, 1, 0)
            vp = dbgProjView(eye: eye, look: look, up: up)
            cam = eye
            let f = simd_normalize(look - eye)
            camRight = simd_normalize(simd_cross(f, up))
            camUp = simd_cross(camRight, f)
        } else {
            vp = dirVP
            cam = dirCam
            camRight = world.director.camRight
            camUp = world.director.camUp
        }

        frameLog &+= 1
        if frameLog % 300 == 1 {
            let msg = "frame \(frameLog): agents=\(instances.count) fx=\(fxVerts.count)\n"
            FileHandle.standardError.write(msg.data(using: .utf8)!)
        }

        // Split instances by kind for the two meshes.
        var soldiers = [Instance]()
        var tanks = [Instance]()
        soldiers.reserveCapacity(instances.count)
        for inst in instances {
            let kind = floor(inst.misc.z / 8.0 + 0.5)
            if kind < 0.5 { soldiers.append(inst) } else { tanks.append(inst) }
        }

        var uni = Uniforms(
            vp: vp,
            cam: SIMD4<Float>(cam.x, cam.y, cam.z, Float(CFAbsoluteTimeGetCurrent().truncatingRemainder(dividingBy: 1000))),
            sun: SIMD4<Float>(simd_normalize(SIMD3<Float>(0.5, 0.8, 0.3)), 0),
            camRight: SIMD4<Float>(camRight, 0),
            camUp: SIMD4<Float>(camUp, 0)
        )

        // sky backdrop (fullscreen triangle, clip-space, no depth interaction)
        enc.setDepthStencilState(skyDepthState)
        enc.setCullMode(.none)
        enc.setRenderPipelineState(skyPipeline)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        enc.setDepthStencilState(depthState)

        // ground
        enc.setRenderPipelineState(groundPipeline)
        enc.setVertexBuffer(groundMesh, offset: 0, index: 0)
        enc.setVertexBytes(&uni, length: MemoryLayout<Uniforms>.stride, index: 2)
        enc.setFragmentBytes(&uni, length: MemoryLayout<Uniforms>.stride, index: 2)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: groundCount)

        // characters
        enc.setRenderPipelineState(charPipeline)
        enc.setVertexBytes(&uni, length: MemoryLayout<Uniforms>.stride, index: 2)

        if !soldiers.isEmpty {
            let buf = device.makeBuffer(bytes: soldiers,
                                        length: MemoryLayout<Instance>.stride * soldiers.count,
                                        options: .storageModeShared)!
            enc.setVertexBuffer(soldierMesh, offset: 0, index: 0)
            enc.setVertexBuffer(buf, offset: 0, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0,
                               vertexCount: soldierCount, instanceCount: soldiers.count)
        }
        if !tanks.isEmpty {
            let buf = device.makeBuffer(bytes: tanks,
                                        length: MemoryLayout<Instance>.stride * tanks.count,
                                        options: .storageModeShared)!
            enc.setVertexBuffer(tankMesh, offset: 0, index: 0)
            enc.setVertexBuffer(buf, offset: 0, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0,
                               vertexCount: tankCount, instanceCount: tanks.count)
        }

        // FX (blended, no depth write)
        if !fxVerts.isEmpty {
            enc.setDepthStencilState(fxDepthState)
            enc.setRenderPipelineState(fxPipeline)
            let buf = device.makeBuffer(bytes: fxVerts,
                                        length: MemoryLayout<FXVertex>.stride * fxVerts.count,
                                        options: .storageModeShared)!
            enc.setVertexBuffer(buf, offset: 0, index: 0)
            enc.setVertexBytes(&uni, length: MemoryLayout<Uniforms>.stride, index: 2)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: fxVerts.count)
        }

        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}

import Foundation
import simd

/// Per-agent interpolation track between the last two snapshots.
struct Track {
    var id: UInt16
    var team: UInt8
    var kind: UInt8
    var state: UInt8
    var hp: UInt8

    var prevX: Float
    var prevZ: Float
    var prevHeading: Float

    var nextX: Float
    var nextZ: Float
    var nextHeading: Float

    var animPhase: Float   // walk cycle accumulator
    var stateStart: Double // when current state began (for fire/throw/death timing)
    var prevState: UInt8
}

/// A transient visual effect spawned from a server event.
struct FX {
    var kind: Int      // 0 tracer, 1 explosion, 2 skull, 3 grenade
    var x1: Float
    var z1: Float
    var x2: Float
    var z2: Float
    var born: Double
    var life: Float
    var radius: Float
    var team: Float
}

/// Holds interpolated world state. Written by Net (background), read by Renderer (main).
final class World {
    private let lock = NSLock()

    private var tracks = [UInt16: Track]()
    private var fx = [FX]()

    private var lastFrameAt: Double = 0
    private var interval: Double = 0.05  // EMA of inter-frame time
    private(set) var started = false

    // Camera director consumes this heat feed.
    let director = CameraDirector()

    private func now() -> Double { CFAbsoluteTimeGetCurrent() }

    /// Called from the network thread for every decoded frame.
    func ingest(_ frame: Frame) {
        lock.lock()
        defer { lock.unlock() }

        let t = now()
        if lastFrameAt > 0 {
            let dt = t - lastFrameAt
            if dt > 0.005 && dt < 0.5 {
                interval = interval * 0.9 + dt * 0.1
            }
        }
        lastFrameAt = t
        started = true

        var seen = Set<UInt16>()
        seen.reserveCapacity(frame.agents.count)

        for a in frame.agents {
            seen.insert(a.id)
            if var tr = tracks[a.id] {
                // Shift next -> prev, install new sample.
                tr.prevX = tr.nextX
                tr.prevZ = tr.nextZ
                tr.prevHeading = tr.nextHeading

                // Respawn teleport: snap instead of sliding across the map.
                let jump = hypot(a.x - tr.nextX, a.z - tr.nextZ)
                if jump > 8.0 {
                    tr.prevX = a.x
                    tr.prevZ = a.z
                    tr.prevHeading = a.heading
                    tr.animPhase = 0
                }

                tr.nextX = a.x
                tr.nextZ = a.z
                tr.nextHeading = a.heading

                // Walk phase advances with distance travelled.
                let moved = hypot(tr.nextX - tr.prevX, tr.nextZ - tr.prevZ)
                tr.animPhase += moved * 2.2

                if a.state != tr.state {
                    tr.prevState = tr.state
                    tr.state = a.state
                    tr.stateStart = t
                }
                tr.hp = a.hp
                tr.team = a.team
                tr.kind = a.kind
                tracks[a.id] = tr
            } else {
                tracks[a.id] = Track(
                    id: a.id, team: a.team, kind: a.kind, state: a.state, hp: a.hp,
                    prevX: a.x, prevZ: a.z, prevHeading: a.heading,
                    nextX: a.x, nextZ: a.z, nextHeading: a.heading,
                    animPhase: 0, stateStart: t, prevState: a.state
                )
            }
        }

        // Drop agents that vanished (shouldn't happen with fixed roster, but safe).
        if tracks.count != seen.count {
            for key in tracks.keys where !seen.contains(key) {
                tracks.removeValue(forKey: key)
            }
        }

        for e in frame.events {
            spawnFX(e, at: t)
            director.feed(e)
        }

        // Cull expired FX.
        fx.removeAll { Float(t - $0.born) > $0.life }
    }

    private func spawnFX(_ e: EventWire, at t: Double) {
        switch e.type {
        case 0: // shot -> tracer
            fx.append(FX(kind: 0, x1: e.x1, z1: e.z1, x2: e.x2, z2: e.z2,
                         born: t, life: 0.09, radius: 0, team: 0))
        case 1: // grenade / shell throw -> arcing projectile
            let flight = Float(e.aux) / 20.0
            fx.append(FX(kind: 3, x1: e.x1, z1: e.z1, x2: e.x2, z2: e.z2,
                         born: t, life: flight, radius: 0, team: 0))
        case 2: // explosion
            let r = Float(e.aux) / 10.0
            fx.append(FX(kind: 1, x1: e.x1, z1: e.z1, x2: e.x1, z2: e.z1,
                         born: t, life: 0.35, radius: r, team: 0))
        case 3: // death -> skull
            fx.append(FX(kind: 2, x1: e.x1, z1: e.z1, x2: e.x1, z2: e.z1,
                         born: t, life: 1.4, radius: 0, team: Float(e.aux)))
        default:
            break
        }
    }

    /// Snapshot for the renderer. Returns instance data + FX vertex data + camera.
    func buildFrame(aspect: Float) -> (instances: [Instance], fxVerts: [FXVertex], vp: matrix_float4x4, cam: SIMD3<Float>) {
        lock.lock()
        let localTracks = tracks
        let localFX = fx
        let iv = interval
        let last = lastFrameAt
        lock.unlock()

        let t = now()
        // Render ~one interval behind the newest snapshot.
        let raw = iv > 0 ? Float((t - last) / iv) : 0
        let alpha = min(max(raw, 0), 1.25)

        var instances = [Instance]()
        instances.reserveCapacity(localTracks.count)

        var cx: Float = 0, cz: Float = 0, alive: Float = 0

        for (_, tr) in localTracks {
            let x = lerpF(tr.prevX, tr.nextX, alpha)
            let z = lerpF(tr.prevZ, tr.nextZ, alpha)
            let h = lerpAngle(tr.prevHeading, tr.nextHeading, alpha)

            if tr.state != 3 {
                cx += x; cz += z; alive += 1
            }

            let stateTime = Float(t - tr.stateStart)
            instances.append(Instance(
                posHead: SIMD4<Float>(x, 0, z, h),
                misc: SIMD4<Float>(tr.animPhase, stateTime, Float(tr.state) + Float(tr.kind) * 8.0, Float(tr.team))
            ))
        }

        if alive > 0 {
            director.setCrowd(SIMD3<Float>(cx / alive, 0, cz / alive))
        }

        var fxVerts = [FXVertex]()
        buildFXVerts(localFX, at: t, into: &fxVerts)

        let (vp, cam) = director.matrices(aspect: aspect, now: t)
        return (instances, fxVerts, vp, cam)
    }

    // Each FX becomes a small set of quad vertices (two triangles).
    private func buildFXVerts(_ list: [FX], at t: Double, into out: inout [FXVertex]) {
        for f in list {
            let age = Float(t - f.born)
            let u = min(max(age / max(f.life, 0.0001), 0), 1)

            switch f.kind {
            case 0: // tracer ribbon
                addTracer(f, u: u, into: &out)
            case 1: // explosion billboard
                addBillboard(kind: 1, x: f.x1, y: 1.0, z: f.z1,
                             size: f.radius * (0.3 + u * 0.9), u: u, team: 0, into: &out)
            case 2: // skull rising
                let y = 1.6 + u * 2.2
                addBillboard(kind: 2, x: f.x1, y: y, z: f.z1,
                             size: 1.1, u: u, team: f.team, into: &out)
            case 3: // grenade / shell in flight
                let px = lerpF(f.x1, f.x2, u)
                let pz = lerpF(f.z1, f.z2, u)
                let arc = 2.5 + f.life * 2.0
                let py = 1.2 + arc * 4 * u * (1 - u)
                addBillboard(kind: 3, x: px, y: py, z: pz, size: 0.35, u: u, team: 0, into: &out)
            default:
                break
            }
        }
    }

    private func addTracer(_ f: FX, u: Float, into out: inout [FXVertex]) {
        let y: Float = 1.25
        let a = SIMD3<Float>(f.x1, y, f.z1)
        let b = SIMD3<Float>(f.x2, y, f.z2)
        let dir = simd_normalize(b - a)
        let side = simd_normalize(simd_cross(dir, SIMD3<Float>(0, 1, 0))) * 0.06
        let p0 = a - side, p1 = a + side, p2 = b + side, p3 = b - side
        quad(p0, p1, p2, p3, kind: 0, u: u, team: 0, into: &out)
    }

    private func addBillboard(kind: Int, x: Float, y: Float, z: Float, size: Float,
                              u: Float, team: Float, into out: inout [FXVertex]) {
        // Camera-facing quads: the shader expands `center` along camRight/camUp
        // by (corner * size). corner is unit here; size travels in data.w.
        let center = SIMD3<Float>(x, y, z)
        let corners: [(Float, Float)] = [(-1,-1),(1,-1),(1,1),(-1,-1),(1,1),(-1,1)]
        for (cx, cy) in corners {
            out.append(FXVertex(
                center: center,
                corner: SIMD2<Float>(cx, cy),
                data: SIMD4<Float>(Float(kind), u, team, size)
            ))
        }
    }

    private func quad(_ p0: SIMD3<Float>, _ p1: SIMD3<Float>, _ p2: SIMD3<Float>, _ p3: SIMD3<Float>,
                      kind: Int, u: Float, team: Float, into out: inout [FXVertex]) {
        // World-space geometry (tracers). kind 0 is detected in the shader as
        // world-space, so corner stays zero and size is irrelevant.
        func v(_ p: SIMD3<Float>) -> FXVertex {
            FXVertex(center: p, corner: .zero, data: SIMD4<Float>(Float(kind), u, team, 0))
        }
        out.append(v(p0)); out.append(v(p1)); out.append(v(p2))
        out.append(v(p0)); out.append(v(p2)); out.append(v(p3))
    }
}

// Small helpers.
@inline(__always) func lerpF(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }

@inline(__always) func lerpAngle(_ a: Float, _ b: Float, _ t: Float) -> Float {
    var d = b - a
    while d > .pi { d -= 2 * .pi }
    while d < -.pi { d += 2 * .pi }
    return a + d * t
}

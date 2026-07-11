import Foundation
import simd

/// Chooses where to look and how to fly. Combat events deposit "heat";
/// the weighted centroid of recent heat is the point of interest. Every
/// few seconds the director cuts to a new shot type framing that point.
final class CameraDirector {
    private struct Heat {
        var x: Float
        var z: Float
        var w: Float
        var born: Double
    }

    private enum Shot {
        case orbit(radius: Float, height: Float, speed: Float, phase0: Float)
        case flyover(height: Float, along: SIMD2<Float>, span: Float)
        case lowDolly(height: Float, offset: Float, along: SIMD2<Float>, span: Float)
        case crane(radius: Float, phase0: Float)
    }

    private let lock = NSLock()
    private var heat = [Heat]()

    private var crowd = SIMD3<Float>(0, 0, 0)
    private var haveCrowd = false

    /// Centroid of living units, fed each frame by World. Used as the camera's
    /// fallback focus while combat is sparse (e.g. the initial advance).
    func setCrowd(_ c: SIMD3<Float>) {
        lock.lock()
        crowd = c
        haveCrowd = true
        lock.unlock()
    }

    private var shot: Shot = .orbit(radius: 36, height: 15, speed: 0.15, phase0: 0)
    private var shotStart: Double = 0
    private var shotDuration: Double = 8

    // Smoothed camera state.
    private var eye = SIMD3<Float>(0, 40, 90)
    private var look = SIMD3<Float>(0, 0, 0)
    private var poi = SIMD3<Float>(0, 0, 0)
    private var inited = false

    private let decay: Float = 2.5      // heat half-life-ish window
    private let window: Double = 5.0

    func feed(_ e: EventWire) {
        let (x, z, w): (Float, Float, Float)
        switch e.type {
        case 3: (x, z, w) = (e.x1, e.z1, 3.0)                       // death
        case 2: (x, z, w) = (e.x1, e.z1, 4.0 + Float(e.aux) / 10 * 0.3) // explosion
        case 1: (x, z, w) = (e.x2, e.z2, 2.0)                       // grenade target
        case 0:
            // Subsample shots — there are many.
            if Int.random(in: 0..<6) != 0 { return }
            (x, z, w) = (e.x2, e.z2, 0.4)
        default:
            return
        }
        lock.lock()
        heat.append(Heat(x: x, z: z, w: w, born: CFAbsoluteTimeGetCurrent()))
        lock.unlock()
    }

    private func computePOI(now: Double) -> SIMD3<Float> {
        lock.lock()
        heat.removeAll { now - $0.born > window }
        let snapshot = heat
        let mass = crowd
        let haveMass = haveCrowd
        lock.unlock()

        var sx: Float = 0, sz: Float = 0, sw: Float = 0
        for h in snapshot {
            let age = Float(now - h.born)
            let w = h.w * expf(-age / decay)
            sx += h.x * w
            sz += h.z * w
            sw += w
        }

        // Too little action: look at the bulk of the army.
        if sw < 0.5 {
            return haveMass ? mass : poi
        }

        let hot = SIMD3<Float>(sx / sw, 0, sz / sw)
        // Favor the hot zone but pull toward the mass so the whole battle
        // stays roughly framed rather than diving onto one lone skirmish.
        return haveMass ? simd_mix(hot, mass, SIMD3<Float>(repeating: 0.35)) : hot
    }

    private func pickShot(now: Double) {
        let along = SIMD2<Float>(0, 1) // front line runs along Z
        let choices: [Shot] = [
            .orbit(radius: .random(in: 30...52),
                   height: .random(in: 26...44),
                   speed: [Float]([-1, 1]).randomElement()! * .random(in: 0.08...0.18),
                   phase0: .random(in: 0...(2 * Float.pi))),
            .flyover(height: .random(in: 34...52), along: along, span: 60),
            .lowDolly(height: .random(in: 16...24),
                      offset: .random(in: 20...30),
                      along: along, span: 46),
            .crane(radius: .random(in: 26...40), phase0: .random(in: 0...(2 * Float.pi)))
        ]
        shot = choices.randomElement()!
        shotStart = now
        shotDuration = .random(in: 6...10)
    }

    /// Returns view-projection and eye position for this frame.
    func matrices(aspect: Float, now: Double) -> (matrix_float4x4, SIMD3<Float>) {
        if !inited {
            shotStart = now
            inited = true
            lock.lock(); let c = crowd; let have = haveCrowd; lock.unlock()
            if have {
                poi = c
                look = c
                eye = c + SIMD3<Float>(0, 46, 46)
            }
        }
        if now - shotStart > shotDuration {
            let smooth = Double.random(in: 0...1) < 0.25
            pickShot(now: now)
            if smooth { /* keep current eye, let smoothing glide */ }
            else {
                // Hard cut: jump smoothing state near new target next frame.
                hardCut = true
            }
        }

        let target = computePOI(now: now)
        // POI drifts smoothly toward the focus.
        poi = simd_mix(poi, target, SIMD3<Float>(repeating: 0.04))
        if !isFinite(poi) { poi = isFinite(target) ? target : SIMD3<Float>(0, 0, 0) }

        let tShot = Float(now - shotStart)
        var desiredEye = eye
        var desiredLook = poi

        switch shot {
        case let .orbit(radius, height, speed, phase0):
            let ang = phase0 + tShot * speed * 2 * Float.pi
            desiredEye = poi + SIMD3<Float>(cos(ang) * radius, height, sin(ang) * radius)
            desiredLook = poi

        case let .flyover(height, along, span):
            let p = (tShot / Float(shotDuration)) * 2 - 1 // -1..1
            let dir3 = SIMD3<Float>(along.x, 0, along.y)
            desiredEye = poi + dir3 * (p * span) + SIMD3<Float>(0, height, 0)
            desiredLook = poi

        case let .lowDolly(height, offset, along, span):
            let p = (tShot / Float(shotDuration)) * 2 - 1
            let dir3 = SIMD3<Float>(along.x, 0, along.y)
            let perp = SIMD3<Float>(1, 0, 0)
            desiredEye = poi + dir3 * (p * span) + perp * offset + SIMD3<Float>(0, height, 0)
            desiredLook = poi + SIMD3<Float>(0, 1.5, 0)

        case let .crane(radius, phase0):
            let f = tShot / Float(shotDuration)
            let h = lerpF(40, 20, smoothstep(0, 1, f))
            let ang = phase0 + f * 1.2
            desiredEye = poi + SIMD3<Float>(cos(ang) * radius, h, sin(ang) * radius)
            desiredLook = poi
        }

        // Never look straight down: a perfectly vertical view makes the forward
        // vector parallel to `up`, which makes lookAt degenerate (NaN matrix) and
        // the whole scene vanishes. Keep a minimum horizontal offset from focus.
        var offX = desiredEye.x - poi.x
        var offZ = desiredEye.z - poi.z
        var horiz = sqrt(offX * offX + offZ * offZ)
        if horiz < 10 {
            let a = (horiz > 0.001) ? (offX / horiz) : 1.0
            let b = (horiz > 0.001) ? (offZ / horiz) : 0.0
            horiz = 10
            offX = a * horiz
            offZ = b * horiz
            desiredEye.x = poi.x + offX
            desiredEye.z = poi.z + offZ
        }
        // Downward pitch so the ground fills the frame (horizon above top edge).
        desiredEye.y = max(desiredEye.y, horiz * 0.62 + 6)

        if hardCut {
            eye = desiredEye
            look = desiredLook
            hardCut = false
        } else {
            let k: Float = 4.5 * (1.0 / 60.0)
            eye = simd_mix(eye, desiredEye, SIMD3<Float>(repeating: k))
            look = simd_mix(look, desiredLook, SIMD3<Float>(repeating: k))
        }

        // Critical: a single NaN in eye/look would propagate through mix() forever
        // and blank the scene permanently. Recover from the valid desired values.
        if !isFinite(eye) { eye = desiredEye }
        if !isFinite(look) { look = desiredLook }
        if !isFinite(eye) { eye = SIMD3<Float>(0, 40, 40) }
        if !isFinite(look) { look = SIMD3<Float>(0, 0, 0) }
        eye.y = max(eye.y, 2.2)
        // Guard against eye coinciding with look (also degenerate).
        if simd_length(eye - look) < 1.0 {
            eye = look + SIMD3<Float>(0, 30, 30)
        }

        let upW = SIMD3<Float>(0, 1, 0)
        let view = lookAt(eye: eye, center: look, up: upW)
        let proj = perspective(fovyRadians: 58 * Float.pi / 180, aspect: aspect, near: 0.5, far: 600)

        // Camera basis for billboard expansion.
        let f = simd_normalize(look - eye)
        camRight = simd_normalize(simd_cross(f, upW))
        camUp = simd_cross(camRight, f)

        return (proj * view, eye)
    }

    private func isFinite(_ v: SIMD3<Float>) -> Bool {
        v.x.isFinite && v.y.isFinite && v.z.isFinite
    }

    private(set) var camRight = SIMD3<Float>(1, 0, 0)
    private(set) var camUp = SIMD3<Float>(0, 1, 0)
    private var hardCut = false
}

// MARK: - Math

@inline(__always) func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
    let t = min(max((x - a) / (b - a), 0), 1)
    return t * t * (3 - 2 * t)
}

func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> matrix_float4x4 {
    let f = simd_normalize(center - eye)
    // If the view is (near) vertical, swap the up reference to avoid a zero cross.
    var upRef = up
    if abs(simd_dot(f, up)) > 0.999 {
        upRef = SIMD3<Float>(0, 0, 1)
    }
    let s = simd_normalize(simd_cross(f, upRef))
    let u = simd_cross(s, f)
    return matrix_float4x4(columns: (
        SIMD4<Float>(s.x, u.x, -f.x, 0),
        SIMD4<Float>(s.y, u.y, -f.y, 0),
        SIMD4<Float>(s.z, u.z, -f.z, 0),
        SIMD4<Float>(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)
    ))
}

func perspective(fovyRadians: Float, aspect: Float, near: Float, far: Float) -> matrix_float4x4 {
    // Right-handed: camera looks down -Z in view space (matches lookAt above).
    // Maps z_view = -near -> 0 and z_view = -far -> 1 (Metal NDC depth).
    let y = 1 / tan(fovyRadians * 0.5)
    let x = y / aspect
    let zs = far / (near - far)
    return matrix_float4x4(columns: (
        SIMD4<Float>(x, 0, 0, 0),
        SIMD4<Float>(0, y, 0, 0),
        SIMD4<Float>(0, 0, zs, -1),
        SIMD4<Float>(0, 0, near * zs, 0)
    ))
}

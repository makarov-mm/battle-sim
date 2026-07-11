import Foundation
import simd

/// Vertex layout shared with the shader (read manually by vertex_id).
/// 32 bytes: packed_float3 pos + packed_float3 nrm + float part + float pad.
struct MeshVertex {
    var px: Float; var py: Float; var pz: Float
    var nx: Float; var ny: Float; var nz: Float
    var part: Float
    var pad: Float
}

struct Instance {
    var posHead: SIMD4<Float> // x, y, z, heading
    var misc: SIMD4<Float>    // animPhase, stateTime, state+kind*8, team
}

struct FXVertex {
    var center: SIMD3<Float>
    var corner: SIMD2<Float>
    var data: SIMD4<Float>    // kind, u(age), team, isWorldSpace
}

enum MeshBuilder {
    /// Local model space: forward = +X, up = +Y, lateral = Z.
    /// Part ids: 0 torso,1 head,2 legL,3 legR,4 armL,5 armR,6 gun,
    ///           7 tank body,8 tank tracks.
    static func soldier() -> [MeshVertex] {
        var v = [MeshVertex]()
        // torso
        box(&v, cx: 0, cy: 1.15, cz: 0, sx: 0.34, sy: 0.5, sz: 0.5, part: 0)
        // head
        box(&v, cx: 0.02, cy: 1.62, cz: 0, sx: 0.26, sy: 0.26, sz: 0.26, part: 1)
        // legs (pivot handled in shader around y≈0.95)
        box(&v, cx: 0, cy: 0.5, cz: -0.12, sx: 0.22, sy: 0.95, sz: 0.2, part: 2)
        box(&v, cx: 0, cy: 0.5, cz: 0.12, sx: 0.22, sy: 0.95, sz: 0.2, part: 3)
        // arms (pivot around shoulder y≈1.42)
        box(&v, cx: 0.0, cy: 1.15, cz: -0.3, sx: 0.18, sy: 0.5, sz: 0.18, part: 4)
        box(&v, cx: 0.0, cy: 1.15, cz: 0.3, sx: 0.18, sy: 0.5, sz: 0.18, part: 5)
        // gun (dark), held forward from right arm
        box(&v, cx: 0.5, cy: 1.2, cz: 0.3, sx: 0.7, sy: 0.1, sz: 0.1, part: 6)
        return v
    }

    static func tank() -> [MeshVertex] {
        var v = [MeshVertex]()
        // hull
        box(&v, cx: 0, cy: 0.55, cz: 0, sx: 2.6, sy: 0.7, sz: 1.9, part: 7)
        // turret
        box(&v, cx: -0.2, cy: 1.05, cz: 0, sx: 1.3, sy: 0.5, sz: 1.2, part: 7)
        // barrel
        box(&v, cx: 1.4, cy: 1.05, cz: 0, sx: 1.8, sy: 0.14, sz: 0.14, part: 7)
        // tracks (darker)
        box(&v, cx: 0, cy: 0.25, cz: -1.0, sx: 2.8, sy: 0.5, sz: 0.35, part: 8)
        box(&v, cx: 0, cy: 0.25, cz: 1.0, sx: 2.8, sy: 0.5, sz: 0.35, part: 8)
        return v
    }

    /// Large ground plane centered at origin. Two triangles; the shader
    /// adds procedural noise, road band, and fog.
    static func ground() -> [MeshVertex] {
        var v = [MeshVertex]()
        let hx: Float = 320, hz: Float = 200
        let n = SIMD3<Float>(0, 1, 0)
        func p(_ x: Float, _ z: Float) -> MeshVertex {
            MeshVertex(px: x, py: 0, pz: z, nx: n.x, ny: n.y, nz: n.z, part: 100, pad: 0)
        }
        v.append(p(-hx, -hz)); v.append(p(hx, -hz)); v.append(p(hx, hz))
        v.append(p(-hx, -hz)); v.append(p(hx, hz)); v.append(p(-hx, hz))
        return v
    }

    // Axis-aligned box centered at (cx,cy,cz) with half? no: full sizes sx,sy,sz.
    private static func box(_ out: inout [MeshVertex],
                            cx: Float, cy: Float, cz: Float,
                            sx: Float, sy: Float, sz: Float, part: Float) {
        let hx = sx / 2, hy = sy / 2, hz = sz / 2
        // 8 corners
        let c = [
            SIMD3<Float>(-hx, -hy, -hz), SIMD3<Float>(hx, -hy, -hz),
            SIMD3<Float>(hx, hy, -hz),   SIMD3<Float>(-hx, hy, -hz),
            SIMD3<Float>(-hx, -hy, hz),  SIMD3<Float>(hx, -hy, hz),
            SIMD3<Float>(hx, hy, hz),    SIMD3<Float>(-hx, hy, hz)
        ].map { $0 + SIMD3<Float>(cx, cy, cz) }

        // faces: (indices, normal)
        let faces: [([Int], SIMD3<Float>)] = [
            ([0, 1, 2, 3], SIMD3<Float>(0, 0, -1)),
            ([5, 4, 7, 6], SIMD3<Float>(0, 0, 1)),
            ([4, 0, 3, 7], SIMD3<Float>(-1, 0, 0)),
            ([1, 5, 6, 2], SIMD3<Float>(1, 0, 0)),
            ([3, 2, 6, 7], SIMD3<Float>(0, 1, 0)),
            ([4, 5, 1, 0], SIMD3<Float>(0, -1, 0))
        ]
        for (idx, n) in faces {
            let quad = [c[idx[0]], c[idx[1]], c[idx[2]], c[idx[3]]]
            let tri = [quad[0], quad[1], quad[2], quad[0], quad[2], quad[3]]
            for p in tri {
                out.append(MeshVertex(px: p.x, py: p.y, pz: p.z,
                                      nx: n.x, ny: n.y, nz: n.z, part: part, pad: 0))
            }
        }
    }
}

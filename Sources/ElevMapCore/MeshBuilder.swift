import Foundation

/// Takes a heightfield and produces a mesh with vertices, normals, and texture coordinates
public enum MeshBuilder {
    public static func buildMesh(from heightField: HeightField, frame: LocalENU) -> TerrainMesh {
        let w = heightField.width
        let h = heightField.height
        precondition(w >= 2 && h >= 2, "height field must be at least 2x2")

        let nw = GeoCoordinate(latitude: heightField.bounds.north, longitude: heightField.bounds.west)
        let se = GeoCoordinate(latitude: heightField.bounds.south, longitude: heightField.bounds.east)
        let nwM = frame.project(nw)
        let seM = frame.project(se)

        var positions = [SIMD3<Float>]()
        var texCoords = [SIMD2<Float>]()
        positions.reserveCapacity(w * h)
        texCoords.reserveCapacity(w * h)

        for y in 0..<h {
            let v = Double(y) / Double(h - 1)
            // Row 0 is north, so north meters decrease as y increases.
            let north = nwM.y + (seM.y - nwM.y) * v
            for x in 0..<w {
                let u = Double(x) / Double(w - 1)
                let east = nwM.x + (seM.x - nwM.x) * u
                let elevation = heightField[x, y]
                positions.append(SIMD3(Float(east), elevation, Float(-north)))
                texCoords.append(SIMD2(Float(u), Float(v)))
            }
        }

        var indices = [UInt32]()
        indices.reserveCapacity((w - 1) * (h - 1) * 6)
        for y in 0..<(h - 1) {
            for x in 0..<(w - 1) {
                let a = UInt32(y * w + x)
                let b = a + 1
                let c = a + UInt32(w)
                let d = c + 1
                indices.append(contentsOf: [a, c, b, b, c, d])
            }
        }

        let normals = accumulateNormals(positions: positions, indices: indices)
        return TerrainMesh(
            positions: positions, normals: normals, texCoords: texCoords, indices: indices,
            frame: frame, gridWidth: w, gridHeight: h)
    }

    private static func accumulateNormals(positions: [SIMD3<Float>], indices: [UInt32]) -> [SIMD3<Float>] {
        var normals = [SIMD3<Float>](repeating: .zero, count: positions.count)
        var i = 0
        while i + 2 < indices.count {
            let ia = Int(indices[i]), ib = Int(indices[i + 1]), ic = Int(indices[i + 2])
            let face = cross(positions[ib] - positions[ia], positions[ic] - positions[ia])
            normals[ia] += face
            normals[ib] += face
            normals[ic] += face
            i += 3
        }
        for j in normals.indices {
            let len = (normals[j] * normals[j]).sum().squareRoot()
            normals[j] = len > 0 ? normals[j] / len : SIMD3(0, 1, 0)
        }
        return normals
    }

    private static func cross(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
    }

}
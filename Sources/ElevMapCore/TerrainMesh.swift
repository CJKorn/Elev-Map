import Foundation

/// Raw geometry
public struct TerrainMesh: Sendable {
    public var positions: [SIMD3<Float>]
    public var normals: [SIMD3<Float>]
    public var texCoords: [SIMD2<Float>]
    public var indices: [UInt32]

    public var frame: LocalENU
    public var gridWidth: Int
    public var gridHeight: Int

    public init(
        positions: [SIMD3<Float>], normals: [SIMD3<Float>], texCoords: [SIMD2<Float>],
        indices: [UInt32], frame: LocalENU, gridWidth: Int, gridHeight: Int
    ) {
        self.positions = positions
        self.normals = normals
        self.texCoords = texCoords
        self.indices = indices
        self.frame = frame
        self.gridWidth = gridWidth
        self.gridHeight = gridHeight
    }

    public var extent: SIMD3<Float> {
        let (lo, hi) = boundingBox
        return hi - lo
    }


    public var sampleSpacing: SIMD2<Float> {
        SIMD2(
            gridWidth > 1 ? extent.x / Float(gridWidth - 1) : 0,
            gridHeight > 1 ? extent.z / Float(gridHeight - 1) : 0)
    }

    public var vertexCount: Int { positions.count }
    public var triangleCount: Int { indices.count / 3 }

    public var boundingBox: (min: SIMD3<Float>, max: SIMD3<Float>) {
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for p in positions {
            lo = SIMD3(min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z))
            hi = SIMD3(max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z))
        }
        return (lo, hi)
    }
}

public struct TextureData: Sendable {
    public enum Format: String, Sendable, Codable {
        case jpeg
        case png

        public var mimeType: String {
            switch self {
            case .jpeg: "image/jpeg"
            case .png: "image/png"
            }
        }
    }

    public var format: Format
    public var width: Int
    public var height: Int
    public var bytes: Data

    public init(format: Format, width: Int, height: Int, bytes: Data) {
        self.format = format
        self.width = width
        self.height = height
        self.bytes = bytes
    }
}

/// Whole terrain model for rendering
public struct TerrainModel: Sendable {
    public var mesh: TerrainMesh
    public var texture: TextureData?
    public var elevationRange: ClosedRange<Float>

    public init(
        mesh: TerrainMesh, texture: TextureData?, elevationRange: ClosedRange<Float>
    ) {
        self.mesh = mesh
        self.texture = texture
        self.elevationRange = elevationRange
    }
}
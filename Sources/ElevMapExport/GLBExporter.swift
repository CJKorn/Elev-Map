import ElevMapCore
import Foundation

/// Writes a `TerrainModel` as a single self-contained `.glb`.
///
/// This exists for the web demo — three.js loads GLB directly. The Vision Pro
/// app skips it entirely and builds a `MeshResource` from the same
/// `TerrainMesh` buffers, which is why nothing glTF-shaped appears in the core
/// types.
public enum GLBExporter {
    public struct Options: Sendable {
        /// Uniform scale applied to the mesh. 1.0 keeps true meters.
        public var scale: Float
        /// Recenters the mesh on its own bounding-box centre in X/Z.
        public var centerHorizontally: Bool
        /// Drops the mesh so its lowest point sits at Y = 0.
        public var restOnGround: Bool

        public init(scale: Float = 1, centerHorizontally: Bool = true, restOnGround: Bool = true) {
            self.scale = scale
            self.centerHorizontally = centerHorizontally
            self.restOnGround = restOnGround
        }
    }

    public static func export(_ model: TerrainModel, options: Options = .init()) throws -> Data {
        let mesh = model.mesh
        let (lo, hi) = mesh.boundingBox
        var offset = SIMD3<Float>.zero
        if options.centerHorizontally {
            offset.x = -(lo.x + hi.x) / 2
            offset.z = -(lo.z + hi.z) / 2
        }
        if options.restOnGround { offset.y = -lo.y }

        let positions = mesh.positions.map { ($0 + offset) * options.scale }

        var binary = Data()
        var bufferViews: [[String: Any]] = []
        var accessors: [[String: Any]] = []

        func append(_ bytes: Data, target: Int?) -> Int {
            while binary.count % 4 != 0 { binary.append(0) }
            var view: [String: Any] = [
                "buffer": 0, "byteOffset": binary.count, "byteLength": bytes.count,
            ]
            if let target { view["target"] = target }
            binary.append(bytes)
            bufferViews.append(view)
            return bufferViews.count - 1
        }

        func accessor(
            view: Int, componentType: Int, count: Int, type: String,
            min: [Float]? = nil, max: [Float]? = nil
        ) -> Int {
            var a: [String: Any] = [
                "bufferView": view, "componentType": componentType, "count": count, "type": type,
            ]
            if let min { a["min"] = min }
            if let max { a["max"] = max }
            accessors.append(a)
            return accessors.count - 1
        }

        // 34962 = ARRAY_BUFFER, 34963 = ELEMENT_ARRAY_BUFFER, 5126 = FLOAT,
        // 5125 = UNSIGNED_INT.
        let positionView = append(floatData(positions.flatMap { [$0.x, $0.y, $0.z] }), target: 34962)
        let normalView = append(
            floatData(mesh.normals.flatMap { [$0.x, $0.y, $0.z] }), target: 34962)
        let uvView = append(floatData(mesh.texCoords.flatMap { [$0.x, $0.y] }), target: 34962)
        let indexView = append(indexData(mesh.indices), target: 34963)

        let scaledLo = (lo + offset) * options.scale
        let scaledHi = (hi + offset) * options.scale
        let positionAccessor = accessor(
            view: positionView, componentType: 5126, count: positions.count, type: "VEC3",
            min: [scaledLo.x, scaledLo.y, scaledLo.z], max: [scaledHi.x, scaledHi.y, scaledHi.z])
        let normalAccessor = accessor(
            view: normalView, componentType: 5126, count: mesh.normals.count, type: "VEC3")
        let uvAccessor = accessor(
            view: uvView, componentType: 5126, count: mesh.texCoords.count, type: "VEC2")
        let indexAccessor = accessor(
            view: indexView, componentType: 5125, count: mesh.indices.count, type: "SCALAR")

        var material: [String: Any] = [
            "name": "terrain",
            "pbrMetallicRoughness": [
                "baseColorFactor": [1.0, 1.0, 1.0, 1.0],
                "metallicFactor": 0.0,
                "roughnessFactor": 1.0,
            ] as [String: Any],
            "doubleSided": true,
        ]
        var images: [[String: Any]] = []
        var textures: [[String: Any]] = []
        var samplers: [[String: Any]] = []

        if let texture = model.texture {
            let imageView = append(texture.bytes, target: nil)
            images.append(["bufferView": imageView, "mimeType": texture.format.mimeType])
            samplers.append(["magFilter": 9729, "minFilter": 9987, "wrapS": 33071, "wrapT": 33071])
            textures.append(["sampler": 0, "source": 0])
            var pbr = material["pbrMetallicRoughness"] as! [String: Any]
            pbr["baseColorTexture"] = ["index": 0, "texCoord": 0]
            material["pbrMetallicRoughness"] = pbr
        }

        // Pad before the length lands in the JSON, or the declared buffer
        // length disagrees with the BIN chunk.
        while binary.count % 4 != 0 { binary.append(0) }

        var json: [String: Any] = [
            "asset": ["version": "2.0", "generator": "ElevMapKit"],
            "scene": 0,
            "scenes": [["nodes": [0]]],
            "nodes": [["mesh": 0, "name": "terrain"]],
            "meshes": [
                [
                    "name": "terrain",
                    "primitives": [
                        [
                            "attributes": [
                                "POSITION": positionAccessor,
                                "NORMAL": normalAccessor,
                                "TEXCOORD_0": uvAccessor,
                            ],
                            "indices": indexAccessor,
                            "material": 0,
                            "mode": 4,
                        ]
                    ],
                ]
            ],
            "materials": [material],
            "accessors": accessors,
            "bufferViews": bufferViews,
            "buffers": [["byteLength": binary.count]],
        ]
        if !images.isEmpty {
            json["images"] = images
            json["textures"] = textures
            json["samplers"] = samplers
        }

        var jsonChunk = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        while jsonChunk.count % 4 != 0 { jsonChunk.append(0x20) }  // pad with spaces

        var out = Data()
        out.append(uint32(0x4654_6C67))  // "glTF"
        out.append(uint32(2))
        out.append(uint32(UInt32(12 + 8 + jsonChunk.count + 8 + binary.count)))
        out.append(uint32(UInt32(jsonChunk.count)))
        out.append(uint32(0x4E4F_534A))  // "JSON"
        out.append(jsonChunk)
        out.append(uint32(UInt32(binary.count)))
        out.append(uint32(0x004E_4942))  // "BIN\0"
        out.append(binary)
        return out
    }

    private static func floatData(_ values: [Float]) -> Data {
        var out = Data(capacity: values.count * 4)
        for v in values { out.append(uint32(v.bitPattern)) }
        return out
    }

    private static func indexData(_ values: [UInt32]) -> Data {
        var out = Data(capacity: values.count * 4)
        for v in values { out.append(uint32(v)) }
        return out
    }

    /// glTF is little-endian everywhere.
    private static func uint32(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)])
    }
}

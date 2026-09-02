import ElevMapCore
import Foundation

// I don't have access to realitykit so this is essentially an AI generated stub
#if canImport(RealityKit) && canImport(MapKit)
    import ImageIO
    import MapKit
    import RealityKit

    extension GeoBounds {
        /// The rectangle a MapKit view is currently showing.
        public init(_ region: MKCoordinateRegion) {
            self.init(
                south: region.center.latitude - region.span.latitudeDelta / 2,
                west: region.center.longitude - region.span.longitudeDelta / 2,
                north: region.center.latitude + region.span.latitudeDelta / 2,
                east: region.center.longitude + region.span.longitudeDelta / 2)
        }

        public init(_ rect: MKMapRect) {
            self.init(MKCoordinateRegion(rect))
        }
    }

    extension TerrainMesh {
        /// The same buffers the GLB exporter writes, handed to RealityKit
        /// directly. No file, no parse, no glTF.
        public func makeMeshResource() throws -> MeshResource {
            var descriptor = MeshDescriptor(name: "terrain")
            descriptor.positions = MeshBuffers.Positions(positions)
            descriptor.normals = MeshBuffers.Normals(normals)
            descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(texCoords)
            descriptor.primitives = .triangles(indices)
            return try MeshResource.generate(from: [descriptor])
        }
    }

    extension TerrainModel {
        /// A textured entity in meters, ready to anchor over the map plane.
        ///
        /// - Parameter scale: 1 keeps true scale, which is what you want when
        ///   the terrain sits on a map at a known zoom. Shrink it for a
        ///   tabletop presentation instead of rebuilding the mesh.
        @MainActor
        public func makeEntity(scale: Float = 1) throws -> ModelEntity {
            var material = PhysicallyBasedMaterial()
            material.roughness = 1.0
            material.metallic = 0.0

            if let texture, let resource = try? Self.textureResource(from: texture) {
                material.baseColor = .init(texture: .init(resource))
            } else {
                material.baseColor = .init(tint: .init(white: 0.6, alpha: 1))
            }

            let entity = try ModelEntity(mesh: mesh.makeMeshResource(), materials: [material])
            entity.name = "terrain"
            entity.scale = .init(repeating: scale)
            return entity
        }

        private static func textureResource(from texture: TextureData) throws -> TextureResource {
            switch texture.format {
            case .jpeg, .png:
                guard
                    let source = CGImageSourceCreateWithData(texture.bytes as CFData, nil),
                    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
                else { throw ElevMapError.malformedResponse("could not decode imagery") }
                return try TextureResource(image: image, options: .init(semantic: .color))
            case .rgba8:
                throw ElevMapError.unsupportedRasterFormat("raw RGBA texture upload")
            }
        }
    }
#endif

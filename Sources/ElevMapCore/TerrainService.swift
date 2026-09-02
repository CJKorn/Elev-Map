/// Interface for generating terrain and retrieving mesh

import Foundation

public struct TerrainRequest: Sendable, Codable {
    public var bounds: GeoBounds
    public var dataset: DEMDataset
    public var textureResolution: Int

    public init(
        bounds: GeoBounds,
        dataset: DEMDataset = .glo30,
        textureResolution: Int = 2048
    ) {
        self.bounds = bounds
        self.dataset = dataset
        self.textureResolution = textureResolution
    }
}

public actor TerrainService {
    public struct Limits: Sendable {
        public var maxAreaSquareKilometers: Double = 40_000
        public init() {}
    }

    private let elevation: [DEMDataset: any ElevationSource]
    private let imagery: (any ImagerySource)?
    private let limits: Limits

    public init(
        elevation: [DEMDataset: any ElevationSource],
        imagery: (any ImagerySource)? = nil,
        limits: Limits = .init()
    ) {
        self.elevation = elevation
        self.imagery = imagery
        self.limits = limits
    }

    public func buildTerrain(
        _ request: TerrainRequest,
        onProgress: (@Sendable (TerrainProgress) -> Void)? = nil
    ) async throws -> TerrainModel {
        guard request.bounds.isValid else { throw ElevMapError.invalidBounds(request.bounds) }
        guard let source = elevation[request.dataset] else {
            throw ElevMapError.datasetDoesNotCoverBounds(request.dataset, request.bounds)
        }

        let area = approximateAreaSquareKilometers(request.bounds)
        guard area <= limits.maxAreaSquareKilometers else {
            throw ElevMapError.areaTooLarge(
                requestedSquareKilometers: area, limit: limits.maxAreaSquareKilometers)
        }

        let bounds = request.bounds
        let textureResolution = request.textureResolution
        let imagery = self.imagery
        let wantsTexture = imagery != nil && textureResolution > 0

        // Elevation is the long pole; the mesh is a fraction of a second on
        // grids this size, but it is the part with nothing to wait on, so it
        // gets enough of the bar to look deliberate rather than instant.
        var weights = ["elevation": 0.72, "mesh": 0.04]
        if wantsTexture { weights["imagery"] = 0.24 }
        let reporter = onProgress.map { ProgressReporter(weights: weights, handler: $0) }

        return try await ProgressReporter.$current.withValue(reporter) {
            async let heightTask = ProgressReporter.run(channel: "elevation") {
                try await source.heightField(for: bounds)
            }
            async let textureTask: TextureData? = ProgressReporter.run(channel: "imagery") {
                guard let imagery, wantsTexture else { return nil }
                return try await imagery.texture(for: bounds, maxDimension: textureResolution)
            }

            var field = try await heightTask
            let texture = try await textureTask

            await ProgressReporter.run(channel: "mesh") {
                await ProgressReporter.report(0.1, "Building the mesh")
            }
            field.fixNull()
            let mesh = MeshBuilder.buildMesh(
                from: field, frame: LocalENU(origin: bounds.center))
            await ProgressReporter.run(channel: "mesh") {
                await ProgressReporter.report(1, "Mesh ready")
            }

            return TerrainModel(
                mesh: mesh, texture: texture, elevationRange: field.elevationRange)
        }
    }

    private func approximateAreaSquareKilometers(_ bounds: GeoBounds) -> Double {
        let frame = LocalENU(origin: bounds.center)
        let w = bounds.longitudeSpan * frame.metersPerDegreeLongitude / 1000
        let h = bounds.latitudeSpan * frame.metersPerDegreeLatitude / 1000
        return abs(w * h)
    }
}


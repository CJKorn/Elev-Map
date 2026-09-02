import ElevMapCore
import ElevMapExport
import Foundation
import Hummingbird

/// Tracks builds in flight so the browser can show progress.
///
/// Only the demo needs this. A build takes anywhere from two seconds to half a
/// minute depending on the dataset, which is too long to leave a page with no
/// feedback; on visionOS the same `TerrainProgress` callback drives whatever
/// the app shows instead.
actor TerrainJobs {
    struct Status: Codable, Sendable, ResponseEncodable {
        enum State: String, Codable, Sendable {
            case running, done, failed
        }

        var state: State
        var progress: Double
        /// Which part of the build the message came from: the page uses this
        /// to tick off its step list instead of pattern-matching prose.
        var channel: String
        var message: String
        var error: String?
        var summary: Summary?
    }

    struct Summary: Codable, Sendable, ResponseEncodable {
        var gridWidth: Int
        var gridHeight: Int
        var vertexCount: Int
        var triangleCount: Int
        var sampleSpacingMeters: Double
        var widthMeters: Double
        var heightMeters: Double
        var minElevation: Double
        var maxElevation: Double
        var textureWidth: Int?
        var textureHeight: Int?
        var byteCount: Int
        var dataset: String
        var seconds: Double
    }

    private struct Job {
        var status: Status
        var model: Data?
        var task: Task<Void, Never>?
        var finished: Date?
    }

    private var jobs: [String: Job] = [:]
    private let service: TerrainService

    init(service: TerrainService) {
        self.service = service
    }

    func start(_ request: TerrainRequest) -> String {
        let id = UUID().uuidString
        jobs[id] = Job(
            status: Status(
                state: .running, progress: 0, channel: "elevation", message: "Starting"),
            model: nil, task: nil, finished: nil)

        let task = Task { [weak self] in
            guard let self else { return }
            let started = Date()
            do {
                let model = try await service.buildTerrain(request) { update in
                    Task { await self.record(id: id, progress: update) }
                }
                await self.record(
                    id: id,
                    progress: TerrainProgress(
                        fraction: 0.97, channel: "export", message: "Packing the glTF"))
                let longest = max(model.mesh.extent.x, model.mesh.extent.z)
                let glb = try GLBExporter.export(
                    model, options: .init(scale: longest > 0 ? 100 / longest : 1))

                let summary = Summary(
                    gridWidth: model.mesh.gridWidth,
                    gridHeight: model.mesh.gridHeight,
                    vertexCount: model.mesh.vertexCount,
                    triangleCount: model.mesh.triangleCount,
                    sampleSpacingMeters: Double(model.mesh.sampleSpacing.x),
                    widthMeters: Double(model.mesh.extent.x),
                    heightMeters: Double(model.mesh.extent.z),
                    minElevation: Double(model.elevationRange.lowerBound),
                    maxElevation: Double(model.elevationRange.upperBound),
                    textureWidth: model.texture?.width,
                    textureHeight: model.texture?.height,
                    byteCount: glb.count,
                    dataset: request.dataset.displayName,
                    seconds: Date().timeIntervalSince(started))

                await self.finish(id: id, model: glb, summary: summary)
            } catch {
                let message = (error as? ElevMapError)?.description ?? "\(error)"
                await self.fail(id: id, error: message)
            }
        }
        jobs[id]?.task = task
        sweep()
        return id
    }

    func status(_ id: String) -> Status? { jobs[id]?.status }

    func model(_ id: String) -> Data? { jobs[id]?.model }

    func cancel(_ id: String) {
        jobs[id]?.task?.cancel()
        jobs[id] = nil
    }

    /// Updates arrive from a detached task per report, so they can overtake
    /// each other; the bar only ever moves forwards.
    private func record(id: String, progress: TerrainProgress) {
        guard let job = jobs[id], job.status.state == .running else { return }
        guard progress.fraction >= job.status.progress else { return }
        jobs[id]?.status.progress = progress.fraction
        jobs[id]?.status.channel = progress.channel
        jobs[id]?.status.message = progress.message
    }

    private func finish(id: String, model: Data, summary: Summary) {
        guard jobs[id] != nil else { return }
        jobs[id]?.model = model
        jobs[id]?.finished = Date()
        jobs[id]?.status = Status(
            state: .done, progress: 1, channel: "done", message: "Ready", error: nil,
            summary: summary)
    }

    private func fail(id: String, error: String) {
        guard jobs[id] != nil else { return }
        jobs[id]?.finished = Date()
        jobs[id]?.status = Status(
            state: .failed, progress: 0, channel: "failed", message: "Failed", error: error,
            summary: nil)
    }

    /// Finished models hold a few megabytes each; drop them after ten minutes.
    private func sweep() {
        let cutoff = Date().addingTimeInterval(-600)
        for (id, job) in jobs where (job.finished ?? .distantFuture) < cutoff {
            jobs[id] = nil
        }
    }
}

import AVFoundation
import QuartzCore

/// Writes a video meme: the template's video with its captions drawn over every frame, and the
/// caption strip, if any, added above the picture.
nonisolated enum VideoExporter {
    enum Failure: Error { case noVideoTrack, couldNotDraw }

    static func export(_ video: URL, document: MemeDocument, to destination: URL) async throws {
        try? FileManager.default.removeItem(at: destination)
        // Nothing to draw: the original is already the meme.
        if document.isEmpty && document.captionStrip == 0 {
            try FileManager.default.copyItem(at: video, to: destination)
            return
        }

        let asset = AVURLAsset(url: video)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideoTrack }
        let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
        let duration = try await asset.load(.duration)
        let picture = CGRect(origin: .zero, size: natural).applying(transform).standardized.size
        guard let captions = MemeRenderer.captions(document, size: picture) else { throw Failure.couldNotDraw }

        // H.264 wants even dimensions.
        let canvas = CGSize(width: (picture.width / 2).rounded(.down) * 2, height: (Double(captions.height) / 2).rounded(.down) * 2)
        let strip = canvas.height - picture.height

        // The render's origin is the top left, so moving the picture down by the strip leaves room above it.
        var layer = AVVideoCompositionLayerInstruction.Configuration(assetTrack: track)
        layer.setTransform(transform.concatenating(CGAffineTransform(translationX: 0, y: strip)), at: .zero)
        let instruction = AVVideoCompositionInstruction(configuration: .init(
            backgroundColor: CGColor(gray: 1, alpha: 1),
            layerInstructions: [AVVideoCompositionLayerInstruction(configuration: layer)],
            timeRange: CMTimeRange(start: .zero, duration: duration)
        ))

        let frame = CGRect(origin: .zero, size: canvas)
        let container = CALayer()
        container.frame = frame
        let videoLayer = CALayer()
        videoLayer.frame = frame
        let textLayer = CALayer()
        textLayer.frame = frame
        textLayer.contents = captions
        container.addSublayer(videoLayer)
        container.addSublayer(textLayer)

        var configuration = try await AVVideoComposition.Configuration(for: asset)
        configuration.instructions = [instruction]
        configuration.renderSize = canvas
        configuration.animationTool = AVVideoCompositionCoreAnimationTool(
            configuration: .init(postProcessingAsVideoLayer: videoLayer, containingLayer: container)
        )

        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw Failure.couldNotDraw
        }
        session.videoComposition = AVVideoComposition(configuration: configuration)
        session.shouldOptimizeForNetworkUse = true
        try await session.export(to: destination, as: .mp4)
    }
}

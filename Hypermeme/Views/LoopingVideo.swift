import AVFoundation
import SwiftUI

/// A video that plays on a loop, with no controls of its own. It fits its frame like the poster does.
///
/// It only plays while it's on screen: leaving the window, the window closing or the panel hiding all
/// stop it, since SwiftUI can keep a view alive in a hidden window.
struct LoopingVideo: NSViewRepresentable {
    let url: URL
    var isMuted = true
    var isPlaying = true

    final class PlayerView: NSView {
        private let player = AVQueuePlayer()
        private var looper: AVPlayerLooper?
        private var url: URL?
        private var wantsToPlay = false
        private var observer: NSObjectProtocol?

        override init(frame: NSRect) {
            super.init(frame: frame)
            let layer = AVPlayerLayer(player: player)
            layer.videoGravity = .resizeAspect
            self.layer = layer
            wantsLayer = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        func show(_ url: URL, muted: Bool, playing: Bool) {
            if self.url != url {
                self.url = url
                player.removeAllItems()
                looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            }
            player.isMuted = muted
            wantsToPlay = playing
            sync()
        }

        func stop() {
            wantsToPlay = false
            player.pause()
            looper?.disableLooping()
            looper = nil
            player.removeAllItems()
            url = nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else {
                stop()
                return
            }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.sync() }
            }
            sync()
        }

        /// Plays only when asked to and actually visible.
        private func sync() {
            let visible = window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false
            if wantsToPlay && visible && url != nil { player.play() } else { player.pause() }
        }

        isolated deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            player.pause()
        }
    }

    func makeNSView(context: Context) -> PlayerView { PlayerView() }

    func updateNSView(_ view: PlayerView, context: Context) {
        view.show(url, muted: isMuted, playing: isPlaying)
    }

    static func dismantleNSView(_ view: PlayerView, coordinator: ()) {
        view.stop()
    }
}

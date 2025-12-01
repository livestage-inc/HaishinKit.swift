@preconcurrency import AVKit
import Combine
import HaishinKit
@preconcurrency import Logboard
import SwiftUI

@MainActor
final class PlaybackViewModel: ObservableObject {
    @Published private(set) var readyState: SessionReadyState = .closed
    @Published private(set) var error: Error?
    @Published var isShowError = false

    private var view: PiPHKView?
    private var session: (any Session)?
    private let audioPlayer = AudioPlayer(audioEngine: AVAudioEngine())
    private var pictureInPictureController: AVPictureInPictureController?

    func start() async {
        guard let session else {
            return
        }
        do {
            try await session.connect {
                Task { @MainActor in
                    self.isShowError = true
                }
            }
        } catch {
            self.error = error
            self.isShowError = true
        }
    }

    func stop() async {
        do {
            try await session?.close()
        } catch {
            logger.error(error)
        }
    }

    func makeSession() async {
        do {
            session = try await SessionBuilderFactory.shared.make(Preference.default.makeURL())
                .setMode(.playback)
                .build()
            await session?.setMaxRetryCount(0)
            guard let session else {
                return
            }
            if let view {
                await session.stream.addOutput(view)
            }
            await session.stream.attachAudioPlayer(audioPlayer)
            Task {
                for await readyState in await session.readyState {
                    self.readyState = readyState
                    switch readyState {
                    case .open:
                        UIApplication.shared.isIdleTimerDisabled = false
                    default:
                        UIApplication.shared.isIdleTimerDisabled = true
                    }
                }
            }
        } catch {
            logger.error(error)
        }
    }
}

extension PlaybackViewModel: PiPHKViewRepresentable.PreviewSource {
    // MARK: PiPHKSwiftUiView.PreviewSource
    nonisolated func connect(to view: HaishinKit.PiPHKView) {
        Task { @MainActor in
            self.view = view
            if pictureInPictureController == nil {
                pictureInPictureController = AVPictureInPictureController(contentSource: .init(sampleBufferDisplayLayer: view.layer, playbackDelegate: PlaybackDelegate()))
            }
        }
    }
}

final class PlaybackDelegate: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate {
    // MARK: AVPictureInPictureControllerDelegate
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        return CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        return false
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}

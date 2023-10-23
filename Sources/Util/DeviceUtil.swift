import AVFoundation

#if os(iOS) || os(macOS)
extension AVFrameRateRange {
    func clamp(rate: Float64) -> Float64 {
        max(minFrameRate, min(maxFrameRate, rate))
    }

    func contains(rate: Float64) -> Bool {
        (minFrameRate...maxFrameRate) ~= rate
    }
}

extension AVCaptureDevice {
    func actualFPS(_ fps: Float64) -> (fps: Float64, duration: CMTime)? {
        var durations: [CMTime] = []
        var frameRates: [Float64] = []

        for range in activeFormat.videoSupportedFrameRateRanges {
            if range.minFrameRate == range.maxFrameRate {
                durations.append(range.minFrameDuration)
                frameRates.append(range.maxFrameRate)
                continue
            }

            if range.contains(rate: fps) {
                return (fps, CMTimeMake(value: 100, timescale: Int32(100 * fps)))
            }

            let actualFPS: Float64 = range.clamp(rate: fps)
            return (actualFPS, CMTimeMake(value: 100, timescale: Int32(100 * actualFPS)))
        }

        let diff = frameRates.map { abs($0 - fps) }

        if let minElement: Float64 = diff.min() {
            for i in 0..<diff.count where diff[i] == minElement {
                return (frameRates[i], durations[i])
            }
        }

        return nil
    }
}

public struct DeviceUtil {
    
    private static var allCaptureDevices: [AVCaptureDevice] {
        if #available(iOS 13.0, *) {
            return AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInTripleCamera, .builtInDualCamera, .builtInDualWideCamera, .builtInWideAngleCamera], mediaType: .video, position: .unspecified).devices
        } else {
            // Fallback on earlier versions
            return []
        }
    }
    
    private static var backCaptureDevices: [AVCaptureDevice] {
        allCaptureDevices
            .filter { $0.position == .back }
    }
    
    public static func device(withPosition: AVCaptureDevice.Position) -> AVCaptureDevice? {
    
        let device = backCaptureDevices.first //AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back)

        return device
        
        
//        AVCaptureDevice.devices().first {
//            $0.hasMediaType(.video) && $0.position == withPosition
//        }
    }

    public static func device(withLocalizedName: String, mediaType: AVMediaType) -> AVCaptureDevice? {
        AVCaptureDevice.devices().first {
            $0.hasMediaType(mediaType) && $0.localizedName == withLocalizedName
        }
    }
}
#endif

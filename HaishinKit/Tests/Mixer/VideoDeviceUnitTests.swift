import AVFoundation
import Foundation
import Testing

@testable import HaishinKit

@Suite struct VideoDeviceUnitTests {
    @Test func release() {
        weak var weakDevice: VideoDeviceUnit?
        _ = {
            let device = try! VideoDeviceUnit(0, device: AVCaptureDevice.default(for: .video)!)
            weakDevice = device
        }()
        #expect(weakDevice == nil)
    }
}

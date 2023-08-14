import AVFoundation
import CoreImage
import UIKit

final class AVVideoIOUnit: NSObject, AVIOUnit {
    
//    var blackCIImageDict: [String: CIImage] = {
//
//        var _blackCIImageDict = [String: CIImage]()
//
//        for index in 0..<32 {
//            let image = UIImage(named: "black\(index + 1).PNG")!
//
////            let size = CGSizeApplyAffineTransform(image.size, CGAffineTransformMakeScale(1, 1))
////            let hasAlpha = true
////            let scale: CGFloat = 0.0 // Automatically use scale factor of main screen
////
////            UIGraphicsBeginImageContextWithOptions(size, !hasAlpha, scale)
////            image.draw(in: CGRect(origin: CGPointZero, size: size))
////
////            let scaledImage = UIGraphicsGetImageFromCurrentImageContext()
////            UIGraphicsEndImageContext()
//
//            var ciImage = CIImage(cgImage: image.cgImage!)
//
//            _blackCIImageDict["black\(index + 1).PNG"] = ciImage
//        }
//
//        return _blackCIImageDict
//    }()
    
//    var whiteCIImage: CIImage = {
//        let image = UIImage(named: "white.PNG")!
//
////        let size = CGSizeApplyAffineTransform(image.size, CGAffineTransformMakeScale(1, 1))
////        let hasAlpha = true
////        let scale: CGFloat = 0.0 // Automatically use scale factor of main screen
////
////        UIGraphicsBeginImageContextWithOptions(size, !hasAlpha, scale)
////        image.draw(in: CGRect(origin: CGPointZero, size: size))
////
////        let scaledImage = UIGraphicsGetImageFromCurrentImageContext()
////        UIGraphicsEndImageContext()
//
//        var ciImage = CIImage(cgImage: image.cgImage!)
//        return ciImage
//    }()
    
    var frameNumber: Int = 0
    
    static let defaultAttributes: [NSString: NSObject] = [
        kCVPixelBufferPixelFormatTypeKey: NSNumber(value: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        kCVPixelBufferMetalCompatibilityKey: kCFBooleanTrue
    ]

    let lockQueue = DispatchQueue(label: "com.haishinkit.HaishinKit.VideoIOComponent.lock")

    var context: CIContext? {
        didSet {
            for effect in effects {
                effect.ciContext = context
            }
        }
    }

    #if os(iOS) || os(macOS)
    weak var renderer: NetStreamRenderer? {
        didSet {
            renderer?.orientation = orientation
        }
    }
    #else
    weak var renderer: NetStreamRenderer?
    #endif

    var formatDescription: CMVideoFormatDescription? {
        didSet {
            decoder.formatDescription = formatDescription
        }
    }
    lazy var encoder: VideoCodec = {
        var encoder = VideoCodec()
        encoder.lockQueue = lockQueue
        return encoder
    }()
    lazy var decoder: H264Decoder = {
        var decoder = H264Decoder()
        decoder.delegate = self
        return decoder
    }()
    weak var mixer: AVMixer?

    private(set) var effects: Set<VideoEffect> = []

    private var extent = CGRect.zero {
        didSet {
            guard extent != oldValue else {
                return
            }
            pixelBufferPool = nil
        }
    }

    private var attributes: [NSString: NSObject] {
        var attributes: [NSString: NSObject] = Self.defaultAttributes
        attributes[kCVPixelBufferWidthKey] = NSNumber(value: Int(extent.width))
        attributes[kCVPixelBufferHeightKey] = NSNumber(value: Int(extent.height))
        return attributes
    }

    private var _pixelBufferPool: CVPixelBufferPool?
    private var pixelBufferPool: CVPixelBufferPool! {
        get {
            if _pixelBufferPool == nil {
                var pixelBufferPool: CVPixelBufferPool?
                CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary?, &pixelBufferPool)
                _pixelBufferPool = pixelBufferPool
            }
            return _pixelBufferPool!
        }
        set {
            _pixelBufferPool = newValue
        }
    }

    #if os(iOS) || os(macOS)
    var fps: Float64 = AVMixer.defaultFPS {
        didSet {
            guard
                let device: AVCaptureDevice = (input as? AVCaptureDeviceInput)?.device,
                let data = device.actualFPS(fps) else {
                    return
            }

            fps = data.fps
            encoder.expectedFPS = data.fps
            logger.info("\(data)")

            do {
                try device.lockForConfiguration()
                device.activeVideoMinFrameDuration = data.duration
                device.activeVideoMaxFrameDuration = data.duration
                device.unlockForConfiguration()
            } catch let error as NSError {
                logger.error("while locking device for fps: \(error)")
            }
        }
    }

    var position: AVCaptureDevice.Position = .back

    var videoSettings: [NSObject: AnyObject] = AVMixer.defaultVideoSettings {
        didSet {
            output.videoSettings = videoSettings as? [String: Any]
        }
    }

    var isVideoMirrored = false {
        didSet {
            guard isVideoMirrored != oldValue else {
                return
            }
            for connection in output.connections where connection.isVideoMirroringSupported {
                connection.isVideoMirrored = isVideoMirrored
            }
        }
    }

    var orientation: AVCaptureVideoOrientation = .portrait {
        didSet {
            renderer?.orientation = orientation
            guard orientation != oldValue else {
                return
            }
            for connection in output.connections where connection.isVideoOrientationSupported {
                connection.videoOrientation = orientation
                if torch {
                    setTorchMode(.on)
                }
                #if os(iOS)
                connection.preferredVideoStabilizationMode = preferredVideoStabilizationMode
                #endif
            }
        }
    }

    var torch = false {
        didSet {
            guard torch != oldValue else {
                return
            }
            setTorchMode(torch ? .on : .off)
        }
    }
    
    var initialZoom: CGFloat = 1.0

    var continuousAutofocus = false {
        didSet {
            guard continuousAutofocus != oldValue else {
                return
            }
            let focusMode: AVCaptureDevice.FocusMode = continuousAutofocus ? .continuousAutoFocus : .autoFocus
            guard let device: AVCaptureDevice = (input as? AVCaptureDeviceInput)?.device,
                device.isFocusModeSupported(focusMode) else {
                    logger.warn("focusMode(\(focusMode.rawValue)) is not supported")
                    return
            }
            do {
                try device.lockForConfiguration()
                device.focusMode = focusMode
                device.unlockForConfiguration()
            } catch let error as NSError {
                logger.error("while locking device for autofocus: \(error)")
            }
        }
    }

    var focusPointOfInterest: CGPoint? {
        didSet {
            guard
                let device: AVCaptureDevice = (input as? AVCaptureDeviceInput)?.device,
                let point: CGPoint = focusPointOfInterest,
                device.isFocusPointOfInterestSupported else {
                    return
            }
            do {
                try device.lockForConfiguration()
                device.focusPointOfInterest = point
                device.focusMode = continuousAutofocus ? .continuousAutoFocus : .autoFocus
                device.unlockForConfiguration()
            } catch let error as NSError {
                logger.error("while locking device for focusPointOfInterest: \(error)")
            }
        }
    }

    var exposurePointOfInterest: CGPoint? {
        didSet {
            guard
                let device: AVCaptureDevice = (input as? AVCaptureDeviceInput)?.device,
                let point: CGPoint = exposurePointOfInterest,
                device.isExposurePointOfInterestSupported else {
                    return
            }
            do {
                try device.lockForConfiguration()
                device.exposurePointOfInterest = point
                device.exposureMode = continuousExposure ? .continuousAutoExposure : .autoExpose
                device.unlockForConfiguration()
            } catch let error as NSError {
                logger.error("while locking device for exposurePointOfInterest: \(error)")
            }
        }
    }

    var continuousExposure = false {
        didSet {
            guard continuousExposure != oldValue else {
                return
            }
            let exposureMode: AVCaptureDevice.ExposureMode = continuousExposure ? .continuousAutoExposure : .autoExpose
            guard let device: AVCaptureDevice = (input as? AVCaptureDeviceInput)?.device,
                device.isExposureModeSupported(exposureMode) else {
                    logger.warn("exposureMode(\(exposureMode.rawValue)) is not supported")
                    return
            }
            do {
                try device.lockForConfiguration()
                device.exposureMode = exposureMode
                device.unlockForConfiguration()
            } catch let error as NSError {
                logger.error("while locking device for autoexpose: \(error)")
            }
        }
    }

    #if os(iOS)
    var preferredVideoStabilizationMode: AVCaptureVideoStabilizationMode = .off {
        didSet {
            guard preferredVideoStabilizationMode != oldValue else {
                return
            }
            for connection in output.connections {
                connection.preferredVideoStabilizationMode = preferredVideoStabilizationMode
            }
        }
    }
    #endif

    private var _output: AVCaptureVideoDataOutput?
    var output: AVCaptureVideoDataOutput! {
        get {
            if _output == nil {
                _output = AVCaptureVideoDataOutput()
                _output?.alwaysDiscardsLateVideoFrames = true
                _output?.videoSettings = videoSettings as? [String: Any]
            }
            return _output!
        }
        set {
            if _output == newValue {
                return
            }
            if let output: AVCaptureVideoDataOutput = _output {
                output.setSampleBufferDelegate(nil, queue: nil)
                mixer?.session.removeOutput(output)
            }
            _output = newValue
        }
    }

    var input: AVCaptureInput? {
        didSet {
            guard let mixer: AVMixer = mixer, oldValue != input else {
                return
            }
            if let oldValue: AVCaptureInput = oldValue {
                mixer.session.removeInput(oldValue)
            }
            if let input: AVCaptureInput = input, mixer.session.canAddInput(input) {
                mixer.session.addInput(input)
            }
        }
    }
    #endif

    #if os(iOS)
    var screen: CaptureSessionConvertible? {
        didSet {
            if let oldValue = oldValue {
                oldValue.delegate = nil
            }
            if let screen = screen {
                screen.delegate = self
            }
        }
    }
    #endif

    deinit {
        if Thread.isMainThread {
            self.renderer?.attachStream(nil)
        } else {
            DispatchQueue.main.sync {
                self.renderer?.attachStream(nil)
            }
        }
        #if os(iOS) || os(macOS)
        input = nil
        output = nil
        #endif
    }

    #if os(iOS) || os(macOS)
    func attachCamera(_ camera: AVCaptureDevice?) throws {
        guard let mixer: AVMixer = mixer else {
            return
        }

        mixer.session.beginConfiguration()
        defer {
            mixer.session.commitConfiguration()
            if torch {
                setTorchMode(.on)
            }
            if initialZoom {
                setZoomFactor(initialZoom, ramping: false, withRate: 1)
            }
        }

        output = nil
        guard let camera: AVCaptureDevice = camera else {
            input = nil
            return
        }
        #if os(iOS)
        screen = nil
        #endif

        input = try AVCaptureDeviceInput(device: camera)
        mixer.session.addOutput(output)

        for connection in output.connections {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = orientation
            }
            if connection.isVideoMirroringSupported {
                connection.isVideoMirrored = isVideoMirrored
            }
            #if os(iOS)
            connection.preferredVideoStabilizationMode = preferredVideoStabilizationMode
            #endif
        }

        output.setSampleBufferDelegate(self, queue: lockQueue)

        fps *= 1
        position = camera.position
        renderer?.position = camera.position
    }

    func setTorchMode(_ torchMode: AVCaptureDevice.TorchMode) {
        guard let device: AVCaptureDevice = (input as? AVCaptureDeviceInput)?.device, device.isTorchModeSupported(torchMode) else {
            logger.warn("torchMode(\(torchMode)) is not supported")
            return
        }
        do {
            try device.lockForConfiguration()
            device.torchMode = torchMode
            device.unlockForConfiguration()
        } catch let error as NSError {
            logger.error("while setting torch: \(error)")
        }
    }
    #endif

    @inline(__always)
    func effect(_ buffer: CVImageBuffer, info: CMSampleBuffer?) -> CIImage {
        var image = CIImage(cvPixelBuffer: buffer)
        for effect in effects {
            image = effect.execute(image, info: info)
        }
        return image
    }

    func registerEffect(_ effect: VideoEffect) -> Bool {
        effect.ciContext = context
        return effects.insert(effect).inserted
    }

    func unregisterEffect(_ effect: VideoEffect) -> Bool {
        effect.ciContext = nil
        return effects.remove(effect) != nil
    }
}

extension AVVideoIOUnit {
    func pad(string : String, toSize: Int) -> String {
      var padded = string
      for _ in 0..<(toSize - string.count) {
        padded = "0" + padded
      }
        return padded
    }
    
    func encodeSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let buffer: CVImageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

//        var imageBuffer: CVImageBuffer?

        CVPixelBufferLockBaseAddress(buffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(buffer, [])
//            if let imageBuffer = imageBuffer {
//                CVPixelBufferUnlockBaseAddress(imageBuffer, [])
//            }
        }
        
//        let ioSurface = CVPixelBufferGetIOSurface(buffer)
        
        // This came from the capture output step so lets record the timestamp and feed the frame for livestage storage
        let absoluteTime = frameNumber//Date.timeIntervalSinceReferenceDate
//        let timestamp: Int = Int(absoluteTime * 1e+5)
        
        
        var image = CIImage(cvPixelBuffer: buffer)
        LiveStageFastStorage.shared.feedIn(ciImage: image, timestamp: absoluteTime)
        
        let num = absoluteTime
        let str = String(num, radix: 2)
        let binaryString = pad(string: str, toSize: 20)
//        print(binaryString)
        
        frameNumber += 1

        if renderer != nil || !effects.isEmpty {

            
//            var uiImage = UIImage(ciImage: image, scale: 0.25, orientation: .up)
//            image = CIImage(cgImage: uiImage.cgImage!)

            
//            let scaleFilter = CIFilter(name:"CILanczosScaleTransform")!
//            scaleFilter.setValue(image, forKey: kCIInputImageKey)
//            scaleFilter.setValue(0.25, forKey: kCIInputScaleKey)
//            scaleFilter.setValue(1, forKey: kCIInputAspectRatioKey)
//            image = scaleFilter.outputImage!

//            if let whiteOverlay = UIImage(named: "white.PNG") {

//                var whiteOverlayImage = whiteCIImage
            
            
            
            if #available(iOS 13.0, *) {
                let destination = CIRenderDestination(pixelBuffer: buffer)
                
                let totalWidth = destination.width
                let blockWidth = totalWidth / 20
                
                try! context?.startTask(toRender: CIImage.white, from: CGRect(x: 0, y: 0, width: totalWidth, height: 100), to: destination, at: CGPoint(x: 0, y: 0))
            

                for (index, char) in binaryString.enumerated() {
                    if char == "1" {
//                        if let overlayImage = blackCIImageDict["black\(index + 1).PNG"] {
//                            whiteOverlayImage = overlayImage.composited(over: whiteOverlayImage)
//                        }
                        if #available(iOS 13.0, *) {
                            try! context?.startTask(toRender: CIImage.black, from: CGRect(x: 0, y: 0, width: blockWidth, height: 100), to: destination, at: CGPoint(x: index * blockWidth, y: 0))
                        } else {
                            // Fallback on earlier versions
                        }
                    }
                }
                
            } else {
                // Fallback on earlier versions
            }
            
            

//                image = whiteOverlayImage.composited(over: image)
//            }
            
//            scaleFilter.setValue(image, forKey: kCIInputImageKey)
//            scaleFilter.setValue(4, forKey: kCIInputScaleKey)
//            scaleFilter.setValue(1, forKey: kCIInputAspectRatioKey)
//            image = scaleFilter.outputImage!
            
//            uiImage = UIImage(ciImage: image, scale: 4, orientation: .up)
//            image = CIImage(cgImage: uiImage.cgImage!)
            
            extent = image.extent

//            let image: CIImage = effect(buffer, info: sampleBuffer)

            
//            if !effects.isEmpty {
//                #if os(macOS)
//                CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferPool, &imageBuffer)
//                #else
//                if buffer.width != Int(extent.width) || buffer.height != Int(extent.height) {
//                    CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferPool, &imageBuffer)
//                }
//                #endif
//                if let imageBuffer = imageBuffer {
//                    CVPixelBufferLockBaseAddress(imageBuffer, [])
//                }
                context?.render(image, to: buffer)
//            }
            renderer?.enqueue(sampleBuffer)
        }

        encoder.encodeImageBuffer(
            buffer,
            presentationTimeStamp: sampleBuffer.presentationTimeStamp,
            duration: sampleBuffer.duration, absoluteTimestamp: Double(absoluteTime)
        )

//        mixer?.recorder.appendPixelBuffer(buffer, withPresentationTime: sampleBuffer.presentationTimeStamp)
    }
}

extension AVVideoIOUnit {
    func startDecoding() {
        decoder.startRunning()
    }

    func stopDecoding() {
        decoder.stopRunning()
        renderer?.enqueue(nil)
    }
}

extension AVVideoIOUnit: AVCaptureVideoDataOutputSampleBufferDelegate {
    // MARK: AVCaptureVideoDataOutputSampleBufferDelegate
    func captureOutput(_ captureOutput: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        #if os(macOS)
        if connection.isVideoMirrored {
            sampleBuffer.reflectHorizontal()
        }
        #endif
        encodeSampleBuffer(sampleBuffer)
    }
}

extension AVVideoIOUnit: VideoDecoderDelegate {
    // MARK: VideoDecoderDelegate
    func sampleOutput(video sampleBuffer: CMSampleBuffer) {
        renderer?.enqueue(sampleBuffer)
    }
}

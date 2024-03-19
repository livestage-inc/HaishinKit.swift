//
//  LiveStageBusinessLogic.swift
//  LiveStage
//
//  Created by Pawan on 24/03/22.
//

import Foundation
import CoreImage
import CoreMedia
import UIKit

#if os(macOS)
import Accelerate
import CoreFoundation
#endif

public class HighResFrameCapture {
    
    // concurrent queue to drive storing multiple HighResFrames in parallel
    static let writeToStorageConcurrentQueue = DispatchQueue(label: "LiveStageFastStorage_writeToStorageConcurrentQueue", attributes: .concurrent)
    
    // one queue for each HighResFrame to sync read-write of that frame
    let readWriteToStorageSerialQueue: DispatchQueue = {
        let queue = DispatchQueue(label: "LiveStageFastStorage_readWriteToStorageSerialQueue", target: .global(qos: .userInteractive))
        return queue
    }()
    
    static let path = FileManager.default.urls(for: .documentDirectory,
                                               in: .userDomainMask)[0]
    
    let timestamp: Int
    private var internalData: Data?
    
    init(timestamp: Int, data: Data) {
        self.timestamp = timestamp
        self.data = data
    }
    
    deinit {
        internalData = nil
        
        let path = HighResFrameCapture.path.appendingPathComponent("\(timestamp)")
        
        
        do {
            try FileManager.default.removeItem(at: path)
        } catch (let error) {
            print("error deleting frame to disk \(error)")
        }
    }
    
    
    public var data: Data? {
        get {
            readWriteToStorageSerialQueue.sync {
                if let internalData = internalData {
                    return internalData
                }
                else {
                    let path = HighResFrameCapture.path.appendingPathComponent("\(timestamp)")
                    
                    do {
                        let data = try Data(contentsOf: path)
                        return data
                    } catch (let error) {
                        print("error reading frame to disk \(error)")
                        return nil
                    }
                }
            }
        }
        
        set {
            readWriteToStorageSerialQueue.sync {
                
                self.internalData = newValue
  
                // start offloading data to disk
                HighResFrameCapture.writeToStorageConcurrentQueue.async {
                    
                    if let internalData = self.internalData {
                        
                        let path = HighResFrameCapture.path.appendingPathComponent("\(self.timestamp)")
                        do {
                            try internalData.write(to: path)
                            self.internalData = nil
                        } catch (let error) {
                            print("error wrting frame to disk \(error)")
                        }
                    }
                }
                
            }
        }
    }
}

enum UploadState {
    case added, uploading, success, failed
}

class UploadTask {
    
    let timestamp: Double
    var frame: Data?
    
    var state: UploadState = .added {
        didSet {
            if state == .success {
                frame = nil
            }
        }
    }
    
    init?(timestamp: Double, frame: Data?) {
        if let frame = frame {
            self.frame = frame
            self.timestamp = timestamp
        }
        else {
            return nil
        }
    }
}

public class LiveStageFastStorage {
    
    public static let shared = LiveStageFastStorage()
    
//    let id = "dixit"
    
    var highResFrameCaptures = [HighResFrameCapture]()
    let ciContext = CIContext(options: [CIContextOption.highQualityDownsample : false])
    //    let ciContext = CIContext(options: [CIContextOption.useSoftwareRenderer: false])
    
    let rateLimiter = RateLimiter()
//    let liveStageHttp = LiveStageHTTP()
    
    let frameProcessingConcurrentQueue = DispatchQueue(label: "LiveStageFastStorage_frameProcessingQueue", qos: .userInteractive, attributes: .concurrent)
    
    let readWrtieSerialQueue = DispatchQueue(label: "LiveStageFastStorage_readWrtieQueue")
    
    func feedIn(ciImage: CIImage, timestamp: Int) {
        
        rateLimiter.feed {
//            let timestamp: Int = Int(timestamp * 1e+5)
            frameProcessingConcurrentQueue.async {
//                let ciImage = CIImage(cvPixelBuffer: buffer)
                if let cgImage = self.ciContext.createCGImage(ciImage, from: ciImage.extent) {
                    if let data = save_cgimage_to_jpeg(image: cgImage) {
                        self.readWrtieSerialQueue.async {
                            guard (!self.highResFrameCaptures.contains{$0.timestamp == timestamp}) else {return}
                            
                            if let lastOne = self.highResFrameCaptures.last {
                                if lastOne.timestamp > timestamp {
    //                                fatalError()
                                    var index = self.highResFrameCaptures.count - 2
                                    
                                    guard index >= 0 else {return}
                                    
                                    while(index > 0 && self.highResFrameCaptures[index].timestamp > timestamp) {
                                        index -= 1
                                    }
                                    
                                    self.highResFrameCaptures.insert(HighResFrameCapture(timestamp: timestamp, data: data as Data), at: index)
                                }
                            }
                            
                            self.highResFrameCaptures.append(HighResFrameCapture(timestamp: timestamp, data: data as Data))
                            
                            if self.highResFrameCaptures.count > 120 {
                                self.highResFrameCaptures.removeFirst()
                            }
                            
                            //                let imageView = UIImage(data: imageDict[absoluteTime]!)
                            //                print(imageView)
    //                                        print("pawan: recording frame \(timestamp) \(self.highResFrameCaptures.last!.data.count/1024)")
                            
    //                        DispatchQueue.main.async {
    //                            let (theCapture, distance) = self.nearestFrame(at: (timestamp - 5))
    //                            if let data = theCapture?.data {
    ////                                let imageView = UIImage(data: data)
    ////                                print("pawan: nearest \(String(describing: theCapture?.timestamp)) distance \(distance)")
    //                            }
    //                            else {
    ////                                print("pawan: did not find \(distance)")
    //                            }
    //                        }
                            
                        }
                    }
                }
            }
        }
    }
    
    public func nearestFrame(at timestamp: Int) -> (HighResFrameCapture?, Int?, Int?, Int?) {
        
        let index = highResFrameCaptures.binarySearch {
            $0.timestamp < timestamp
        }
        
        guard index >= 0 && index < highResFrameCaptures.count else { return (nil, nil, highResFrameCaptures.first?.timestamp, highResFrameCaptures.last?.timestamp) }
        
        let distance = highResFrameCaptures[index].timestamp - timestamp
        
//        print("pawan: nearestFrame: timestamp \(timestamp), frametime\(highResFrameCaptures[index].timestamp)")
        
//        guard abs(distance) < 10 else { return (nil, distance) }
        
        return readWrtieSerialQueue.sync {
            (highResFrameCaptures[index], (highResFrameCaptures[index].timestamp - timestamp), highResFrameCaptures.first?.timestamp, highResFrameCaptures.last?.timestamp)
        }
    }
    
    init() {
//        monitorRequestsAndUploadRequestedFrame()
//        startSchedulingUploadTasks()
    }
    
    public func emptyStorage() {
        let documentsUrl =  FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!

        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: documentsUrl,
                                                                       includingPropertiesForKeys: nil,
                                                                       options: .skipsHiddenFiles)
            for fileURL in fileURLs {
                try FileManager.default.removeItem(at: fileURL)
            }
        } catch  {
            print("error emptying all frames from disk \(error)")
        }
    }
    
//    func monitorRequestsAndUploadRequestedFrame() {
//        DispatchQueue.main.async {
//            Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
//                self.liveStageHttp.httpQueue.async {
////                    self.checkIncomingRequests()
//                }
//            }
//        }
//    }
    
//    func startSchedulingUploadTasks() {
//        DispatchQueue.main.async {
//            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
//                self.liveStageHttp.httpQueue.async {
//                    self.uploadTasks.filter{$0.state == .added}.forEach {
//                        self.uploadFrame(uploadTask: $0)
//                    }
//                }
//            }
//        }
//    }
    
//    private var uploadTasks = [UploadTask]()
    
    // get checkIncomingRequests - id returns [timestamp]
//    private func checkIncomingRequests() {
//        liveStageHttp.request(method:"GET", endpoint: "checkIncomingRequests", parameters: ["id": id]) { data, error in
//
//            guard let data = data, error == nil else {
//                return
//            }
//
//            DispatchQueue.main.async {
//                let timestampsDict = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String : Any]
//                let timestamps = timestampsDict?["frameIDs"] as? [String]
////                print("pawan: sender: got icoming request \(timestamps)")
//
//                timestamps?.compactMap{Double($0)}.forEach { timestamp in
//
//                    guard !(self.uploadTasks.contains{ $0.timestamp == timestamp}) else {
//
//                        print("Upload task already there")
//                        return
//                    }
//
//                    guard let uploadTask = UploadTask(timestamp: timestamp, frame: self.nearestFrame(at: timestamp).0?.data ?? Data()) else {
//
//                        print("Upload task nil")
//                        return
//                    }
//
//                    self.uploadTasks.append(uploadTask)
//                }
//            }
//        }
//    }
    
//    // post uploadFrame - t, id body: heic-image header: X-Content-Type-Options:image/heic
//    private func uploadFrame(uploadTask: UploadTask) {
//
//        uploadTask.state = .uploading
//
//        liveStageHttp.request(endpoint: "uploadFrame", parameters: ["t": "\(uploadTask.timestamp)", "id" : id], body: uploadTask.frame, contentHeader: ["Content-Type" : "image/heic"]) { data, error in
//            if error != nil {
//                uploadTask.state = .failed
//            }
//            else {
//                uploadTask.state = .success
//            }
//        }
//    }
}

public class LiveStageViewer {
    public static let shared = LiveStageViewer()
    
//    let id = "dixit"
    
    public var currentDrawnTimestamp: Int = 0
    public var currentDrawnImage: CIImage?
//    let liveStageHttp = LiveStageHTTP()
//
//    init() {
//        checkForIncomingFrameAndDownload()
//    }
//
//    func checkForIncomingFrameAndDownload() {
//        DispatchQueue.main.async {
//            Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
//                self.liveStageHttp.httpQueue.async {
//                    self.checkIncomingFrames()
//                }
//            }
//        }
//    }
    
//    public func capture() {
//        requestFrame(timestamp: currentDrawnTimestamp)
//    }
    
//    // 1. post requestFrame - t,id
//    private func requestFrame(timestamp: Double) {
//        liveStageHttp.request(endpoint: "requestFrame", parameters: ["t": "\(timestamp)", "id": id], completion: { data, error in
//            print("pawan: capture with \(timestamp) \(error)")
//        })
//    }
    
//    // 2. get checkIncomingFrames - id
//    private func checkIncomingFrames() {
//        liveStageHttp.request(method: "GET", endpoint: "checkIncomingFrames", parameters: ["id": id]) {data, error in
//
//            guard let data = data, error == nil else {
//                return
//            }
//
//            DispatchQueue.main.async {
//                print("pawan: viewer: Got incoming frame")
//
//                let timestampsDict = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String : Any]
//                let timestamps = timestampsDict?["frameIDs"] as? [String]
//                print("pawan: sender: got icoming request \(timestamps)")
//
//                timestamps?.compactMap{Double($0)}.forEach { timestamp in
//                    self.liveStageHttp.httpQueue.async {
//                        self.getFrame(timestamp: timestamp)
//                    }
//                }
//            }
//        }
//    }
    
    
//    // get getFrame - t, id
//    private func getFrame(timestamp: Double) {
//        liveStageHttp.request(method: "GET", endpoint: "getFrame", parameters: ["t": "\(timestamp)", "id": id]) { data, error in
//
//            guard let data = data, error == nil else {
//                return
//            }
//
//            DispatchQueue.main.async {
//                print("pawan: viewer: Got frame")
//
//                if let inputImage = UIImage(data: data) {
//                    print("pawan: viewer: saved frame")
//                    UIImageWriteToSavedPhotosAlbum(inputImage, nil, nil, nil)
//                }
//            }
//        }
//    }
    
}

//class LiveStageHTTP {
//    
//    let httpQueue = DispatchQueue(label: "LiveStageFastStorage_HttpQueue")
//    
//    enum LiveStageHTTPError: Error {
//        case malformedUrl
//        case badResponse(String)
//    }
//    
////    func getRequest(endpoint: String, parameters: [String: String], completion: @escaping (Data?, Error?)->Void) {
////
////        guard let url = URL(string: "https://livestagepocserver.herokuapp.com/api/\(endpoint)") else {
////            completion(nil, LiveStageHTTPError.malformedUrl)
////            return
////        }
////
////        var urlComponents = URLComponents(string: url.absoluteString)
////
////        let queryItems = parameters.map  { URLQueryItem(name: $0.key, value: $0.value) }
////        urlComponents?.queryItems = queryItems
////
////        if let url = urlComponents?.url?.absoluteURL {
////            let task = URLSession.shared.dataTask(with: url) { data, response, error in
////                guard let data = data,
////                    let response = response as? HTTPURLResponse,
////                    error == nil else {                                              // check for fundamental networking error
////                    print("error", error ?? "Unknown error")
////                    return
////                }
////
////                guard (200 ... 299) ~= response.statusCode else {                    // check for http errors
////                    print("statusCode should be 2xx, but is \(response.statusCode)")
////                    print("response = \(response)")
////                    return
////                }
////
////                let responseString = String(data: data, encoding: .utf8)
////                let image = UIImage(data: data)
////                print("responseString = \(responseString)")
////                success(data)
////            }
////
////            task.resume()
////        }
////        else {
////            completion(nil, LiveStageHTTPError.malformedUrl)
////        }
////    }
//    
////    func request(method: String? = "POST", endpoint: String, parameters: [String: String], body: Data? = nil, contentHeader: [String: String]? = nil, completion: @escaping (Data?, Error?)->Void) {
////
////        guard let url = URL(string: "https://livestagepocserver.herokuapp.com/api/\(endpoint)") else {
////            completion(nil, LiveStageHTTPError.malformedUrl)
////            return
////        }
////
////        var urlComponents = URLComponents(string: url.absoluteString)
////
////        let queryItems = parameters.map  { URLQueryItem(name: $0.key, value: $0.value) }
////        urlComponents?.queryItems = queryItems
////
////        if let url = urlComponents?.url?.absoluteURL {
////
////            var request = URLRequest(url: url)
////
////            if method == "POST" {
////
////                if let contentHeader = contentHeader?.first {
////                    request.setValue(contentHeader.value, forHTTPHeaderField: contentHeader.key)
////                }
////
////                request.httpMethod = "POST"
////
////                if let body = body {
////                    request.httpBody = body
////                }
////            }
////
//////            else {
//////                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
//////            }
////            let task = URLSession.shared.dataTask(with: request) { data, response, error in
////                guard let data = data,
////                    let response = response as? HTTPURLResponse,
////                    error == nil else {                                              // check for fundamental networking error
////                    print("error", error ?? "Unknown error")
////                    completion(nil, error)
////                    return
////                }
////
////                guard (200 ... 299) ~= response.statusCode else {                    // check for http errors
////                    print("statusCode should be 2xx, but is \(response.statusCode)")
////                    print("response = \(response)")
////                    completion(nil, LiveStageHTTPError.badResponse("statusCode should be 2xx, but is \(response.statusCode)"))
////                    return
////                }
////
////                let responseString = String(data: data, encoding: .utf8)
//////                print("responseString = \(responseString)")
////                completion(data, nil)
////            }
////            task.resume()
////        }
////        else {
////            completion(nil, LiveStageHTTPError.malformedUrl)
////        }
////    }
//}

class RateLimiter {
    
    private let syncQueue = DispatchQueue(label: "com.samsoffes.ratelimit", attributes: [])
    public let limit: TimeInterval = 0.5
    public private(set) var lastExecutedAt: Date?
    
    func feed(block: ()->Void) {
        let now = Date()
        let timeInterval = now.timeIntervalSince(lastExecutedAt ?? .distantPast)
        
        if timeInterval > limit {
            lastExecutedAt = now
            
            block()
        }
    }
}

extension RandomAccessCollection {

    func binarySearch(predicate: (Iterator.Element) -> Bool) -> Index {
        var low = startIndex
        var high = endIndex
        while low != high {
            let mid = index(low, offsetBy: distance(from: low, to: high)/2)
            if predicate(self[mid]) {
                low = index(after: mid)
            } else {
                high = mid
            }
        }
        return low
    }
}

func save_cgimage_to_jpeg (image: CGImage) -> CFData?
{
    let data = CFDataCreateMutable(nil,0);
    if let dest = CGImageDestinationCreateWithData(data!, "public.jpeg" as CFString, 1, [:] as CFDictionary) {
        CGImageDestinationSetProperties(dest, [kCGImageDestinationLossyCompressionQuality:0.9] as CFDictionary)
        
        CGImageDestinationAddImage (dest, image, [:] as CFDictionary);
        
        if(!CGImageDestinationFinalize(dest)) {
    //        ; // error
            print("error")
            return nil
        }
        return data
    } //(data, , 1, NULL);
    
    return nil
        
//    CFRelease(dest);
}

func toByteArray<T>(_ value: T) -> [UInt8] {
    var value = value
    return withUnsafeBytes(of: &value) { Array($0) }
}

func fromByteArray<T>(_ value: [UInt8], _: T.Type) -> T {
    return value.withUnsafeBytes {
        $0.baseAddress!.load(as: T.self)
    }
}

extension CMSampleBuffer {
    @inline(__always)
    func getAttachmentValue(for key: CFString) -> String? {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(self, createIfNecessary: false) as? [[CFString: Any]],
            let value = attachments.first?[key] as? String else {
            return nil
        }
        return value
    }

    @inline(__always)
    func setAttachmentValue(for key: CFString, value: Double) {
        guard
            let attachments: CFArray = CMSampleBufferGetSampleAttachmentsArray(self, createIfNecessary: true), 0 < CFArrayGetCount(attachments) else {
            return
        }
        let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(
            attachment,
            Unmanaged.passUnretained(key).toOpaque(),
            Unmanaged.passRetained("\(value)" as NSString).toOpaque()
    //            Unmanaged.passUnretained(value).toOpaque()
        )
    }
}

extension Dictionary {
    func percentEncoded() -> Data? {
        return map { key, value in
            let escapedKey = "\(key)".addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? ""
            let escapedValue = "\(value)".addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? ""
            return escapedKey + "=" + escapedValue
        }
        .joined(separator: "&")
        .data(using: .utf8)
    }
}

extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        let generalDelimitersToEncode = ":#[]@" // does not include "?" or "/" due to RFC 3986 - Section 3.4
        let subDelimitersToEncode = "!$&'()*+,;="

        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "\(generalDelimitersToEncode)\(subDelimitersToEncode)")
        return allowed
    }()
}

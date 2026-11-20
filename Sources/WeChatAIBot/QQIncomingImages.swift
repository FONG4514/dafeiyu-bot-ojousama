import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(ImageIO)
import ImageIO
#endif
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

struct QQIncomingImages {
    private static let ephemeralSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()
    var session: URLSession = ephemeralSession
    static func allowedURL(_ value: String?) -> URL? {
        guard let value, value.utf8.count <= 8192, var url = URLComponents(string: value),
              ["http", "https"].contains(url.scheme ?? ""), url.user == nil, url.password == nil, url.port == nil,
              let host = url.host?.lowercased(), Self.allowedHost(host) else { return nil }
        url.scheme = "https"; url.fragment = nil
        return url.url
    }
    private static func allowedHost(_ host: String) -> Bool {
        if host == "multimedia.nt.qq.com.cn" { return true }
        return ["qpic.cn", "qlogo.cn", "qq.com", "qq.com.cn"].contains { host == $0 || host.hasSuffix("." + $0) }
    }
    func load(_ value: String?, maxFrames: Int = 6) async throws -> [Data] {
        guard let url = Self.allowedURL(value) else { throw AppFailure.message("图片下载地址不受支持") }
        var request = URLRequest(url: url); request.timeoutInterval = 15
        #if os(Linux) || os(Windows)
        let (linuxData, response) = try await session.boundedData(for: request, limit: 8_000_000) { QQIncomingImages.allowedURL($0.absoluteString) != nil }
        #else
        let (bytes, response) = try await session.bytes(for: request, delegate: QQImageRedirect())
        #endif
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, response.expectedContentLength <= 8_000_000 else { throw AppFailure.message("图片暂时无法下载") }
        var data = Data()
        #if os(Linux) || os(Windows)
        data = linuxData
        #else
        for try await byte in bytes {
            guard data.count < 8_000_000 else { throw AppFailure.message("图片太大，未进行识别") }
            data.append(byte)
        }
        #endif
        try Task.checkCancellation()
        return try Self.usableFrames(data, maxFrames: maxFrames)
    }
    /// Pillow can sample animation. A still JPEG, PNG, GIF, or WebP can go to the model without it.
    static func usableFrames(_ data: Data, maxFrames: Int = 6) throws -> [Data] {
        if let frames = try? frames(data, maxFrames: maxFrames), !frames.isEmpty { return frames }
        guard let original = originalImage(data) else { throw AppFailure.message("图片格式或尺寸不受支持") }
        return [original]
    }
    static func originalImage(_ data: Data) -> Data? {
        guard data.count <= 8_000_000 else { return nil }
        let header = [UInt8](data.prefix(12))
        let png = header.count >= 8 && Array(header[0..<8]) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let gif = header.count >= 6 && (Array(header[0..<6]) == Array("GIF87a".utf8) || Array(header[0..<6]) == Array("GIF89a".utf8))
        let webp = header.count >= 12 && Array(header[0..<4]) == Array("RIFF".utf8) && Array(header[8..<12]) == Array("WEBP".utf8)
        let jpeg = header.count >= 3 && header[0] == 0xFF && header[1] == 0xD8 && header[2] == 0xFF
        return png || gif || webp || jpeg ? data : nil
    }
    static func frames(_ data: Data, maxFrames: Int = 6) throws -> [Data] {
        #if os(Linux) || os(Windows)
        return try LinuxImages.process(data, mode: "frames", options: ["maxFrames": maxFrames])
        #else
        guard data.count <= 8_000_000, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...12000).contains(width), (1...12000).contains(height), width * height <= 40_000_000 else { throw AppFailure.message("图片格式或尺寸不受支持") }
        let count = CGImageSourceGetCount(source)
        guard count > 0 && count <= 1000 else { throw AppFailure.message("动图帧数不受支持") }
        // Sample across playback time, not only frame number; GIF delays can vary greatly.
        let budget = min(count, max(1, min(6, maxFrames)))
        var elapsed = 0.0, ends: [Double] = []
        for index in 0..<count {
            let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            elapsed += delay.isFinite ? min(10, max(0.02, delay)) : 0.1; ends.append(elapsed)
        }
        var selected = Set([0])
        if budget > 1 {
            selected.insert(count - 1)
            for step in 1..<(budget - 1) {
                let time = elapsed * Double(step) / Double(budget - 1)
                selected.insert(ends.firstIndex(where: { $0 >= time }) ?? count - 1)
            }
            // Long holds may collapse samples; fill remaining slots with evenly spaced frames.
            for step in 0..<budget where selected.count < budget { selected.insert(step * (count - 1) / (budget - 1)) }
        }
        let indexes = selected.sorted()
        var frames: [Data] = []
        for index in indexes {
            try Task.checkCancellation()
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1280, kCGImageSourceCreateThumbnailWithTransform: true]
            guard let frame = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { continue }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, frame, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
            if CGImageDestinationFinalize(destination), output.length <= 2_000_000 { frames.append(output as Data) }
        }
        guard !frames.isEmpty else { throw AppFailure.message("图片解码失败") }
        return frames
        #endif
    }
}
private final class QQImageRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, QQIncomingImages.allowedURL(url.absoluteString) != nil else { completionHandler(nil); return }
        completionHandler(request)
    }
}

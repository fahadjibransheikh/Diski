import AppKit
import QuickLookThumbnailing

/// Quick Look thumbnails for images, movies, PDFs and documents.
/// Requests are de-duplicated, cached per (path, modification date, size bucket)
/// and can be cancelled when a cell scrolls away.
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, NSImage>()
    private var requests: [String: QLThumbnailGenerator.Request] = [:]
    private var waiting: [String: [String: (NSImage?) -> Void]] = [:]
    private var subscriptions: [String: String] = [:]
    /// Keys that produced no thumbnail, so they are not asked for again.
    private let failed = NSCache<NSString, NSNumber>()
    private let decodeQueue = DispatchQueue(label: "app.diski.thumbnail-decode", qos: .userInitiated, attributes: .concurrent)

    private init() {
        cache.totalCostLimit = 256 * 1024 * 1024
        failed.countLimit = 4000
    }

    static func bucket(for points: CGFloat) -> Int {
        let sizes = [16, 32, 64, 128, 256, 512, 1024]
        let target = Int(points.rounded(.up))
        return sizes.first { $0 >= target } ?? 1024
    }

    /// Everything but the bucket (the modification date's bits: no Double formatting).
    private func baseKey(for item: FileItem) -> String {
        "\(item.path)|\(item.modified.bitPattern)|\(item.size)|"
    }

    /// Icon-mode thumbnails (Quick Look's own decoration) are cached apart from plain ones.
    private func key(for item: FileItem, bucket: Int, iconMode: Bool) -> String {
        baseKey(for: item) + String(bucket) + (iconMode ? "|icon" : "")
    }

    func cached(for item: FileItem, points: CGFloat, iconMode: Bool = false) -> NSImage? {
        let b = Self.bucket(for: points), base = baseKey(for: item), suffix = iconMode ? "|icon" : ""
        if let image = cache.object(forKey: (base + String(b) + suffix) as NSString) { return image }
        // The next size up scales down cleanly; much larger images alias when a layer shrinks them.
        for larger in [32, 64, 128, 256, 512, 1024] where larger > b && larger <= b * 2 {
            if let image = cache.object(forKey: (base + String(larger) + suffix) as NSString) { return image }
        }
        return nil
    }

    /// Requests a thumbnail. Returns a token for `cancel(_:)`. `completion` runs on the main thread.
    /// `iconMode` asks for Finder's decorated style (rounded, inset and softly shadowed;
    /// music tiles for audio), as its list, column and icon views show thumbnails.
    @discardableResult
    func request(for item: FileItem, points: CGFloat, scale: CGFloat, iconMode: Bool = false,
                 completion: @escaping (NSImage?) -> Void) -> String? {
        let b = Self.bucket(for: points)
        let k = key(for: item, bucket: b, iconMode: iconMode)
        if let image = cache.object(forKey: k as NSString) {
            completion(image)
            return nil
        }
        if failed.object(forKey: k as NSString) != nil {
            completion(nil)
            return nil
        }
        let token = UUID().uuidString
        subscriptions[token] = k
        if waiting[k] != nil {
            waiting[k]?[token] = completion
            return token
        }
        waiting[k] = [token: completion]
        let request = QLThumbnailGenerator.Request(fileAt: item.url,
                                                   size: CGSize(width: b, height: b),
                                                   scale: max(scale, 1),
                                                   representationTypes: .thumbnail)
        request.iconMode = iconMode
        requests[k] = request
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            self?.decodeQueue.async {
                let image = representation.map { Self.decodedImage($0.cgImage, size: $0.nsImage.size) }
                DispatchQueue.main.async {
                    guard let self else { return }
                    // A cancelled (or superseded) request still calls back; ignore its failure.
                    let isCurrent = self.requests[k] === request
                    if isCurrent { self.requests.removeValue(forKey: k) }
                    if let image {
                        let pixels = Int(image.size.width * image.size.height * 4 * scale * scale)
                        self.cache.setObject(image, forKey: k as NSString, cost: pixels)
                    } else if isCurrent {
                        self.failed.setObject(NSNumber(value: true), forKey: k as NSString)
                    }
                    guard isCurrent else { return }
                    let callbacks = self.waiting.removeValue(forKey: k) ?? [:]
                    for (token, callback) in callbacks {
                        self.subscriptions.removeValue(forKey: token)
                        callback(image)
                    }
                }
            }
        }
        return token
    }

    private static func decodedImage(_ source: CGImage, size: NSSize) -> NSImage {
        // Keeps the thumbnail's own colour space (Display P3 photos stay P3).
        let space = source.colorSpace.flatMap { $0.model == .rgb && $0.supportsOutput ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: source.width, height: source.height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return NSImage(cgImage: source, size: size)
        }
        context.draw(source, in: CGRect(x: 0, y: 0, width: CGFloat(source.width), height: CGFloat(source.height)))
        return NSImage(cgImage: context.makeImage() ?? source, size: size)
    }

    func cancel(_ token: String?) {
        guard let token, let key = subscriptions.removeValue(forKey: token) else { return }
        waiting[key]?.removeValue(forKey: token)
        guard waiting[key]?.isEmpty == true else { return }
        waiting.removeValue(forKey: key)
        if let request = requests.removeValue(forKey: key) {
            QLThumbnailGenerator.shared.cancel(request)
        }
    }
}

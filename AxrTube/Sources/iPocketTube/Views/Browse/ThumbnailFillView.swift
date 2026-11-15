import SwiftUI

// MARK: - ThumbnailFillView
//
// Fills its frame with a remote thumbnail (scaledToFill + clipped), trying
// `fallbackURLs` in order when a URL fails. On UIKit platforms images come
// from `RemoteImageLoader`: a shared in-memory + disk cache whose downloads
// survive a cell scrolling away, so a card never sticks on a spinner.

#if canImport(UIKit)
import UIKit

struct ThumbnailFillView: View {
    let primaryURL: URL?
    var fallbackURLs: [URL] = []

    var body: some View {
        GeometryReader { geo in
            CachedRemoteImage(urls: [primaryURL].compactMap { $0 } + fallbackURLs) { image in
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            } placeholder: {
                Color.secondary.opacity(0.15)
            }
        }
    }
}

/// Remote image view backed by `RemoteImageLoader`. Shows the placeholder
/// (no spinner, like YouTube) until the first URL in `urls` that loads.
struct CachedRemoteImage<Content: View, Placeholder: View>: View {
    let urls: [URL]
    @ViewBuilder let content: (UIImage) -> Content
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var image: UIImage?
    @State private var loadedKey: [URL] = []

    init(
        urls: [URL],
        @ViewBuilder content: @escaping (UIImage) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.urls = urls
        self.content = content
        self.placeholder = placeholder
    }

    init(
        url: URL?,
        @ViewBuilder content: @escaping (UIImage) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.init(urls: [url].compactMap { $0 }, content: content, placeholder: placeholder)
    }

    var body: some View {
        ZStack {
            if let shown = image ?? urls.lazy.compactMap(RemoteImageLoader.shared.cached).first {
                content(shown)
            } else {
                placeholder()
            }
        }
        .task(id: urls) {
            if loadedKey != urls {
                loadedKey = urls
                image = urls.lazy.compactMap(RemoteImageLoader.shared.cached).first
            }
            guard image == nil else { return }
            for url in urls {
                if let loaded = await RemoteImageLoader.shared.image(for: url) {
                    image = loaded
                    return
                }
                if Task.isCancelled { return }
            }
        }
    }
}

/// Shared image downloader: memory cache, disk URL cache, one download per
/// URL, a few retries. A download started for a cell keeps running when the
/// cell disappears, so the next appearance gets the finished image.
final class RemoteImageLoader: @unchecked Sendable {
    static let shared = RemoteImageLoader()

    private let memory = NSCache<NSURL, UIImage>()
    private let lock = NSLock()
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]
    private var failedAt: [URL: Date] = [:]
    private let session: URLSession

    private init() {
        memory.totalCostLimit = 80 * 1024 * 1024
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024, diskCapacity: 300 * 1024 * 1024)
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.timeoutIntervalForRequest = 15
        config.httpMaximumConnectionsPerHost = 8
        session = URLSession(configuration: config)
    }

    func cached(_ url: URL) -> UIImage? {
        memory.object(forKey: url as NSURL)
    }

    func image(for url: URL) async -> UIImage? {
        if let hit = cached(url) { return hit }
        let task: Task<UIImage?, Never> = lock.withLock {
            // A URL that just failed (e.g. a 404 maxres thumbnail) is skipped
            // for a minute so fallbacks are tried immediately.
            if let failed = failedAt[url], Date().timeIntervalSince(failed) < 60 {
                return Task { nil }
            }
            if let running = inFlight[url] { return running }
            let created = Task { [weak self] () -> UIImage? in
                guard let self else { return nil }
                let image = await self.download(url)
                self.finish(url, image: image)
                return image
            }
            inFlight[url] = created
            return created
        }
        return await task.value
    }

    private func finish(_ url: URL, image: UIImage?) {
        lock.withLock {
            inFlight[url] = nil
            if image == nil { failedAt[url] = Date() } else { failedAt[url] = nil }
        }
        if let image {
            let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
            memory.setObject(image, forKey: url as NSURL, cost: cost)
        }
    }

    private func download(_ url: URL) async -> UIImage? {
        for attempt in 0..<3 {
            do {
                let (data, response) = try await session.data(from: url)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                // 404/410 are final (missing size variant); retry only transient errors.
                if status == 404 || status == 410 { return nil }
                if (200..<300).contains(status), let image = UIImage(data: data) {
                    return await image.byPreparingForDisplay() ?? image
                }
            } catch {
                if (error as? URLError)?.code == .cancelled { return nil }
            }
            try? await Task.sleep(for: .milliseconds(400 * (attempt + 1)))
        }
        return nil
    }
}

#else

struct ThumbnailFillView: View {
    let primaryURL: URL?
    var fallbackURLs: [URL] = []

    @State private var fallbackIndex: Int = -1

    private var activeURL: URL? {
        if fallbackIndex < 0 { return primaryURL }
        guard fallbackIndex < fallbackURLs.count else { return nil }
        return fallbackURLs[fallbackIndex]
    }

    var body: some View {
        GeometryReader { geo in
            AsyncImage(url: activeURL) { phase in
                switch phase {
                case .success(let img):
                    img.resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                case .failure:
                    let next = fallbackIndex < 0 ? 0 : fallbackIndex + 1
                    Color.secondary.opacity(0.15)
                        .onAppear {
                            if next < fallbackURLs.count { fallbackIndex = next }
                        }
                default:
                    Color.secondary.opacity(0.15)
                }
            }
        }
        .task(id: primaryURL) { fallbackIndex = -1 }
    }
}

#endif

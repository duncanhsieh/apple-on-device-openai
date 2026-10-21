import CoreGraphics
import Foundation
import ImageIO
import Vapor

/// Loads images referenced by OpenAI `image_url` content parts and chat attachments.
///
/// Supports `data:image/...;base64,...` URLs and http(s) URLs. Other schemes
/// (including `file://`) are rejected so remote clients can't read local files.
nonisolated enum ImageLoader {
    static let maxImageBytes = 20 * 1024 * 1024

    static func loadImage(from urlString: String) async throws -> CGImage {
        try decodeImage(try await loadData(from: urlString))
    }

    /// User-facing text for a loading error (the reason of an `Abort`, not its HTTP wrapper)
    static func message(for error: any Error) -> String {
        (error as? any AbortError)?.reason ?? error.localizedDescription
    }

    static func decodeImage(_ data: Data) throws -> CGImage {
        guard data.count <= maxImageBytes else {
            throw Abort(
                .badRequest, reason: "Image exceeds the \(maxImageBytes / 1024 / 1024) MB limit")
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw Abort(.badRequest, reason: "Unsupported or corrupt image data")
        }
        return image
    }

    private static func loadData(from urlString: String) async throws -> Data {
        if urlString.hasPrefix("data:") {
            // data:[<mediatype>][;base64],<payload>
            guard let comma = urlString.firstIndex(of: ","),
                urlString[..<comma].hasSuffix(";base64"),
                let data = Data(
                    base64Encoded: String(urlString[urlString.index(after: comma)...]),
                    options: .ignoreUnknownCharacters)
            else {
                throw Abort(.badRequest, reason: "Image data URLs must be base64 encoded")
            }
            return data
        }

        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else {
            throw Abort(.badRequest, reason: "Image URLs must be data, http or https URLs")
        }

        let request = URLRequest(url: url, timeoutInterval: 30)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Abort(
                .badRequest, reason: "Failed to download image: \(error.localizedDescription)")
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Abort(.badRequest, reason: "Failed to download image: HTTP \(http.statusCode)")
        }
        return data
    }
}

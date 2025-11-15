import Foundation
import UniformTypeIdentifiers
import GhosttyKit
import os

extension Ghostty {
    /// Helper class for handling image upload functionality on macOS
    class ImageUpload {
        private static let logger = Logger(
            subsystem: Bundle.main.bundleIdentifier!,
            category: "image-upload"
        )
        /// Check if a file is an image based on its URL
        static func isImageFile(_ url: URL) -> Bool {
            // Get the file type identifier
            guard let typeId = try? url.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier,
                  let type = UTType(typeId) else {
                return false
            }
            
            // Check if it conforms to image type
            return type.conforms(to: .image)
        }
        
        /// Upload an image file and return the uploaded URL string
        /// Returns nil if upload is not enabled, fails, or should fall back to local path
        static func uploadImage(filePath: String, config: ghostty_config_t) async -> String? {
            // Check if image upload is enabled
            var enabled = false
            let enableKey = "image-upload-enable"
            guard ghostty_config_get(config, &enabled, enableKey, UInt(enableKey.count)),
                  enabled else {
                return nil
            }
            
            // Check if upload URL is configured
            var urlPtr: UnsafePointer<Int8>? = nil
            let urlKey = "image-upload-url"
            guard ghostty_config_get(config, &urlPtr, urlKey, UInt(urlKey.count)),
                  let urlCStr = urlPtr else {
                return nil
            }
            
            let uploadURL = String(cString: urlCStr)
            guard let url = URL(string: uploadURL) else {
                Self.logger.error("Invalid image-upload-url: \(uploadURL)")
                return nil
            }
            
            // Read file contents
            guard let fileData = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else {
                Self.logger.error("Failed to read image file: \(filePath)")
                return nil
            }
            
            // Check file size limit
            var maxSize: UInt32 = 10
            let maxSizeKey = "image-upload-max-size"
            _ = ghostty_config_get(config, &maxSize, maxSizeKey, UInt(maxSizeKey.count))
            
            let maxBytes = UInt64(maxSize) * 1024 * 1024
            if UInt64(fileData.count) > maxBytes {
                Self.logger.warning("Image file exceeds max size (\(maxSize)MB): \(filePath)")
                return nil
            }
            
            // Get upload format
            var formatPtr: UnsafePointer<Int8>? = nil
            let formatKey = "image-upload-format"
            _ = ghostty_config_get(config, &formatPtr, formatKey, UInt(formatKey.count))
            let format = formatPtr.map { String(cString: $0) } ?? "multipart"
            
            // Get field name
            var fieldPtr: UnsafePointer<Int8>? = nil
            let fieldKey = "image-upload-field"
            _ = ghostty_config_get(config, &fieldPtr, fieldKey, UInt(fieldKey.count))
            let fieldName = fieldPtr.map { String(cString: $0) } ?? "image"
            
            // Get timeout
            var timeout: UInt32 = 30
            let timeoutKey = "image-upload-timeout"
            _ = ghostty_config_get(config, &timeout, timeoutKey, UInt(timeoutKey.count))
            
            // Perform the upload
            do {
                let responseBody = try await performUpload(
                    url: url,
                    fileData: fileData,
                    fileName: URL(fileURLWithPath: filePath).lastPathComponent,
                    format: format,
                    fieldName: fieldName,
                    timeout: TimeInterval(timeout),
                    config: config
                )
                
                // Parse response to extract URL
                return try extractURL(from: responseBody, config: config)
            } catch {
                Self.logger.error("Image upload failed: \(error)")
                return nil
            }
        }
        
        private static func performUpload(
            url: URL,
            fileData: Data,
            fileName: String,
            format: String,
            fieldName: String,
            timeout: TimeInterval,
            config: ghostty_config_t
        ) async throws -> Data {
            var request = URLRequest(url: url, timeoutInterval: timeout)
            request.httpMethod = "POST"
            
            // Note: custom headers from config.@"image-upload-header" are not yet implemented
            // for macOS. This requires exposing the repeatable string list API through ghostty.h
            
            // Build request body based on format
            switch format {
            case "multipart":
                let boundary = "----GhosttyImageUploadBoundary"
                request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
                
                var body = Data()
                body.append("--\(boundary)\r\n".data(using: .utf8)!)
                body.append("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
                body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
                body.append(fileData)
                body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
                request.httpBody = body
                
            case "json":
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                let base64 = fileData.base64EncodedString()
                let jsonObj = [fieldName: base64]
                request.httpBody = try JSONSerialization.data(withJSONObject: jsonObj)
                
            case "binary":
                request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                request.httpBody = fileData
                
            default:
                throw NSError(domain: "ImageUpload", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported upload format: \(format)"])
            }
            
            // Perform request
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                throw NSError(domain: "ImageUpload", code: 2, userInfo: [NSLocalizedDescriptionKey: "HTTP request failed"])
            }
            
            return data
        }
        
        private static func extractURL(from data: Data, config: ghostty_config_t) throws -> String {
            // Get response path configuration
            var pathPtr: UnsafePointer<Int8>? = nil
            let pathKey = "image-upload-response-path"
            _ = ghostty_config_get(config, &pathPtr, pathKey, UInt(pathKey.count))
            let responsePath = pathPtr.map { String(cString: $0) } ?? "json:$.data.link"
            
            if responsePath.hasPrefix("json:") {
                let jsonPath = String(responsePath.dropFirst(5))
                return try extractURLFromJSON(data: data, path: jsonPath)
            } else if responsePath.hasPrefix("regex:") {
                let pattern = String(responsePath.dropFirst(6))
                return try extractURLFromRegex(data: data, pattern: pattern)
            } else {
                throw NSError(domain: "ImageUpload", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid response path format"])
            }
        }
        
        private static func extractURLFromJSON(data: Data, path: String) throws -> String {
            let json = try JSONSerialization.jsonObject(with: data)
            
            // Parse JSONPath (simplified implementation supporting $.key.subkey format)
            let components = path.split(separator: ".").map { String($0) }
            var current: Any = json
            
            for component in components {
                if component == "$" { continue }
                
                if let dict = current as? [String: Any] {
                    guard let value = dict[component] else {
                        throw NSError(domain: "ImageUpload", code: 4, userInfo: [NSLocalizedDescriptionKey: "JSON path not found: \(component)"])
                    }
                    current = value
                } else if let array = current as? [Any],
                          let index = Int(component),
                          index < array.count {
                    current = array[index]
                } else {
                    throw NSError(domain: "ImageUpload", code: 5, userInfo: [NSLocalizedDescriptionKey: "Cannot traverse JSON path at: \(component)"])
                }
            }
            
            guard let urlString = current as? String else {
                throw NSError(domain: "ImageUpload", code: 6, userInfo: [NSLocalizedDescriptionKey: "Final value is not a string"])
            }
            
            return urlString
        }
        
        private static func extractURLFromRegex(data: Data, pattern: String) throws -> String {
            guard let responseString = String(data: data, encoding: .utf8) else {
                throw NSError(domain: "ImageUpload", code: 7, userInfo: [NSLocalizedDescriptionKey: "Invalid response encoding"])
            }
            
            // Support common URL regex patterns
            let urlPattern: String
            if pattern == "https?://[^\\s\"]+" || pattern == "http://.*" || pattern == "https://.*" {
                // Find first URL-like string
                let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
                let matches = detector.matches(in: responseString, range: NSRange(responseString.startIndex..., in: responseString))
                
                if let match = matches.first {
                    if let range = Range(match.range, in: responseString) {
                        let urlStr = String(responseString[range])
                        if urlStr.hasPrefix("http://") || urlStr.hasPrefix("https://") {
                            return urlStr
                        }
                    }
                }
                
                throw NSError(domain: "ImageUpload", code: 8, userInfo: [NSLocalizedDescriptionKey: "No URL found in response"])
            } else {
                // Try custom regex
                let regex = try NSRegularExpression(pattern: pattern)
                if let match = regex.firstMatch(in: responseString, range: NSRange(responseString.startIndex..., in: responseString)),
                   let range = Range(match.range, in: responseString) {
                    return String(responseString[range])
                }
                
                throw NSError(domain: "ImageUpload", code: 9, userInfo: [NSLocalizedDescriptionKey: "Regex pattern did not match"])
            }
        }
    }
}

import Foundation
import ImageIO
import CryptoKit

// Build-time gate, not a runtime fallback: a partial library must never ship.
struct Catalog: Decodable {
    struct Asset: Decodable { let id: String }
    let assets: [Asset]
}

struct InvalidLibrary: Error, CustomStringConvertible {
    let description: String
}

func validate(_ root: URL, bundle: URL?) throws {
    let data = try Data(contentsOf: root.appendingPathComponent("catalog.json"))
    let manifestURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("food-art-sha256.json")
    let hashes = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: manifestURL))
    try checkHash(data, name: "catalog.json", hashes: hashes)
    if let bundle {
        try checkHash(Data(contentsOf: bundle.appendingPathComponent("catalog.json")),
                      name: "catalog.json", hashes: hashes)
    }
    let assets = try JSONDecoder().decode(Catalog.self, from: data).assets
    guard !assets.isEmpty, Set(assets.map(\.id)).count == assets.count else {
        throw InvalidLibrary(description: "catalog must contain nonempty, unique identities")
    }
    for asset in assets {
        guard !asset.id.isEmpty, asset.id.range(of: "^[a-z0-9]+(?:-[a-z0-9]+)*$",
                                              options: .regularExpression) != nil else {
            throw InvalidLibrary(description: "invalid identity: \(asset.id)")
        }
        for theme in ["paper", "night"] {
            let name = "\(asset.id)-\(theme)-64.png"
            let bytes = try read(root.appendingPathComponent(name))
            // ImageIO can accept a truncated PNG header. Pin the approved bytes
            // as well as decoding; never let a partially readable file ship.
            try checkHash(bytes, name: name, hashes: hashes)
            let original = try pixels(bytes, name: name)
            if let bundle {
                let bundled = try read(bundle.appendingPathComponent(name))
                guard try pixels(bundled, name: name) == original else {
                    throw InvalidLibrary(description: "\(name): bundled pixels differ from approved source")
                }
            }
        }
    }
    print("FoodArt completeness: \(assets.count) identities / \(assets.count * 2) readable 64px PNGs (Paper + Night)")
}

func read(_ url: URL) throws -> Data {
    do { return try Data(contentsOf: url) } catch {
        throw InvalidLibrary(description: "\(url.lastPathComponent): \(error)")
    }
}

// Xcode losslessly repackages PNGs as CgBI: compare decoded pixels, not its bytes.
func pixels(_ bytes: Data, name: String) throws -> Data {
    guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
          CGImageSourceGetCount(source) == 1,
          let image = CGImageSourceCreateImageAtIndex(
            source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
          ), image.width == 64, image.height == 64,
          CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
          let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let buffer = context.data else {
        throw InvalidLibrary(description: "\(name): unreadable or not a complete 64px image")
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64))
    return Data(bytes: buffer, count: 64 * 64 * 4)
}

func checkHash(_ bytes: Data, name: String, hashes: [String: String]) throws {
    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    guard hashes[name] == digest else {
        throw InvalidLibrary(description: "\(name): bytes differ from the frozen approved library")
    }
}

do {
    guard (2...3).contains(CommandLine.arguments.count) else {
        throw InvalidLibrary(description: "usage: swift validate-food-art.swift <FoodArt directory> [built bundle]")
    }
    let bundle = CommandLine.arguments.count == 3 ? URL(fileURLWithPath: CommandLine.arguments[2]) : nil
    try validate(URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true), bundle: bundle)
} catch {
    FileHandle.standardError.write(Data("error: FoodArt completeness: \(error)\n".utf8))
    exit(1)
}

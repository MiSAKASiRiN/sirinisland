import AppKit

enum AlbumTint {
    static let fallback = NSColor(srgbRed: 1, green: 0.74, blue: 0.39, alpha: 1)

    static func dominant(_ art: NSImage) -> NSColor {
        var rect = CGRect(origin: .zero, size: art.size)
        guard let image = art.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return fallback }
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side*side*4)
        let rendered = pixels.withUnsafeMutableBytes { data -> Bool in
            guard let ctx = CGContext(data: data.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side*4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0,y: 0,width: side,height: side))
            return true
        }
        guard rendered else { return fallback }
        struct Bucket { var weight = 0.0, r = 0.0, g = 0.0, b = 0.0 }
        var bins = [Int: Bucket]()
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = Double(pixels[i+3])
            guard a > 150 else { continue }
            let r = Double(pixels[i])/a, g = Double(pixels[i+1])/a, b = Double(pixels[i+2])/a
            let hi = max(r,g,b), lo = min(r,g,b), chroma = hi-lo
            let key: Int
            let weight: Double
            if chroma < 0.065 {
                key = 24 + min(3,Int(hi*4))
                weight = 0.3
            } else {
                let h: Double
                if hi == r { h = (g-b)/chroma }
                else if hi == g { h = (b-r)/chroma+2 }
                else { h = (r-g)/chroma+4 }
                key = (Int(round(h*4))+24)%24
                weight = 0.65 + 0.7*chroma
            }
            var v = bins[key] ?? Bucket()
            v.weight += weight; v.r += r*weight; v.g += g*weight; v.b += b*weight
            bins[key] = v
        }
        guard let v = bins.values.max(by: { $0.weight < $1.weight }) else { return fallback }
        let r = v.r/v.weight, g = v.g/v.weight, b = v.b/v.weight
        let luminance = 0.213*r+0.715*g+0.072*b
        let lift = max(0,(0.52-luminance)/max(0.01,1-luminance))
        return NSColor(srgbRed: r+(1-r)*lift, green: g+(1-g)*lift, blue: b+(1-b)*lift, alpha: 1)
    }
}

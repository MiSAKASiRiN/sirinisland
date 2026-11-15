import AppKit

enum IslandLogo {
    static let orange = NSColor(srgbRed: 1, green: 0.49, blue: 0.045, alpha: 1)

    // Draw from the same outline for the app icon and the live island. The small
    // mark uses heavier rings so both circles survive at menu-bar sizes.
    static func draw(in rect: CGRect, color: NSColor = orange, small: Bool = false) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform()
        transform.translateX(by: rect.midX, yBy: rect.midY)
        let scale = min(rect.width, rect.height) / 100
        transform.scale(by: scale)
        transform.concat()
        color.setFill()
        color.setStroke()
        for (radius, width): (CGFloat, CGFloat) in [(47, small ? 6 : 4), (32.5, small ? 4.6 : 2.1)] {
            let ring = NSBezierPath(ovalIn: CGRect(x: -radius, y: -radius, width: 2 * radius, height: 2 * radius))
            ring.lineWidth = width
            ring.stroke()
        }
        NSBezierPath(ovalIn: CGRect(x: -13.4, y: -13.4, width: 26.8, height: 26.8)).fill()
        let turn = NSAffineTransform()
        turn.rotate(byDegrees: 90)
        for _ in 0..<4 {
            let arm = NSBezierPath()
            arm.move(to: CGPoint(x: -4.2, y: 12))
            arm.curve(to: CGPoint(x: 0, y: 25.7), controlPoint1: CGPoint(x: -2.2, y: 13.6), controlPoint2: CGPoint(x: -1.0, y: 19.4))
            arm.curve(to: CGPoint(x: 4.2, y: 12), controlPoint1: CGPoint(x: 1.0, y: 19.4), controlPoint2: CGPoint(x: 2.2, y: 13.6))
            arm.close()
            let halfWidth: CGFloat = small ? 2.9 : 2.2
            arm.move(to: CGPoint(x: 0, y: 25.7))
            arm.line(to: CGPoint(x: -halfWidth, y: 32.5))
            arm.line(to: CGPoint(x: 0, y: 47))
            arm.line(to: CGPoint(x: halfWidth, y: 32.5))
            arm.close()
            arm.fill()
            turn.concat()
        }
    }

    static let menuImage: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            draw(in: rect.insetBy(dx: 1, dy: 1), color: .black, small: true)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "SirinIsland"
        return image
    }()

    static let idleImage = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
        draw(in: rect, small: true)
        return true
    }
}

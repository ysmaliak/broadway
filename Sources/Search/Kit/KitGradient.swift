import QuartzCore

extension CAGradientLayer {
    func kitAxis(from start: CGPoint = .zero, to end: CGPoint = CGPoint(x: 1, y: 1), in size: CGSize) {
        let dx = end.x - start.x, dy = end.y - start.y
        let normal = CGPoint(x: dx * size.width * size.width, y: dy * size.height * size.height)
        let length = normal.x * normal.x + normal.y * normal.y
        guard length > 0 else {
            startPoint = start
            endPoint = end
            return
        }
        let reach = (dx * normal.x + dy * normal.y) / length
        startPoint = start
        endPoint = CGPoint(x: start.x + normal.x * reach, y: start.y + normal.y * reach)
    }
}

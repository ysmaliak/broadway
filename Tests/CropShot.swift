import AppKit

@main
enum CropShot {
    static func main() {
        let args = CommandLine.arguments
        guard args.count == 3, let width = Int(args[2]),
              let source = NSImage(contentsOfFile: args[1])?.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let cut = source.cropping(to: CGRect(x: 0, y: 0, width: min(width, source.width), height: source.height)) else {
            print("usage: CropShot PNG WIDTH")
            exit(1)
        }
        let rep = NSBitmapImageRep(cgImage: cut)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[1]))
        print("cropped \(cut.width)x\(cut.height)")
    }
}

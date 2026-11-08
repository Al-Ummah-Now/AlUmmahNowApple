#if os(macOS)
    import AUNCoreBridge
    import AUNDesign
    import AVFoundation
    import AppKit
    import MetalKit
    import SwiftUI

    /// Pure geometry for the timeline, so hit-testing and layout are unit-tested.
    struct TimelineLayout {
        let list: EditDecisionList
        let pointsPerSecond: CGFloat

        func frames(height: CGFloat) -> [(clip: EditClip, frame: CGRect)] {
            var x: CGFloat = 0
            return list.clips.map { clip in
                let width = CGFloat(clip.duration) * pointsPerSecond
                defer { x += width }
                return (clip, CGRect(x: x, y: 0, width: width, height: height))
            }
        }

        func time(atX x: CGFloat) -> Double { max(0, min(Double(x / pointsPerSecond), list.duration)) }
        func x(atTime time: Double) -> CGFloat { CGFloat(time) * pointsPerSecond }
    }

    /// Custom-drawn AppKit timeline. Time runs left to right in every language, like the editors creators already use.
    final class TimelineNSView: NSView {
        var list = EditDecisionList() { didSet { needsDisplay = true } }
        var selection: UUID? { didSet { needsDisplay = true } }
        var playhead = 0.0 { didSet { needsDisplay = true } }
        var onSelect: ((UUID?) -> Void)?
        var onScrub: ((Double) -> Void)?
        let pointsPerSecond: CGFloat = 40

        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }

        private var layoutModel: TimelineLayout { TimelineLayout(list: list, pointsPerSecond: pointsPerSecond) }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.windowBackgroundColor.setFill()
            dirtyRect.fill()
            for (clip, frame) in layoutModel.frames(height: bounds.height) {
                let rect = frame.insetBy(dx: 1, dy: 8)
                (clip.id == selection ? NSColor.systemOrange : NSColor.systemTeal).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
                let label = clip.source.lastPathComponent as NSString
                label.draw(
                    in: rect.insetBy(dx: 6, dy: 6),
                    withAttributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 11)])
            }
            NSColor.systemRed.setFill()
            NSRect(x: layoutModel.x(atTime: playhead), y: 0, width: 2, height: bounds.height).fill()
        }

        private func position(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

        override func mouseDown(with event: NSEvent) {
            let point = position(event)
            onSelect?(layoutModel.frames(height: bounds.height).first { $0.frame.contains(point) }?.clip.id)
            onScrub?(layoutModel.time(atX: point.x))
        }

        override func mouseDragged(with event: NSEvent) { onScrub?(layoutModel.time(atX: position(event).x)) }
    }

    struct TimelineView: NSViewRepresentable {
        let list: EditDecisionList
        let selection: UUID?
        let playhead: Double
        let onSelect: (UUID?) -> Void
        let onScrub: (Double) -> Void

        func makeNSView(context: Context) -> TimelineNSView { TimelineNSView() }

        func updateNSView(_ view: TimelineNSView, context: Context) {
            view.list = list
            view.selection = selection
            view.playhead = playhead
            view.onSelect = onSelect
            view.onScrub = onScrub
        }
    }

    /// Draws the composition's current frame through Metal, the base for real-time effects later.
    @MainActor
    final class MetalPreviewRenderer: NSObject, MTKViewDelegate {
        private static let shader = """
            #include <metal_stdlib>
            using namespace metal;
            struct V { float4 p [[position]]; float2 t; };
            vertex V v(uint i [[vertex_id]]) {
                float2 u = float2((i << 1) & 2, i & 2);
                return { float4(u * float2(2, -2) + float2(-1, 1), 0, 1), u };
            }
            fragment float4 f(V in [[stage_in]], texture2d<float> x [[texture(0)]]) {
                constexpr sampler s(filter::linear);
                return x.sample(s, in.t);
            }
            """
        private let queue: any MTLCommandQueue
        private let pipeline: any MTLRenderPipelineState
        private var cache: CVMetalTextureCache?
        private let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        private var currentTexture: CVMetalTexture?

        init?(view: MTKView) {
            guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
                let library = try? device.makeLibrary(source: Self.shader, options: nil)
            else { return nil }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "v")
            descriptor.fragmentFunction = library.makeFunction(name: "f")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
            self.queue = queue
            self.pipeline = pipeline
            super.init()
            view.device = device
            view.colorPixelFormat = .bgra8Unorm
            CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        }

        func attach(to item: AVPlayerItem) { item.add(output) }

        nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        nonisolated func draw(in view: MTKView) {
            MainActor.assumeIsolated { render(view) }
        }

        private func updateTexture() {
            let time = output.itemTime(forHostTime: CACurrentMediaTime())
            guard output.hasNewPixelBuffer(forItemTime: time), let cache,
                let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
            else { return }
            var texture: CVMetalTexture?
            CVMetalTextureCacheCreateTextureFromImage(
                nil, cache, buffer, nil, .bgra8Unorm, CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &texture)
            currentTexture = texture ?? currentTexture
        }

        private func render(_ view: MTKView) {
            updateTexture()
            guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
                let commands = queue.makeCommandBuffer(), let encoder = commands.makeRenderCommandEncoder(descriptor: pass)
            else { return }
            if let currentTexture, let texture = CVMetalTextureGetTexture(currentTexture) {
                encoder.setRenderPipelineState(pipeline)
                encoder.setFragmentTexture(texture, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
            encoder.endEncoding()
            commands.present(drawable)
            commands.commit()
        }
    }

    struct MetalPreview: NSViewRepresentable {
        let item: AVPlayerItem?

        final class Coordinator {
            var renderer: MetalPreviewRenderer?
            var item: AVPlayerItem?
        }

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeNSView(context: Context) -> MTKView {
            let view = MTKView()
            context.coordinator.renderer = MetalPreviewRenderer(view: view)
            view.delegate = context.coordinator.renderer
            return view
        }

        func updateNSView(_ view: MTKView, context: Context) {
            guard let item, item !== context.coordinator.item else { return }
            context.coordinator.item = item
            context.coordinator.renderer?.attach(to: item)
        }
    }

    struct EditorView: View {
        @Environment(\.l10n) private var l10n
        @State private var list = EditDecisionList()
        @State private var selection: UUID?
        @State private var playhead = 0.0
        @State private var importing = false
        @State private var player = AVPlayer()
        @State private var previewItem: AVPlayerItem?

        var body: some View {
            VStack(spacing: 8) {
                HStack {
                    Text(l10n("studio.editor.title")).font(.title2.weight(.bold)).accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button(l10n("studio.editor.import")) { importing = true }.accessibilityIdentifier("editor-import")
                    Button(l10n("studio.editor.split")) { mutate { $0.split(at: playhead) } }.disabled(list.clips.isEmpty)
                    Button(l10n("studio.editor.delete")) {
                        if let selection { mutate { $0.rippleDelete(id: selection) } }
                    }
                    .disabled(selection == nil)
                }
                if list.clips.isEmpty {
                    Text(l10n("studio.editor.empty")).foregroundStyle(Fanous.textSecondary).frame(
                        maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    MetalPreview(item: previewItem).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                TimelineView(
                    list: list, selection: selection, playhead: playhead,
                    onSelect: { selection = $0 },
                    onScrub: { time in
                        playhead = time
                        seekPlayer(to: time)
                    }
                )
                .environment(\.layoutDirection, .leftToRight)
                .frame(height: 96)
            }
            .padding()
            .fileImporter(isPresented: $importing, allowedContentTypes: [.movie], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { Task { await importClips(urls) } }
            }
        }

        private func seekPlayer(to time: Double) {
            player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            }
        }

        private func importClips(_ urls: [URL]) async {
            for url in urls {
                _ = url.startAccessingSecurityScopedResource()
                guard let duration = try? await AVURLAsset(url: url).load(.duration).seconds else { continue }
                list.append(EditClip(source: url, duration: duration))
            }
            await rebuildPreview()
        }

        private func mutate(_ change: (inout EditDecisionList) -> Void) {
            change(&list)
            Task { await rebuildPreview() }
        }

        private func rebuildPreview() async {
            guard let composition = try? await CompositionBuilder.build(list) else {
                previewItem = nil
                return
            }
            let item = AVPlayerItem(asset: composition)
            player.replaceCurrentItem(with: item)
            previewItem = item
            seekPlayer(to: min(playhead, list.duration))
        }
    }
#endif

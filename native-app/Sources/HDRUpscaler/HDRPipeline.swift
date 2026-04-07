import Metal
import MetalKit
import MetalPerformanceShaders
import AppKit

/// Orchestrates the video processing pipeline:
/// ScreenCaptureKit frame → MetalFX upscale → SDR-to-EDR shader → downscale → overlay
final class HDRPipeline {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let upscaler: Upscaler
    private let overlay: OverlayWindow
    private let hdrComputePipeline: MTLComputePipelineState

    private var upscaledTexture: MTLTexture?
    private var hdrOutputTexture: MTLTexture?
    private var presentTexture: MTLTexture?   // native-res texture for final presentation
    private var paramsBuffer: MTLBuffer?
    private var frameCount: UInt64 = 0
    private(set) var isActive = false

    // Backpressure: skip new frames if previous hasn't presented
    private var frameInFlight = false

    // Upscale factor (1.5, 2)
    private(set) var upscaleFactor: Float = 2.0

    // HDR intensity: 0.0 = SDR passthrough, 1.0 = full EDR expansion
    private(set) var hdrIntensity: Float = 0.3

    // Matches the Metal shader struct layout exactly
    struct HDRParams {
        var maxEDR: Float       // EDR headroom from NSScreen
        var intensity: Float    // 0.0–1.0 HDR intensity
    }

    init(device: MTLDevice) throws {
        self.device = device

        guard let queue = device.makeCommandQueue() else {
            throw PipelineError.commandQueueFailed
        }
        self.commandQueue = queue

        // Load Metal shader from bundled source
        let library: MTLLibrary
        if let url = Bundle.module.url(forResource: "sdr_to_hdr", withExtension: "metal") {
            let source = try String(contentsOf: url)
            library = try device.makeLibrary(source: source, options: nil)
        } else {
            throw PipelineError.shaderNotFound
        }

        guard let function = library.makeFunction(name: "sdr_to_hdr") else {
            throw PipelineError.shaderNotFound
        }
        self.hdrComputePipeline = try device.makeComputePipelineState(function: function)

        self.upscaler = Upscaler(device: device)
        self.overlay = OverlayWindow(device: device)

        self.paramsBuffer = device.makeBuffer(length: MemoryLayout<HDRParams>.stride, options: .storageModeShared)
        updateParamsBuffer()
    }

    // MARK: - Control

    func start(windowFrame: NSRect) {
        isActive = true
        frameCount = 0
        frameInFlight = false
        overlay.show(frame: windowFrame)
        print("[HDRPipeline] Started — overlay at \(windowFrame)")
    }

    func stop() {
        isActive = false
        overlay.hide()
        print("[HDRPipeline] Stopped")
    }

    func updateOverlayFrame(_ frame: NSRect) {
        overlay.updateFrame(frame)
    }

    func setTabVisible(_ visible: Bool) {
        overlay.setVisible(visible)
    }

    func setUpscaleFactor(_ factor: Float) {
        upscaleFactor = factor
        // Force texture recreation on next frame
        upscaledTexture = nil
        hdrOutputTexture = nil
        presentTexture = nil
        print("[HDRPipeline] Upscale factor → \(factor)x")
    }

    func setHDRIntensity(_ intensity: Float) {
        hdrIntensity = max(0.0, min(1.0, intensity))
        updateParamsBuffer()
        print("[HDRPipeline] HDR intensity → \(String(format: "%.0f%%", hdrIntensity * 100))")
    }

    // MARK: - Frame Processing (called from processing queue)

    func processFrame(inputTexture: MTLTexture, width: Int, height: Int) {
        guard isActive else { return }

        // Backpressure: skip if previous frame hasn't presented yet
        if frameInFlight { return }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        // Update EDR headroom each frame (it can change with brightness/ambient)
        updateParamsBuffer()

        // Safety clamp
        let maxSize = 16384
        let outputWidth = Int(Float(width) * upscaleFactor)
        let outputHeight = Int(Float(height) * upscaleFactor)

        if outputWidth > maxSize || outputHeight > maxSize {
            return
        }

        let needsUpscale = upscaleFactor > 1.0

        // Step 1: MetalFX upscale (skip if 1x)
        let textureAfterUpscale: MTLTexture
        let processW: Int
        let processH: Int

        if needsUpscale {
            do {
                try upscaler.configure(
                    inputWidth: width,
                    inputHeight: height,
                    outputWidth: outputWidth,
                    outputHeight: outputHeight,
                    inputPixelFormat: inputTexture.pixelFormat
                )
            } catch {
                print("[HDRPipeline] Upscaler error: \(error)")
                return
            }

            if upscaledTexture == nil ||
               upscaledTexture!.width != outputWidth ||
               upscaledTexture!.height != outputHeight {
                upscaledTexture = upscaler.makeOutputTexture()
            }

            guard let upscaledTex = upscaledTexture else { return }

            do {
                try upscaler.encode(input: inputTexture, output: upscaledTex, commandBuffer: commandBuffer)
            } catch {
                print("[HDRPipeline] Upscaler encode error: \(error)")
                return
            }
            textureAfterUpscale = upscaledTex
            processW = outputWidth
            processH = outputHeight
        } else {
            textureAfterUpscale = inputTexture
            processW = width
            processH = height
        }

        // Step 2: SDR-to-EDR compute shader (at upscaled resolution for quality)
        ensureHDROutputTexture(width: processW, height: processH)
        guard let hdrTex = hdrOutputTexture,
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return }

        encoder.setComputePipelineState(hdrComputePipeline)
        encoder.setTexture(textureAfterUpscale, index: 0)
        encoder.setTexture(hdrTex, index: 1)
        encoder.setBuffer(paramsBuffer, offset: 0, index: 0)

        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (processW + 15) / 16,
            height: (processH + 15) / 16,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        encoder.endEncoding()

        // Step 3: If upscaled, MPS downscale back to native resolution (supersampling)
        let textureToPresent: MTLTexture
        if needsUpscale {
            ensurePresentTexture(width: width, height: height)
            guard let presentTex = presentTexture else { return }

            let scale = MPSImageBilinearScale(device: device)
            scale.encode(commandBuffer: commandBuffer, sourceTexture: hdrTex, destinationTexture: presentTex)
            textureToPresent = presentTex
        } else {
            textureToPresent = hdrTex
        }

        // Step 4: Blit to overlay drawable (always native res now)
        overlay.present(texture: textureToPresent, commandBuffer: commandBuffer)

        // Backpressure tracking
        frameInFlight = true
        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.frameInFlight = false
        }

        commandBuffer.commit()

        frameCount += 1
        if frameCount % 120 == 0 {
            let maxEDR = Float(NSScreen.main?.maximumExtendedDynamicRangeColorComponentValue ?? 2.0)
            print("[HDRPipeline] \(frameCount) frames | \(width)x\(height) → \(processW)x\(processH) (\(upscaleFactor)x) | EDR: \(String(format: "%.1f", maxEDR))x | intensity: \(String(format: "%.0f%%", hdrIntensity * 100))")
        }
    }

    // MARK: - Helpers

    private func updateParamsBuffer() {
        guard let buffer = paramsBuffer else { return }
        let maxEDR = Float(NSScreen.main?.maximumExtendedDynamicRangeColorComponentValue ?? 2.0)
        let params = HDRParams(maxEDR: maxEDR, intensity: hdrIntensity)
        buffer.contents().storeBytes(of: params, as: HDRParams.self)
    }

    private func ensureHDROutputTexture(width: Int, height: Int) {
        if hdrOutputTexture == nil ||
           hdrOutputTexture!.width != width ||
           hdrOutputTexture!.height != height {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float,
                width: width,
                height: height,
                mipmapped: false
            )
            desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
            desc.storageMode = .private
            hdrOutputTexture = device.makeTexture(descriptor: desc)
        }
    }

    /// Native-resolution texture for final presentation after MPS downscale
    private func ensurePresentTexture(width: Int, height: Int) {
        if presentTexture == nil ||
           presentTexture!.width != width ||
           presentTexture!.height != height {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float,
                width: width,
                height: height,
                mipmapped: false
            )
            desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
            desc.storageMode = .private
            presentTexture = device.makeTexture(descriptor: desc)
        }
    }

    enum PipelineError: Error {
        case commandQueueFailed
        case shaderNotFound
    }
}

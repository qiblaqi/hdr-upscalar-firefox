import Metal
import MetalFX
import HDRUpscalerCore

/// MetalFX spatial upscaler wrapper.
/// Creates and manages MTLFXSpatialScaler instances for real-time video frame upscaling.
final class Upscaler {
    private let device: MTLDevice
    private var scaler: (any MTLFXSpatialScaler)?
    private var currentInputWidth: Int = 0
    private var currentInputHeight: Int = 0
    private var currentOutputWidth: Int = 0
    private var currentOutputHeight: Int = 0
    private var currentInputPixelFormat: MTLPixelFormat = .invalid

    let outputPixelFormat: MTLPixelFormat = .rgba16Float

    init(device: MTLDevice) {
        self.device = device
    }

    /// Configure the scaler for given input/output dimensions.
    /// Recreates the scaler only if dimensions changed.
    func configure(
        inputWidth: Int,
        inputHeight: Int,
        outputWidth: Int,
        outputHeight: Int,
        inputPixelFormat: MTLPixelFormat = .bgra8Unorm
    ) throws {
        guard inputWidth != currentInputWidth ||
              inputHeight != currentInputHeight ||
              outputWidth != currentOutputWidth ||
              outputHeight != currentOutputHeight ||
              inputPixelFormat != currentInputPixelFormat else {
            return // already configured
        }

        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.inputWidth = inputWidth
        descriptor.inputHeight = inputHeight
        descriptor.outputWidth = outputWidth
        descriptor.outputHeight = outputHeight
        descriptor.colorTextureFormat = inputPixelFormat
        descriptor.outputTextureFormat = outputPixelFormat
        descriptor.colorProcessingMode = .perceptual

        guard let newScaler = descriptor.makeSpatialScaler(device: device) else {
            throw UpscalerError.creationFailed
        }

        scaler = newScaler
        currentInputWidth = inputWidth
        currentInputHeight = inputHeight
        currentOutputWidth = outputWidth
        currentOutputHeight = outputHeight
        currentInputPixelFormat = inputPixelFormat

        logInfo("[Upscaler] Configured: \(inputWidth)x\(inputHeight) -> \(outputWidth)x\(outputHeight) (\(inputPixelFormat.rawValue))")
    }

    /// Encode an upscale pass into the command buffer.
    /// - Parameters:
    ///   - input: Source texture (SDR video frame)
    ///   - output: Destination texture (upscaled)
    ///   - commandBuffer: Metal command buffer to encode into
    func encode(input: MTLTexture, output: MTLTexture, commandBuffer: MTLCommandBuffer) throws {
        guard let scaler = scaler else {
            throw UpscalerError.notConfigured
        }

        scaler.colorTexture = input
        scaler.outputTexture = output
        scaler.encode(commandBuffer: commandBuffer)
    }

    /// Create an output texture matching current output dimensions.
    func makeOutputTexture() -> MTLTexture? {
        guard currentOutputWidth > 0 && currentOutputHeight > 0 else { return nil }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: outputPixelFormat,
            width: currentOutputWidth,
            height: currentOutputHeight,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        desc.storageMode = .private
        return device.makeTexture(descriptor: desc)
    }

    enum UpscalerError: Error {
        case creationFailed
        case notConfigured
    }
}

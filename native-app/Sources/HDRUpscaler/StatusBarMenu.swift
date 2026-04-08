import AppKit
import HDRUpscalerCore

/// Menu bar status item with upscale factor selector, HDR intensity, and status info.
final class StatusBarMenu {
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?

    // Current state
    private var currentFactor: Float = 2.0
    private var currentIntensity: Float = 0.3
    private var isCapturing = false
    private var windowTitle: String = "Not connected"

    // Callbacks
    var onUpscaleFactorChanged: ((Float) -> Void)?
    var onHDRIntensityChanged: ((Float) -> Void)?
    var onQuit: (() -> Void)?

    private let allFactors: [Float] = [1.5, 2.0, 3.0, 4.0]
    private var availableFactors: [Float] = [1.5, 2.0, 3.0, 4.0]

    // HDR intensity presets: (label, value)
    private let intensityPresets: [(String, Float)] = [
        ("Off (SDR only)", 0.0),
        ("Low (15%)", 0.15),
        ("Medium (30%)", 0.3),
        ("High (50%)", 0.5),
        ("Max (100%)", 1.0),
    ]

    private static let maxTextureSize = 16384

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.title = "HDR"
            button.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
        }

        rebuildMenu()
    }

    func updateStatus(capturing: Bool, windowTitle: String) {
        self.isCapturing = capturing
        self.windowTitle = windowTitle
        rebuildMenu()

        if let button = statusItem?.button {
            button.title = capturing ? "HDR ●" : "HDR ○"
        }
    }

    func setCurrentFactor(_ factor: Float) {
        self.currentFactor = factor
        rebuildMenu()
    }

    func setCurrentIntensity(_ intensity: Float) {
        self.currentIntensity = intensity
        rebuildMenu()
    }

    @discardableResult
    func updateAvailableFactors(inputWidth: Int, inputHeight: Int) -> Float {
        let maxDimension = max(inputWidth, inputHeight)
        availableFactors = allFactors.filter { factor in
            Int(Float(maxDimension) * factor) <= StatusBarMenu.maxTextureSize
        }

        if !availableFactors.contains(currentFactor) {
            let newFactor = availableFactors.last ?? 2.0
            logInfo("[StatusBar] Factor \(currentFactor)x exceeds GPU limit, downgrading to \(newFactor)x")
            currentFactor = newFactor
            onUpscaleFactorChanged?(newFactor)
        }

        rebuildMenu()
        return currentFactor
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        // Status header
        let displayTitle = windowTitle.count > 40
            ? String(windowTitle.prefix(37)) + "..."
            : windowTitle
        let statusText = isCapturing ? "Capturing: \(displayTitle)" : displayTitle
        let statusItem = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        menu.addItem(NSMenuItem.separator())

        // Upscale factor section
        let factorHeader = NSMenuItem(title: "Upscale Factor", action: nil, keyEquivalent: "")
        factorHeader.isEnabled = false
        menu.addItem(factorHeader)

        for factor in availableFactors {
            let label = factor == 1.5 ? "1.5x" : "\(Int(factor))x"
            let item = NSMenuItem(title: "  \(label)", action: #selector(factorSelected(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(factor * 10)
            item.state = (factor == currentFactor) ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        // HDR intensity section
        let hdrHeader = NSMenuItem(title: "HDR Intensity", action: nil, keyEquivalent: "")
        hdrHeader.isEnabled = false
        menu.addItem(hdrHeader)

        for (index, preset) in intensityPresets.enumerated() {
            let item = NSMenuItem(title: "  \(preset.0)", action: #selector(intensitySelected(_:)), keyEquivalent: "")
            item.target = self
            item.tag = 100 + index
            item.state = (preset.1 == currentIntensity) ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit HDR Upscaler", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        self.menu = menu
        self.statusItem?.menu = menu
    }

    @objc private func factorSelected(_ sender: NSMenuItem) {
        let factor = Float(sender.tag) / 10.0
        currentFactor = factor
        onUpscaleFactorChanged?(factor)
        rebuildMenu()
    }

    @objc private func intensitySelected(_ sender: NSMenuItem) {
        let index = sender.tag - 100
        guard index >= 0 && index < intensityPresets.count else { return }
        let intensity = intensityPresets[index].1
        currentIntensity = intensity
        onHDRIntensityChanged?(intensity)
        rebuildMenu()
    }

    @objc private func quitApp() {
        onQuit?()
    }
}

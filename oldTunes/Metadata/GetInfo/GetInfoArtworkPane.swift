import AppKit
import UniformTypeIdentifiers

/// The Artwork tab: the image in a large well, with Add… and Delete beneath it.
@MainActor
final class GetInfoArtworkPane: NSView {
    private let well = ArtworkWell()
    private let addButton = AquaButton(title: "Add…")
    private let deleteButton = AquaButton(title: "Delete")
    private let sizeLabel = FormKit.label("", font: AquaStyle.tinyFont, color: AquaStyle.noteText, alignment: .right)

    /// New image bytes (PNG or JPEG) chosen by the user.
    var onAdd: ((Data) -> Void)?
    var onDelete: (() -> Void)?

    override var isFlipped: Bool { true }

    init(frame: NSRect, boxBottom: CGFloat) {
        super.init(frame: frame)
        let L = GetInfoLayout.self
        let buttonsY = boxBottom - 14 - AquaButton.height
        let side = min(L.contentRight - L.contentLeft, buttonsY - 12 - L.contentTop)
        well.frame = NSRect(x: (L.windowWidth - side) / 2, y: L.contentTop, width: side, height: side)
        addSubview(well)

        let addW = AquaButton.width(for: addButton.title)
        addButton.frame = NSRect(x: L.contentLeft, y: buttonsY, width: addW, height: AquaButton.height)
        addButton.onPress = { [weak self] in self?.chooseImage() }
        addSubview(addButton)
        let delW = AquaButton.width(for: deleteButton.title)
        deleteButton.frame = NSRect(x: L.contentLeft + addW + 10, y: buttonsY, width: delW, height: AquaButton.height)
        deleteButton.onPress = { [weak self] in self?.onDelete?() }
        addSubview(deleteButton)

        sizeLabel.frame = NSRect(x: L.contentRight - 160, y: buttonsY + 4, width: 160, height: 13)
        addSubview(sizeLabel)
    }

    required init?(coder: NSCoder) { nil }

    func show(_ data: Data?) {
        let image = data.flatMap(NSImage.init(data:))
        well.image = image
        deleteButton.isEnabled = image != nil
        if let image, let rep = image.representations.first, rep.pixelsWide > 0 {
            sizeLabel.stringValue = "\(rep.pixelsWide) × \(rep.pixelsHigh)"
        } else {
            sizeLabel.stringValue = ""
        }
    }

    func setEditable(_ editable: Bool) {
        addButton.isEnabled = editable
        deleteButton.isEnabled = editable && well.image != nil
    }

    private func chooseImage() {
        guard let window else { return }
        ArtworkPicker.choose(for: window) { [weak self] data in self?.onAdd?(data) }
    }
}

/// NSOpenPanel for images, returning PNG or JPEG bytes. Anything else (HEIC, TIFF, …) is
/// converted to PNG, because ID3 and MP4 covers are only reliably read back as PNG or JPEG.
@MainActor
enum ArtworkPicker {
    static func choose(for window: NSWindow, completion: @escaping (Data) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an image to use as the artwork."
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url, let data = imageData(from: url) else { return }
            completion(data)
        }
    }

    static func imageData(from url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let type = UTType(filenameExtension: url.pathExtension),
           type.conforms(to: .png) || type.conforms(to: .jpeg) {
            return data
        }
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

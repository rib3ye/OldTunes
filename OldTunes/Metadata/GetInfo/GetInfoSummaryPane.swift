import AppKit

/// The Summary tab: artwork, the three names, then the technical block (Kind, Size, Bit Rate,
/// Sample Rate, Date Added, Play Count) in Monaco and Where. Read-only, as in iTunes.
@MainActor
final class GetInfoSummaryPane: NSView {
    private let artworkWell = ArtworkWell()
    private let titleLabel = FormKit.label("", font: AquaStyle.titleBold13)
    private let artistLabel = FormKit.label("")
    private let albumLabel = FormKit.label("")
    private let timeLabel = FormKit.label("")
    private let cloudBadge = CloudBadgeView()
    private let readNote = FormKit.label("", font: AquaStyle.tinyFont, color: AquaStyle.noteText)
    private var valueLabels: [NSTextField] = []
    private let whereValue = NSTextField(wrappingLabelWithString: "")

    private static let rows = ["Kind:", "Size:", "Bit Rate:", "Sample Rate:", "Date Added:", "Play Count:"]
    private static let whereLines = 7
    private var etchY: [CGFloat] = []

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let L = GetInfoLayout.self
        var y = L.contentTop

        artworkWell.placeholder = .disc
        artworkWell.frame = NSRect(x: L.contentLeft, y: y, width: 100, height: 100)
        addSubview(artworkWell)

        let textX = L.contentLeft + 116
        let textW = L.contentRight - textX
        for (i, label) in [titleLabel, artistLabel, albumLabel, timeLabel].enumerated() {
            let h: CGFloat = i == 0 ? 17 : 14
            label.frame = NSRect(x: textX, y: y + 6 + CGFloat(i) * 19 + (i == 0 ? 0 : 2), width: textW, height: h)
            addSubview(label)
        }
        cloudBadge.frame = NSRect(x: textX, y: y + 84, width: textW, height: 14)
        addSubview(cloudBadge)

        y += 100 + 14
        etchY.append(y)
        y += 12

        let labelW: CGFloat = 92
        let valueX = L.contentLeft + labelW + 8
        for title in Self.rows {
            let l = FormKit.label(title, alignment: .right)
            l.frame = NSRect(x: L.contentLeft, y: y + 1, width: labelW, height: 14)
            addSubview(l)
            let v = FormKit.label("", font: Theme.monoFont)
            v.frame = NSRect(x: valueX, y: y, width: L.contentRight - valueX, height: 15)
            addSubview(v)
            valueLabels.append(v)
            y += 17
        }
        y += 8
        etchY.append(y)
        y += 12

        let whereLabel = FormKit.label("Where:", alignment: .right)
        whereLabel.frame = NSRect(x: L.contentLeft, y: y + 1, width: labelW, height: 14)
        addSubview(whereLabel)
        whereValue.font = Theme.monoFont
        whereValue.textColor = AquaStyle.text
        whereValue.lineBreakMode = .byCharWrapping
        // Seven Monaco lines hold about 300 characters, more than any path in this library;
        // `whereText` shortens a longer one from the middle so the file name always shows.
        whereValue.maximumNumberOfLines = Self.whereLines
        whereValue.frame = NSRect(x: valueX, y: y, width: L.contentRight - valueX, height: CGFloat(Self.whereLines) * 15 + 2)
        addSubview(whereValue)

        readNote.frame = NSRect(x: L.contentLeft, y: whereValue.frame.maxY + 6, width: L.contentRight - L.contentLeft, height: 13)
        addSubview(readNote)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        for y in etchY {
            AquaStyle.drawEtchedLine(from: GetInfoLayout.contentLeft, to: GetInfoLayout.contentRight, y: y, flipped: true)
        }
    }

    func show(_ track: Track, fields: TagFields) {
        titleLabel.stringValue = fields.title.isEmpty ? track.displayTitle : fields.title
        artistLabel.stringValue = fields.artist
        albumLabel.stringValue = fields.album
        timeLabel.stringValue = GetInfoFormat.duration(track.duration)
        cloudBadge.isHidden = !track.isCloudOnly
        let values = [GetInfoFormat.kind(track), GetInfoFormat.size(track.fileSize),
                      GetInfoFormat.bitRate(track.bitRate), GetInfoFormat.sampleRate(track.sampleRate),
                      GetInfoFormat.date(track.dateAdded), "\(track.playCount)"]
        for (label, value) in zip(valueLabels, values) { label.stringValue = value }
        whereValue.stringValue = GetInfoFormat.whereText(track, maxCharacters: Self.whereCapacity(whereValue))
    }

    /// Characters the Where box holds: Monaco is monospaced, so it is columns × lines. Wide
    /// (full-width) characters take two columns, which `whereText` accounts for.
    private static func whereCapacity(_ label: NSTextField) -> Int {
        let advance = ("M" as NSString).size(withAttributes: [.font: Theme.monoFont]).width
        guard advance > 0 else { return 200 }
        return Int((label.frame.width - 4) / advance) * whereLines
    }

    func showArtwork(_ data: Data?) {
        artworkWell.image = data.flatMap(NSImage.init(data:))
    }

    /// When the file's own tags could not be read the sheet falls back to the library's copy;
    /// say so rather than silently showing possibly stale values.
    func showReadProblem(_ message: String?) {
        readNote.stringValue = message.map { "Showing the library’s information: \($0)" } ?? ""
    }
}

/// A one-line note in small grey type: "Stored in iCloud" under a cloud-only song's names, and
/// under the Info fields where a Music-library song's changes are saved. The cloud glyph is for
/// songs stored in iCloud; a song with a file on this Mac gets the text alone.
@MainActor
final class CloudBadgeView: NSView {
    var text = "Stored in iCloud — changes are saved through Music" { didSet { needsDisplay = true } }
    var showsCloud = true { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if showsCloud { AquaIcons.drawCloud(in: NSRect(x: 0, y: 2, width: 16, height: 10)) }
        let x: CGFloat = showsCloud ? 21 : 0
        let attrs = AquaStyle.attributes(AquaStyle.tinyFont, color: AquaStyle.noteText)
        (text as NSString).draw(in: NSRect(x: x, y: 0, width: bounds.width - x, height: 14), withAttributes: attrs)
    }
}

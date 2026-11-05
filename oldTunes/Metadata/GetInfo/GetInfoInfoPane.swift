import AppKit

/// The Info tab: every editable tag of one song, laid out the way iTunes 4.9 did — label above
/// field, Year/BPM and the "N of N" pairs at the right of their rows.
@MainActor
final class GetInfoInfoPane: NSView {
    let name: AquaTextField
    let artist: AquaTextField
    let year: AquaTextField
    let albumArtist: AquaTextField
    let bpm: AquaTextField
    let album: AquaTextField
    let trackNumber: AquaTextField
    let trackCount: AquaTextField
    let grouping: AquaTextField
    let discNumber: AquaTextField
    let discCount: AquaTextField
    let composer: AquaTextField
    let comments = AquaTextArea()
    let genre: AquaTextField
    let compilation = AquaCheckbox(title: "Part of a compilation")
    private let cloudNote = CloudBadgeView()

    /// Bottom of the last control, so the window can size its box.
    let contentBottom: CGFloat

    /// Any edit, for enabling OK-time diffing and nothing else.
    var onEdit: (() -> Void)?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        let L = GetInfoLayout.self
        let left = L.contentLeft, right = L.contentRight
        let smallW: CGFloat = 76
        let pairW = L.numberWidth * 2 + 26              // "[__] of [__]"
        var y = L.contentTop

        func field(_ t: String, x: CGFloat, w: CGFloat, align: NSTextAlignment = .left, digits: Int? = nil) -> AquaTextField {
            let f = AquaTextField(alignment: align)
            f.digitLimit = digits
            f.setBezelFrame(NSRect(x: x, y: 0, width: w, height: L.fieldHeight))
            f.identifier = NSUserInterfaceItemIdentifier(t)
            return f
        }
        name = field("Name", x: left, w: right - left)
        artist = field("Artist", x: left, w: right - smallW - 12 - left)
        year = field("Year", x: right - smallW, w: smallW, digits: 4)
        albumArtist = field("Album Artist", x: left, w: right - smallW - 12 - left)
        bpm = field("BPM", x: right - smallW, w: smallW, digits: 4)
        album = field("Album", x: left, w: right - pairW - 12 - left)
        trackNumber = field("Track Number", x: right - pairW, w: L.numberWidth, align: .center, digits: 4)
        trackCount = field("of", x: right - L.numberWidth, w: L.numberWidth, align: .center, digits: 4)
        grouping = field("Grouping", x: left, w: right - pairW - 12 - left)
        discNumber = field("Disc Number", x: right - pairW, w: L.numberWidth, align: .center, digits: 3)
        discCount = field("of", x: right - L.numberWidth, w: L.numberWidth, align: .center, digits: 3)
        composer = field("Composer", x: left, w: right - left)
        genre = field("Genre", x: left, w: 200)

        // Label/field pairs per row, top to bottom. An empty label is the "of" half of a pair.
        let rows: [[(String, AquaTextField)]] = [
            [("Name", name)],
            [("Artist", artist), ("Year", year)],
            [("Album Artist", albumArtist), ("BPM", bpm)],
            [("Album", album), ("Track Number", trackNumber), ("", trackCount)],
            [("Grouping", grouping), ("Disc Number", discNumber), ("", discCount)],
            [("Composer", composer)],
        ]
        var placements: [(NSTextField, NSRect)] = []
        var fieldYs: [(AquaTextField, CGFloat)] = []
        var ofLabels: [CGFloat] = []
        for row in rows {
            for (title, f) in row {
                let fx = f.frame.minX + AquaTextField.ringMargin
                let fw = f.frame.width - 2 * AquaTextField.ringMargin
                if !title.isEmpty {
                    placements.append((FormKit.label(title), NSRect(x: fx, y: y, width: max(fw, 110), height: L.labelHeight)))
                } else {
                    ofLabels.append(y + L.labelHeight + 2)
                }
                fieldYs.append((f, y + L.labelHeight + 2))
            }
            y += L.rowPitch
        }

        let commentsLabelY = y
        let commentsY = y + L.labelHeight + 2
        let commentsH: CGFloat = 46
        y = commentsY + commentsH + 9

        let genreLabelY = y
        let genreY = y + L.labelHeight + 2
        y = genreY + L.fieldHeight + 14
        let noteY = y
        contentBottom = noteY + 14

        super.init(frame: frame)

        for (label, rect) in placements { label.frame = rect; addSubview(label) }
        for (f, fy) in fieldYs {
            let bezel = NSRect(x: f.frame.minX + AquaTextField.ringMargin, y: fy,
                               width: f.frame.width - 2 * AquaTextField.ringMargin, height: L.fieldHeight)
            f.setBezelFrame(bezel)
            addSubview(f)
            f.onChange = { [weak self] in self?.onEdit?() }
        }
        for oy in ofLabels {
            let of = FormKit.label("of", alignment: .center)
            of.frame = NSRect(x: right - L.numberWidth - 26, y: oy + 2, width: 26, height: 14)
            addSubview(of)
        }

        let cl = FormKit.label("Comments")
        cl.frame = NSRect(x: left, y: commentsLabelY, width: 200, height: L.labelHeight)
        addSubview(cl)
        comments.setBezelFrame(NSRect(x: left, y: commentsY, width: right - left, height: commentsH))
        comments.onChange = { [weak self] in self?.onEdit?() }
        addSubview(comments)

        let gl = FormKit.label("Genre")
        gl.frame = NSRect(x: left, y: genreLabelY, width: 200, height: L.labelHeight)
        addSubview(gl)
        genre.setBezelFrame(NSRect(x: left, y: genreY, width: 200, height: L.fieldHeight))
        genre.onChange = { [weak self] in self?.onEdit?() }
        addSubview(genre)
        let size = compilation.fittingSize
        compilation.frame = NSRect(x: left + 220, y: genreY + (L.fieldHeight - size.height) / 2,
                                   width: size.width, height: size.height)
        compilation.onToggle = { [weak self] _ in self?.onEdit?() }
        addSubview(compilation)

        cloudNote.frame = NSRect(x: left, y: noteY, width: right - left, height: 14)
        cloudNote.isHidden = true
        addSubview(cloudNote)
    }

    required init?(coder: NSCoder) { nil }

    func load(_ f: TagFields) {
        name.stringValue = f.title
        artist.stringValue = f.artist
        year.intValue = f.year
        albumArtist.stringValue = f.albumArtist
        bpm.intValue = f.bpm
        album.stringValue = f.album
        trackNumber.intValue = f.trackNumber
        trackCount.intValue = f.trackCount
        grouping.stringValue = f.grouping
        discNumber.intValue = f.discNumber
        discCount.intValue = f.discCount
        composer.stringValue = f.composer
        comments.stringValue = f.comments
        genre.stringValue = f.genre
        compilation.isOn = f.isCompilation
    }

    func currentFields() -> TagFields {
        var f = TagFields()
        f.title = name.stringValue
        f.artist = artist.stringValue
        f.year = year.intValue
        f.albumArtist = albumArtist.stringValue
        f.bpm = bpm.intValue
        f.album = album.stringValue
        f.trackNumber = trackNumber.intValue
        f.trackCount = trackCount.intValue
        f.grouping = grouping.stringValue
        f.discNumber = discNumber.intValue
        f.discCount = discCount.intValue
        f.composer = composer.stringValue
        f.comments = comments.stringValue
        f.genre = genre.stringValue
        f.isCompilation = compilation.isOn
        return f
    }

    /// Where this song's changes are saved, or nil to show nothing (a folder song's own file).
    func showMusicNote(_ note: GetInfoWindowController.MusicNote?) {
        cloudNote.isHidden = note == nil
        if let note {
            cloudNote.text = note.text
            cloudNote.showsCloud = note.showsCloud
        }
    }

    func setEditable(_ editable: Bool) {
        for f in [name, artist, year, albumArtist, bpm, album, trackNumber, trackCount, grouping,
                  discNumber, discCount, composer, genre] { f.isEditable = editable }
        comments.textView.isEditable = editable
        compilation.isEnabled = editable
    }
}

import AppKit

/// "Multiple Song Information": one page of shared fields, each with a small checkbox that
/// turns on as soon as that field is edited. Only checked fields go into the patch, so a field
/// whose values differ across the selection (shown blank) is never blanked by accident.
@MainActor
final class GetInfoMultiplePane: NSView {
    enum Field: String, CaseIterable {
        case artist, year, albumArtist, bpm, album, trackNumber, trackCount, grouping
        case discNumber, discCount, composer, comments, genre, compilation, artwork
    }

    private(set) var checkboxes: [Field: AquaCheckbox] = [:]
    private(set) var fields: [Field: AquaTextField] = [:]
    let comments = AquaTextArea()
    /// "No" / "Yes", as iTunes had it here: a checkbox would sit beside its own apply box.
    let compilation = AquaPopUpButton(items: ["No", "Yes"])
    private let artworkWell = ArtworkWell()
    private let addArtwork = AquaButton(title: "Add…")
    private let cloudNote = CloudBadgeView()
    private(set) var pendingArtwork: Data?

    let contentBottom: CGFloat
    static let contentTop: CGFloat = 52

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        let L = GetInfoLayout.self
        let left = L.contentLeft, right = L.contentRight
        let cb: CGFloat = 18                 // checkbox column: 12 pt box + gap
        let smallW: CGFloat = 70
        let pairW = cb + L.numberWidth + 22 + cb + L.numberWidth
        var y = Self.contentTop

        var layout: [(Field, String, NSRect)] = []   // field, label, bezel
        func row(_ items: [(Field, String, CGFloat, CGFloat)]) {
            for (field, label, x, w) in items {
                layout.append((field, label, NSRect(x: x + cb, y: y + L.labelHeight + 2, width: w - cb, height: L.fieldHeight)))
            }
            y += L.rowPitch
        }
        let mainW = right - smallW - cb - 12 - left
        row([(.artist, "Artist", left, mainW), (.year, "Year", right - smallW - cb, smallW + cb)])
        row([(.albumArtist, "Album Artist", left, mainW), (.bpm, "BPM", right - smallW - cb, smallW + cb)])
        let albumW = right - pairW - 12 - left
        row([(.album, "Album", left, albumW), (.trackNumber, "Track Number", right - pairW, cb + L.numberWidth),
             (.trackCount, "", right - cb - L.numberWidth, cb + L.numberWidth)])
        row([(.grouping, "Grouping", left, albumW), (.discNumber, "Disc Number", right - pairW, cb + L.numberWidth),
             (.discCount, "", right - cb - L.numberWidth, cb + L.numberWidth)])
        row([(.composer, "Composer", left, right - left)])

        let commentsLabelY = y
        let commentsRect = NSRect(x: left + cb, y: y + L.labelHeight + 2, width: right - left - cb, height: 40)
        y = commentsRect.maxY + 9
        let genreLabelY = y
        let genreRect = NSRect(x: left + cb, y: y + L.labelHeight + 2, width: 180, height: L.fieldHeight)
        y = genreRect.maxY + 12
        let artworkLabelY = y
        let wellRect = NSRect(x: left + cb, y: y + L.labelHeight + 2, width: 64, height: 64)
        y = wellRect.maxY + 12
        let noteY = y
        contentBottom = noteY + 14

        super.init(frame: frame)

        for (field, label, bezel) in layout {
            if !label.isEmpty {
                let l = FormKit.label(label)
                l.frame = NSRect(x: bezel.minX - cb, y: bezel.minY - L.labelHeight - 2, width: max(bezel.width + cb, 110), height: L.labelHeight)
                addSubview(l)
            } else {
                let of = FormKit.label("of", alignment: .center)
                of.frame = NSRect(x: bezel.minX - cb - 22, y: bezel.minY + 2, width: 22, height: 14)
                addSubview(of)
            }
            let f = AquaTextField(alignment: [.trackNumber, .trackCount, .discNumber, .discCount].contains(field) ? .center : .left)
            if [.year, .bpm, .trackNumber, .trackCount].contains(field) { f.digitLimit = 4 }
            if [.discNumber, .discCount].contains(field) { f.digitLimit = 3 }
            f.setBezelFrame(bezel)
            f.onChange = { [weak self] in self?.checkboxes[field]?.isOn = true }
            addSubview(f)
            fields[field] = f
            addCheckbox(field, besideY: bezel.midY, x: bezel.minX - cb)
        }

        let cl = FormKit.label("Comments")
        cl.frame = NSRect(x: left, y: commentsLabelY, width: 200, height: L.labelHeight)
        addSubview(cl)
        comments.setBezelFrame(commentsRect)
        comments.onChange = { [weak self] in self?.checkboxes[.comments]?.isOn = true }
        addSubview(comments)
        addCheckbox(.comments, besideY: commentsRect.minY + 9, x: left)

        let gl = FormKit.label("Genre")
        gl.frame = NSRect(x: left, y: genreLabelY, width: 200, height: L.labelHeight)
        addSubview(gl)
        let genre = AquaTextField()
        genre.setBezelFrame(genreRect)
        genre.onChange = { [weak self] in self?.checkboxes[.genre]?.isOn = true }
        addSubview(genre)
        fields[.genre] = genre
        addCheckbox(.genre, besideY: genreRect.midY, x: left)

        // "Part of a Compilation" lines up with the right-hand column (Year, BPM, the pairs).
        let compX = right - pairW
        let compLabel = FormKit.label("Part of a Compilation")
        compLabel.frame = NSRect(x: compX, y: genreLabelY, width: right - compX, height: L.labelHeight)
        addSubview(compLabel)
        addCheckbox(.compilation, besideY: genreRect.midY, x: compX)
        compilation.frame = NSRect(x: compX + cb, y: (genreRect.midY - AquaPopUpButton.height / 2).rounded(),
                                   width: AquaPopUpButton.width(for: compilation.items), height: AquaPopUpButton.height)
        compilation.onSelect = { [weak self] _ in self?.checkboxes[.compilation]?.isOn = true }
        addSubview(compilation)

        let al = FormKit.label("Artwork")
        al.frame = NSRect(x: left, y: artworkLabelY, width: 200, height: L.labelHeight)
        addSubview(al)
        artworkWell.frame = wellRect
        artworkWell.placeholder = .text("")
        artworkWell.onClick = { [weak self] in self?.chooseArtwork() }
        addSubview(artworkWell)
        addCheckbox(.artwork, besideY: wellRect.minY + 9, x: left)
        let addW = AquaButton.width(for: addArtwork.title)
        addArtwork.frame = NSRect(x: wellRect.maxX + 12, y: wellRect.maxY - AquaButton.height, width: addW, height: AquaButton.height)
        addArtwork.onPress = { [weak self] in self?.chooseArtwork() }
        addSubview(addArtwork)

        cloudNote.frame = NSRect(x: left, y: noteY, width: right - left, height: 14)
        cloudNote.isHidden = true
        addSubview(cloudNote)
    }

    required init?(coder: NSCoder) { nil }

    private func addCheckbox(_ field: Field, besideY midY: CGFloat, x: CGFloat) {
        let box = AquaCheckbox(size: .small)
        let s = box.fittingSize
        box.frame = NSRect(x: x, y: (midY - s.height / 2).rounded(), width: s.width, height: s.height)
        box.setAccessibilityLabel("Apply \(field.rawValue)")
        addSubview(box)
        checkboxes[field] = box
    }

    /// Shows values every selected song shares; a field whose songs disagree stays blank.
    /// `keepingEdits` is for the second load, once the files have been read: a field the user
    /// has already ticked keeps its value, because overwriting it would silently drop the edit.
    func load(_ all: [TagFields], keepingEdits: Bool = false) {
        func common<T: Equatable>(_ key: (TagFields) -> T) -> T? {
            guard let first = all.first.map(key) else { return nil }
            return all.allSatisfy { key($0) == first } ? first : nil
        }
        func untouched(_ f: Field) -> Bool { !(keepingEdits && checkboxes[f]?.isOn == true) }
        func text(_ f: Field, _ key: (TagFields) -> String) {
            if untouched(f) { fields[f]?.stringValue = common(key) ?? "" }
        }
        func number(_ f: Field, _ key: (TagFields) -> Int) {
            if untouched(f) { fields[f]?.intValue = common(key) ?? 0 }
        }
        text(.artist, \.artist)
        number(.year, \.year)
        text(.albumArtist, \.albumArtist)
        number(.bpm, \.bpm)
        text(.album, \.album)
        number(.trackNumber, \.trackNumber)
        number(.trackCount, \.trackCount)
        text(.grouping, \.grouping)
        number(.discNumber, \.discNumber)
        number(.discCount, \.discCount)
        text(.composer, \.composer)
        text(.genre, \.genre)
        if untouched(.comments) { comments.stringValue = common(\.comments) ?? "" }
        if untouched(.compilation) { compilation.selectedIndex = (common(\.isCompilation) ?? false) ? 1 : 0 }
        if !keepingEdits { for box in checkboxes.values { box.isOn = false } }
    }

    /// Where the library songs' changes are saved, or nil when every song is a folder file.
    func showMusicNote(_ note: GetInfoWindowController.MusicNote?) {
        cloudNote.isHidden = note == nil
        if let note {
            cloudNote.text = note.text
            cloudNote.showsCloud = note.showsCloud
        }
    }

    /// Only the checked fields.
    func patch() -> TagPatch {
        var p = TagPatch()
        func on(_ f: Field) -> Bool { checkboxes[f]?.isOn == true }
        func text(_ f: Field) -> String { fields[f]?.stringValue ?? "" }
        func number(_ f: Field) -> Int { fields[f]?.intValue ?? 0 }
        if on(.artist) { p.artist = text(.artist) }
        if on(.year) { p.year = number(.year) }
        if on(.albumArtist) { p.albumArtist = text(.albumArtist) }
        if on(.bpm) { p.bpm = number(.bpm) }
        if on(.album) { p.album = text(.album) }
        if on(.trackNumber) { p.trackNumber = number(.trackNumber) }
        if on(.trackCount) { p.trackCount = number(.trackCount) }
        if on(.grouping) { p.grouping = text(.grouping) }
        if on(.discNumber) { p.discNumber = number(.discNumber) }
        if on(.discCount) { p.discCount = number(.discCount) }
        if on(.composer) { p.composer = text(.composer) }
        if on(.comments) { p.comments = comments.stringValue }
        if on(.genre) { p.genre = text(.genre) }
        if on(.compilation) { p.isCompilation = compilation.selectedIndex == 1 }
        if on(.artwork) {
            // A checked, empty well removes the artwork, as iTunes did.
            if let pendingArtwork { p.artwork = pendingArtwork } else { p.removeArtwork = true }
        }
        return p
    }

    func setArtwork(_ data: Data) {
        pendingArtwork = data
        artworkWell.image = NSImage(data: data)
        checkboxes[.artwork]?.isOn = true
    }

    private func chooseArtwork() {
        guard let window else { return }
        ArtworkPicker.choose(for: window) { [weak self] data in self?.setArtwork(data) }
    }
}

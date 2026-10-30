import UIKit

@MainActor
final class PhotoDayHeader: UICollectionReusableView {
    private let dateLabel = UILabel()
    private let checkbox = UIButton(type: .system)
    private let line = UIView()
    private var onToggle: () -> Void = {}
    private var contentRotation: CGFloat = 0
    private var controlsSize: CGSize = .zero

    static func height(date: Date, width: CGFloat, rotation: CGFloat, traits: UITraitCollection, controlsSize: CGSize = .zero) -> CGFloat {
        let font = UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traits)
        let title = title(for: date)
        if rotation != 0 {
            // Fit the upright date between the top controls and the checkbox at the bottom.
            let widestWord = title.split(separator: " ").map { (String($0) as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
            var textWidth = max(64, ceil(widestWord))
            let availableHeight = max(font.lineHeight, width - 60 - controlsSize.height)
            let fullWidth = ceil((title as NSString).size(withAttributes: [.font: font]).width)
            while textWidth < fullWidth && textHeight(title, width: textWidth, font: font) > availableHeight {
                textWidth = min(fullWidth, textWidth + 12)
            }
            return textWidth + 24
        }
        return portraitGeometry(title: title, width: width, font: font, controlsSize: controlsSize).height
    }

    private static func textHeight(_ title: String, width: CGFloat, font: UIFont) -> CGFloat {
        ceil((title as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font], context: nil).height)
    }

    private static func portraitGeometry(title: String, width: CGFloat, font: UIFont, controlsSize: CGSize)
        -> (height: CGFloat, textWidth: CGFloat, top: CGFloat) {
        let available = max(1, width - 72 - controlsSize.width)
        let widestWord = title.split(separator: " ").map { (String($0) as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        let belowControls = controlsSize.width > 0 && available < max(120, ceil(widestWord))
        let textWidth = belowControls ? max(1, width - 72) : available
        let top = belowControls ? controlsSize.height : 0
        let text = (title as NSString).boundingRect(with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font], context: nil)
        return (top + max(44, ceil(text.height) + 20), textWidth, top)
    }

    private static func title(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = .current
        formatter.dateFormat = "EEE, MMM d, yyyy"
        return formatter.string(from: date)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        dateLabel.font = .preferredFont(forTextStyle: .subheadline)
        dateLabel.adjustsFontForContentSizeCategory = true
        dateLabel.numberOfLines = 0
        dateLabel.textColor = .secondaryLabel
        dateLabel.accessibilityTraits = .header
        checkbox.setPreferredSymbolConfiguration(.init(pointSize: 24, weight: .regular), forImageIn: .normal)
        checkbox.addTarget(self, action: #selector(toggle), for: .touchUpInside)
        line.backgroundColor = .separator
        for child in [line, dateLabel, checkbox] { addSubview(child) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        line.frame = CGRect(x: 8, y: 0, width: max(0, bounds.width - 16), height: 1 / traitCollection.displayScale)
        checkbox.bounds = CGRect(x: 0, y: 0, width: 44, height: 44)
        if contentRotation == 0 {
            let geometry = Self.portraitGeometry(title: dateLabel.text ?? "", width: bounds.width, font: dateLabel.font, controlsSize: controlsSize)
            let height = max(1, bounds.height - geometry.top)
            dateLabel.bounds = CGRect(x: 0, y: 0, width: geometry.textWidth, height: height)
            dateLabel.center = CGPoint(x: 60 + dateLabel.bounds.width / 2, y: geometry.top + height / 2)
            checkbox.center = CGPoint(x: 30, y: dateLabel.center.y)
        } else {
            let width = max(1, bounds.height - 24)
            let height = min(bounds.width - 72, ceil(dateLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height))
            dateLabel.bounds = CGRect(x: 0, y: 0, width: width, height: max(1, height))
            dateLabel.center = CGPoint(x: contentRotation > 0 ? 60 + dateLabel.bounds.height / 2 : bounds.width - 60 - dateLabel.bounds.height / 2,
                                      y: bounds.midY)
            checkbox.center = CGPoint(x: contentRotation > 0 ? 30 : max(22, bounds.width - 30), y: bounds.midY)
        }
    }

    func configure(date: Date, selectedCount: Int, totalCount: Int, rotation: CGFloat, controlsSize: CGSize = .zero, onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
        contentRotation = rotation
        self.controlsSize = controlsSize
        dateLabel.transform = CGAffineTransform(rotationAngle: rotation)
        checkbox.transform = CGAffineTransform(rotationAngle: rotation)
        dateLabel.font = .preferredFont(forTextStyle: .subheadline, compatibleWith: traitCollection)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = .current
        let title = Self.title(for: date)
        dateLabel.text = title
        let all = selectedCount == totalCount
        let partial = selectedCount > 0 && !all
        let colors = UIImage.SymbolConfiguration(paletteColors: all ? [.white, .systemBlue] : [.white.withAlphaComponent(0.75), .systemGray3])
        checkbox.setImage(UIImage(systemName: "checkmark.circle.fill", withConfiguration: colors), for: .normal)
        checkbox.accessibilityLabel = "Select photos for \(title)"
        checkbox.accessibilityValue = all ? "Checked" : partial ? "Partially selected" : "Unchecked"
        checkbox.accessibilityHint = all ? "Deselect all photos for this day" : "Select all photos for this day"
        checkbox.accessibilityTraits = all ? [.button, .selected] : [.button]
        formatter.dateFormat = "yyyy-MM-dd"
        checkbox.accessibilityIdentifier = "grid.day.\(formatter.string(from: date))"
        setNeedsLayout()
    }
    @objc private func toggle() { onToggle() }
}

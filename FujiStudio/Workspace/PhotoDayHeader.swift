import UIKit

@MainActor
final class PhotoDayHeader: UICollectionReusableView {
    private let dateLabel = UILabel()
    private let checkbox = UIButton(type: .system)
    private let line = UIView()
    private var onToggle: () -> Void = {}
    private var contentRotation: CGFloat = 0

    static func height(date: Date, width: CGFloat, rotation: CGFloat, traits: UITraitCollection) -> CGFloat {
        let font = UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traits)
        let title = title(for: date)
        if rotation != 0 {
            // The tray becomes a side panel. Keep its date upright, wrapping into a compact column.
            let widestWord = title.split(separator: " ").map { (String($0) as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
            return max(88, ceil(widestWord) + 24)
        }
        let text = (title as NSString).boundingRect(with: CGSize(width: max(1, width - 72), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font], context: nil)
        return max(44, ceil(text.height) + 20)
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
        checkbox.setPreferredSymbolConfiguration(.init(pointSize: 22, weight: .regular), forImageIn: .normal)
        checkbox.addTarget(self, action: #selector(toggle), for: .touchUpInside)
        line.backgroundColor = .separator
        for child in [line, dateLabel, checkbox] { addSubview(child) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        line.frame = CGRect(x: 8, y: 0, width: max(0, bounds.width - 16), height: 1 / traitCollection.displayScale)
        checkbox.bounds = CGRect(x: 0, y: 0, width: 44, height: 44)
        checkbox.center = CGPoint(x: max(22, bounds.width - 30), y: bounds.midY)
        if contentRotation == 0 {
            dateLabel.bounds = CGRect(x: 0, y: 0, width: max(0, bounds.width - 72), height: bounds.height)
            dateLabel.center = CGPoint(x: 12 + dateLabel.bounds.width / 2, y: bounds.midY)
        } else {
            let width = max(1, bounds.height - 24)
            let height = min(bounds.width - 72, ceil(dateLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height))
            dateLabel.bounds = CGRect(x: 0, y: 0, width: width, height: max(1, height))
            dateLabel.center = CGPoint(x: 12 + dateLabel.bounds.height / 2, y: bounds.midY)
        }
    }

    func configure(date: Date, selectedCount: Int, totalCount: Int, rotation: CGFloat, onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
        contentRotation = rotation
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
        checkbox.setImage(UIImage(systemName: all ? "checkmark.square.fill" : partial ? "minus.square" : "square"), for: .normal)
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

import UIKit

final class GalleryWorkCell: UICollectionViewCell {
    private let imgV = UIImageView()
    private let durationLabel = UILabel()
    private let dateLabel = UILabel()
    private let infoGradient = CAGradientLayer()
    private var previewTask: Task<Void, Never>?
    private var representedURL: URL?

    deinit { previewTask?.cancel() }

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .white
        contentView.layer.cornerRadius = 16; contentView.clipsToBounds = true
        contentView.layer.borderWidth = 1; contentView.layer.borderColor = UIColor.systemGray6.cgColor

        imgV.contentMode = .scaleAspectFill; imgV.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(imgV)

        // Gradient overlay at the bottom to make text readable
        infoGradient.colors = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.4).cgColor]
        imgV.layer.addSublayer(infoGradient)

        durationLabel.font = .systemFont(ofSize: 10, weight: .bold)
        durationLabel.textColor = .white
        durationLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(durationLabel)

        dateLabel.font = .systemFont(ofSize: 10, weight: .medium)
        dateLabel.textColor = .white.withAlphaComponent(0.9)
        dateLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(dateLabel)

        NSLayoutConstraint.activate([
            imgV.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 3),
            imgV.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 3),
            imgV.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -3),
            imgV.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -3),

            durationLabel.trailingAnchor.constraint(equalTo: imgV.trailingAnchor, constant: -6),
            durationLabel.bottomAnchor.constraint(equalTo: imgV.bottomAnchor, constant: -6),

            dateLabel.leadingAnchor.constraint(equalTo: imgV.leadingAnchor, constant: 6),
            dateLabel.bottomAnchor.constraint(equalTo: imgV.bottomAnchor, constant: -6)
        ])
        imgV.layer.cornerRadius = 13; imgV.clipsToBounds = true
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 禁用隐式动画，防止阴影在首次展示或布局变化时出现滑动/变形动效
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        infoGradient.frame = CGRect(x: 0, y: imgV.bounds.height * 0.6,
                                   width: imgV.bounds.width, height: imgV.bounds.height * 0.4)
        CATransaction.commit()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        previewTask?.cancel()
        previewTask = nil
        representedURL = nil
        imgV.image = nil
        durationLabel.text = nil
        dateLabel.text = nil
    }

    func configure(url: URL, cache: WorkPreviewCache = .shared) {
        previewTask?.cancel()
        representedURL = url
        imgV.image = nil
        durationLabel.text = nil
        dateLabel.text = nil
        previewTask = Task { [weak self] in
            guard let preview = try? await cache.preview(for: url), !Task.isCancelled,
                  let self, self.representedURL == url else { return }
            self.imgV.image = preview.thumbnail
            self.durationLabel.text = preview.durationText
            self.dateLabel.text = preview.dateText
            self.previewTask = nil
        }
    }
    required init?(coder: NSCoder) { fatalError() }
}

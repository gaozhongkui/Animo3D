//
//  ProfileViewController.swift
//  Animo3D
//
//  「我的」页用 UIKit 实现（作品网格 + 设置列表）。
//  SwiftUI 列表在本项目里踩坑较多，这里改用 UICollectionView + 组合布局，稳定可控。
//

import UIKit
import SwiftUI

nonisolated enum ProfileSection: Int, CaseIterable { case pro, works, more }
nonisolated enum ProfileItem: Hashable, Sendable {
    case pro
    case empty
    case work(URL)
    case setting(id: String, icon: String, color: UInt, title: String, subtitle: String)
}

final class ProfileViewController: UIViewController {

    private typealias Section = ProfileSection
    private typealias Item = ProfileItem

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "我的"
        view.backgroundColor = .systemBackground
        setupCollectionView()
        setupDataSource()
        reload()
        NotificationCenter.default.addObserver(self, selector: #selector(reload),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        WorksStore.shared.reload()
        reload()
    }

    // MARK: Layout（每节不同：作品=网格，更多=系统 inset 列表）
    private func setupCollectionView() {
        let layout = UICollectionViewCompositionalLayout { [weak self] index, env in
            guard let self else { return nil }
            let section = Section(rawValue: index)!
            switch section {
            case .pro:
                let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(150)))
                let group = NSCollectionLayoutGroup.vertical(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(150)), subitems: [item])
                let s = NSCollectionLayoutSection(group: group)
                s.contentInsets = .init(top: 12, leading: 16, bottom: 16, trailing: 16)
                return s
            case .works:
                if WorksStore.shared.works.isEmpty {
                    // 空状态：整块一个大 cell
                    let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(220)))
                    let group = NSCollectionLayoutGroup.vertical(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(220)), subitems: [item])
                    let s = NSCollectionLayoutSection(group: group)
                    s.contentInsets = .init(top: 8, leading: 16, bottom: 24, trailing: 16)
                    s.boundarySupplementaryItems = [Self.header()]
                    return s
                }
                let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(0.5), heightDimension: .fractionalHeight(1)))
                item.contentInsets = .init(top: 6, leading: 6, bottom: 6, trailing: 6)
                let group = NSCollectionLayoutGroup.horizontal(
                    layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(300)),
                    subitems: [item, item])
                let s = NSCollectionLayoutSection(group: group)
                s.contentInsets = .init(top: 4, leading: 10, bottom: 24, trailing: 10)
                s.boundarySupplementaryItems = [Self.header()]
                return s
            case .more:
                var cfg = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
                cfg.headerMode = .supplementary
                return NSCollectionLayoutSection.list(using: cfg, layoutEnvironment: env)
            }
        }
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .systemBackground
        collectionView.delegate = self
        view.addSubview(collectionView)
    }

    private static func header() -> NSCollectionLayoutBoundarySupplementaryItem {
        NSCollectionLayoutBoundarySupplementaryItem(
            layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(40)),
            elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)
    }

    // MARK: Data source
    private func setupDataSource() {
        // Pro 订阅横幅
        let proReg = UICollectionView.CellRegistration<ProCell, Item> { cell, _, _ in
            cell.onTap = { [weak self] in self?.openPaywall() }
        }
        // 作品 cell
        let workReg = UICollectionView.CellRegistration<WorkCell, URL> { cell, _, url in
            cell.configure(url: url)
        }
        // 空状态 cell
        let emptyReg = UICollectionView.CellRegistration<EmptyWorksCell, Item> { [weak self] cell, _, _ in
            cell.onTap = { self?.openStudio() }
        }
        // 设置行
        let settingReg = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { cell, _, item in
            guard case let .setting(_, icon, color, title, subtitle) = item else { return }
            cell.contentConfiguration = Self.iconConfig(icon: icon, color: UIColor(rgb: color),
                                                        title: title, subtitle: subtitle)
            cell.accessories = [.disclosureIndicator()]
        }

        dataSource = .init(collectionView: collectionView) { cv, indexPath, item in
            switch item {
            case .pro:              return cv.dequeueConfiguredReusableCell(using: proReg, for: indexPath, item: item)
            case .empty:            return cv.dequeueConfiguredReusableCell(using: emptyReg, for: indexPath, item: item)
            case .work(let url):    return cv.dequeueConfiguredReusableCell(using: workReg, for: indexPath, item: url)
            case .setting:          return cv.dequeueConfiguredReusableCell(using: settingReg, for: indexPath, item: item)
            }
        }

        // 头部标题
        let headerReg = UICollectionView.SupplementaryRegistration<TitleHeader>(elementKind: UICollectionView.elementKindSectionHeader) { header, _, indexPath in
            header.label.text = Section(rawValue: indexPath.section) == .works ? "我的作品" : "更多"
        }
        dataSource.supplementaryViewProvider = { cv, kind, indexPath in
            cv.dequeueConfiguredReusableSupplementary(using: headerReg, for: indexPath)
        }
    }

    private static func iconConfig(icon: String, color: UIColor, title: String, subtitle: String) -> UIContentConfiguration {
        var c = UIListContentConfiguration.subtitleCell()
        c.text = title
        c.secondaryText = subtitle
        c.image = roundedIcon(system: icon, bg: color)
        c.imageProperties.reservedLayoutSize = CGSize(width: 40, height: 40)
        c.imageToTextPadding = 14
        return c
    }

    private static func roundedIcon(system: String, bg: UIColor) -> UIImage {
        let size = CGSize(width: 34, height: 34)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let path = UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 9)
            bg.setFill(); path.fill()
            let cfg = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
            if let sym = UIImage(systemName: system, withConfiguration: cfg)?.withTintColor(.white, renderingMode: .alwaysOriginal) {
                let r = CGRect(x: (size.width - 20)/2, y: (size.height - 20)/2, width: 20, height: 20)
                sym.draw(in: r)
            }
        }
    }

    @objc private func reload() {
        var snap = NSDiffableDataSourceSnapshot<Section, Item>()
        snap.appendSections([.pro, .works, .more])
        snap.appendItems([.pro], toSection: .pro)
        let works = WorksStore.shared.works
        snap.appendItems(works.isEmpty ? [.empty] : works.map { .work($0) }, toSection: .works)
        snap.appendItems([
            .setting(id: "about",  icon: "info.circle.fill",    color: 0x8E8E93, title: "关于 Animo3D", subtitle: "版本 1.0"),
        ], toSection: .more)
        dataSource.apply(snap, animatingDifferences: false)
    }

    // MARK: Actions
    private func openStudio() {
        let host = UIHostingController(rootView: StudioModal { [weak self] in self?.dismiss(animated: true) })
        host.modalPresentationStyle = .fullScreen
        present(host, animated: true)
    }
    private func shareWork(_ url: URL) {
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        vc.popoverPresentationController?.sourceView = view
        present(vc, animated: true)
    }
    private func openPaywall() {
        let host = UIHostingController(rootView: PaywallView { [weak self] in self?.dismiss(animated: true) })
        present(host, animated: true)
    }
}

extension ProfileViewController: UICollectionViewDelegate {
    func collectionView(_ cv: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        cv.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        switch item {
        case .pro: openPaywall()
        case .work(let url): shareWork(url)
        case .setting: break
        case .empty: break
        }
    }
}

// MARK: - Cells

private final class ProCell: UICollectionViewCell {
    var onTap: (() -> Void)?
    private let gradient = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.layer.cornerRadius = 18
        contentView.layer.cornerCurve = .continuous
        contentView.clipsToBounds = true

        gradient.colors = [UIColor(rgb: 0x7C3AED).cgColor, UIColor(rgb: 0xDB2777).cgColor]
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        contentView.layer.insertSublayer(gradient, at: 0)

        let crown = UIImageView(image: UIImage(systemName: "crown.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 26, weight: .semibold)))
        crown.tintColor = .white

        let title = UILabel()
        title.text = "Animo3D Pro"
        title.font = .systemFont(ofSize: 20, weight: .bold)
        title.textColor = .white

        let sub = UILabel()
        sub.text = "解锁全部角色与舞蹈 · 无水印 · 高清导出"
        sub.font = .systemFont(ofSize: 13)
        sub.textColor = UIColor.white.withAlphaComponent(0.9)
        sub.numberOfLines = 2

        let btn = UILabel()
        btn.text = "立即订阅"
        btn.font = .systemFont(ofSize: 14, weight: .semibold)
        btn.textColor = UIColor(rgb: 0x7C3AED)
        btn.textAlignment = .center
        btn.backgroundColor = .white
        btn.layer.cornerRadius = 15
        btn.clipsToBounds = true
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.widthAnchor.constraint(equalToConstant: 96).isActive = true
        btn.heightAnchor.constraint(equalToConstant: 30).isActive = true

        let text = UIStackView(arrangedSubviews: [title, sub])
        text.axis = .vertical; text.spacing = 4
        let top = UIStackView(arrangedSubviews: [crown, text])
        top.axis = .horizontal; top.spacing = 12; top.alignment = .center

        let stack = UIStackView(arrangedSubviews: [top, btn])
        stack.axis = .vertical; stack.spacing = 14; stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -18),
        ])

        contentView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func tapped() { onTap?() }
    override func layoutSubviews() { super.layoutSubviews(); gradient.frame = contentView.bounds }
}

private final class WorkCell: UICollectionViewCell {
    private let imageView = UIImageView()
    private let badge = UIImageView(image: UIImage(systemName: "square.and.arrow.up"))
    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.layer.cornerRadius = 14
        contentView.layer.cornerCurve = .continuous
        contentView.clipsToBounds = true
        contentView.backgroundColor = .secondarySystemBackground
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.frame = contentView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(imageView)
        badge.tintColor = .white
        badge.contentMode = .center
        badge.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        badge.frame = CGRect(x: 0, y: 0, width: 30, height: 30)
        badge.layer.cornerRadius = 15
        contentView.addSubview(badge)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() {
        super.layoutSubviews()
        badge.frame.origin = CGPoint(x: contentView.bounds.width - 38, y: contentView.bounds.height - 38)
    }
    func configure(url: URL) {
        imageView.image = WorksStore.shared.thumbnail(for: url)
    }
    override func prepareForReuse() { super.prepareForReuse(); imageView.image = nil }
}

private final class EmptyWorksCell: UICollectionViewCell {
    var onTap: (() -> Void)?
    private let button = UIButton(type: .system)
    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .secondarySystemBackground
        contentView.layer.cornerRadius = 16
        contentView.layer.cornerCurve = .continuous

        let icon = UIImageView(image: UIImage(systemName: "film.stack",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 38, weight: .regular)))
        icon.tintColor = .tintColor
        let title = UILabel(); title.text = "还没有作品"; title.font = .systemFont(ofSize: 15, weight: .medium)
        let sub = UILabel(); sub.text = "去创作里录一段角色跳舞吧"; sub.font = .systemFont(ofSize: 12); sub.textColor = .secondaryLabel

        var bc = UIButton.Configuration.filled()
        bc.title = "去跳舞"
        bc.image = UIImage(systemName: "play.fill")
        bc.imagePadding = 6
        bc.cornerStyle = .capsule
        button.configuration = bc
        button.addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [icon, title, sub, button])
        stack.axis = .vertical; stack.alignment = .center; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 36),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -36),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

private final class TitleHeader: UICollectionReusableView {
    let label = UILabel()
    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 20, weight: .bold)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - SwiftUI 挂载

/// SwiftUI 壳：把 UIKit 的「我的」包进导航控制器。
struct ProfileView: View {
    var body: some View {
        ProfileNav().ignoresSafeArea()
    }
}

private struct ProfileNav: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UINavigationController {
        let nav = UINavigationController(rootViewController: ProfileViewController())
        nav.navigationBar.prefersLargeTitles = true
        return nav
    }
    func updateUIViewController(_ vc: UINavigationController, context: Context) {}
}

/// 工作室的全屏包装（供 UIKit present）。
private struct StudioModal: View {
    let onClose: () -> Void
    var body: some View {
        NavigationStack {
            DanceStudioView().toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.body.weight(.semibold)).foregroundStyle(.primary)
                    }
                }
            }
        }
    }
}

private extension UIColor {
    convenience init(rgb: UInt) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF)/255, green: CGFloat((rgb >> 8) & 0xFF)/255,
                  blue: CGFloat(rgb & 0xFF)/255, alpha: 1)
    }
}

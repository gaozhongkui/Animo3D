//
//  ProfileViewController.swift
//  Livo 3D
//
//  Me page: Clean, modern gallery style with a premium feel.
//

import UIKit
import SwiftUI

nonisolated enum ProfileSection: Int, CaseIterable { case header, pro, works, more }
nonisolated enum ProfileItem: Hashable, Sendable {
    case header(name: String, bio: String, avatar: String)
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
        view.backgroundColor = .systemBackground
        setupCollectionView()
        setupDataSource()
        reload()

        NotificationCenter.default.addObserver(self, selector: #selector(reload),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
        WorksStore.shared.reload()
        reload()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    private func setupCollectionView() {
        let layout = UICollectionViewCompositionalLayout { [weak self] index, _ in
            guard let self = self else { return nil }
            let section = Section(rawValue: index)!

            switch section {
            case .header:
                let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(360))
                return NSCollectionLayoutSection(group: NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)]))

            case .pro:
                let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(100))
                let s = NSCollectionLayoutSection(group: NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)]))
                s.contentInsets = .init(top: 0, leading: 20, bottom: 32, trailing: 20)
                return s

            case .works:
                if WorksStore.shared.works.isEmpty {
                    let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(200))
                    let s = NSCollectionLayoutSection(group: NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)]))
                    s.contentInsets = .init(top: 0, leading: 20, bottom: 20, trailing: 20)
                    s.boundarySupplementaryItems = [Self.createHeader("My Creations")]
                    return s
                }
                let itemSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(0.5), heightDimension: .fractionalHeight(1))
                let item = NSCollectionLayoutItem(layoutSize: itemSize)
                item.contentInsets = .init(top: 8, leading: 8, bottom: 8, trailing: 8)
                let groupSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(240))
                let s = NSCollectionLayoutSection(group: NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item, item]))
                s.contentInsets = .init(top: 4, leading: 12, bottom: 32, trailing: 12)
                s.boundarySupplementaryItems = [Self.createHeader("My Creations")]
                return s

            case .more:
                let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(52))
                let s = NSCollectionLayoutSection(group: NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)]))
                s.contentInsets = .init(top: 0, leading: 20, bottom: 120, trailing: 20)
                s.interGroupSpacing = 0
                s.boundarySupplementaryItems = [Self.createHeader("Settings")]
                return s
            }
        }

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.backgroundColor = .systemBackground
        collectionView.delegate = self
        view.addSubview(collectionView)

        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private static func createHeader(_ title: String) -> NSCollectionLayoutBoundarySupplementaryItem {
        NSCollectionLayoutBoundarySupplementaryItem(
            layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(50)),
            elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)
    }

    private func setupDataSource() {
        let headerReg = UICollectionView.CellRegistration<CleanHeaderCell, Item> { cell, _, item in
            if case let .header(n, b, _) = item { cell.configure(name: n, bio: b) }
        }
        let proReg = UICollectionView.CellRegistration<ModernProCell, Item> { cell, _, _ in
            cell.onTap = { [weak self] in self?.openPaywall() }
        }
        let workReg = UICollectionView.CellRegistration<GalleryWorkCell, URL> { cell, _, url in
            cell.configure(url: url)
        }
        let emptyReg = UICollectionView.CellRegistration<EmptyWorksCell, Item> { [weak self] cell, _, _ in
            cell.onTap = { self?.openStudio() }
        }
        let settingReg = UICollectionView.CellRegistration<CleanSettingCell, Item> { cell, _, item in
            if case let .setting(_, icon, color, title, subtitle) = item {
                cell.configure(icon: icon, color: UIColor(rgb: color), title: title, sub: subtitle)
            }
        }

        dataSource = .init(collectionView: collectionView) { cv, indexPath, item in
            switch item {
            case .header: return cv.dequeueConfiguredReusableCell(using: headerReg, for: indexPath, item: item)
            case .pro:    return cv.dequeueConfiguredReusableCell(using: proReg, for: indexPath, item: item)
            case .empty:  return cv.dequeueConfiguredReusableCell(using: emptyReg, for: indexPath, item: item)
            case .work(let url): return cv.dequeueConfiguredReusableCell(using: workReg, for: indexPath, item: url)
            case .setting: return cv.dequeueConfiguredReusableCell(using: settingReg, for: indexPath, item: item)
            }
        }

        let titleReg = UICollectionView.SupplementaryRegistration<TitleHeader>(elementKind: UICollectionView.elementKindSectionHeader) { h, _, ip in
            let sec = Section(rawValue: ip.section)
            h.label.text = (sec == .works) ? "My Creations" : ((sec == .more) ? "Settings" : "")
        }
        dataSource.supplementaryViewProvider = { cv, kind, ip in
            cv.dequeueConfiguredReusableSupplementary(using: titleReg, for: ip)
        }
    }

    static func roundedIcon(system: String, bg: UIColor) -> UIImage {
        let size = CGSize(width: 32, height: 32)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 9).addClip()
            bg.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            let cfg = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            if let img = UIImage(systemName: system, withConfiguration: cfg)?.withTintColor(.white, renderingMode: .alwaysOriginal) {
                img.draw(in: CGRect(x: (size.width-16)/2, y: (size.height-16)/2, width: 16, height: 16))
            }
        }
    }

    @objc private func reload() {
        var snap = NSDiffableDataSourceSnapshot<Section, Item>()
        snap.appendSections([.header, .pro, .works, .more])
        snap.appendItems([.header(name: "Livo Creator", bio: "Exploring the infinity of 3D motion ✨", avatar: "")], toSection: .header)
        snap.appendItems([.pro], toSection: .pro)
        let works = WorksStore.shared.works
        snap.appendItems(works.isEmpty ? [.empty] : works.map { .work($0) }, toSection: .works)
        snap.appendItems([
            .setting(id: "pro", icon: "crown.fill", color: 0xFF9500, title: "Subscription", subtitle: "Manage Perks"),
            .setting(id: "cache", icon: "trash.fill", color: 0xFF3B30, title: "Clear Cache", subtitle: StorageManager.getCacheSize()),
            .setting(id: "about", icon: "info.circle.fill", color: 0x007AFF, title: "About Livo", subtitle: "v1.0.0"),
        ], toSection: .more)
        dataSource.apply(snap, animatingDifferences: false)
    }

    private func openStudio() {
        let host = UIHostingController(rootView: StudioModal { [weak self] in self?.dismiss(animated: true) })
        host.modalPresentationStyle = .fullScreen
        present(host, animated: true)
    }
    private func openWork(_ url: URL) {
        let host = UIHostingController(rootView: WorkDetailView(url: url) { [weak self] in self?.dismiss(animated: true) })
        host.modalPresentationStyle = .fullScreen
        present(host, animated: true)
    }
    private func openPaywall() {
        let host = UIHostingController(rootView: PaywallView { [weak self] in self?.dismiss(animated: true) })
        present(host, animated: true)
    }
}

extension ProfileViewController: UICollectionViewDelegate {
    func collectionView(_ cv: UICollectionView, didSelectItemAt ip: IndexPath) {
        cv.deselectItem(at: ip, animated: true)
        guard let item = dataSource.itemIdentifier(for: ip) else { return }
        switch item {
        case .pro: openPaywall()
        case .work(let url): openWork(url)
        case .setting(let id, _, _, _, _):
            if id == "cache" {
                HapticManager.medium()
                StorageManager.clearCache()
                HapticManager.success()
                reload()
            }
        default: break
        }
    }
}

// MARK: - Cells

private final class CleanHeaderCell: UICollectionViewCell {
    private let meshBg = UIView()
    private let neonRing = UIView()
    private let avatarContainer = UIView()
    private let avatarGradient = CAGradientLayer()
    private let avatarSymbol = UIImageView(image: UIImage(systemName: "figure.dance"))
    private let glassOverlay = UIView()

    private let nameLabel = UILabel()
    private let bioLabel = UILabel()
    private let statsStack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)

        meshBg.backgroundColor = UIColor(rgb: 0x6366F1).withAlphaComponent(0.08)
        meshBg.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(meshBg)

        let grad = CAGradientLayer()
        grad.colors = [UIColor(rgb: 0x6366F1).withAlphaComponent(0.12).cgColor, UIColor.white.cgColor]
        grad.frame = CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 360)
        meshBg.layer.addSublayer(grad)

        neonRing.layer.cornerRadius = 56
        neonRing.layer.borderWidth = 1.5
        neonRing.layer.borderColor = UIColor(rgb: 0x6366F1).withAlphaComponent(0.3).cgColor
        neonRing.layer.shadowColor = UIColor(rgb: 0x6366F1).cgColor
        neonRing.layer.shadowOffset = .zero
        neonRing.layer.shadowRadius = 10
        neonRing.layer.shadowOpacity = 0.3
        neonRing.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(neonRing)

        avatarContainer.layer.cornerRadius = 50; avatarContainer.clipsToBounds = true
        avatarContainer.backgroundColor = .white; avatarContainer.layer.borderWidth = 2; avatarContainer.layer.borderColor = UIColor.white.cgColor
        avatarContainer.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(avatarContainer)

        avatarGradient.colors = [UIColor(rgb: 0x4F46E5).cgColor, UIColor(rgb: 0xA855F7).cgColor]
        avatarGradient.startPoint = .zero; avatarGradient.endPoint = CGPoint(x: 1, y: 1)
        avatarGradient.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        avatarContainer.layer.addSublayer(avatarGradient)

        avatarSymbol.tintColor = .white; avatarSymbol.contentMode = .scaleAspectFit
        avatarSymbol.preferredSymbolConfiguration = .init(pointSize: 42, weight: .bold)
        avatarSymbol.translatesAutoresizingMaskIntoConstraints = false
        avatarContainer.addSubview(avatarSymbol)

        glassOverlay.backgroundColor = .clear
        let glassGrad = CAGradientLayer()
        glassGrad.colors = [UIColor.white.withAlphaComponent(0.4).cgColor, UIColor.clear.cgColor]
        glassGrad.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        glassGrad.startPoint = .zero; glassGrad.endPoint = CGPoint(x: 0.5, y: 0.5)
        glassOverlay.layer.addSublayer(glassGrad)
        glassOverlay.translatesAutoresizingMaskIntoConstraints = false
        avatarContainer.addSubview(glassOverlay)

        nameLabel.font = .roundedFont(ofSize: 28, weight: .black); nameLabel.textAlignment = .center
        nameLabel.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview(nameLabel)

        bioLabel.font = .systemFont(ofSize: 14); bioLabel.textColor = .secondaryLabel; bioLabel.textAlignment = .center
        bioLabel.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview(bioLabel)

        setupStats()

        NSLayoutConstraint.activate([
            meshBg.topAnchor.constraint(equalTo: contentView.topAnchor),
            meshBg.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            meshBg.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            meshBg.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            neonRing.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            neonRing.centerYAnchor.constraint(equalTo: avatarContainer.centerYAnchor),
            neonRing.widthAnchor.constraint(equalToConstant: 112),
            neonRing.heightAnchor.constraint(equalToConstant: 112),

            avatarContainer.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            avatarContainer.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 80),
            avatarContainer.widthAnchor.constraint(equalToConstant: 100),
            avatarContainer.heightAnchor.constraint(equalToConstant: 100),

            avatarSymbol.centerXAnchor.constraint(equalTo: avatarContainer.centerXAnchor),
            avatarSymbol.centerYAnchor.constraint(equalTo: avatarContainer.centerYAnchor),

            glassOverlay.topAnchor.constraint(equalTo: avatarContainer.topAnchor),
            glassOverlay.leadingAnchor.constraint(equalTo: avatarContainer.leadingAnchor),
            glassOverlay.trailingAnchor.constraint(equalTo: avatarContainer.trailingAnchor),
            glassOverlay.bottomAnchor.constraint(equalTo: avatarContainer.bottomAnchor),

            nameLabel.topAnchor.constraint(equalTo: avatarContainer.bottomAnchor, constant: 24),
            nameLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),

            bioLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 6),
            bioLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),

            statsStack.topAnchor.constraint(equalTo: bioLabel.bottomAnchor, constant: 32),
            statsStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 40),
            statsStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -40)
        ])
    }

    private func setupStats() {
        statsStack.axis = .horizontal; statsStack.distribution = .fillEqually; statsStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(statsStack)
        statsStack.addArrangedSubview(statItem(v: "15", l: "Works"))
        statsStack.addArrangedSubview(statItem(v: "1.2k", l: "Likes"))
        statsStack.addArrangedSubview(statItem(v: "9", l: "Days"))
    }

    private func statItem(v: String, l: String) -> UIView {
        let view = UIView()
        let vL = UILabel(); vL.text = v; vL.font = .roundedFont(ofSize: 22, weight: .bold); vL.textAlignment = .center; vL.translatesAutoresizingMaskIntoConstraints = false
        let lL = UILabel(); lL.text = l; lL.font = .systemFont(ofSize: 12); lL.textColor = .secondaryLabel; lL.textAlignment = .center; lL.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(vL); view.addSubview(lL)
        NSLayoutConstraint.activate([
            vL.topAnchor.constraint(equalTo: view.topAnchor), vL.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            lL.topAnchor.constraint(equalTo: vL.bottomAnchor, constant: 4), lL.bottomAnchor.constraint(equalTo: view.bottomAnchor), lL.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        ])
        return view
    }
    func configure(name: String, bio: String) {
        nameLabel.text = name; bioLabel.text = bio
    }
    required init?(coder: NSCoder) { fatalError() }
}

private final class ModernProCell: UICollectionViewCell {
    var onTap: (() -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = UIColor(rgb: 0x1C1C1E)
        contentView.layer.cornerRadius = 22; contentView.clipsToBounds = true

        let crown = UIImageView(image: UIImage(systemName: "crown.fill"))
        crown.tintColor = UIColor(rgb: 0xFFD60A); crown.contentMode = .scaleAspectFit

        let title = UILabel(); title.text = "Upgrade Livo 3D Pro"; title.textColor = .white; title.font = .systemFont(ofSize: 17, weight: .bold)
        let sub = UILabel(); sub.text = "Unlock 4K exports and all characters"; sub.textColor = .systemGray; sub.font = .systemFont(ofSize: 13)

        let vStack = UIStackView(arrangedSubviews: [title, sub]); vStack.axis = .vertical; vStack.spacing = 2
        let hStack = UIStackView(arrangedSubviews: [crown, vStack]); hStack.axis = .horizontal; hStack.spacing = 16; hStack.alignment = .center
        hStack.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview(hStack)

        let arrow = UIImageView(image: UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(weight: .bold)))
        arrow.tintColor = .systemGray2; arrow.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview(arrow)

        NSLayoutConstraint.activate([
            hStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            hStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            crown.widthAnchor.constraint(equalToConstant: 26), crown.heightAnchor.constraint(equalToConstant: 26),
            arrow.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            arrow.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])
        contentView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(btnTap)))
    }
    @objc private func btnTap() { onTap?() }
    required init?(coder: NSCoder) { fatalError() }
}

private final class GalleryWorkCell: UICollectionViewCell {
    private let imgV = UIImageView()
    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .white
        contentView.layer.cornerRadius = 24; contentView.clipsToBounds = true
        contentView.layer.borderWidth = 1; contentView.layer.borderColor = UIColor.systemGray6.cgColor

        imgV.contentMode = .scaleAspectFill; imgV.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(imgV)
        NSLayoutConstraint.activate([
            imgV.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            imgV.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            imgV.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
            imgV.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4)
        ])
        imgV.layer.cornerRadius = 20; imgV.clipsToBounds = true
    }
    func configure(url: URL) { imgV.image = WorksStore.shared.thumbnail(for: url) }
    required init?(coder: NSCoder) { fatalError() }
}

private final class CleanSettingCell: UICollectionViewCell {
    private let iconV = UIImageView(); private let titleL = UILabel(); private let subL = UILabel()
    override init(frame: CGRect) {
        super.init(frame: frame)
        iconV.translatesAutoresizingMaskIntoConstraints = false; titleL.translatesAutoresizingMaskIntoConstraints = false; subL.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(iconV); contentView.addSubview(titleL); contentView.addSubview(subL)
        titleL.font = .systemFont(ofSize: 16, weight: .medium); subL.font = .systemFont(ofSize: 14); subL.textColor = .secondaryLabel
        NSLayoutConstraint.activate([
            iconV.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4), iconV.centerYAnchor.constraint(equalTo: contentView.centerYAnchor), iconV.widthAnchor.constraint(equalToConstant: 32), iconV.heightAnchor.constraint(equalToConstant: 32),
            titleL.leadingAnchor.constraint(equalTo: iconV.trailingAnchor, constant: 14), titleL.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            subL.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4), subL.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])
        let line = UIView(); line.backgroundColor = .systemGray6; line.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview(line)
        NSLayoutConstraint.activate([line.leadingAnchor.constraint(equalTo: titleL.leadingAnchor), line.trailingAnchor.constraint(equalTo: contentView.trailingAnchor), line.bottomAnchor.constraint(equalTo: contentView.bottomAnchor), line.heightAnchor.constraint(equalToConstant: 0.5)])
    }
    func configure(icon: String, color: UIColor, title: String, sub: String) {
        titleL.text = title; subL.text = sub; iconV.image = ProfileViewController.roundedIcon(system: icon, bg: color)
    }
    required init?(coder: NSCoder) { fatalError() }
}

private final class EmptyWorksCell: UICollectionViewCell {
    var onTap: (() -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.layer.cornerRadius = 24; contentView.backgroundColor = .systemGray6
        let l = UILabel(); l.text = "No Creations Yet"; l.font = .systemFont(ofSize: 15, weight: .medium); l.textColor = .secondaryLabel
        let b = UIButton(type: .system); b.setTitle("Start Recording", for: .normal); b.addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .touchUpInside)
        let s = UIStackView(arrangedSubviews: [l, b]); s.axis = .vertical; s.alignment = .center; s.spacing = 8; s.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview(s)
        NSLayoutConstraint.activate([s.centerXAnchor.constraint(equalTo: contentView.centerXAnchor), s.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)])
    }
    required init?(coder: NSCoder) { fatalError() }
}

private final class TitleHeader: UICollectionReusableView {
    let label = UILabel()
    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .roundedFont(ofSize: 20, weight: .bold); label.translatesAutoresizingMaskIntoConstraints = false; addSubview(label)
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4), label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)])
    }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - SwiftUI 挂载

struct ProfileView: View {
    var body: some View {
        ProfileNav().ignoresSafeArea()
    }
}

private struct ProfileNav: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UINavigationController {
        return UINavigationController(rootViewController: ProfileViewController())
    }
    func updateUIViewController(_ vc: UINavigationController, context: Context) {}
}

private struct StudioModal: View {
    let onClose: () -> Void
    var body: some View {
        NavigationStack {
            DanceStudioView().toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onClose) { Image(systemName: "xmark").font(.body.weight(.semibold)).foregroundStyle(.primary) }
                }
            }
        }
    }
}

//
//  DiscoverViewController.swift
//  Animo3D
//

import UIKit
import SwiftUI

final class DiscoverViewController: UIViewController {

    private var models: [SketchfabModel] = []
    private var collectionView: UICollectionView!
    private var activityIndicator: UIActivityIndicatorView!
    private let refreshControl = UIRefreshControl()

    private var nextUrl: String?
    private var isFetching = false
    private var currentQuery: String?

    var onModelSelected: ((SketchfabModel) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        // 使用标准的系统背景色，确保与 Navigation Bar 融合
        view.backgroundColor = .systemBackground
        setupCollectionView()
        setupActivityIndicator()
        loadInitialData()
    }

    private func setupCollectionView() {
        let layout = UICollectionViewCompositionalLayout { _, _ in
            let itemSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(0.5), heightDimension: .absolute(240))
            let item = NSCollectionLayoutItem(layoutSize: itemSize)
            item.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)

            let groupSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .absolute(240))
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])

            let section = NSCollectionLayoutSection(group: group)
            section.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
            return section
        }

        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.dataSource = self
        // 确保 CollectionView 能够正确处理 NavigationBar 和 SearchBar 的 safe area
        collectionView.contentInsetAdjustmentBehavior = .always
        collectionView.register(ModelCell.self, forCellWithReuseIdentifier: "ModelCell")

        refreshControl.addTarget(self, action: #selector(refreshData), for: .valueChanged)
        collectionView.refreshControl = refreshControl

        view.addSubview(collectionView)
    }

    private func setupActivityIndicator() {
        activityIndicator = UIActivityIndicatorView(style: .medium)
        activityIndicator.hidesWhenStopped = true
        view.addSubview(activityIndicator)
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    private func loadInitialData() {
        nextUrl = nil
        models = []
        collectionView.reloadData()
        fetchPage()
    }

    @objc private func refreshData() {
        nextUrl = nil
        fetchPage(isRefreshing: true)
    }

    func loadData(query: String? = nil, isRefreshing: Bool = false) {
        if query != currentQuery {
            currentQuery = query
            nextUrl = nil
            models = []
            collectionView.reloadData()
            fetchPage()
        }
    }

    private func fetchPage(isRefreshing: Bool = false) {
        guard !isFetching else { return }
        isFetching = true

        if models.isEmpty && !isRefreshing {
            activityIndicator.startAnimating()
        }

        Task {
            do {
                let resp = try await SketchfabClient.shared.fetchModels(query: currentQuery, nextUrl: nextUrl)
                await MainActor.run {
                    if self.nextUrl == nil {
                        self.models = resp.results
                    } else {
                        self.models.append(contentsOf: resp.results)
                    }
                    self.nextUrl = resp.next
                    self.collectionView.reloadData()
                    self.activityIndicator.stopAnimating()
                    self.refreshControl.endRefreshing()
                    self.isFetching = false
                }
            } catch {
                print("Fetch error: \(error)")
                await MainActor.run {
                    self.activityIndicator.stopAnimating()
                    self.refreshControl.endRefreshing()
                    self.isFetching = false
                }
            }
        }
    }
}

extension DiscoverViewController: UICollectionViewDataSource, UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return models.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "ModelCell", for: indexPath) as! ModelCell
        cell.configure(with: models[indexPath.item])
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        onModelSelected?(models[indexPath.item])
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let offsetY = scrollView.contentOffset.y
        let contentHeight = scrollView.contentSize.height
        let frameHeight = scrollView.frame.size.height

        if offsetY > contentHeight - frameHeight * 1.5, nextUrl != nil {
            fetchPage()
        }
    }
}

// MARK: - Cell
final class ModelCell: UICollectionViewCell {
    private let containerView = UIView()
    private let imageView = UIImageView()
    private let titleLabel = UILabel()
    private let infoLabel = UILabel()
    private let gradientLayer = CAGradientLayer()

    private var imageTask: URLSessionDataTask?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        // 卡片阴影
        contentView.backgroundColor = .clear
        containerView.backgroundColor = .secondarySystemGroupedBackground
        containerView.layer.cornerRadius = 18
        containerView.layer.shadowColor = UIColor.black.cgColor
        containerView.layer.shadowOpacity = 0.1
        containerView.layer.shadowOffset = CGSize(width: 0, height: 4)
        containerView.layer.shadowRadius = 10

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 18
        imageView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        imageView.backgroundColor = .secondarySystemBackground

        gradientLayer.colors = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.3).cgColor]
        gradientLayer.locations = [0.7, 1.0]
        imageView.layer.addSublayer(gradientLayer)

        titleLabel.font = .systemFont(ofSize: 15, weight: .bold)
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 2

        infoLabel.font = .systemFont(ofSize: 12, weight: .medium)
        infoLabel.textColor = .secondaryLabel

        contentView.addSubview(containerView)
        containerView.addSubview(imageView)
        containerView.addSubview(titleLabel)
        containerView.addSubview(infoLabel)

        containerView.translatesAutoresizingMaskIntoConstraints = false
        imageView.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        infoLabel.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            containerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            containerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            containerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            imageView.topAnchor.constraint(equalTo: containerView.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            imageView.heightAnchor.constraint(equalToConstant: 130),

            titleLabel.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -12),

            infoLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            infoLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 12),
            infoLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -12),
            infoLabel.bottomAnchor.constraint(lessThanOrEqualTo: containerView.bottomAnchor, constant: -12)
        ])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradientLayer.frame = imageView.bounds
    }

    func configure(with model: SketchfabModel) {
        titleLabel.text = model.name
        infoLabel.text = "❤️ \(model.likeCount.formattedAbbreviated)  👁️ \(model.viewCount.formattedAbbreviated)"

        imageView.image = nil
        imageTask?.cancel()

        if let url = model.bestThumbnail {
            imageTask = ImageLoader.shared.loadImage(from: url) { [weak self] image in
                self?.imageView.image = image
            }
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageView.image = nil
        imageTask?.cancel()
    }
}

// MARK: - SwiftUI Wrapper
struct DiscoverViewControllerRepresentable: UIViewControllerRepresentable {
    @Binding var searchText: String
    var onModelSelected: (SketchfabModel) -> Void

    func makeUIViewController(context: Context) -> DiscoverViewController {
        let vc = DiscoverViewController()
        vc.onModelSelected = onModelSelected
        return vc
    }

    func updateUIViewController(_ uiViewController: DiscoverViewController, context: Context) {
        uiViewController.loadData(query: searchText, isRefreshing: false)
    }
}

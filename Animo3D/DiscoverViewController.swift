//
//  DiscoverViewController.swift
//  Animo3D
//

import UIKit
import SwiftUI

final class DiscoverViewController: UIViewController {
    /// The width a card wants to be. The column count is whatever gets closest to it.
    private static let targetCellWidth: CGFloat = 190


    private var models: [SketchfabModel] = []
    private var collectionView: UICollectionView!
    private var activityIndicator: UIActivityIndicatorView!
    private let refreshControl = UIRefreshControl()
    private let bottomLoader = UIActivityIndicatorView(style: .medium)

    private var nextUrl: String?
    private var isFetching = false
    private var currentQuery: String?
    private var currentCategory: String?
    private var fetchTask: Task<Void, Never>?

    var onModelSelected: ((SketchfabModel) -> Void)?
    /// How many results are on screen, and whether a load is still in flight. The search screen
    /// needs both to tell "nothing matched" apart from "still looking", which from the outside are
    /// the same empty grid.
    var onResults: ((Int, Bool) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        // Use the standard system background color so it blends with the navigation bar
        view.backgroundColor = .systemBackground
        setupCollectionView()
        setupActivityIndicator()
        setupBottomLoader()
        loadInitialData()
    }

    private func setupBottomLoader() {
        bottomLoader.hidesWhenStopped = true
        bottomLoader.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bottomLoader)
        NSLayoutConstraint.activate([
            bottomLoader.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            bottomLoader.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12)
        ])
    }

    private func setupCollectionView() {
        // Columns come from the width available, not from a constant.
        //
        // This was `fractionalWidth(0.5)` with a flat 240pt row - two columns, whatever the device.
        // On an iPad that is two ~470pt-wide cells whose thumbnail is pinned to 130pt tall, so
        // every card is a squashed letterbox with an acre of empty space under the title. Aiming
        // for a cell about 190pt wide gives two columns on a phone exactly as before, and four to
        // six across an iPad - and it follows Split View and Stage Manager, because the layout
        // closure re-runs with the new container width rather than reading the screen.
        let layout = UICollectionViewCompositionalLayout { _, env in
            let outerInset: CGFloat = 10, itemInset: CGFloat = 10
            let available = max(1, env.container.effectiveContentSize.width - outerInset * 2)
            let columns = max(2, min(6, Int((available / Self.targetCellWidth).rounded())))
            // What the card itself gets, once its own insets are taken off.
            let cardWidth = available / CGFloat(columns) - itemInset * 2
            // Matches the aspect the cell pins its image view to; the two have to agree or the
            // title is clipped on one side and floats on the other.
            let rowHeight = (cardWidth * ModelCell.imageAspect + ModelCell.textBlockHeight
                             + itemInset * 2).rounded()

            let itemSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0 / CGFloat(columns)),
                                                  heightDimension: .absolute(rowHeight))
            let item = NSCollectionLayoutItem(layoutSize: itemSize)
            item.contentInsets = NSDirectionalEdgeInsets(top: itemInset, leading: itemInset,
                                                         bottom: itemInset, trailing: itemInset)

            let groupSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0),
                                                   heightDimension: .absolute(rowHeight))
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize,
                                                           repeatingSubitem: item, count: columns)

            let section = NSCollectionLayoutSection(group: group)
            section.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: outerInset,
                                                            bottom: 10, trailing: outerInset)
            return section
        }

        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.dataSource = self
        // Make sure the collection view handles the navigation bar and search bar safe area correctly
        collectionView.contentInsetAdjustmentBehavior = .always
        collectionView.register(ModelCell.self, forCellWithReuseIdentifier: "ModelCell")

        // Dismissing the keyboard is this view's job, not the search field's: the field is SwiftUI,
        // the results are UIKit, and a tap or a scroll over the results never reached SwiftUI at
        // all - so the keyboard stayed up over half the results with no way to put it away short of
        // opening a model.
        //
        // `.onDrag` covers scrolling. The tap recogniser covers a plain tap on the grid or on the
        // space around it, and `cancelsTouchesInView = false` is what keeps it from eating the tap
        // that opens a model - both happen, which is what a user expects from tapping a card while
        // the keyboard is up.
        collectionView.keyboardDismissMode = .onDrag
        let dismissTap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        dismissTap.cancelsTouchesInView = false
        collectionView.addGestureRecognizer(dismissTap)

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
        // Cached page first, request second. This controller is rebuilt on every switch onto the
        // tab, and clearing the array here meant every switch flashed an empty grid with a spinner
        // over content the user had just been looking at.
        showCachedPage()
        fetchPage()
    }

    /// Put whatever is cached for the current query/category on screen immediately.
    ///
    /// Returns whether anything was shown, which is what decides between a full-screen spinner and
    /// a silent refresh underneath existing content.
    @discardableResult
    private func showCachedPage() -> Bool {
        let key = DiscoverFeedCache.key(query: currentQuery, category: currentCategory)
        guard let page = DiscoverFeedCache.shared.page(for: key) else {
            models = []
            collectionView.reloadData()
            onResults?(0, true)
            return false
        }
        models = page.models
        nextUrl = page.nextUrl
        collectionView.reloadData()
        onResults?(models.count, false)
        return true
    }

    @objc private func dismissKeyboard() {
        view.window?.endEditing(true)
    }

    @objc private func refreshData() {
        nextUrl = nil
        fetchPage(isRefreshing: true)
    }

    func loadData(query: String? = nil, category: String? = nil, isRefreshing: Bool = false) {
        let cleanQuery = query?.trimmingCharacters(in: .whitespaces) ?? ""
        let hasQueryChanged = cleanQuery != (currentQuery ?? "")
        let hasCategoryChanged = category != currentCategory

        if hasQueryChanged || hasCategoryChanged {
            currentQuery = cleanQuery
            currentCategory = category

            // Cancel the in-flight load immediately, so the new category request wins
            fetchTask?.cancel()
            nextUrl = nil
            // Each query/category has its own cache slot, so switching category can also show
            // something straight away rather than blanking the grid.
            showCachedPage()
            fetchPage()
        }
    }

    private func fetchPage(isRefreshing: Bool = false) {
        guard !isFetching || fetchTask != nil else { return }

        if isFetching {
            fetchTask?.cancel()
        }

        isFetching = true

        let requestingNext = nextUrl
        // The full-screen indicator is only for an empty grid. With a cached page showing, the
        // refresh happens underneath it - covering content the user is already reading with a
        // spinner is the thing this whole change is meant to stop.
        if models.isEmpty && !isRefreshing {
            activityIndicator.startAnimating()
        } else if requestingNext != nil {
            bottomLoader.startAnimating()
        }

        fetchTask = Task {
            do {
                let resp = try await SketchfabClient.shared.fetchModels(query: currentQuery, category: currentCategory, nextUrl: requestingNext)

                // Check whether the task has already been cancelled
                if Task.isCancelled { return }

                await MainActor.run {
                    if requestingNext == nil {
                        self.models = resp.results
                        // Only the first page is cached; later pages are scroll state, not the
                        // thing that has to be on screen the instant the tab appears.
                        DiscoverFeedCache.shared.store(
                            models: resp.results, nextUrl: resp.next,
                            for: DiscoverFeedCache.key(query: self.currentQuery,
                                                       category: self.currentCategory))
                    } else {
                        self.models.append(contentsOf: resp.results)
                    }
                    self.nextUrl = resp.next
                    self.collectionView.reloadData()
                    self.activityIndicator.stopAnimating()
                    self.bottomLoader.stopAnimating()
                    self.refreshControl.endRefreshing()
                    self.isFetching = false
                    self.fetchTask = nil
                    self.onResults?(self.models.count, false)
                }
            } catch {
                if !Task.isCancelled {
                    print("Fetch error: \(error)")
                    await MainActor.run {
                        self.activityIndicator.stopAnimating()
                        self.bottomLoader.stopAnimating()
                        self.refreshControl.endRefreshing()
                        self.isFetching = false
                        self.fetchTask = nil
                        self.onResults?(self.models.count, false)
                    }
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

        // Prefetch 2.5 screens ahead for smoother paging (it used to trigger only at the very bottom, which felt like "nothing is loading")
        if offsetY > contentHeight - frameHeight * 2.5, nextUrl != nil, !isFetching {
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
        // Card shadow
        contentView.backgroundColor = .clear
        containerView.backgroundColor = .secondarySystemGroupedBackground
        containerView.layer.cornerRadius = 18
        containerView.layer.shadowColor = UIColor.black.cgColor
        containerView.layer.shadowOpacity = 0.1
        containerView.layer.shadowOffset = CGSize(width: 0, height: 4)
        containerView.layer.shadowRadius = 10
        // The shape is set in layoutSubviews. Leaving `shadowPath` nil makes Core Animation derive
        // the shadow from the blurred alpha of the whole rendered subtree, which is why the cards
        // did not all have the same shadow: it changed shape at the image's bottom edge, and it was
        // recomputed whenever the layer's content changed - so a card's shadow visibly shifted the
        // moment its thumbnail arrived. It is also an offscreen pass per cell, every frame of a
        // scroll, for a shape that never varies.

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
            // An aspect ratio, not a constant. 130pt was right for the one cell width this grid
            // used to have; at any other width it is a letterbox. The layout computes the row
            // height from the same ratio.
            imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor,
                                              multiplier: ModelCell.imageAspect),

            titleLabel.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -12),

            infoLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            infoLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 12),
            infoLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -12),
            infoLabel.bottomAnchor.constraint(lessThanOrEqualTo: containerView.bottomAnchor, constant: -12)
        ])
    }

    /// Thumbnail height as a fraction of the card's width, and the space the two labels need
    /// under it (12 top + two lines of 15pt + 6 + one line of 12pt + 12 bottom). The layout reads
    /// both so the row is exactly as tall as the cell wants to be.
    static let imageAspect: CGFloat = 0.72
    static let textBlockHeight: CGFloat = 84

    override func layoutSubviews() {
        super.layoutSubviews()

        // Both of these are raw CALayer property changes, and CALayer animates those by default -
        // `shadowPath` and `frame` each have a 0.25s implicit action. Set from inside a layout pass
        // that the collection view is already animating (and `reloadData` gives every visible cell
        // one), they animate too: the shadow grows into place and the gradient slides, every
        // refresh. That is the shadow "changing size" - it was never the wrong size, it was
        // interpolating to the right one in front of the user. UIKit sets no implicit animations on
        // views, only on layers touched by hand, which is why nothing else in the cell does this.
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        gradientLayer.frame = imageView.bounds

        // One rounded rect, matching the card exactly, so every cell casts the same shadow no
        // matter what is inside it or whether the image has loaded yet.
        let path = UIBezierPath(roundedRect: containerView.bounds,
                                cornerRadius: containerView.layer.cornerRadius).cgPath
        if containerView.layer.shadowPath != path {
            containerView.layer.shadowPath = path
        }

        CATransaction.commit()
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
    @Binding var selectedCategory: String
    var onModelSelected: (SketchfabModel) -> Void
    var onResults: ((Int, Bool) -> Void)? = nil

    func makeUIViewController(context: Context) -> DiscoverViewController {
        let vc = DiscoverViewController()
        vc.onModelSelected = onModelSelected
        vc.onResults = onResults
        return vc
    }

    func updateUIViewController(_ uiViewController: DiscoverViewController, context: Context) {
        uiViewController.loadData(query: searchText, category: selectedCategory, isRefreshing: false)
    }
}

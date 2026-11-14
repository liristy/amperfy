//
//  LibraryVC.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 09.03.19.
//  Copyright (c) 2019 Maximilian Bauer. All rights reserved.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

import AmperfyKit
import CoreData
import UIKit

@MainActor
class LibraryVC: KeyCommandCollectionViewController {
  private enum Section: Int, Hashable { case pinned, categories, recent }
  private enum Item: Hashable { case playlist(String), category(Int), album(NSManagedObjectID) }
  private let account: Account
  private var source: UICollectionViewDiffableDataSource<Section, Item>!
  private var recentAlbums: AlbumFetchedResultsController?
  private var playlists = [Playlist]()
  private var syncTask: Task<Void, Never>?
  private var needsRefresh = true
  private var didSync = false
  private var pinKey: String { "libraryPinnedPlaylists." + account.managedObject.objectID.uriRepresentation().absoluteString }
  private func pinIdentifier(_ playlist: Playlist) -> String {
    playlist.managedObject.objectID.uriRepresentation().absoluteString
  }
  private var pinnedIDs: [String] {
    get { UserDefaults.standard.stringArray(forKey: pinKey) ?? [] }
    set { UserDefaults.standard.set(newValue, forKey: pinKey) }
  }

  init(collectionViewLayout: UICollectionViewLayout, account: Account) {
    self.account = account
    super.init(collectionViewLayout: collectionViewLayout)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override var sceneTitle: String? { "Library".localized }

  override func viewDidLoad() {
    super.viewDidLoad()
    navigationController?.navigationBar.prefersLargeTitles = true
    navigationItem.largeTitleDisplayMode = .inline
    title = "Library".localized
    collectionView.backgroundColor = .systemBackground
    collectionView.collectionViewLayout = makeLayout()
    collectionView.register(LibraryArtworkTile.self, forCellWithReuseIdentifier: "artwork")
    collectionView.register(UICollectionViewListCell.self, forCellWithReuseIdentifier: "category")
    collectionView.register(LibraryRecentHeading.self,
      forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader, withReuseIdentifier: "heading")
    source = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) { [weak self] view, path, item in
      guard let self else { return nil }
      if case let .category(raw) = item, let category = LibraryDisplayType(rawValue: raw) {
        let cell = view.dequeueReusableCell(withReuseIdentifier: "category", for: path) as! UICollectionViewListCell
        var content = cell.defaultContentConfiguration()
        content.text = category == .downloads ? "Downloaded".localized : category.displayName
        content.image = category.image.withConfiguration(UIImage.SymbolConfiguration(pointSize: 22, weight: .regular))
        content.imageProperties.tintColor = .label
        content.imageProperties.reservedLayoutSize = CGSize(width: 28, height: 28)
        content.textProperties.font = .preferredFont(forTextStyle: .title3)
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20)
        cell.contentConfiguration = content
        cell.accessories = [.disclosureIndicator()]
        cell.backgroundConfiguration = .clear()
        cell.accessibilityIdentifier = "library-category-\(raw)"
        return cell
      }
      let cell = view.dequeueReusableCell(withReuseIdentifier: "artwork", for: path) as! LibraryArtworkTile
      switch item {
      case let .playlist(id):
        if let playlist = playlists.first(where: { $0.managedObject.objectID.uriRepresentation().absoluteString == id }) {
          cell.display(playlist, pinned: true)
        }
      case let .album(id):
        if let mo = try? appDelegate.storage.main.context.existingObject(with: id) as? AlbumMO {
          cell.display(Album(managedObject: mo), pinned: false)
        }
      case .category: break
      }
      return cell
    }
    source.supplementaryViewProvider = { view, kind, path in
      view.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: "heading", for: path)
    }
    NotificationCenter.default.addObserver(self, selector: #selector(libraryChanged), name: .LibraryItemsChanged, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(objectsChanged(_:)),
      name: .NSManagedObjectContextObjectsDidChange, object: appDelegate.storage.main.context)
    NotificationCenter.default.addObserver(self, selector: #selector(becameActive),
      name: UIApplication.didBecomeActiveNotification, object: nil)
    refreshLibrary()
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    navigationController?.navigationBar.prefersLargeTitles = true
    refreshLibrary()
    guard !didSync, appDelegate.storage.settings.user.isOnlineMode else { return }
    didSync = true
    syncTask = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        try await appDelegate.getMeta(account.info).librarySyncer.syncNewestAlbums(offset: 0, count: 40)
        guard !Task.isCancelled else { return }
        refreshLibrary()
      } catch { didSync = false }
    }
  }

  @objc private func becameActive() {
    if viewIfLoaded?.window != nil, needsRefresh { refreshLibrary() }
  }
  @objc private func libraryChanged() {
    needsRefresh = true
    if viewIfLoaded?.window != nil, UIApplication.shared.applicationState == .active { refreshLibrary() }
  }
  @objc private func objectsChanged(_ note: Notification) {
    // Playback progress mutates SongMO every few seconds. It must not rebuild
    // the hidden library or decode its artwork while music plays in background.
    let keys = [NSInsertedObjectsKey, NSUpdatedObjectsKey, NSDeletedObjectsKey]
    let relevant = keys.contains { key in
      (note.userInfo?[key] as? Set<NSManagedObject>)?.contains { $0 is AlbumMO || $0 is PlaylistMO } == true
    }
    if relevant { libraryChanged() }
  }

  private func refreshLibrary() {
    guard source != nil else { return }
    needsRefresh = false
    playlists = appDelegate.storage.main.library.getPlaylists(for: account)
    recentAlbums = AlbumFetchedResultsController(coreDataCompanion: appDelegate.storage.main, account: account,
      sortType: .newest, isGroupedInAlphabeticSections: false, fetchLimit: 40)
    recentAlbums?.search(searchText: "", onlyCached: appDelegate.storage.settings.user.isOfflineMode, displayFilter: .newest)
    let albums = (recentAlbums?.fetchedObjects as? [AlbumMO]) ?? []
    let selected = appDelegate.storage.settings.accounts.getSetting(account.info).read.libraryDisplaySettings.inUse
    // Favorites stays in the user's category order; only playlists can be pinned.
    let categories = selected.filter { $0 != .newestAlbums }
    var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
    let pins = pinnedIDs.filter { id in playlists.contains { $0.managedObject.objectID.uriRepresentation().absoluteString == id } }.map(Item.playlist)
    if !pins.isEmpty {
      snapshot.appendSections([.pinned])
      snapshot.appendItems(pins, toSection: .pinned)
    }
    snapshot.appendSections([.categories])
    snapshot.appendItems(categories.map { .category($0.rawValue) }, toSection: .categories)
    if !albums.isEmpty {
      snapshot.appendSections([.recent])
      snapshot.appendItems(albums.map { .album($0.objectID) }, toSection: .recent)
    }
    let existing = Set(source.snapshot().itemIdentifiers)
    snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { existing.contains($0) })
    source.apply(snapshot, animatingDifferences: false)
    collectionView.collectionViewLayout.invalidateLayout()
    updateMenu()
  }

  private func updateMenu() {
    let pins = pinnedIDs
    let pinActions = playlists.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map { playlist in
      UIAction(title: playlist.name, image: UIImage(systemName: "pin"), state: pins.contains(pinIdentifier(playlist)) ? .on : .off) { [weak self] _ in
        guard let self else { return }
        var ids = pinnedIDs
        let id = pinIdentifier(playlist)
        if ids.contains(id) { ids.removeAll { $0 == id } } else { ids.append(id) }
        pinnedIDs = ids
        refreshLibrary()
      }
    }
    let pin = UIBarButtonItem(image: UIImage(systemName: "pin"), menu: UIMenu(title: "Pin to Library".localized, children: pinActions))
    pin.accessibilityLabel = "Pin to Library".localized
    let edit = UIBarButtonItem(title: "Edit".localized, style: .plain, target: self,
                              action: #selector(editCategories))
    edit.accessibilityIdentifier = "library-edit-categories"
    navigationItem.rightBarButtonItems = [edit, pin]
  }

  @objc private func editCategories() {
    let editor = LibraryCategoriesEditor(account: account)
    present(UINavigationController(rootViewController: editor), animated: true)
  }

  private func makeLayout() -> UICollectionViewLayout {
    UICollectionViewCompositionalLayout { [weak self] index, environment in
      guard let self, let sections = source?.snapshot().sectionIdentifiers, sections.indices.contains(index) else { return nil }
      let section = sections[index]
      let width = environment.container.effectiveContentSize.width
      switch section {
      case .pinned:
        let side = min(120, width * 0.286)
        let count = source.snapshot().numberOfItems(inSection: .pinned)
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .absolute(side), heightDimension: .absolute(side + 30)),
          subitems: [NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .fractionalHeight(1)))])
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = 12
        section.orthogonalScrollingBehavior = .continuous
        let inset = max(20, (width - CGFloat(count) * side - CGFloat(max(0, count - 1)) * 12) / 2)
        section.contentInsets = .init(top: 8, leading: inset, bottom: 12, trailing: inset)
        return section
      case .categories:
        var config = UICollectionLayoutListConfiguration(appearance: .plain)
        config.backgroundColor = .systemBackground
        let section = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
        return section
      case .recent:
        let columns = width > 600 ? 4 : 2
        let side = (width - 40 - CGFloat(columns - 1) * 12) / CGFloat(columns)
        let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .absolute(side), heightDimension: .fractionalHeight(1)))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(side + 46)),
          repeatingSubitem: item, count: columns)
        group.interItemSpacing = .fixed(12)
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = 12
        section.contentInsets = .init(top: 4, leading: 20, bottom: 24, trailing: 20)
        section.boundarySupplementaryItems = [.init(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(56)),
          elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)]
        return section
      }
    }
  }

  override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    collectionView.deselectItem(at: indexPath, animated: true)
    guard let item = source.itemIdentifier(for: indexPath) else { return }
    let destination: UIViewController?
    switch item {
    case let .playlist(id):
      destination = playlists.first(where: { $0.managedObject.objectID.uriRepresentation().absoluteString == id }).map { AppStoryboard.Main.segueToPlaylistDetail(account: account, playlist: $0) }
    case let .category(raw): destination = LibraryDisplayType(rawValue: raw)?.controller(account: account, settings: appDelegate.storage.settings)
    case let .album(id):
      if let mo = try? appDelegate.storage.main.context.existingObject(with: id) as? AlbumMO {
        destination = AppStoryboard.Main.segueToAlbumDetail(account: account, album: Album(managedObject: mo))
      } else { destination = nil }
    }
    if let destination {
      switch item {
      case .playlist, .album:
        destination.preferredTransition = .zoom(options: (destination as? PlaylistDetailVC)?.scrollCompatibleZoomOptions) { [weak self] _ in
          guard let self, let path = source.indexPath(for: item) else { return nil }
          return (collectionView.cellForItem(at: path) as? LibraryArtworkTile)?.artwork
        }
      default: break
      }
      AppDelegate.mainWindowHostVC?.pushLibraryCategory(vc: destination)
    }
  }
}

@MainActor
private final class LibraryCategoriesEditor: UICollectionViewController {
  private let account: Account
  private var configurator: LibraryNavigatorConfigurator!
  init(account: Account) {
    self.account = account
    super.init(collectionViewLayout: UICollectionViewFlowLayout())
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func viewDidLoad() {
    super.viewDidLoad()
    title = "Library".localized
    configurator = LibraryNavigatorConfigurator(account: account, offsetData: [],
      librarySettings: appDelegate.storage.settings.accounts.getSetting(account.info).read.libraryDisplaySettings,
      layoutConfig: UICollectionLayoutListConfiguration(appearance: .insetGrouped), pressedOnLibraryItemCB: { _ in })
    configurator.viewDidLoad(navigationItem: navigationItem, collectionView: collectionView)
    configurator.editingDidFinish = { [weak self] in self?.dismiss(animated: true) }
    configurator.editingPressed()
    navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
  }
}

@MainActor
private final class LibraryRecentHeading: UICollectionReusableView {
  private let label = UILabel()
  override init(frame: CGRect) {
    super.init(frame: frame)
    label.text = "Recently Added".localized
    label.font = .systemFont(ofSize: 20, weight: .bold)
    label.adjustsFontForContentSizeCategory = true
    addSubview(label)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func layoutSubviews() {
    super.layoutSubviews()
    label.frame = CGRect(x: 0, y: 20, width: bounds.width, height: bounds.height - 20)
  }
}

@MainActor
private final class LibraryArtworkTile: UICollectionViewCell {
  let artwork = EntityImageView(frame: .zero)
  let titleLabel = UILabel()
  let subtitleLabel = UILabel()
  private var pinned = false
  override init(frame: CGRect) {
    super.init(frame: frame)
    [artwork, titleLabel, subtitleLabel].forEach { contentView.addSubview($0) }
    artwork.imageContentMode = .scaleAspectFill
    titleLabel.numberOfLines = 1
    subtitleLabel.numberOfLines = 1
    subtitleLabel.textColor = .secondaryLabel
    isAccessibilityElement = true
    accessibilityTraits = .button
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  func display(_ container: PlayableContainable, pinned: Bool) {
    self.pinned = pinned
    artwork.display(theme: appDelegate.storage.settings.accounts.getSetting(container.account?.info).read.themePreference,
      container: container, cornerRadius: .small)
    titleLabel.text = container.name
    subtitleLabel.text = pinned ? nil : container.subtitle
    updateStyle()
    accessibilityIdentifier = pinned ? "library-pinned-playlist" : "library-recent-album"
  }
  private func updateStyle() {
    titleLabel.font = .systemFont(ofSize: pinned ? 12 : 13, weight: pinned ? .medium : .regular)
    subtitleLabel.font = .systemFont(ofSize: 12)
    titleLabel.textAlignment = pinned ? .center : .natural
    accessibilityLabel = [titleLabel.text, subtitleLabel.text].compactMap { $0 }.joined(separator: ", ")
    setNeedsLayout()
  }
  override func layoutSubviews() {
    super.layoutSubviews()
    let side = bounds.width
    artwork.frame = CGRect(x: 0, y: 0, width: side, height: side)
    titleLabel.frame = CGRect(x: 0, y: side + 5, width: side, height: 18)
    subtitleLabel.frame = CGRect(x: 0, y: side + 23, width: side, height: 16)
  }
}

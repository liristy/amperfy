//
//  AlbumDetailVC.swift
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
import UIKit

// MARK: - AlbumDetailDiffableDataSource

class AlbumDetailDiffableDataSource: BasicUITableViewDiffableDataSource {
  override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
    false
  }

  override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
    // Return true to be enable swipe
    true
  }
}

// MARK: - AlbumDetailVC

class AlbumDetailVC: SingleSnapshotFetchedResultsTableViewController<SongMO> {
  override var sceneTitle: String? { album.name }

  var songToScrollTo: Song?
  private var fetchedResultsController: AlbumSongsFetchedResultsController!
  private var optionsButton: UIBarButtonItem!
  private(set) var detailOperationsView: MusicArtworkHeader?
  private let albumFooter = UILabel()
  private var previousNavStyle: UIUserInterfaceStyle?
  private var previousNavTint: UIColor?
  let album: Album

  init(account: Account, album: Album) {
    self.album = album
    super.init(style: .plain, account: account)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func createDiffableDataSource() -> BasicUITableViewDiffableDataSource {
    let source =
      AlbumDetailDiffableDataSource(tableView: tableView) { tableView, indexPath, objectID -> UITableViewCell? in
        guard let object = try? self.appDelegate.storage.main.context
          .existingObject(with: objectID),
          let songMO = object as? SongMO
        else {
          fatalError("Managed object should be available")
        }
        let song = Song(managedObject: songMO)
        return self.createCell(tableView, forRowAt: indexPath, song: song)
      }
    return source
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    appDelegate.userStatistics.visited(.albumDetail)

    optionsButton = UIBarButtonItem.createOptionsBarButton()

    fetchedResultsController = AlbumSongsFetchedResultsController(
      forAlbum: album,
      coreDataCompanion: appDelegate.storage.main,
      isGroupedInAlphabeticSections: false
    )
    singleFetchedResultsController = fetchedResultsController
    singleFetchedResultsController?.delegate = self
    singleFetchedResultsController?.fetch()

    configureSearchController(
      placeholder: "Search in \"Album\"",
      scopeButtonTitles: ["All".localized, "Cached".localized]
    )
    tableView.register(nibName: PlayableTableCell.typeName)
    tableView.rowHeight = PlayableTableCell.rowHeight
    // Catalyst also need an estimate to calculate the correct height before scrolling
    tableView.estimatedRowHeight = PlayableTableCell.rowHeight
    tableView.sectionFooterHeight = 0.0
    tableView.estimatedSectionFooterHeight = 0.0
    tableView.sectionHeaderHeight = 0.0
    tableView.estimatedSectionHeaderHeight = 0.0
    tableView.backgroundColor = .backgroundColor

    overrideUserInterfaceStyle = .dark
    tableView.backgroundColor = UIColor(white: 0.16, alpha: 1)
    tableView.rowHeight = 56
    tableView.separatorColor = .white.withAlphaComponent(0.12)
    tableView.separatorInset = UIEdgeInsets(top: 0, left: 20, bottom: 0, right: 20)
    navigationItem.largeTitleDisplayMode = .never
    let appearance = UINavigationBarAppearance()
    appearance.configureWithTransparentBackground()
    appearance.titleTextAttributes = [.foregroundColor: UIColor.white]
    navigationItem.standardAppearance = appearance
    navigationItem.scrollEdgeAppearance = appearance
    let header = MusicArtworkHeader(entity: album)
    header.playAction = { [weak self] shuffled in
      guard let self else { return }
      let songs = fetchedResultsController.getContextSongs(onlyCachedSongs: appDelegate.storage.settings.user.isOfflineMode) ?? []
      let context = PlayContext(containable: album, playables: songs)
      if shuffled { appDelegate.player.playShuffled(context: context) } else { appDelegate.player.play(context: context) }
    }
    header.secondaryAction = { [weak self] in
      guard let self else { return }
      appDelegate.getMeta(account.info).playableDownloadManager.download(objects: album.playables.filter { $0.isDownloadAvailable && !$0.isCached })
    }
    header.artistAction = { [weak self] in
      guard let self, let artist = album.artist else { return }
      navigationController?.pushViewController(AppStoryboard.Main.segueToArtistDetail(account: account, artist: artist), animated: true)
    }
    header.paletteChanged = { [weak self] color in self?.tableView.backgroundColor = color }
    detailOperationsView = header
    tableView.tableHeaderView = header
    header.refresh()
    albumFooter.font = .preferredFont(forTextStyle: .footnote)
    albumFooter.textColor = .white.withAlphaComponent(0.55)
    albumFooter.numberOfLines = 0
    snapshotDidChange = { [weak self] in self?.refreshAlbumFooter() }
    refreshAlbumFooter()

    optionsButton = UIBarButtonItem.createOptionsBarButton()
    optionsButton.menu = UIMenu.lazyMenu {
      EntityPreviewActionBuilder(container: self.album, on: self).createMenuActions()
    }
    navigationItem.rightBarButtonItem = optionsButton

    containableAtIndexPathCallback = { indexPath in
      self.fetchedResultsController.getWrappedEntity(at: indexPath)
    }
    playContextAtIndexPathCallback = convertIndexPathToPlayContext
    swipeCallback = { indexPath, completionHandler in
      let song = self.fetchedResultsController.getWrappedEntity(at: indexPath)
      let playContext = self.convertIndexPathToPlayContext(songIndexPath: indexPath)
      completionHandler(SwipeActionContext(containable: song, playContext: playContext))
    }
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    navigationController?.navigationBar.prefersLargeTitles = false
    if previousNavStyle == nil {
      previousNavStyle = navigationController?.navigationBar.overrideUserInterfaceStyle
      previousNavTint = navigationController?.navigationBar.tintColor
    }
    navigationController?.navigationBar.overrideUserInterfaceStyle = .dark
    navigationController?.navigationBar.tintColor = .white
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    let bar = navigationController?.navigationBar
    let restore = { [previousNavStyle, previousNavTint] in
      bar?.overrideUserInterfaceStyle = previousNavStyle ?? .unspecified
      bar?.tintColor = previousNavTint
    }
    if let coordinator = transitionCoordinator {
      coordinator.animate(alongsideTransition: nil) { context in
        if !context.isCancelled { restore() }
      }
    } else { restore() }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    guard let header = detailOperationsView else { return }
    let size = CGSize(width: tableView.bounds.width, height: header.preferredHeight(width: tableView.bounds.width))
    if header.frame.size != size { header.frame.size = size; tableView.tableHeaderView = header }
    refreshAlbumFooter()
    updateAlbumTitle()
  }

  override func scrollViewDidScroll(_ scrollView: UIScrollView) { updateAlbumTitle() }

  private func updateAlbumTitle() {
    let collapsed = tableView.contentOffset.y + tableView.adjustedContentInset.top > (detailOperationsView?.frame.height ?? 0) - 70
    let title = collapsed ? album.name : ""
    if navigationItem.title != title { navigationItem.title = title }
  }

  private func refreshAlbumFooter() {
    let year = album.year > 0 ? String(album.year) + "\n" : ""
    albumFooter.text = year + CommonString.songs(album.songCount) + " · " + album.duration.asDurationShortString
    let footer = tableView.tableFooterView ?? UIView()
    if albumFooter.superview !== footer { footer.addSubview(albumFooter) }
    footer.frame.size = CGSize(width: tableView.bounds.width, height: 88)
    albumFooter.frame = footer.bounds.insetBy(dx: 20, dy: 16)
    if tableView.tableFooterView !== footer { tableView.tableFooterView = footer }
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    extendSafeAreaToAccountForMiniPlayer()

    Task { @MainActor in
      do {
        try await album.fetch(
          storage: self.appDelegate.storage,
          librarySyncer: self.appDelegate.getMeta(self.account.info).librarySyncer,
          playableDownloadManager: self.appDelegate.getMeta(self.account.info)
            .playableDownloadManager
        )
      } catch {
        self.appDelegate.eventLogger.report(topic: "Album Sync", error: error)
      }
      self.detailOperationsView?.refresh()
    }
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    defer { songToScrollTo = nil }
    guard let songToScrollTo = songToScrollTo,
          let indexPath = fetchedResultsController.fetchResultsController
          .indexPath(forObject: songToScrollTo.managedObject)
    else { return }
    tableView.scrollToRow(at: indexPath, at: .top, animated: true)
  }

  func convertIndexPathToPlayContext(songIndexPath: IndexPath) -> PlayContext? {
    guard let songs = fetchedResultsController
      .getContextSongs(onlyCachedSongs: appDelegate.storage.settings.user.isOfflineMode)
    else { return nil }
    let selectedSong = fetchedResultsController.getWrappedEntity(at: songIndexPath)
    guard let playContextIndex = songs.firstIndex(of: selectedSong) else { return nil }
    return PlayContext(containable: album, index: playContextIndex, playables: songs)
  }

  func convertCellViewToPlayContext(cell: UITableViewCell) -> PlayContext? {
    guard let indexPath = tableView.indexPath(for: cell) else { return nil }
    return convertIndexPathToPlayContext(songIndexPath: indexPath)
  }

  func createCell(
    _ tableView: UITableView,
    forRowAt indexPath: IndexPath,
    song: Song
  )
    -> UITableViewCell {
    let cell: PlayableTableCell = dequeueCell(for: tableView, at: indexPath)
    cell.display(
      playable: song,
      playContextCb: convertCellViewToPlayContext,
      rootView: self,
      isDislayAlbumTrackNumberStyle: true
    )
    return cell
  }

  override func updateSearchResults(for searchController: UISearchController) {
    fetchedResultsController.search(
      searchText: searchController.searchBar.text ?? "",
      onlyCachedSongs: searchController.searchBar.selectedScopeButtonIndex == 1
    )
    tableView.reloadData()
  }
}


// Shared artwork treatment for the album page and the artist's full-bleed hero.
@MainActor
final class MusicArtworkHeader: UIView {
  let artwork = EntityImageView(frame: .zero)
  private let titleLabel = UILabel()
  private let artistButton = UIButton(type: .system)
  private let metadataLabel = UILabel()
  private let playButton = UIButton(type: .system)
  private let shuffleButton = UIButton(type: .system)
  private let secondaryButton = UIButton(type: .system)
  private let fade = CAGradientLayer()
  private let entity: AbstractLibraryEntity & PlayableContainable
  private let artistHero: Bool
  private var paletteKey: String?
  private var paletteTask: Task<Void, Never>?
  private var baseColor = UIColor(white: 0.16, alpha: 1)
  var playAction: ((Bool) -> Void)?
  var secondaryAction: (() -> Void)?
  var artistAction: (() -> Void)?
  var paletteChanged: ((UIColor) -> Void)?

  init(entity: AbstractLibraryEntity & PlayableContainable) {
    self.entity = entity
    artistHero = entity is Artist
    super.init(frame: .zero)
    [artwork, titleLabel, artistButton, metadataLabel, playButton, shuffleButton, secondaryButton].forEach { addSubview($0) }
    artwork.imageContentMode = .scaleAspectFill
    artwork.clipsToBounds = true
    artwork.accessibilityIdentifier = artistHero ? "artist-hero-artwork" : "album-header-artwork"
    fade.locations = [0, 0.5, 1]
    artwork.layer.addSublayer(fade)
    titleLabel.font = .systemFont(ofSize: artistHero ? 32 : 22, weight: .bold)
    titleLabel.textColor = .white
    titleLabel.textAlignment = .center
    titleLabel.numberOfLines = 2
    artistButton.titleLabel?.font = .systemFont(ofSize: 17)
    artistButton.setTitleColor(.white.withAlphaComponent(0.8), for: .normal)
    artistButton.addAction(UIAction { [weak self] _ in self?.artistAction?() }, for: .touchUpInside)
    metadataLabel.font = .systemFont(ofSize: 12)
    metadataLabel.textColor = .white.withAlphaComponent(0.55)
    metadataLabel.textAlignment = .center
    var play = UIButton.Configuration.filled()
    play.image = UIImage(systemName: "play.fill")
    if !artistHero { play.title = "Play".localized; play.imagePadding = 7 }
    play.baseBackgroundColor = .white
    play.baseForegroundColor = .black
    play.cornerStyle = .capsule
    playButton.configuration = play
    playButton.accessibilityLabel = "Play".localized
    playButton.addAction(UIAction { [weak self] _ in self?.playAction?(false) }, for: .touchUpInside)
    for (button, symbol, label) in [(shuffleButton, "shuffle", "Shuffle"),
      (secondaryButton, artistHero ? "star" : "arrow.down", artistHero ? "Favorite" : "Download")] {
      var config = UIButton.Configuration.filled()
      config.image = UIImage(systemName: symbol)
      config.baseBackgroundColor = .white.withAlphaComponent(0.10)
      config.baseForegroundColor = .white
      config.cornerStyle = .capsule
      button.configuration = config
      button.accessibilityLabel = label.localized
    }
    shuffleButton.addAction(UIAction { [weak self] _ in self?.playAction?(true) }, for: .touchUpInside)
    secondaryButton.addAction(UIAction { [weak self] _ in self?.secondaryAction?() }, for: .touchUpInside)
    NotificationCenter.default.addObserver(self, selector: #selector(stopVisualWork), name: UIApplication.willResignActiveNotification, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(refreshVisible), name: UIApplication.didBecomeActiveNotification, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(downloadFinished(_:)), name: .downloadFinishedSuccess, object: nil)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  @objc private func stopVisualWork() { paletteTask?.cancel(); paletteTask = nil; paletteKey = nil }
  @objc private func refreshVisible() { if window != nil { refresh() } }
  @objc private func downloadFinished(_ note: Notification) {
    guard let download = DownloadNotification.fromNotification(note),
          download.id == entity.artwork?.uniqueID else { return }
    paletteKey = nil
    refreshVisible()
  }
  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil { refresh() } else { stopVisualWork() }
  }
  func preferredHeight(width: CGFloat) -> CGFloat {
    if artistHero { return min(600, width * 1.25) + 8 }
    let side = min(340, width * 0.694)
    let titleHeight = max(28, titleLabel.sizeThatFits(CGSize(width: max(1, width - 40), height: 80)).height)
    return 16 + side + 18 + titleHeight + 27 + 20 + 18 + 44 + 22
  }
  func refresh() {
    guard UIApplication.shared.applicationState == .active else { return }
    let settings = appDelegate.storage.settings.accounts.getSetting(entity.account?.info).read
    artwork.display(theme: settings.themePreference, container: entity)
    if let album = entity as? Album {
      titleLabel.text = album.name
      artistButton.setTitle(album.artist?.name, for: .normal)
      artistButton.isEnabled = album.artist != nil
      metadataLabel.text = [album.genre?.name, album.year > 0 ? String(album.year) : nil].compactMap { $0 }.joined(separator: " · ")
      secondaryButton.configuration?.image = UIImage(systemName: album.isCached ? "checkmark" : "arrow.down")
      secondaryButton.isEnabled = appDelegate.storage.settings.user.isOnlineMode && !album.isCached
    } else if let artist = entity as? Artist {
      titleLabel.text = artist.name
      secondaryButton.configuration?.image = UIImage(systemName: artist.isFavorite ? "star.fill" : "star")
      secondaryButton.isEnabled = appDelegate.storage.settings.user.isOnlineMode
    }
    artistButton.isHidden = artistHero
    metadataLabel.isHidden = artistHero
    playButton.isEnabled = !entity.playables.isEmpty
    shuffleButton.isEnabled = playButton.isEnabled
    setNeedsLayout()
    guard let path = entity.artwork?.imagePath, path != paletteKey else { return }
    paletteKey = path
    paletteTask?.cancel()
    paletteTask = Task { @MainActor [weak self] in
      let colors = await LibraryEntityImage.loadArtworkPalette(at: path)
      guard !Task.isCancelled, let self, UIApplication.shared.applicationState == .active,
            self.paletteKey == path, let color = colors.first else { return }
      var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
      color.getRed(&r, green: &g, blue: &b, alpha: &a)
      self.baseColor = UIColor(red: r * 0.25 + 0.08, green: g * 0.25 + 0.08, blue: b * 0.25 + 0.08, alpha: 1)
      self.paletteChanged?(self.baseColor)
      self.setNeedsLayout()
    }
  }
  override func layoutSubviews() {
    super.layoutSubviews()
    let width = bounds.width
    if artistHero {
      artwork.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
      artwork.layer.cornerRadius = 0
      titleLabel.frame = CGRect(x: 20, y: bounds.height - 150, width: width - 40, height: 54)
      playButton.frame = CGRect(x: (width - 56) / 2, y: bounds.height - 82, width: 56, height: 56)
      shuffleButton.frame = CGRect(x: playButton.frame.minX - 68, y: playButton.frame.minY + 6, width: 44, height: 44)
      secondaryButton.frame = CGRect(x: playButton.frame.maxX + 24, y: shuffleButton.frame.minY, width: 44, height: 44)
    } else {
      let side = min(340, width * 0.694)
      artwork.frame = CGRect(x: (width - side) / 2, y: 16, width: side, height: side)
      let titleHeight = max(28, titleLabel.sizeThatFits(CGSize(width: max(1, width - 40), height: 80)).height)
      titleLabel.frame = CGRect(x: 20, y: artwork.frame.maxY + 18, width: width - 40, height: titleHeight)
      artistButton.frame = CGRect(x: 20, y: titleLabel.frame.maxY, width: width - 40, height: 27)
      metadataLabel.frame = CGRect(x: 20, y: artistButton.frame.maxY, width: width - 40, height: 20)
      let playWidth = min(156, width * 0.365), y = metadataLabel.frame.maxY + 18
      playButton.frame = CGRect(x: (width - playWidth) / 2, y: y, width: playWidth, height: 44)
      shuffleButton.frame = CGRect(x: playButton.frame.minX - 58, y: y, width: 44, height: 44)
      secondaryButton.frame = CGRect(x: playButton.frame.maxX + 14, y: y, width: 44, height: 44)
    }
    CATransaction.begin(); CATransaction.setDisableActions(true)
    fade.frame = artwork.bounds
    fade.colors = artistHero ? [UIColor.clear.cgColor, baseColor.withAlphaComponent(0.05).cgColor, baseColor.cgColor] : []
    CATransaction.commit()
  }
}

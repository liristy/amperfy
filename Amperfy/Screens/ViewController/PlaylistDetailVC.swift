//
//  PlaylistDetailVC.swift
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

// MARK: - PlaylistDetailDiffableDataSource

class PlaylistDetailDiffableDataSource: BasicUITableViewDiffableDataSource {
  var playlist: Playlist!
  var isMoveAllowed = false
  var isEditAllowed = true

  override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
    // Return false if you do not want the item to be re-orderable.
    isMoveAllowed
  }

  override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
    // Return true to be enable swipe
    isEditAllowed
  }

  override func tableView(
    _ tableView: UITableView,
    moveRowAt sourceIndexPath: IndexPath,
    to destinationIndexPath: IndexPath
  ) {
    exectueAfterAnimation {
      self.playlist?.movePlaylistItem(fromIndex: sourceIndexPath.row, to: destinationIndexPath.row)

      guard self.appDelegate.storage.settings.user.isOnlineMode,
            let account = self.playlist.account else { return }
      Task { @MainActor in do {
        try await self.appDelegate.getMeta(account.info).librarySyncer
          .syncUpload(playlistToUpdateOrder: self.playlist)
      } catch {
        self.appDelegate.eventLogger.report(topic: "Playlist Upload Order Update", error: error)
      }}
    }
    super.tableView(tableView, moveRowAt: sourceIndexPath, to: destinationIndexPath)
  }

  override func tableView(
    _ tableView: UITableView,
    commit editingStyle: UITableViewCell.EditingStyle,
    forRowAt indexPath: IndexPath
  ) {
    guard editingStyle == .delete else { return }
    exectueAfterAnimation {
      self.playlist?.remove(at: indexPath.row)
      guard self.appDelegate.storage.settings.user.isOnlineMode,
            let account = self.playlist.account else { return }
      Task { @MainActor in do {
        try await self.appDelegate.getMeta(account.info).librarySyncer.syncUpload(
          playlistToDeleteSong: self.playlist,
          index: indexPath.row
        )
      } catch {
        self.appDelegate.eventLogger.report(topic: "Playlist Upload Entry Remove", error: error)
      }}
    }
    super.tableView(tableView, commit: editingStyle, forRowAt: indexPath)
  }
}

// MARK: - PlaylistDetailVC

class PlaylistDetailVC: SingleSnapshotFetchedResultsTableViewController<PlaylistItemMO> {
  override var sceneTitle: String? { playlist.name }

  private var fetchedResultsController: PlaylistItemsFetchedResultsController!
  let playlist: Playlist

  private var editButton: UIBarButtonItem!
  private var optionsButton: UIBarButtonItem!
  var detailOperationsView: PlaylistArtworkHeader?
  private var previousNavStyle: UIUserInterfaceStyle?
  private var previousNavTint: UIColor?

  init(account: Account, playlist: Playlist) {
    self.playlist = playlist
    super.init(style: .plain, account: account)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func createDiffableDataSource() -> BasicUITableViewDiffableDataSource {
    let source =
      PlaylistDetailDiffableDataSource(tableView: tableView) { tableView, indexPath, objectID -> UITableViewCell? in
        guard let object = try? self.appDelegate.storage.main.context
          .existingObject(with: objectID),
          let playlistItemMO = object as? PlaylistItemMO
        else {
          return UITableViewCell()
        }
        let playlistItem = PlaylistItem(
          library: self.appDelegate.storage.main.library,
          managedObject: playlistItemMO
        )
        return self.createCell(tableView, forRowAt: indexPath, playlistItem: playlistItem)
      }
    source.playlist = playlist
    return source
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    #if !targetEnvironment(macCatalyst)
      refreshControl = UIRefreshControl()
    #endif

    appDelegate.userStatistics.visited(.playlistDetail)
    fetchedResultsController = PlaylistItemsFetchedResultsController(
      forPlaylist: playlist,
      coreDataCompanion: appDelegate.storage.main,
      isGroupedInAlphabeticSections: false
    )
    singleFetchedResultsController = fetchedResultsController
    singleFetchedResultsController?.delegate = self
    singleFetchedResultsController?.fetch()

    tableView.register(nibName: PlayableTableCell.typeName)
    tableView.rowHeight = 56
    tableView.estimatedRowHeight = 56
    tableView.sectionFooterHeight = 0.0
    tableView.estimatedSectionFooterHeight = 0.0
    tableView.sectionHeaderHeight = 0.0
    tableView.estimatedSectionHeaderHeight = 0.0
    overrideUserInterfaceStyle = .dark
    tableView.backgroundColor = UIColor(white: 0.12, alpha: 1)
    tableView.separatorColor = .white.withAlphaComponent(0.13)
    tableView.separatorInset = UIEdgeInsets(top: 0, left: 76, bottom: 0, right: 20)
    navigationItem.largeTitleDisplayMode = .never
    let appearance = UINavigationBarAppearance()
    appearance.configureWithTransparentBackground()
    appearance.titleTextAttributes = [.foregroundColor: UIColor.white]
    navigationItem.standardAppearance = appearance
    navigationItem.scrollEdgeAppearance = appearance

    // Use a single button, two buttons don't work on catalyst
    editButton = UIBarButtonItem(
      title: "Edit".localized,
      style: .plain,
      target: self,
      action: #selector(openEditView)
    )
    optionsButton = UIBarButtonItem.createOptionsBarButton()
    optionsButton.menu = UIMenu.lazyMenu {
      EntityPreviewActionBuilder(container: self.playlist, on: self).createMenuActions()
    }

    let header = PlaylistArtworkHeader(playlist: playlist)
    header.playAction = { [weak self] shuffled in
      guard let self else { return }
      let songs = fetchedResultsController.getContextSongs(onlyCachedSongs: appDelegate.storage.settings.user.isOfflineMode) ?? []
      let context = PlayContext(containable: playlist, playables: songs)
      if shuffled { appDelegate.player.playShuffled(context: context) } else { appDelegate.player.play(context: context) }
    }
    header.downloadAction = { [weak self] in self?.downloadPlaylist() }
    header.paletteChanged = { [weak self] color in
      guard let self else { return }
      tableView.backgroundColor = color
    }
    detailOperationsView = header
    tableView.tableHeaderView = header
    header.refresh()
    refreshControl?.addTarget(
      self,
      action: #selector(Self.handleRefresh),
      for: UIControl.Event.valueChanged
    )

    snapshotDidChange = { [weak self] in self?.detailOperationsView?.refresh() }

    containableAtIndexPathCallback = { indexPath in
      self.fetchedResultsController.getWrappedEntity(at: indexPath).playable
    }
    playContextAtIndexPathCallback = { indexPath in
      self.convertIndexPathToPlayContext(songIndexPath: indexPath)
    }
    swipeCallback = { indexPath, completionHandler in
      let playlistItem = self.fetchedResultsController.getWrappedEntity(at: indexPath)
      let playContext = self.convertIndexPathToPlayContext(songIndexPath: indexPath)
      completionHandler(SwipeActionContext(
        containable: playlistItem.playable,
        playContext: playContext
      ))
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
    navigationController?.navigationBar.overrideUserInterfaceStyle = previousNavStyle ?? .unspecified
    navigationController?.navigationBar.tintColor = previousNavTint
    transitionCoordinator?.animate(alongsideTransition: nil) { [weak self] context in
      guard context.isCancelled, let self else { return }
      navigationController?.navigationBar.overrideUserInterfaceStyle = .dark
      navigationController?.navigationBar.tintColor = .white
    }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    guard let header = detailOperationsView else { return }
    let size = CGSize(width: tableView.bounds.width, height: header.preferredHeight(width: tableView.bounds.width))
    if header.frame.size != size {
      header.frame.size = size
      tableView.tableHeaderView = header
    }
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    let headerHeight = detailOperationsView?.frame.height ?? 0
    navigationItem.title = scrollView.contentOffset.y + scrollView.adjustedContentInset.top > headerHeight - 80 ? playlist.name : nil
  }

  private func downloadPlaylist() {
    guard appDelegate.storage.settings.user.isOnlineMode else { return }
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        try await playlist.fetch(storage: appDelegate.storage,
          librarySyncer: appDelegate.getMeta(account.info).librarySyncer,
          playableDownloadManager: appDelegate.getMeta(account.info).playableDownloadManager)
        appDelegate.getMeta(account.info).playableDownloadManager.download(objects: playlist.playables.filter { $0.isDownloadAvailable && !$0.isCached })
        detailOperationsView?.refresh()
      } catch { appDelegate.eventLogger.report(topic: "Playlist Download", error: error) }
    }
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    extendSafeAreaToAccountForMiniPlayer()
    if appDelegate.storage.settings.user.isOfflineMode {
      tableView.isEditing = false
    }
    refreshBarButtons()
    Task { @MainActor in
      do {
        try await playlist.fetch(
          storage: self.appDelegate.storage,
          librarySyncer: self.appDelegate.getMeta(self.account.info).librarySyncer,
          playableDownloadManager: self.appDelegate.getMeta(self.account.info)
            .playableDownloadManager
        )
      } catch {
        self.appDelegate.eventLogger.report(topic: "Playlist Sync", error: error)
      }
      self.detailOperationsView?.refresh()
    }
  }

  func refreshBarButtons() {
    var edititingBarButton: UIBarButtonItem? = nil

    if appDelegate.storage.settings.user.isOnlineMode {
      edititingBarButton = editButton
      edititingBarButton?.title = "Edit".localized
      edititingBarButton?.style = .plain
      if playlist.isSmartPlaylist {
        edititingBarButton?.isEnabled = false
      }
    }

    navigationItem.rightBarButtonItems = [optionsButton, edititingBarButton].compactMap { $0 }
  }

  func convertIndexPathToPlayContext(songIndexPath: IndexPath) -> PlayContext? {
    guard let songs = fetchedResultsController
      .getContextSongs(onlyCachedSongs: appDelegate.storage.settings.user.isOfflineMode)
    else { return nil }
    return PlayContext(containable: playlist, index: songIndexPath.row, playables: songs)
  }

  func convertCellViewToPlayContext(cell: UITableViewCell) -> PlayContext? {
    guard let indexPath = tableView.indexPath(for: cell)
    else { return nil }
    return convertIndexPathToPlayContext(songIndexPath: IndexPath(row: indexPath.row, section: 0))
  }

  @objc
  private func openEditView(sender: UIBarButtonItem) {
    let playlistDetailVC = AppStoryboard.Main.segueToPlaylistEdit(
      account: account,
      playlist: playlist
    )
    let playlistDetailNav = UINavigationController(rootViewController: playlistDetailVC)
    playlistDetailVC.onDoneCB = {
      self.detailOperationsView?.refresh()
      self.tableView.reloadData()
    }
    present(playlistDetailNav, animated: true, completion: nil)
  }

  func createCell(
    _ tableView: UITableView,
    forRowAt indexPath: IndexPath,
    playlistItem: PlaylistItem
  )
    -> UITableViewCell {
    let cell: PlayableTableCell = dequeueCell(for: tableView, at: indexPath)
    if let song = playlistItem.playable.asSong {
      cell.display(playable: song, playContextCb: convertCellViewToPlayContext, rootView: self)
    }
    return cell
  }

  override func updateSearchResults(for searchController: UISearchController) {
    fetchedResultsController
      .search(onlyCachedSongs: appDelegate.storage.settings.user.isOfflineMode)
    tableView.reloadData()
  }

  @objc
  func handleRefresh(refreshControl: UIRefreshControl) {
    Task { @MainActor in
      do {
        try await self.appDelegate.getMeta(self.account.info).librarySyncer
          .syncDown(playlist: playlist)
      } catch {
        self.appDelegate.eventLogger.report(topic: "Playlist Sync", error: error)
      }
      self.detailOperationsView?.refresh()
      self.refreshControl?.endRefreshing()
    }
  }
}


@MainActor
final class PlaylistArtworkHeader: UIView {
  let artwork = EntityImageView(frame: .zero)
  private let nameLabel = UILabel()
  private let subtitle = UILabel()
  private let playButton = UIButton(type: .system)
  private let shuffleButton = UIButton(type: .system)
  private let downloadButton = UIButton(type: .system)
  private let playlist: Playlist
  private var paletteTask: Task<Void, Never>?
  private var paletteKey: String?
  var playAction: ((Bool) -> Void)?
  var downloadAction: (() -> Void)?
  var paletteChanged: ((UIColor) -> Void)?

  init(playlist: Playlist) {
    self.playlist = playlist
    super.init(frame: .zero)
    [artwork, nameLabel, subtitle, playButton, shuffleButton, downloadButton].forEach { addSubview($0) }
    artwork.accessibilityIdentifier = "playlist-header-artwork"
    nameLabel.font = .preferredFont(forTextStyle: .title2)
    nameLabel.textAlignment = .center
    nameLabel.textColor = .white
    nameLabel.numberOfLines = 2
    nameLabel.adjustsFontForContentSizeCategory = true
    subtitle.font = .preferredFont(forTextStyle: .body)
    subtitle.textAlignment = .center
    subtitle.textColor = .white.withAlphaComponent(0.75)
    var play = UIButton.Configuration.filled()
    play.title = "Play".localized
    play.image = UIImage(systemName: "play.fill")
    play.imagePadding = 6
    play.baseForegroundColor = .black
    play.baseBackgroundColor = .white
    play.cornerStyle = .capsule
    playButton.configuration = play
    playButton.addAction(UIAction { [weak self] _ in self?.playAction?(false) }, for: .touchUpInside)
    for (button, symbol, label) in [(shuffleButton, "shuffle", "Shuffle"), (downloadButton, "arrow.down", "Download")] {
      var config = UIButton.Configuration.filled()
      config.image = UIImage(systemName: symbol)
      config.baseForegroundColor = .white
      config.baseBackgroundColor = .white.withAlphaComponent(0.12)
      config.cornerStyle = .capsule
      button.configuration = config
      button.accessibilityLabel = label.localized
    }
    shuffleButton.addAction(UIAction { [weak self] _ in self?.playAction?(true) }, for: .touchUpInside)
    downloadButton.addAction(UIAction { [weak self] _ in self?.downloadAction?() }, for: .touchUpInside)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  private func artworkSide(width: CGFloat) -> CGFloat { min(340, width * 0.694) }
  private func titleHeight(width: CGFloat) -> CGFloat {
    max(28, nameLabel.sizeThatFits(CGSize(width: max(1, width - 48), height: 100)).height)
  }
  func preferredHeight(width: CGFloat) -> CGFloat {
    12 + artworkSide(width: width) + 20 + titleHeight(width: width) + 26 + 16 + 44 + 22
  }
  func refresh() {
    let settings = appDelegate.storage.settings.accounts.getSetting(playlist.account?.info).read
    artwork.display(theme: settings.themePreference, container: playlist, cornerRadius: .small)
    nameLabel.text = playlist.name
    // The server model has no playlist owner field; don't invent an owner.
    subtitle.text = CommonString.songs(playlist.songCount)
    playButton.isEnabled = playlist.songCount > 0
    shuffleButton.isEnabled = playButton.isEnabled
    downloadButton.isEnabled = appDelegate.storage.settings.user.isOnlineMode && !playlist.isCached
    downloadButton.configuration?.image = UIImage(systemName: playlist.isCached ? "checkmark" : "arrow.down")
    downloadButton.accessibilityLabel = playlist.isCached ? "Downloaded".localized : "Download".localized
    setNeedsLayout()
    guard let path = playlist.artwork?.imagePath ?? playlist.getPlayable(at: 0)?.imagePath(setting: settings.artworkDisplayPreference), path != paletteKey else { return }
    paletteKey = path
    paletteTask?.cancel()
    paletteTask = Task { @MainActor [weak self] in
      guard let image = await LibraryEntityImage.loadPreparedImage(at: path), !Task.isCancelled else { return }
      let colors = await Task.detached(priority: .utility) { (try? image.dominantColors(max: 1)) ?? [] }.value
      guard let self, !Task.isCancelled, paletteKey == path, let color = colors.first else { return }
      var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
      color.getRed(&r, green: &g, blue: &b, alpha: &a)
      paletteChanged?(UIColor(red: r * 0.28 + 0.04, green: g * 0.28 + 0.04, blue: b * 0.28 + 0.04, alpha: 1))
    }
  }
  override func layoutSubviews() {
    super.layoutSubviews()
    let width = bounds.width, side = artworkSide(width: bounds.width)
    artwork.frame = CGRect(x: (width-side)/2, y: 12, width: side, height: side)
    let titleY = artwork.frame.maxY + 20, height = titleHeight(width: width)
    nameLabel.frame = CGRect(x: 24, y: titleY, width: width-48, height: height)
    subtitle.frame = CGRect(x: 24, y: nameLabel.frame.maxY, width: width-48, height: 26)
    let y = subtitle.frame.maxY + 16, playWidth = min(156, width * 0.365)
    playButton.frame = CGRect(x: (width-playWidth)/2, y: y, width: playWidth, height: 44)
    shuffleButton.frame = CGRect(x: playButton.frame.minX-58, y: y, width: 44, height: 44)
    downloadButton.frame = CGRect(x: playButton.frame.maxX+14, y: y, width: 44, height: 44)
  }
}

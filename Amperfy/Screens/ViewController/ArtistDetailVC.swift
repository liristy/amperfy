//
//  ArtistDetailVC.swift
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

class ArtistDetailVC: MultiSourceTableViewController {
  override var sceneTitle: String? { artist.name }
  private var previousNavStyle: UIUserInterfaceStyle?
  private var previousNavTint: UIColor?
  let artist: Artist
  var albumToScrollTo: Album?
  private(set) var rankedSongs = [Song]()
  private var albums = [Album]()
  private(set) var artworkHeader: MusicArtworkHeader!
  private var needsRefresh = true

  init(account: Account, artist: Artist) {
    self.artist = artist
    super.init(style: .plain, account: account)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    appDelegate.userStatistics.visited(.artistDetail)
    overrideUserInterfaceStyle = .dark
    navigationItem.largeTitleDisplayMode = .never
    let appearance = UINavigationBarAppearance()
    appearance.configureWithTransparentBackground()
    appearance.titleTextAttributes = [.foregroundColor: UIColor.white]
    navigationItem.standardAppearance = appearance
    navigationItem.scrollEdgeAppearance = appearance
    let options = UIBarButtonItem.createOptionsBarButton()
    options.menu = UIMenu.lazyMenu { EntityPreviewActionBuilder(container: self.artist, on: self).createMenuActions() }
    navigationItem.rightBarButtonItem = options
    tableView.contentInsetAdjustmentBehavior = .never
    tableView.backgroundColor = UIColor(white: 0.16, alpha: 1)
    tableView.separatorColor = .white.withAlphaComponent(0.12)
    tableView.separatorInset = UIEdgeInsets(top: 0, left: 76, bottom: 0, right: 20)
    tableView.register(nibName: PlayableTableCell.typeName)
    tableView.register(ArtistAlbumStripCell.self, forCellReuseIdentifier: "artist-albums")
    artworkHeader = MusicArtworkHeader(entity: artist)
    artworkHeader.playAction = { [weak self] shuffled in
      guard let self else { return }
      let context = PlayContext(containable: artist, playables: rankedSongs)
      if shuffled { appDelegate.player.playShuffled(context: context) } else { appDelegate.player.play(context: context) }
    }
    artworkHeader.secondaryAction = { [weak self] in
      guard let self, appDelegate.storage.settings.user.isOnlineMode else { return }
      Task { @MainActor in
        do { try await self.artist.remoteToggleFavorite(syncer: self.appDelegate.getMeta(self.account.info).librarySyncer) }
        catch { self.appDelegate.eventLogger.report(topic: "Artist Favorite", error: error) }
        self.artworkHeader.refresh()
      }
    }
    artworkHeader.paletteChanged = { [weak self] color in self?.tableView.backgroundColor = color }
    tableView.tableHeaderView = artworkHeader
    containableAtIndexPathCallback = { [weak self] path in
      guard let self, path.section == 0, path.row < min(5, rankedSongs.count) else { return nil }
      return rankedSongs[path.row]
    }
    playContextAtIndexPathCallback = { [weak self] path in self?.songContext(at: path.row) }
    swipeCallback = { [weak self] path, completion in
      guard let self, path.section == 0, path.row < min(5, rankedSongs.count) else { completion(nil); return }
      completion(SwipeActionContext(containable: rankedSongs[path.row], playContext: songContext(at: path.row)))
    }
    NotificationCenter.default.addObserver(self, selector: #selector(libraryChanged(_:)), name: .NSManagedObjectContextObjectsDidChange, object: appDelegate.storage.main.context)
    NotificationCenter.default.addObserver(self, selector: #selector(refreshVisible), name: UIApplication.didBecomeActiveNotification, object: nil)
    refreshContent()
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
    refreshContent()
  }
  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    Task { @MainActor [weak self] in
      guard let self else { return }
      do { try await artist.fetch(storage: appDelegate.storage, librarySyncer: appDelegate.getMeta(account.info).librarySyncer,
                                  playableDownloadManager: appDelegate.getMeta(account.info).playableDownloadManager) }
      catch { appDelegate.eventLogger.report(topic: "Artist Sync", error: error) }
      needsRefresh = true
      refreshVisible()
    }
  }
  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    if let albumToScrollTo, albums.contains(where: { $0.id == albumToScrollTo.id }) {
      tableView.scrollToRow(at: IndexPath(row: 0, section: 1), at: .top, animated: false)
      (tableView.cellForRow(at: IndexPath(row: 0, section: 1)) as? ArtistAlbumStripCell)?.scroll(to: albumToScrollTo)
    }
    albumToScrollTo = nil
  }
  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    guard isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true else { return }
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
    let size = CGSize(width: tableView.bounds.width, height: artworkHeader.preferredHeight(width: tableView.bounds.width))
    if artworkHeader.frame.size != size { artworkHeader.frame.size = size; tableView.tableHeaderView = artworkHeader }
    // The hero extends behind the navigation bar; preserve the system dock reservation below.
    let bottom = view.safeAreaInsets.bottom
    if tableView.contentInset.bottom != bottom { tableView.contentInset.bottom = bottom }
    updateNavigationTitle()
  }
  override func scrollViewDidScroll(_ scrollView: UIScrollView) { updateNavigationTitle() }
  private func updateNavigationTitle() {
    guard let artworkHeader else { return }
    let text = tableView.contentOffset.y > artworkHeader.frame.height - 140 ? artist.name : ""
    if navigationItem.title != text { navigationItem.title = text }
  }
  @objc private func libraryChanged(_ note: Notification) {
    let inserted = note.userInfo?[NSInsertedObjectsKey] as? Set<NSManagedObject> ?? []
    let deleted = note.userInfo?[NSDeletedObjectsKey] as? Set<NSManagedObject> ?? []
    let updated = note.userInfo?[NSUpdatedObjectsKey] as? Set<NSManagedObject> ?? []
    let keys: Set<String> = ["playCount", "title", "name", "artist", "album", "artwork", "isFavorite"]
    guard inserted.union(deleted).contains(where: { $0 is SongMO || $0 is AlbumMO }) ||
      updated.contains(where: { ($0 is SongMO || $0 is AlbumMO || $0 is ArtistMO) && !Set($0.changedValuesForCurrentEvent().keys).isDisjoint(with: keys) }) else { return }
    needsRefresh = true
    refreshVisible()
  }
  @objc private func refreshVisible() {
    guard needsRefresh, viewIfLoaded?.window != nil, UIApplication.shared.applicationState == .active,
          !tableView.isDragging, !tableView.isDecelerating, !isSingleCellEditingModeActive else { return }
    refreshContent()
  }
  private func refreshContent() {
    guard isViewLoaded, UIApplication.shared.applicationState == .active else { needsRefresh = true; return }
    needsRefresh = false
    let offline = appDelegate.storage.settings.user.isOfflineMode
    rankedSongs = artist.songsRankedByPlayCount(onlyCached: offline)
    albums = appDelegate.storage.main.library.getAlbums(for: account, whichContainsSongsWithArtist: artist, onlyCached: offline).sorted {
      $0.year == $1.year ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.year > $1.year
    }
    artworkHeader.playableCount = rankedSongs.count
    artworkHeader.refresh()
    tableView.reloadData()
  }
  private func songContext(at index: Int) -> PlayContext? {
    guard rankedSongs.indices.contains(index) else { return nil }
    return PlayContext(containable: artist, index: index, playables: rankedSongs)
  }
  override func numberOfSections(in tableView: UITableView) -> Int { 2 }
  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    section == 0 ? min(5, rankedSongs.count) : (albums.isEmpty ? 0 : 1)
  }
  override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
    indexPath.section == 0 ? 56 : min(220, tableView.bounds.width * 0.43) + 50
  }
  override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
    let button = UIButton(type: .system)
    button.setTitle((section == 0 ? "Top Songs".localized + " ›" : "Albums".localized), for: .normal)
    button.titleLabel?.font = .systemFont(ofSize: 22, weight: .bold)
    button.setTitleColor(.white, for: .normal)
    button.contentHorizontalAlignment = .leading
    button.configuration = .plain()
    button.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20)
    if section == 0 {
      button.addAction(UIAction { [weak self] _ in
        guard let self else { return }
        navigationController?.pushViewController(ArtistRankingVC(account: account, artist: artist), animated: true)
      }, for: .touchUpInside)
    } else { button.isUserInteractionEnabled = false }
    return button
  }
  override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat { 52 }
  override func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat { 12 }
  override func tableView(_ tableView: UITableView, cellForRowAt path: IndexPath) -> UITableViewCell {
    if path.section == 1 {
      let cell = tableView.dequeueReusableCell(withIdentifier: "artist-albums", for: path) as! ArtistAlbumStripCell
      cell.display(albums: albums, root: self)
      return cell
    }
    let cell: PlayableTableCell = dequeueCell(for: tableView, at: path)
    cell.display(playable: rankedSongs[path.row], playContextCb: nil, rootView: self,
                 playAction: { [weak self] in
                   guard let self, let context = songContext(at: path.row) else { return }
                   appDelegate.player.play(context: context)
                 })
    return cell
  }
}

private final class ArtistAlbumStripCell: UITableViewCell, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
  private let collection: UICollectionView
  private var albums = [Album]()
  private weak var root: ArtistDetailVC?
  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    let layout = UICollectionViewFlowLayout()
    layout.scrollDirection = .horizontal
    layout.minimumLineSpacing = 12
    layout.sectionInset = UIEdgeInsets(top: 0, left: 20, bottom: 0, right: 20)
    collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    backgroundColor = .clear; selectionStyle = .none
    collection.backgroundColor = .clear; collection.showsHorizontalScrollIndicator = false
    collection.dataSource = self; collection.delegate = self
    collection.register(ArtistAlbumTile.self, forCellWithReuseIdentifier: "album")
    contentView.addSubview(collection)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func layoutSubviews() { super.layoutSubviews(); collection.frame = contentView.bounds }
  func display(albums: [Album], root: ArtistDetailVC) { self.albums = albums; self.root = root; collection.reloadData() }
  func scroll(to album: Album) {
    guard let index = albums.firstIndex(where: { $0.id == album.id }) else { return }
    collection.layoutIfNeeded()
    collection.scrollToItem(at: IndexPath(item: index, section: 0), at: .centeredHorizontally, animated: false)
  }
  func collectionView(_ view: UICollectionView, numberOfItemsInSection section: Int) -> Int { albums.count }
  func collectionView(_ view: UICollectionView, layout: UICollectionViewLayout, sizeForItemAt path: IndexPath) -> CGSize {
    let side = max(1, min(220, view.bounds.width * 0.43))
    return CGSize(width: side, height: side + 46)
  }
  func collectionView(_ view: UICollectionView, cellForItemAt path: IndexPath) -> UICollectionViewCell {
    let cell = view.dequeueReusableCell(withReuseIdentifier: "album", for: path) as! ArtistAlbumTile
    cell.display(albums[path.item]); return cell
  }
  func collectionView(_ view: UICollectionView, didSelectItemAt path: IndexPath) {
    guard let root else { return }
    root.navigationController?.pushViewController(AppStoryboard.Main.segueToAlbumDetail(account: root.account, album: albums[path.item]), animated: true)
  }
}

private final class ArtistAlbumTile: UICollectionViewCell {
  private let artwork = EntityImageView(frame: .zero)
  private let title = UILabel(), year = UILabel()
  override init(frame: CGRect) {
    super.init(frame: frame)
    [artwork, title, year].forEach { contentView.addSubview($0) }
    artwork.imageContentMode = .scaleAspectFill; artwork.clipsToBounds = true
    title.font = .systemFont(ofSize: 14); title.textColor = .white
    year.font = .systemFont(ofSize: 12); year.textColor = .white.withAlphaComponent(0.5)
    isAccessibilityElement = true; accessibilityTraits = .button
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  func display(_ album: Album) {
    let settings = appDelegate.storage.settings.accounts.getSetting(album.account?.info).read
    artwork.display(theme: settings.themePreference, container: album)
    title.text = album.name; year.text = album.year > 0 ? String(album.year) : nil
    accessibilityLabel = [title.text, year.text].compactMap { $0 }.joined(separator: ", ")
  }
  override func layoutSubviews() {
    super.layoutSubviews()
    artwork.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.width)
    title.frame = CGRect(x: 0, y: bounds.width + 6, width: bounds.width, height: 18)
    year.frame = CGRect(x: 0, y: bounds.width + 25, width: bounds.width, height: 16)
  }
}

final class ArtistRankingVC: MultiSourceTableViewController {
  private let artist: Artist
  private var songs = [Song]()
  init(account: Account, artist: Artist) { self.artist = artist; super.init(style: .plain, account: account) }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func viewDidLoad() {
    super.viewDidLoad(); title = "Top Songs".localized; overrideUserInterfaceStyle = .dark
    tableView.register(nibName: PlayableTableCell.typeName)
    tableView.backgroundColor = UIColor(white: 0.16, alpha: 1); tableView.rowHeight = 56
    containableAtIndexPathCallback = { [weak self] path in self?.songs[path.row] }
    playContextAtIndexPathCallback = { [weak self] path in self?.context(at: path.row) }
    swipeCallback = { [weak self] path, completion in
      guard let self else { completion(nil); return }
      completion(SwipeActionContext(containable: songs[path.row], playContext: context(at: path.row)))
    }
  }
  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    songs = artist.songsRankedByPlayCount(onlyCached: appDelegate.storage.settings.user.isOfflineMode)
    tableView.reloadData()
  }
  private func context(at index: Int) -> PlayContext { PlayContext(containable: artist, index: index, playables: songs) }
  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { songs.count }
  override func tableView(_ tableView: UITableView, cellForRowAt path: IndexPath) -> UITableViewCell {
    let cell: PlayableTableCell = dequeueCell(for: tableView, at: path)
    cell.display(playable: songs[path.row], playContextCb: nil, rootView: self,
      playAction: { [weak self] in guard let self else { return }; appDelegate.player.play(context: context(at: path.row)) })
    cell.backgroundColor = .clear
    return cell
  }
}

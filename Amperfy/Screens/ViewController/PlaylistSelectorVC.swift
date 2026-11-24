//
//  PlaylistSelectorVC.swift
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

// MARK: - AddToPlaylistSelectMode

enum AddToPlaylistSelectMode {
  case single
  case multi
}

// MARK: - PlaylistsSelectorDiffableDataSource

class PlaylistsSelectorDiffableDataSource: BasicUITableViewDiffableDataSource {
  override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
    // Return false if you do not want the item to be re-orderable.
    false
  }
}

// MARK: - PlaylistSelectorVC

class PlaylistSelectorVC: SingleSnapshotFetchedResultsTableViewController<PlaylistMO> {
  override var sceneTitle: String? { "Playlists".localized }

  private enum DuplicateHandling {
    case skip
    case allow
  }

  let itemsToAdd: [Song]
  var onSongsAdded: (() -> Void)?
  private let sourcePlaylist: Playlist?
  private var selectedPlaylists = [Playlist: DuplicateHandling]()
  private var isCheckingPlaylist = false
  private var isAddingSongs = false

  private var fetchedResultsController: PlaylistSelectorFetchedResultsController!
  private var sortType: PlaylistSortType = .name
  private var selectMode = AddToPlaylistSelectMode.single
  private var optionsButton: UIBarButtonItem!
  private var closeButton: UIBarButtonItem!
  private var selectBarButton: UIBarButtonItem!
  private var addBarButton: UIBarButtonItem!

  init(account: Account, itemsToAdd: [Song], sourcePlaylist: Playlist? = nil) {
    self.itemsToAdd = itemsToAdd
    self.sourcePlaylist = sourcePlaylist
    super.init(style: .grouped, account: account)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func createDiffableDataSource() -> BasicUITableViewDiffableDataSource {
    let source =
      PlaylistsSelectorDiffableDataSource(tableView: tableView) { tableView, indexPath, objectID -> UITableViewCell? in
        guard let object = try? self.appDelegate.storage.main.context
          .existingObject(with: objectID),
          let playlistMO = object as? PlaylistMO
        else {
          return UITableViewCell()
        }
        let playlist = Playlist(
          library: self.appDelegate.storage.main.library,
          managedObject: playlistMO
        )
        return self.createCell(tableView, forRowAt: indexPath, playlist: playlist)
      }
    return source
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    optionsButton = UIBarButtonItem.createSortBarButton()

    appDelegate.userStatistics.visited(.playlistSelector)
    setNavBarTitle(
      title: ((itemsToAdd.count) > 1) ?
        "Add %ld Songs to Playlist".localizedFormat(itemsToAdd.count) : "Add to Playlist".localized
    )

    change(sortType: appDelegate.storage.settings.user.playlistsSortSetting)

    configureSearchController(placeholder: "Search in \"Playlists\"")
    tableView.register(nibName: PlaylistTableCell.typeName)
    tableView.rowHeight = PlaylistTableCell.rowHeight
    tableView.estimatedRowHeight = PlaylistTableCell.rowHeight
    tableView.sectionFooterHeight = 0.0
    tableView.estimatedSectionFooterHeight = 0.0
    tableView.sectionHeaderHeight = 0.0
    tableView.estimatedSectionHeaderHeight = 0.0
    tableView.backgroundColor = .backgroundColor

    tableView.tableHeaderView = UIView(frame: CGRect(
      x: 0,
      y: 0,
      width: view.bounds.size.width,
      height: NewPlaylistTableHeader.frameHeight
    ))
    if let newPlaylistTableHeaderView = ViewCreator<NewPlaylistTableHeader>
      .createFromNib(withinFixedFrame: CGRect(
        x: 0,
        y: 0,
        width: view.bounds.size.width,
        height: NewPlaylistTableHeader.frameHeight
      )) {
      tableView.tableHeaderView?.addSubview(newPlaylistTableHeaderView)
      newPlaylistTableHeaderView.account = account
    }

    navigationController?.setToolbarHidden(false, animated: false)
    let flexible = UIBarButtonItem(
      barButtonSystemItem: UIBarButtonItem.SystemItem.flexibleSpace,
      target: self,
      action: nil
    )
    selectBarButton = UIBarButtonItem(
      title: "Select".localized,
      style: .plain,
      target: self,
      action: #selector(selectBarButtonPressed)
    )
    addBarButton = UIBarButtonItem(
      image: .plus,
      style: .plain,
      target: self,
      action: #selector(addBarButtonPressed)
    )
    toolbarItems = [selectBarButton, flexible, addBarButton]
    refreshAddButton()
  }

  func change(sortType: PlaylistSortType) {
    self.sortType = sortType
    // sortType will not be saved permanently. This behaviour differs from PlaylistsVC
    singleFetchedResultsController?.clearResults()
    tableView.reloadData()
    fetchedResultsController = PlaylistSelectorFetchedResultsController(
      coreDataCompanion: appDelegate.storage.main, account: account,
      sortType: sortType,
      isGroupedInAlphabeticSections: sortType.asSectionIndexType != .none
    )
    singleFetchedResultsController = fetchedResultsController
    singleFetchedResultsController?.delegate = self
    singleFetchedResultsController?.fetch()
    tableView.reloadData()
    updateRightBarButtonItems()
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    updateRightBarButtonItems()
    guard appDelegate.storage.settings.user.isOnlineMode else { return }
    Task { @MainActor in do {
      try await self.appDelegate.getMeta(self.account.info).librarySyncer
        .syncDownPlaylistsWithoutSongs()
    } catch {
      self.appDelegate.eventLogger.report(topic: "Playlists Sync", error: error)
    }}
  }

  func updateRightBarButtonItems() {
    closeButton = UIBarButtonItem.createCloseBarButton(
      target: self,
      selector: #selector(cancelBarButtonPressed)
    )
    closeButton.isEnabled = !isAddingSongs
    optionsButton = UIBarButtonItem.createOptionsBarButton()
    optionsButton.menu = createSortButtonMenu()
    navigationItem.rightBarButtonItems = [closeButton, optionsButton]
  }

  @IBAction
  func addBarButtonPressed(_ sender: UIBarButtonItem) {
    guard !isCheckingPlaylist, !selectedPlaylists.isEmpty else { return }
    addSongsToSelectedPlaylists()
  }

  private func addSongsToSelectedPlaylists() {
    guard !isAddingSongs else { return }
    isAddingSongs = true
    navigationController?.isModalInPresentation = true
    tableView.tableHeaderView?.isUserInteractionEnabled = false
    refreshAddButton()
    let additions = selectedPlaylists
    let syncer = appDelegate.getMeta(account.info).librarySyncer
    let isMulti = selectMode == .multi
    Task { @MainActor in
      var addedSongs = false
      for (playlist, handling) in additions {
        do {
          guard appDelegate.networkMonitor.isConnectedToNetwork else {
            throw URLError(.notConnectedToInternet)
          }
          if isMulti, handling == .skip, !playlist.id.isEmpty {
            try await syncer.syncDown(playlist: playlist)
          }
          let songs = handling == .skip ? songsNotIn(playlist) : itemsToAdd
          if !songs.isEmpty {
            try await syncer.syncUpload(playlistToAddSongs: playlist, songs: songs)
            playlist.append(playables: songs)
            addedSongs = true
          }
          selectedPlaylists.removeValue(forKey: playlist)
          updatePlaylistSelection(playlist)
        } catch {
          appDelegate.eventLogger.report(topic: "Playlist Add Songs".localized, error: error)
        }
      }
      isAddingSongs = false
      navigationController?.isModalInPresentation = false
      tableView.tableHeaderView?.isUserInteractionEnabled = true
      if selectedPlaylists.isEmpty {
        if addedSongs { onSongsAdded?() }
        dismiss()
      } else {
        if !isMulti { selectedPlaylists.removeAll() }
        refreshAddButton()
      }
    }
  }

  @IBAction
  func selectBarButtonPressed(_ sender: Any) {
    selectMode = ((selectMode == .single) ? .multi : .single)
    selectBarButton.isSelected = (selectMode == .multi)
    selectedPlaylists.removeAll()
    refreshAddButton()
    tableView.reloadData()
  }

  func refreshAddButton() {
    let canSelect = !isCheckingPlaylist && !isAddingSongs
    selectBarButton.isEnabled = canSelect
    addBarButton.isEnabled = canSelect && !selectedPlaylists.isEmpty
    closeButton.isEnabled = !isAddingSongs
  }

  @IBAction
  func cancelBarButtonPressed(_ sender: UIBarButtonItem) {
    dismiss()
  }

  private func createSortButtonMenu() -> UIMenu {
    let sortByName = UIAction(
      title: "Name".localized,
      image: sortType == .name ? .check : nil,
      handler: { _ in
        self.change(sortType: .name)
        self.updateSearchResults(for: self.searchController)
        self.appDelegate.notificationHandler.post(
          name: .fetchControllerSortChanged,
          object: nil,
          userInfo: nil
        )
      }
    )
    let sortByLastTimePlayed = UIAction(
      title: "Last time played".localized,
      image: sortType == .lastPlayed ? .check : nil,
      handler: { _ in
        self.change(sortType: .lastPlayed)
        self.updateSearchResults(for: self.searchController)
        self.appDelegate.notificationHandler.post(
          name: .fetchControllerSortChanged,
          object: nil,
          userInfo: nil
        )
      }
    )
    let sortByChangeDate = UIAction(
      title: "Change date".localized,
      image: sortType == .lastChanged ? .check : nil,
      handler: { _ in
        self.change(sortType: .lastChanged)
        self.updateSearchResults(for: self.searchController)
        self.appDelegate.notificationHandler.post(
          name: .fetchControllerSortChanged,
          object: nil,
          userInfo: nil
        )
      }
    )
    let sortByDuration = UIAction(
      title: "Duration".localized,
      image: sortType == .duration ? .check : nil,
      handler: { _ in
        self.change(sortType: .duration)
        self.updateSearchResults(for: self.searchController)
        self.appDelegate.notificationHandler.post(
          name: .fetchControllerSortChanged,
          object: nil,
          userInfo: nil
        )
      }
    )
    return UIMenu(
      title: "Sort".localized,
      image: .sort,
      options: [],
      children: [sortByName, sortByLastTimePlayed, sortByChangeDate, sortByDuration]
    )
  }

  private func dismiss() {
    searchController.dismiss(animated: false, completion: nil)
    dismiss(animated: true, completion: nil)
  }

  func createCell(
    _ tableView: UITableView,
    forRowAt indexPath: IndexPath,
    playlist: Playlist
  )
    -> UITableViewCell {
    let cell: PlaylistTableCell = dequeueCell(for: tableView, at: indexPath)
    cell.display(playlist: playlist, rootView: nil)
    let isSource = playlist.managedObject.objectID == sourcePlaylist?.managedObject.objectID
    cell.contentView.alpha = isSource ? 0.45 : 1
    if isSource {
      cell.accessibilityTraits.insert(.notEnabled)
    } else {
      cell.accessibilityTraits.remove(.notEnabled)
    }

    if selectMode == .multi, !isSource {
      let isMarked = (selectedPlaylists[playlist] != nil)
      let img = UIImageView(image: isMarked ? .checkmark : .circle)
      img.tintColor = isMarked ? appDelegate.storage.settings.accounts
        .getSetting(playlist.account?.info).read
        .themePreference
        .asColor : .secondaryLabelColor
      cell.accessoryView = img
    } else {
      cell.accessoryView = nil
    }

    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: false)
    guard !isCheckingPlaylist, !isAddingSongs,
          let objectID = diffableDataSource?.itemIdentifier(for: indexPath),
          objectID != sourcePlaylist?.managedObject.objectID,
          let playlistMO = (try? appDelegate.storage.main.context
            .existingObject(with: objectID)) as? PlaylistMO,
          !playlistMO.isDeleted else { return }

    let playlist = Playlist(
      library: appDelegate.storage.main.library,
      managedObject: playlistMO
    )
    if selectedPlaylists.removeValue(forKey: playlist) != nil {
      updatePlaylistSelection(playlist)
      return
    }

    isCheckingPlaylist = true
    refreshAddButton()
    Task { @MainActor in
      defer {
        isCheckingPlaylist = false
        refreshAddButton()
      }
      do {
        guard appDelegate.networkMonitor.isConnectedToNetwork else {
          throw URLError(.notConnectedToInternet)
        }
        if !playlist.id.isEmpty {
          try await appDelegate.getMeta(account.info).librarySyncer.syncDown(playlist: playlist)
        }
        guard viewIfLoaded?.window != nil, navigationController?.isBeingDismissed == false,
              !playlist.managedObject.isDeleted else { return }
        confirmSelection(of: playlist)
      } catch {
        appDelegate.eventLogger.report(topic: "Playlist Sync", error: error)
      }
    }
  }

  private func confirmSelection(of playlist: Playlist) {
    let newSongs = songsNotIn(playlist)
    func select(_ handling: DuplicateHandling) {
      guard handling == .allow ? !itemsToAdd.isEmpty : !newSongs.isEmpty else { return }
      selectedPlaylists[playlist] = handling
      if selectMode == .single {
        addSongsToSelectedPlaylists()
      } else {
        updatePlaylistSelection(playlist)
      }
    }

    guard newSongs.count != itemsToAdd.count else {
      select(.skip)
      return
    }
    let alert = UIAlertController(
      title: nil,
      message: "Some Songs are already in this Playlist.".localized,
      preferredStyle: .alert
    )
    let skipDuplicates = UIAlertAction(title: "Skip Duplicates".localized, style: .default) { _ in
      select(.skip)
    }
    alert.addAction(skipDuplicates)
    alert.addAction(UIAlertAction(title: "Add Duplicates".localized, style: .default) { _ in
      select(.allow)
    })
    alert.addAction(UIAlertAction(title: "Cancel".localized, style: .cancel))
    alert.preferredAction = skipDuplicates
    present(alert, animated: true)
  }

  private func songsNotIn(_ playlist: Playlist) -> [Song] {
    Array(playlist.notContaines(playables: itemsToAdd)).filterSongs()
  }

  private func updatePlaylistSelection(_ playlist: Playlist) {
    refreshAddButton()
    guard let diffableDataSource else { return }
    var snapshot = diffableDataSource.snapshot()
    let objectID = playlist.managedObject.objectID
    guard snapshot.indexOfItem(objectID) != nil else { return }
    snapshot.reconfigureItems([objectID])
    diffableDataSource.apply(snapshot)
  }

  override func updateSearchResults(for searchController: UISearchController) {
    let searchText = searchController.searchBar.text ?? ""
    fetchedResultsController.search(searchText: searchText)
    tableView.reloadData()
  }
}

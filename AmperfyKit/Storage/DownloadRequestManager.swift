//
//  DownloadRequestManager.swift
//  AmperfyKit
//
//  Created by Maximilian Bauer on 21.07.21.
//  Copyright (c) 2021 Maximilian Bauer. All rights reserved.
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

import CoreData
import Foundation

// MARK: - DownloadTaskInfo

struct DownloadTaskInfo: Sendable {
  let request: DownloadRequest
  let url: URL
  var httpHeaders: [String: String] = [:]
  var hasStarted = false
}

typealias GetDownloadManagerDelegateCB = @MainActor () -> DownloadManagerDelegate

// MARK: - DownloadRequestManager

actor DownloadRequestManager {
  private let accountObjectId: NSManagedObjectID
  private let storage: AsyncCoreDataAccessWrapper
  private let getDownloadDelegateCB: GetDownloadManagerDelegateCB
  private var mutationInProgress = false
  private var mutationWaiters = [CheckedContinuation<Void, Never>]()

  // Each storage call creates its own background context. Actor isolation alone
  // is not enough: another add can enter while the first context is saving.
  private func acquireMutation() async {
    if mutationInProgress {
      await withCheckedContinuation { mutationWaiters.append($0) }
    } else {
      mutationInProgress = true
    }
  }

  private func releaseMutation() {
    if mutationWaiters.isEmpty {
      mutationInProgress = false
    } else {
      mutationWaiters.removeFirst().resume()
    }
  }

  init(
    accountObjectId: NSManagedObjectID,
    storage: AsyncCoreDataAccessWrapper,
    getDownloadDelegateCB: @escaping GetDownloadManagerDelegateCB
  ) {
    self.accountObjectId = accountObjectId
    self.storage = storage
    self.getDownloadDelegateCB = getDownloadDelegateCB
  }

  func add(downloadInfo: DownloadElementInfo) async -> DownloadRequest? {
    await acquireMutation()
    defer { releaseMutation() }
    let request = try? await storage.performAndGet { asyncCompanion -> DownloadRequest? in
      let asyncObject = Download.createDownloadableObject(
        inContext: asyncCompanion.context,
        info: downloadInfo
      )
      let download = self.addLowPrio(object: asyncObject, library: asyncCompanion.library)
      guard let download else { return nil }
      return DownloadRequest(
        objectID: download.managedObject.objectID,
        id: asyncObject.uniqueID,
        title: download.title,
        info: downloadInfo
      )
    }
    return request
  }

  func add(downloadInfos: [DownloadElementInfo]) async -> [DownloadRequest] {
    guard !downloadInfos.isEmpty else { return [] }
    await acquireMutation()
    defer { releaseMutation() }
    return try! await storage.performAndGet { asyncCompanion in
      var asyncRequests = [DownloadRequest]()
      var objects = [(DownloadElementInfo, Downloadable)]()
      downloadInfos.forEach {
        let downloadable = Download.createDownloadableObject(
          inContext: asyncCompanion.context,
          info: $0
        )
        objects.append(($0, downloadable))
      }
      let asyncDownloads = self.addLowPrio(objects: objects, library: asyncCompanion.library)
      asyncDownloads.forEach {
        asyncRequests.append(DownloadRequest(
          objectID: $0.2.managedObject.objectID,
          id: $0.1.uniqueID, title: $0.2.title, info: $0.0
        ))
      }
      return asyncRequests
    }
  }

  nonisolated private func addLowPrio(
    objects: [(DownloadElementInfo, Downloadable)],
    library: LibraryStorage
  )
    -> [(DownloadElementInfo, Downloadable, Download)] {
    var hasCoreDataChanges = false
    let account = library.getAccount(managedObjectId: accountObjectId)
    let ids = Set(objects.compactMap { $0.1.uniqueID })
    let existingDownloadsDict = library.getDownloadsDict(account: account, ids: ids)
    var seen = Set<String>()

    var downloadMapping = [(DownloadElementInfo, Downloadable, Download)]()
    for (info, object) in objects {
      guard seen.insert(object.uniqueID).inserted else { continue }
      // Recheck in the current context: caching may have completed since the
      // caller checked its main-context object.
      guard info.type != .playable || !object.isCached else { continue }
      if let existingDownload = existingDownloadsDict[object.uniqueID] {
        if !existingDownload.isDownloading,
           existingDownload.errorDate != nil || (existingDownload.finishDate != nil && !object.isCached) {
          existingDownload.reset()
          hasCoreDataChanges = true
          downloadMapping.append((info, object, existingDownload))
        } else {
          // do nothing: the download has already an unused request
        }
      } else {
        hasCoreDataChanges = true
        let newDownload = library.createDownload(account: account, id: object.uniqueID)
        newDownload.element = object
        downloadMapping.append((info, object, newDownload))
      }
    }

    if hasCoreDataChanges {
      library.saveContext()
    }
    return downloadMapping
  }

  nonisolated private func addLowPrio(object: Downloadable, library: LibraryStorage) -> Download? {
    guard let info = object.threadSafeInfo else { return nil }
    return addLowPrio(objects: [(info, object)], library: library).first?.2
  }

  /// Repair records created by older concurrent enqueues before starting tasks.
  /// This removes queue metadata only; cached audio/artwork files are retained.
  func repairDuplicateDownloads() async {
    await acquireMutation()
    defer { releaseMutation() }
    let predicate = await getDownloadDelegateCB().requestPredicate.predicateFormat
    try? await storage.perform { companion in
      let account = companion.library.getAccount(managedObjectId: self.accountObjectId)
      let fetch: NSFetchRequest<DownloadMO> = DownloadMO.creationDateSortedFetchRequest
      fetch.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
        companion.library.getFetchPredicate(forAccount: account),
        NSCompoundPredicate(orPredicateWithSubpredicates: [
          NSPredicate(format: predicate),
          NSPredicate(format: "playable == nil AND artwork == nil"),
        ]),
      ])
      let rows = try companion.context.fetch(fetch)
      var retained = [String: (Download, DownloadElementInfo)]()
      var removed = [Download]()
      for row in rows {
        let download = Download(managedObject: row)
        guard let element = download.element, let info = element.threadSafeInfo else {
          removed.append(download)
          continue
        }
        let id = element.uniqueID
        if let previous = retained[id] {
          if element.isCached, download.isFinishedSuccessfully, !previous.0.isFinishedSuccessfully {
            removed.append(previous.0)
            retained[id] = (download, info)
          } else {
            removed.append(download)
          }
        } else {
          retained[id] = (download, info)
        }
      }
      guard !removed.isEmpty else { return }
      removed.forEach { companion.library.deleteDownload($0) }
      companion.context.processPendingChanges()
      // Restore the inverse link in stores whose concurrent writes left more
      // than one download pointing at the same playable/artwork.
      for (id, (download, info)) in retained {
        let element = Download.createDownloadableObject(inContext: companion.context, info: info)
        download.managedObject.playable = nil
        download.managedObject.artwork = nil
        download.element = element
        download.id = id
      }
    }
  }

  func removeFinishedDownload(for uniqueID: String) async {
    try? await storage.perform { asyncCompanion in
      let account = asyncCompanion.library.getAccount(managedObjectId: self.accountObjectId)
      guard let existingDownload = asyncCompanion.library.getDownload(
        account: account,
        id: uniqueID
      ),
        existingDownload.finishDate != nil
      else { return }
      asyncCompanion.library.deleteDownload(existingDownload)
      asyncCompanion.saveContext()
    }
  }

  func removeFinishedDownload(for uniqueIDs: [String]) async {
    try? await storage.perform { asyncCompanion in
      let account = asyncCompanion.library.getAccount(managedObjectId: self.accountObjectId)
      for uniqueID in uniqueIDs {
        guard let existingDownload = asyncCompanion.library.getDownload(
          account: account,
          id: uniqueID
        ),
          existingDownload.finishDate != nil
        else { continue }
        asyncCompanion.library.deleteDownload(existingDownload)
      }
      asyncCompanion.saveContext()
    }
  }

  func getRequestedDownloads(excluding activeIDs: Set<String> = []) async -> [DownloadRequest] {
    let predicateFormat = await getDownloadDelegateCB().requestPredicate.predicateFormat
    let requestedDownloads = try? await storage.performAndGet { asyncCompanion in
      let account = asyncCompanion.library.getAccount(managedObjectId: self.accountObjectId)
      let fetchRequest: NSFetchRequest<DownloadMO> = DownloadMO.creationDateSortedFetchRequest
      fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
        NSPredicate(format: predicateFormat),
        NSPredicate(format: "%K == nil", #keyPath(DownloadMO.finishDate)),
        NSPredicate(format: "%K == nil", #keyPath(DownloadMO.errorDate)),
        asyncCompanion.library.getFetchPredicate(forAccount: account),
        // ignore start date -> reset it after fetched
      ])
      let downloadsMO = try? asyncCompanion.context.fetch(fetchRequest)
      let downloadRequests = downloadsMO?.compactMap { downloadMo -> DownloadRequest? in
        let download = Download(managedObject: downloadMo)
        guard !activeIDs.contains(download.id) else { return nil }
        download.startDate = nil
        let id = download.id
        guard let element = download.element else { return nil }
        return DownloadRequest(
          objectID: downloadMo.objectID,
          id: id,
          title: download.title,
          info: DownloadElementInfo(objectId: element.objectID, type: download.baseType)
        )
      }
      asyncCompanion.saveContext()
      return downloadRequests
    }
    return requestedDownloads ?? []
  }

  func clearFinishedDownloads() async {
    let downloadPredicateFormat = await getDownloadDelegateCB().requestPredicate.predicateFormat
    try? await storage.perform { asyncCompanion in
      let account = asyncCompanion.library.getAccount(managedObjectId: self.accountObjectId)
      let fetchRequest: NSFetchRequest<DownloadMO> = DownloadMO.creationDateSortedFetchRequest
      fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
        NSPredicate(format: downloadPredicateFormat),
        NSCompoundPredicate(orPredicateWithSubpredicates: [
          NSPredicate(format: "%K != nil", #keyPath(DownloadMO.finishDate)),
          NSPredicate(format: "%K != nil", #keyPath(DownloadMO.errorDate)),
          asyncCompanion.library.getFetchPredicate(forAccount: account),
        ]),
      ])
      let results = try? asyncCompanion.context.fetch(fetchRequest)
      let downloads = results?.compactMap { Download(managedObject: $0) }
      downloads?.forEach { asyncCompanion.library.deleteDownload($0) }
      asyncCompanion.saveContext()
    }
  }

  nonisolated func clearAllDownloadsAsyncIfAllHaveFinished() {
    Task { await clearAllDownloadsIfAllHaveFinished() }
  }

  private func clearAllDownloadsIfAllHaveFinished() async {
    await acquireMutation()
    defer { releaseMutation() }
    let downloadPredicateFormat = await getDownloadDelegateCB().requestPredicate.predicateFormat
    let notStartedDownloadCount = try? await storage.performAndGet { asyncCompanion in
      let account = asyncCompanion.library.getAccount(managedObjectId: self.accountObjectId)
      let request: NSFetchRequest<DownloadMO> = DownloadMO.creationDateSortedFetchRequest
      request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
        NSPredicate(format: downloadPredicateFormat),
        NSPredicate(format: "%K == nil", #keyPath(DownloadMO.startDate)),
        asyncCompanion.library.getFetchPredicate(forAccount: account),
      ])
      return (try? asyncCompanion.context.count(for: request)) ?? 0
    }

    if notStartedDownloadCount == 0 {
      await clearAllDownloads()
    }
  }

  func clearAllDownloads() async {
    let downloadPredicateFormat = await getDownloadDelegateCB().requestPredicate.predicateFormat
    try? await storage.perform { asyncCompanion in
      let account = asyncCompanion.library.getAccount(managedObjectId: self.accountObjectId)
      let fetchRequest: NSFetchRequest<DownloadMO> = DownloadMO.creationDateSortedFetchRequest
      fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
        NSPredicate(format: downloadPredicateFormat),
        asyncCompanion.library.getFetchPredicate(forAccount: account),
      ])
      let results = try? asyncCompanion.context.fetch(fetchRequest)
      let downloads = results?.compactMap { Download(managedObject: $0) }
      downloads?.forEach { asyncCompanion.library.deleteDownload($0) }
      asyncCompanion.saveContext()
    }
  }

  func cancelDownloads() async {
    let downloadPredicateFormat = await getDownloadDelegateCB().requestPredicate.predicateFormat
    try? await storage.perform { asyncCompanion in
      let account = asyncCompanion.library.getAccount(managedObjectId: self.accountObjectId)
      let fetchRequest: NSFetchRequest<DownloadMO> = DownloadMO.creationDateSortedFetchRequest
      fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
        NSPredicate(format: downloadPredicateFormat),
        NSPredicate(format: "%K == nil", #keyPath(DownloadMO.finishDate)),
        NSPredicate(format: "%K == nil", #keyPath(DownloadMO.errorDate)),
        asyncCompanion.library.getFetchPredicate(forAccount: account),
      ])
      let results = try? asyncCompanion.context.fetch(fetchRequest)
      let downloads = results?.compactMap { Download(managedObject: $0) }
      downloads?.forEach { $0.isCanceled = true }
      asyncCompanion.saveContext()
    }
  }

  func getAndResetFailedDownloads() async -> [DownloadRequest] {
    let predicateFormat = await getDownloadDelegateCB().requestPredicate.predicateFormat
    let failedDownloads = try? await storage.performAndGet { asyncCompanion in
      let account = asyncCompanion.library.getAccount(managedObjectId: self.accountObjectId)
      let fetchRequest: NSFetchRequest<DownloadMO> = DownloadMO.creationDateSortedFetchRequest
      fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
        NSPredicate(format: predicateFormat),
        NSPredicate(format: "%K != nil", #keyPath(DownloadMO.errorDate)),
        asyncCompanion.library.getFetchPredicate(forAccount: account),
      ])
      let downloadsMO = try? asyncCompanion.context.fetch(fetchRequest)
      let downloadRequests = downloadsMO?.compactMap { downloadMo -> DownloadRequest? in
        let download = Download(managedObject: downloadMo)
        let id = download.id
        download.reset()
        guard let element = download.element else { return nil }
        return DownloadRequest(
          objectID: downloadMo.objectID,
          id: id,
          title: download.title,
          info: DownloadElementInfo(objectId: element.objectID, type: download.baseType)
        )
      }
      return downloadRequests
    }
    return failedDownloads ?? []
  }
}

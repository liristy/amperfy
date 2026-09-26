//
//  ArtworkTest.swift
//  AmperfyKitTests
//
//  Created by Maximilian Bauer on 01.01.20.
//  Copyright (c) 2020 Maximilian Bauer. All rights reserved.
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

@testable import AmperfyKit
import UIKit
import XCTest

@MainActor
class ArtworkTest: XCTestCase {
  var cdHelper: CoreDataHelper!
  var library: LibraryStorage!
  var account: Account!
  var testArtwork: Artwork!

  override func setUp() async throws {
    cdHelper = CoreDataHelper()
    library = cdHelper.createSeededStorage()
    account = library.getAccount(info: TestAccountInfo.create1())
    testArtwork = library.createArtwork(account: account)
  }

  override func tearDown() {}

  func testEveryThemeHasReadablePlaceholdersInBothAppearances() {
    let bundle = Bundle(for: Artwork.self)
    for theme in ThemePreference.allCases {
      for artworkType in ArtworkType.allCases {
        for appearance in [UIUserInterfaceStyle.light, .dark] {
          let resource = theme.assetName + artworkType.description
          let traits = UITraitCollection(userInterfaceStyle: appearance)
          let image = UIImage(named: resource, in: bundle, compatibleWith: traits)
          XCTAssertNotNil(image, "Missing placeholder: \(resource), \(appearance.rawValue)")
          XCTAssertGreaterThan(image?.size.width ?? 0, 0)
          traits.performAsCurrent {
            XCTAssertGreaterThan(
              UIImage.getGeneratedArtwork(theme: theme, artworkType: artworkType).size.width,
              0
            )
          }
        }
      }
    }
  }

  func testFailedArtworkRequestCanRetryWithoutDuplicatingPendingDownloads() async throws {
    testArtwork.id = "retry-cover"
    testArtwork.status = .NotChecked
    library.saveContext()
    let info = try XCTUnwrap(testArtwork.threadSafeInfo)
    let asyncStorage = AsyncCoreDataAccessWrapper(persistentContainer: cdHelper.persistentContainer)
    let manager = DownloadRequestManager(
      accountObjectId: account.managedObject.objectID,
      storage: asyncStorage,
      getDownloadDelegateCB: { MOCK_DownloadManagerDelegate() }
    )
    let created = await manager.add(downloadInfo: info)
    let requestID = try XCTUnwrap(created?.objectID)
    let duplicate = await manager.add(downloadInfo: info)
    XCTAssertNil(duplicate)

    try await asyncStorage.perform { companion in
      let download = Download(managedObject: companion.context.object(with: requestID) as! DownloadMO)
      download.error = .fetchFailed
      download.isDownloading = false
    }
    let retried = await manager.add(downloadInfo: info)
    XCTAssertEqual(retried?.objectID, requestID)
    let duplicateRetry = await manager.add(downloadInfo: info)
    XCTAssertNil(duplicateRetry)

    // A completed download whose file was lost must also be recoverable.
    try await asyncStorage.perform { companion in
      let download = Download(managedObject: companion.context.object(with: requestID) as! DownloadMO)
      download.isDownloading = false
    }
    let missingCacheRetry = await manager.add(downloadInfo: info)
    XCTAssertEqual(missingCacheRetry?.objectID, requestID)
  }

  func testCreation() {
    let artwork = library.createArtwork(account: account)
    XCTAssertEqual(artwork.account?.serverHash, TestAccountInfo.test1ServerHash)
    XCTAssertEqual(artwork.account?.userHash, TestAccountInfo.test1UserHash)
    XCTAssertEqual(artwork.status.rawValue, ImageStatus.IsDefaultImage.rawValue)
    XCTAssertEqual(artwork.id, "")
    XCTAssertEqual(artwork.type, "")
    XCTAssertNil(artwork.imagePath)
    XCTAssertEqual(artwork.owners.count, 0)
  }

  func testStatus() {
    testArtwork.status = ImageStatus.FetchError
    XCTAssertEqual(testArtwork.status, ImageStatus.FetchError)
    guard let artist1 = library.getArtist(for: account, id: cdHelper.seeder.artists[0].id)
    else { XCTFail(); return }
    artist1.managedObject.artwork = testArtwork.managedObject
    library.saveContext()
    guard let artistFetched = library.getArtist(for: account, id: cdHelper.seeder.artists[0].id)
    else { XCTFail(); return }
    XCTAssertEqual(artistFetched.artwork?.status, ImageStatus.FetchError)
  }

  func testImageWithCorrectStatus() {
    testArtwork.status = ImageStatus.CustomImage
    let testData = Data(base64Encoded: "Test", options: .ignoreUnknownCharacters)!
    let relFilePath = URL(string: "testArtwork")!
    let absFilePath = CacheFileManager.shared.getAbsoluteAmperfyPath(relFilePath: relFilePath)!
    try! CacheFileManager.shared.writeDataExcludedFromBackup(
      data: testData,
      to: absFilePath,
      accountInfo: account.info
    )
    testArtwork.relFilePath = relFilePath
    XCTAssertEqual(testArtwork.status, ImageStatus.CustomImage)
    XCTAssertEqual(testArtwork.imagePath, absFilePath.path)
    try! CacheFileManager.shared.removeItem(at: absFilePath, accountInfo: account.info)
  }

  func testImageWithWrongStatus() {
    testArtwork.status = ImageStatus.NotChecked
    let testData = Data(base64Encoded: "Test", options: .ignoreUnknownCharacters)!
    let relFilePath = URL(string: "testArtwork")!
    let absFilePath = CacheFileManager.shared.getAbsoluteAmperfyPath(relFilePath: relFilePath)!
    try! CacheFileManager.shared.writeDataExcludedFromBackup(
      data: testData,
      to: absFilePath,
      accountInfo: account.info
    )
    testArtwork.relFilePath = relFilePath
    XCTAssertEqual(testArtwork.status, ImageStatus.NotChecked)
    XCTAssertNil(testArtwork.imagePath)
    try! CacheFileManager.shared.removeItem(at: absFilePath, accountInfo: account.info)
  }

  func testOwners() {
    guard let artist1 = library.getArtist(for: account, id: cdHelper.seeder.artists[0].id)
    else { XCTFail(); return }
    guard let artist2 = library.getArtist(for: account, id: cdHelper.seeder.artists[1].id)
    else { XCTFail(); return }
    XCTAssertEqual(testArtwork.owners.count, 0)
    artist1.managedObject.artwork = testArtwork.managedObject
    XCTAssertEqual(testArtwork.owners.count, 1)
    artist2.managedObject.artwork = testArtwork.managedObject
    XCTAssertEqual(testArtwork.owners.count, 2)
  }
}

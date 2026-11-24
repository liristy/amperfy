//
//  SsAlbumParserDelegate.swift
//  AmperfyKit
//
//  Created by Maximilian Bauer on 05.04.19.
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

import CoreData
import Foundation
import os.log
import UIKit

class SsAlbumParserDelegate: SsXmlLibWithArtworkParser {
  var guessedArtist: Artist?
  var guessedGenre: Genre?
  var parsedAlbums = [Album]()
  var clearsMissingReleaseDate = false
  private var albumBuffer: Album?
  private var elementDepth = 0
  private var albumDepth: Int?
  private var explicitYear: Int?
  private var releaseDate: DateComponents?
  private var originalReleaseDate: DateComponents?

  private static let releaseCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    return calendar
  }()

  override func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String]
  ) {
    super.parser(
      parser,
      didStartElement: elementName,
      namespaceURI: namespaceURI,
      qualifiedName: qName,
      attributes: attributeDict
    )
    elementDepth += 1
    if let albumDepth, elementDepth == albumDepth + 1 {
      switch elementName {
      case "releaseDate":
        releaseDate = Self.releaseDateComponents(attributeDict)
      case "originalReleaseDate":
        originalReleaseDate = Self.releaseDateComponents(attributeDict)
      default:
        break
      }
    }

    if elementName == "album", albumDepth == nil {
      guard let albumId = attributeDict["id"] else { return }
      albumDepth = elementDepth

      if let prefetchedAlbum = prefetch.prefetchedAlbumDict[albumId] {
        albumBuffer = prefetchedAlbum
        guessedArtist = prefetchedAlbum.artist
        guessedGenre = prefetchedAlbum.genre
      } else {
        albumBuffer = library.createAlbum(account: account)
        prefetch.prefetchedAlbumDict[albumId] = albumBuffer
        albumBuffer?.id = albumId
        guessedArtist = nil
        guessedGenre = nil
      }
      albumBuffer?.remoteStatus = .available

      if let attributeAlbumtName = attributeDict["name"] {
        albumBuffer?.name = attributeAlbumtName
      }
      if let attributeCoverArt = attributeDict["coverArt"] {
        albumBuffer?.artwork = parseArtwork(id: attributeCoverArt)
      }
      albumBuffer?.rating = Int(attributeDict["userRating"] ?? "0") ?? 0
      albumBuffer?.isFavorite = attributeDict["starred"] != nil
      explicitYear = attributeDict["year"].flatMap { Int($0) }
      if let explicitYear {
        albumBuffer?.year = explicitYear
      }
      if let attributeSongCount = attributeDict["songCount"],
         let songCount = Int(attributeSongCount) {
        albumBuffer?.remoteSongCount = songCount
      }
      if let attributeDuration = attributeDict["duration"], let duration = Int(attributeDuration) {
        albumBuffer?.remoteDuration = duration
      }

      if let artistId = attributeDict["artistId"] {
        if let guessedArtist, guessedArtist.id == artistId {
          albumBuffer?.artist = guessedArtist
        } else if let prefetchedArtist = prefetch.prefetchedArtistDict[artistId] {
          albumBuffer?.artist = prefetchedArtist
        } else if let artistName = attributeDict["artist"] {
          let artist = library.createArtist(account: account)
          prefetch.prefetchedArtistDict[artistId] = artist
          artist.id = artistId
          artist.name = artistName
          os_log(
            "Artist <%s> with id %s has been created",
            log: log,
            type: .error,
            artistName,
            artistId
          )
          albumBuffer?.artist = artist
        }
      }

      if let genreName = attributeDict["genre"] {
        if let guessedGenre, guessedGenre.name == genreName {
          albumBuffer?.genre = guessedGenre
        } else if let prefetchedGenre = prefetch.prefetchedGenreDict[genreName] {
          albumBuffer?.genre = prefetchedGenre
        } else {
          let genre = library.createGenre(account: account)
          prefetch.prefetchedGenreDict[genreName] = genre
          genre.name = genreName
          os_log("Genre <%s> has been created", log: log, type: .error, genreName)
          albumBuffer?.genre = genre
        }
      }
    }
  }

  override func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    if elementName == "album", elementDepth == albumDepth {
      parsedCount += 1
      if let album = albumBuffer {
        let fullDate = Self.completeDate(releaseDate) ?? Self.completeDate(originalReleaseDate)
        if fullDate != nil || clearsMissingReleaseDate {
          album.releaseDate = fullDate
        }
        if (explicitYear ?? 0) <= 0, let dateYear = releaseDate?.year ?? originalReleaseDate?.year {
          album.year = dateYear
        }
        parsedAlbums.append(album)
      }
      albumBuffer = nil
      albumDepth = nil
      explicitYear = nil
      releaseDate = nil
      originalReleaseDate = nil
    }
    elementDepth -= 1

    super.parser(
      parser,
      didEndElement: elementName,
      namespaceURI: namespaceURI,
      qualifiedName: qName
    )
  }

  private static func releaseDateComponents(_ attributes: [String: String]) -> DateComponents? {
    guard let year = attributes["year"].flatMap({ Int($0) }), (1 ... 9999).contains(year) else {
      return nil
    }
    return DateComponents(
      year: year,
      month: attributes["month"].flatMap { Int($0) },
      day: attributes["day"].flatMap { Int($0) }
    )
  }

  private static func completeDate(_ components: DateComponents?) -> Date? {
    guard let components, components.month != nil, components.day != nil,
          components.isValidDate(in: releaseCalendar) else { return nil }
    return releaseCalendar.date(from: components)
  }
}

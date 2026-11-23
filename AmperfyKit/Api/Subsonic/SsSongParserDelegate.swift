//
//  SsSongParserDelegate.swift
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

class SsSongParserDelegate: SsPlayableParserDelegate {
  var songBuffer: Song?
  var parsedSongs = [Song]()
  var guessedArtist: Artist?
  var guessedAlbum: Album?
  var guessedGenre: Genre?
  private var artistDisplayName: String?
  private var legacyArtistName: String?
  private var creditedArtists = [String]()

  override func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String]
  ) {
    if elementName == "song" || elementName == "entry" || elementName == "child" || elementName ==
      "episode" {
      guard let songId = attributeDict["id"] else { return }
      let isDir = attributeDict["isDir"] ?? "false"
      guard let isDirBool = Bool(isDir), isDirBool == false else { return }
      artistDisplayName = attributeDict["displayArtist"]?.trimmingCharacters(in: .whitespacesAndNewlines)
      legacyArtistName = attributeDict["artist"]?.trimmingCharacters(in: .whitespacesAndNewlines)
      creditedArtists.removeAll(keepingCapacity: true)

      if let prefetchedSong = prefetch.prefetchedSongDict[songId] {
        songBuffer = prefetchedSong
        songBuffer?.remoteStatus = .available
        guessedArtist = prefetchedSong.artist
        guessedAlbum = prefetchedSong.album
        guessedGenre = prefetchedSong.genre
      } else {
        songBuffer = library.createSong(account: account)
        prefetch.prefetchedSongDict[songId] = songBuffer
        songBuffer?.id = songId
        guessedArtist = nil
        guessedAlbum = nil
        guessedGenre = nil
      }
      playableBuffer = songBuffer

      if let artistId = attributeDict["artistId"] {
        if let guessedArtist, guessedArtist.id == artistId {
          songBuffer?.artist = guessedArtist
          songBuffer?.artist?.remoteStatus = .available
        } else if let prefetchedArtist = prefetch.prefetchedArtistDict[artistId] {
          songBuffer?.artist = prefetchedArtist
          songBuffer?.artist?.remoteStatus = .available
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
          songBuffer?.artist = artist
        }
      } else if let songBuffer = songBuffer, let artistName = attributeDict["artist"] {
        if let guessedArtist, guessedArtist.name == artistName {
          songBuffer.artist = guessedArtist
        } else if let prefetchedArtist = prefetch.prefetchedLocalArtistDict[artistName] {
          songBuffer.artist = prefetchedArtist
        } else {
          let artist = library.createArtist(account: account)
          prefetch.prefetchedLocalArtistDict[artistName] = artist
          artist.name = artistName
          songBuffer.artist = artist
          os_log("Local Artist <%s> has been created (no id)", log: log, type: .error, artistName)
        }
      }

      if let albumId = attributeDict["albumId"] {
        if let guessedAlbum, guessedAlbum.id == albumId {
          songBuffer?.album = guessedAlbum
          songBuffer?.album?.remoteStatus = .available
        } else if let prefetchedAlbum = prefetch.prefetchedAlbumDict[albumId] {
          songBuffer?.album = prefetchedAlbum
          songBuffer?.album?.remoteStatus = .available
        } else if let albumName = attributeDict["album"] {
          let album = library.createAlbum(account: account)
          prefetch.prefetchedAlbumDict[albumId] = album
          album.id = albumId
          album.name = albumName
          os_log(
            "Album <%s> with id %s has been created",
            log: log,
            type: .error,
            albumName,
            albumId
          )
          songBuffer?.album = album
        }
      }

      if let genreName = attributeDict["genre"] {
        if let guessedGenre, guessedGenre.name == genreName {
          songBuffer?.genre = guessedGenre
        } else if let prefetchedGenre = prefetch.prefetchedGenreDict[genreName] {
          songBuffer?.genre = prefetchedGenre
        } else {
          let genre = library.createGenre(account: account)
          prefetch.prefetchedGenreDict[genreName] = genre
          genre.name = genreName
          os_log("Genre <%s> has been created", log: log, type: .error, genreName)
          songBuffer?.genre = genre
        }
      }
      if let createdTag = attributeDict["created"] {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        songBuffer?.addedDate = dateFormatter.date(from: createdTag)
      }
    } else if elementName == "artists", songBuffer != nil,
              let name = attributeDict["name"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty, !creditedArtists.contains(name) {
      creditedArtists.append(name)
    }

    super.parser(
      parser,
      didStartElement: elementName,
      namespaceURI: namespaceURI,
      qualifiedName: qName,
      attributes: attributeDict
    )
  }

  override func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    if elementName == "song" || elementName == "entry" || elementName == "child" || elementName ==
      "episode", songBuffer != nil {
      parsedCount += 1
      resetPlayableBuffer()
      if let song = songBuffer {
        updateArtistCredit(for: song)
        parsedSongs.append(song)
      }
      songBuffer = nil
    }

    super.parser(
      parser,
      didEndElement: elementName,
      namespaceURI: namespaceURI,
      qualifiedName: qName
    )
  }

  private func updateArtistCredit(for song: Song) {
    let displayName = artistDisplayName.flatMap { $0.isEmpty ? nil : $0 }
    let credit: String
    if creditedArtists.count > 1, displayName.map({ creditedArtists.contains($0) }) ?? true {
      credit = creditedArtists.joined(separator: ", ")
    } else if let displayName {
      credit = displayName
    } else if let artist = creditedArtists.first {
      credit = artist
    } else if let legacyArtistName, !legacyArtistName.isEmpty,
              legacyArtistName != song.artist?.name {
      credit = legacyArtistName
    } else {
      // Responses carrying only the primary artist must not erase a previous credit.
      return
    }
    let storedCredit = credit == song.artist?.name ? nil : credit
    if song.managedObject.artistCredit != storedCredit {
      song.managedObject.artistCredit = storedCredit
    }
  }
}

import AVFoundation
import Observation
import SwiftUI

// MARK: - AudioAnalyzerProtocol

@MainActor
protocol AudioAnalyzerProtocol: AnyObject {
  func install(on audioNode: AVAudioNode)
  func playing(sampleRate: Float)
  func play()
  func stop()
}

// MARK: - AudioAnalyzer

@MainActor
public final class AudioAnalyzer: ObservableObject, AudioAnalyzerProtocol {
  @Published
  public var magnitudes: [Magnitude]
  @Published
  public var rms: Float = .zero

  private let fftSize: Int

  public var isActive = false { didSet { updateTap() } }
  private var isPlaying = false { didSet { updateTap() } }
  var isInForeground = true { didSet { updateTap() } }
  private weak var tappedNode: AVAudioNode?
  public private(set) var isTapInstalled = false
  nonisolated(unsafe) private var _shouldAnalyze = false
  private let analysisLock = NSLock()
  nonisolated private var shouldAnalyze: Bool {
    analysisLock.withLock { _shouldAnalyze }
  }

  nonisolated(unsafe) private var _sampleRate: Float = 0.0
  private let _sampleRateLock = NSLock()
  nonisolated private var sampleRate: Float {
    get {
      _sampleRateLock.withLock { _sampleRate }
    }
    set {
      _sampleRateLock.withLock { _sampleRate = newValue }
    }
  }

  nonisolated(unsafe) private var _fft: FFT
  private let _fftLock = NSLock()
  nonisolated private var fft: FFT {
    get {
      _fftLock.withLock { _fft }
    }
    set {
      _fftLock.withLock { _fft = newValue }
    }
  }

  public init(fftSize: Int = 256, windowType: WindowType = .hannWindow) {
    self.fftSize = fftSize
    self._fft = FFT(size: fftSize, windowType: windowType)
    self.magnitudes = .init(repeating: .zero, count: fftSize / 2)
  }

  public func install(on audioNode: AVAudioNode) {
    if isTapInstalled { tappedNode?.removeTap(onBus: 0) }
    isTapInstalled = false
    tappedNode = audioNode
    updateTap()
  }

  private func updateTap() {
    let enabled = isInForeground && isActive && isPlaying
    analysisLock.withLock { _shouldAnalyze = enabled }
    guard let tappedNode, enabled != isTapInstalled else { return }
    if enabled {
      tappedNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(fftSize),
                           format: nil) { [weak self] buffer, time in
        self?.calculate(buffer: buffer, audioTime: time)
      }
    } else {
      // The tap only copies samples for the visualizer. Removing it leaves
      // the playback/equalizer graph and transport envelope untouched.
      tappedNode.removeTap(onBus: 0)
    }
    isTapInstalled = enabled
  }

  public func playing(sampleRate: Float) {
    self.sampleRate = sampleRate
  }

  public func play() {
    isPlaying = true
  }

  public func stop() {
    isPlaying = false
    magnitudes = .init(repeating: .zero, count: fftSize / 2)
  }

  nonisolated func calculate(buffer: AVAudioPCMBuffer, audioTime: AVAudioTime) {
    if shouldAnalyze, let data = buffer.floatChannelData {
      let magnitudesCalculated = fft.compute(sampleRate: sampleRate, audioData: data.pointee)
      let rmsCalculated = fft.rms(audioData: data.pointee)

      Task { @MainActor in
        guard self.isInForeground, self.isActive, self.isPlaying else { return }
        self.magnitudes = magnitudesCalculated
        self.rms = rmsCalculated
      }
    }
  }
}

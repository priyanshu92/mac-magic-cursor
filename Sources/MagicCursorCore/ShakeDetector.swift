import Foundation

public struct ShakeDetector {
  public enum Sensitivity: String, CaseIterable, Sendable {
    case gentle, standard, deliberate

    public var title: String { rawValue.capitalized }
    var minimumTravel: CGFloat {
      switch self {
      case .gentle: 300
      case .standard: 420
      case .deliberate: 600
      }
    }

    var minimumReversals: Int {
      switch self {
      case .gentle: 4
      case .standard: 5
      case .deliberate: 6
      }
    }

    var minimumSpan: CGFloat {
      switch self {
      case .gentle: 50
      case .standard: 60
      case .deliberate: 80
      }
    }
  }

  private struct Sample {
    let point: CGPoint
    let time: TimeInterval
  }

  public var sensitivity: Sensitivity
  private var samples: [Sample] = []
  private var lastActivation: TimeInterval = -.infinity

  public init(sensitivity: Sensitivity = .standard) {
    self.sensitivity = sensitivity
  }

  public mutating func reset() {
    samples.removeAll(keepingCapacity: true)
  }

  public mutating func add(_ point: CGPoint, at time: TimeInterval) -> Bool {
    guard point.x.isFinite, point.y.isFinite, time.isFinite else {
      reset()
      return false
    }
    if let last = samples.last, time <= last.time {
      reset()
    }
    samples.removeAll { time - $0.time > 0.75 }
    samples.append(Sample(point: point, time: time))
    guard time - lastActivation >= 3, samples.count >= sensitivity.minimumReversals + 2 else {
      return false
    }

    // Track meaningful strokes rather than per-frame signs: hand tremor and
    // trackpad jitter must not turn ordinary pointing into an activation.
    for horizontal in [true, false] {
      let values = samples.map { horizontal ? $0.point.x : $0.point.y }
      var extreme = values[0]
      var direction: CGFloat = 0
      var reversals = 0
      var travel: CGFloat = 0
      for value in values.dropFirst() {
        let delta = value - extreme
        if direction == 0 {
          if abs(delta) >= 18 {
            direction = delta > 0 ? 1 : -1
            travel += abs(delta)
            extreme = value
          }
        } else if delta * direction >= 0 {
          travel += abs(delta)
          extreme = value
        } else if abs(delta) >= 18 {
          reversals += 1
          direction *= -1
          travel += abs(delta)
          extreme = value
        }
      }
      let span = (values.max() ?? 0) - (values.min() ?? 0)
      if reversals >= sensitivity.minimumReversals, travel >= sensitivity.minimumTravel,
        span >= sensitivity.minimumSpan
      {
        lastActivation = time
        reset()
        return true
      }
    }
    return false
  }
}

import Foundation

public struct QuotaObservation: Equatable, Sendable {
    public let windowMinutes: Int
    public let remainingPercent: Int
    public let resetsAt: Date
    public let observedAt: Date

    public init(
        windowMinutes: Int,
        remainingPercent: Int,
        resetsAt: Date,
        observedAt: Date
    ) {
        self.windowMinutes = windowMinutes
        self.remainingPercent = remainingPercent
        self.resetsAt = resetsAt
        self.observedAt = observedAt
    }
}

public enum QuotaRecoveryKind: String, Equatable, Sendable {
    case scheduledReset
    case earlyReset
    case significantRecovery
}

public struct QuotaRecoveryEvent: Equatable, Sendable {
    public let kind: QuotaRecoveryKind
    public let windowMinutes: Int
    public let previousRemainingPercent: Int
    public let currentRemainingPercent: Int
    public let previousResetDate: Date
    public let currentResetDate: Date
    public let detectedAt: Date

    public var fingerprint: String {
        let resetEpoch = Int(currentResetDate.timeIntervalSince1970.rounded())
        switch kind {
        case .scheduledReset, .earlyReset:
            return "\(kind.rawValue)-\(windowMinutes)-\(resetEpoch)"
        case .significantRecovery:
            let remainingBucket = (currentRemainingPercent / 5) * 5
            return "\(kind.rawValue)-\(windowMinutes)-\(resetEpoch)-\(remainingBucket)"
        }
    }
}

public struct QuotaRecoveryDetector: Sendable {
    public let resetTimeTolerance: TimeInterval
    public let naturalResetGrace: TimeInterval
    public let minimumEarlyResetGain: Int
    public let minimumSameWindowGain: Int
    public let nearFullThreshold: Int
    public let confirmationRemainingTolerance: Int

    public init(
        resetTimeTolerance: TimeInterval = 120,
        naturalResetGrace: TimeInterval = 5 * 60,
        minimumEarlyResetGain: Int = 3,
        minimumSameWindowGain: Int = 10,
        nearFullThreshold: Int = 99,
        confirmationRemainingTolerance: Int = 5
    ) {
        self.resetTimeTolerance = resetTimeTolerance
        self.naturalResetGrace = naturalResetGrace
        self.minimumEarlyResetGain = minimumEarlyResetGain
        self.minimumSameWindowGain = minimumSameWindowGain
        self.nearFullThreshold = nearFullThreshold
        self.confirmationRemainingTolerance = confirmationRemainingTolerance
    }

    public func detect(
        previous: QuotaObservation,
        current: QuotaObservation,
        now: Date
    ) -> QuotaRecoveryEvent? {
        guard previous.windowMinutes == current.windowMinutes,
              current.observedAt >= previous.observedAt else {
            return nil
        }

        let gain = current.remainingPercent - previous.remainingPercent
        let resetDelta = current.resetsAt.timeIntervalSince(previous.resetsAt)
        let resetAdvanced = resetDelta > resetTimeTolerance

        if resetAdvanced {
            let previousWindowWasDue = previous.resetsAt <= now.addingTimeInterval(naturalResetGrace)
            if previousWindowWasDue {
                return event(.scheduledReset, previous: previous, current: current, now: now)
            }
            if gain >= minimumEarlyResetGain {
                return event(.earlyReset, previous: previous, current: current, now: now)
            }
            return nil
        }

        let sameResetWindow = abs(resetDelta) <= resetTimeTolerance
        let recoveredNearFull = current.remainingPercent >= nearFullThreshold
            && gain >= minimumEarlyResetGain
        guard sameResetWindow,
              gain >= minimumSameWindowGain || recoveredNearFull else {
            return nil
        }

        return event(.significantRecovery, previous: previous, current: current, now: now)
    }

    public func confirms(
        _ event: QuotaRecoveryEvent,
        with observation: QuotaObservation
    ) -> Bool {
        guard observation.windowMinutes == event.windowMinutes,
              observation.observedAt > event.detectedAt,
              abs(observation.resetsAt.timeIntervalSince(event.currentResetDate)) <= resetTimeTolerance else {
            return false
        }
        return observation.remainingPercent
            >= event.currentRemainingPercent - confirmationRemainingTolerance
    }

    private func event(
        _ kind: QuotaRecoveryKind,
        previous: QuotaObservation,
        current: QuotaObservation,
        now: Date
    ) -> QuotaRecoveryEvent {
        QuotaRecoveryEvent(
            kind: kind,
            windowMinutes: current.windowMinutes,
            previousRemainingPercent: previous.remainingPercent,
            currentRemainingPercent: current.remainingPercent,
            previousResetDate: previous.resetsAt,
            currentResetDate: current.resetsAt,
            detectedAt: now
        )
    }
}

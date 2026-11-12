import Foundation
import HomeKit

extension HomeManagerHomeKitService {
    static func trigger(from trigger: HMTrigger) -> Trigger {
        Trigger(
            id: trigger.uniqueIdentifier.uuidString,
            name: trigger.name,
            isEnabled: trigger.isEnabled,
            linkedSceneIds: trigger.actionSets.map { $0.uniqueIdentifier.uuidString },
            triggerActivationState: (trigger as? HMEventTrigger).map { Int($0.triggerActivationState.rawValue) },
            detail: Self.detail(from: trigger)
        )
    }

    private static func detail(from trigger: HMTrigger) -> Trigger.Detail {
        if let timer = trigger as? HMTimerTrigger {
            return .timer(
                fireDate: timer.fireDate,
                recurrence: Self.recurrenceValues(from: timer.recurrence)
            )
        }
        if let eventTrigger = trigger as? HMEventTrigger {
            let endEvents = eventTrigger.endEvents
            return .event(
                Trigger.Detail.EventDetail.reading(
                    events: eventTrigger.events.map(Self.eventRef(from:)),
                    endEvents: endEvents.isEmpty ? nil : endEvents.map(Self.eventRef(from:)),
                    executeOnce: eventTrigger.executeOnce,
                    predicate: eventTrigger.predicate?.description
                )
            )
        }
        return .unknown(kind: String(describing: type(of: trigger)))
    }

    /// Non-zero date components as a JSON-friendly dictionary, e.g.
    /// `{"hour": 7, "minute": 30}`. Nil and zero components are dropped.
    static func recurrenceValues(from components: DateComponents?) -> [String: Int] {
        guard let components else { return [:] }
        var values: [String: Int] = [:]
        let namedComponents: [(String, Int?)] = [
            ("year", components.year),
            ("month", components.month),
            ("weekday", components.weekday),
            ("day", components.day),
            ("hour", components.hour),
            ("minute", components.minute),
            ("second", components.second),
        ]
        for (name, value) in namedComponents where value.map({ $0 != 0 }) == true {
            values[name] = value
        }
        return values
    }

    private static func eventRef(from event: HMEvent) -> EventRef {
        // Presence events: HomeKit evaluates them itself, so the structured
        // read carries the event type it was created with.
        if let presenceEvent = event as? HMPresenceEvent {
            return EventRef(
                type: "presence",
                characteristicType: nil,
                valueDescription: Self.presenceEventTypeDescription(presenceEvent.presenceEventType)
            )
        }
        // `HMCharacteristicEvent` is generic over its target value type and
        // has no public non-generic base, so match the concrete
        // specializations HomeKit actually produces.
        if let numberEvent = event as? HMCharacteristicEvent<NSNumber> {
            return eventRef(characteristic: numberEvent.characteristic, value: numberEvent.triggerValue)
        }
        if let stringEvent = event as? HMCharacteristicEvent<NSString> {
            return eventRef(characteristic: stringEvent.characteristic, value: stringEvent.triggerValue)
        }
        if let nullEvent = event as? HMCharacteristicEvent<NSNull> {
            return eventRef(characteristic: nullEvent.characteristic, value: nullEvent.triggerValue)
        }
        return EventRef(
            type: String(describing: type(of: event)),
            characteristicType: nil,
            valueDescription: nil
        )
    }

    /// `HMPresenceEventType` rendered as its JSON-friendly name. Unknown
    /// future cases render as their debug name rather than a lie.
    static func presenceEventTypeDescription(_ type: HMPresenceEventType) -> String {
        switch type {
        case .atHome: return "atHome"
        case .notAtHome: return "notAtHome"
        @unknown default: return String(describing: type)
        }
    }

    private static func eventRef(characteristic: HMCharacteristic, value: Any?) -> EventRef {
        EventRef(
            type: "characteristic",
            characteristicType: characteristic.characteristicType,
            valueDescription: value.map(String.init(describing:))
        )
    }
}

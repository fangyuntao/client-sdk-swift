/*
 * Copyright 2024 LiveKit
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import Foundation

@_implementationOnly import LiveKitWebRTC

@objc
public class Participant: NSObject, ObservableObject, Loggable {
    // MARK: - MulticastDelegate

    public let delegates = MulticastDelegate<ParticipantDelegate>()

    @objc
    public var sid: Sid? { _state.sid }

    @objc
    public var identity: Identity? { _state.identity }

    @objc
    public var name: String? { _state.name }

    @objc
    public var audioLevel: Float { _state.audioLevel }

    @objc
    public var isSpeaking: Bool { _state.isSpeaking }

    @objc
    public var metadata: String? { _state.metadata }

    @objc
    public var connectionQuality: ConnectionQuality { _state.connectionQuality }

    @objc
    public var permissions: ParticipantPermissions { _state.permissions }

    @objc
    public var joinedAt: Date? { _state.joinedAt }

    @objc
    public var trackPublications: [Track.Sid: TrackPublication] { _state.trackPublications }

    @objc
    public var audioTracks: [TrackPublication] {
        _state.trackPublications.values.filter { $0.kind == .audio }
    }

    @objc
    public var videoTracks: [TrackPublication] {
        _state.trackPublications.values.filter { $0.kind == .video }
    }

    var info: Livekit_ParticipantInfo?

    // Reference to the Room this Participant belongs to
    weak var _room: Room?

    // MARK: - Internal

    struct State: Equatable, Hashable {
        var sid: Sid?
        var identity: Identity?
        var name: String?
        var audioLevel: Float = 0.0
        var isSpeaking: Bool = false
        var metadata: String?
        var joinedAt: Date?
        var connectionQuality: ConnectionQuality = .unknown
        var permissions = ParticipantPermissions()
        var trackPublications = [Track.Sid: TrackPublication]()
    }

    var _state: StateSync<State>

    init(room: Room, sid: Sid? = nil, identity: Identity? = nil) {
        _room = room

        // initial state
        _state = StateSync(State(sid: sid, identity: identity))

        super.init()

        // trigger events when state mutates
        _state.onDidMutate = { [weak self] newState, oldState in

            guard let self, let room = self._room else { return }

            if newState.isSpeaking != oldState.isSpeaking {
                self.delegates.notify(label: { "participant.didUpdate isSpeaking: \(self.isSpeaking)" }) {
                    $0.participant?(self, didUpdateIsSpeaking: self.isSpeaking)
                }
            }

            // metadata updated
            if let newMetadata = newState.metadata, newMetadata != oldState.metadata,
               // don't notify if empty string (first time only)
               oldState.metadata == nil ? !newMetadata.isEmpty : true
            {
                self.delegates.notify(label: { "participant.didUpdate metadata: \(newMetadata)" }) {
                    $0.participant?(self, didUpdateMetadata: newMetadata)
                }
                room.delegates.notify(label: { "room.didUpdate metadata: \(newMetadata)" }) {
                    $0.room?(room, participant: self, didUpdateMetadata: newMetadata)
                }
            }

            // name updated
            if let newName = newState.name, newName != oldState.name {
                // notfy participant delegates
                self.delegates.notify(label: { "participant.didUpdateName: \(String(describing: newName))" }) {
                    $0.participant?(self, didUpdateName: newName)
                }
                // notify room delegates
                room.delegates.notify(label: { "room.didUpdateName: \(String(describing: newName))" }) {
                    $0.room?(room, participant: self, didUpdateName: newName)
                }
            }

            if newState.connectionQuality != oldState.connectionQuality {
                self.delegates.notify(label: { "participant.didUpdate connectionQuality: \(self.connectionQuality)" }) {
                    $0.participant?(self, didUpdateConnectionQuality: self.connectionQuality)
                }
                room.delegates.notify(label: { "room.didUpdate connectionQuality: \(self.connectionQuality)" }) {
                    $0.room?(room, participant: self, didUpdateConnectionQuality: self.connectionQuality)
                }
            }

            // Notify when state mutates
            Task.detached { @MainActor in
                // Notify Participant
                self.objectWillChange.send()
                if let room = self._room {
                    // Notify Room
                    room.objectWillChange.send()
                }
            }
        }
    }

    func cleanUp(notify _notify: Bool = true) async {
        await unpublishAll(notify: _notify)
        // Reset state
        if let self = self as? RemoteParticipant, let room = self._room {
            room.delegates.notify(label: { "room.participantDidDisconnect:" }) {
                $0.room?(room, participantDidDisconnect: self)
            }
        }

        _state.mutate { $0 = State() }
    }

    func unpublishAll(notify _: Bool = true) async {
        fatalError("Unimplemented")
    }

    func add(publication: TrackPublication) {
        _state.mutate { $0.trackPublications[publication.sid] = publication }
        publication.track?._state.mutate { $0.sid = publication.sid }
    }

    func updateFromInfo(info: Livekit_ParticipantInfo) {
        _state.mutate {
            $0.sid = Sid(from: info.sid)
            $0.identity = Identity(from: info.identity)
            $0.name = info.name
            $0.metadata = info.metadata
            $0.joinedAt = Date(timeIntervalSince1970: TimeInterval(info.joinedAt))
        }

        self.info = info
        set(permissions: info.permission.toLKType())
    }

    @discardableResult
    func set(permissions newValue: ParticipantPermissions) -> Bool {
        guard permissions != newValue else {
            // no change
            return false
        }

        _state.mutate { $0.permissions = newValue }

        return true
    }
}

// MARK: - Simplified API

public extension Participant {
    func isCameraEnabled() -> Bool {
        !(getTrackPublication(source: .camera)?.isMuted ?? true)
    }

    func isMicrophoneEnabled() -> Bool {
        !(getTrackPublication(source: .microphone)?.isMuted ?? true)
    }

    func isScreenShareEnabled() -> Bool {
        !(getTrackPublication(source: .screenShareVideo)?.isMuted ?? true)
    }

    internal func getTrackPublication(name: String) -> TrackPublication? {
        _state.trackPublications.values.first(where: { $0.name == name })
    }

    /// find the first publication matching `source` or any compatible.
    internal func getTrackPublication(source: Track.Source) -> TrackPublication? {
        // if source is unknown return nil
        guard source != .unknown else { return nil }
        // try to find a Publication with matching source
        if let result = _state.trackPublications.values.first(where: { $0.source == source }) {
            return result
        }
        // try to find a compatible Publication
        if let result = _state.trackPublications.values.filter({ $0.source == .unknown }).first(where: {
            (source == .microphone && $0.kind == .audio) ||
                (source == .camera && $0.kind == .video && $0.name != Track.screenShareVideoName) ||
                (source == .screenShareVideo && $0.kind == .video && $0.name == Track.screenShareVideoName) ||
                (source == .screenShareAudio && $0.kind == .audio && $0.name == Track.screenShareVideoName)
        }) {
            return result
        }

        return nil
    }
}

// MARK: - Private helpers

extension Participant {
    func requireRoom() throws -> Room {
        guard let room = _room else {
            log("Room is nil", .error)
            throw LiveKitError(.invalidState, message: "Room is nil")
        }

        return room
    }
}

import Foundation
import KyroFoundation

public enum Capability:String,Codable,Sendable,CaseIterable {case directPlay,transcode,seek,liveTV,progressWrite,multiAudio,subtitles}
public enum CapabilityState:Codable,Sendable,Equatable {case supported,unsupported,unknown,limited(String)}
public protocol CapabilityProvider:Sendable {func state(of capability:Capability) async -> CapabilityState}

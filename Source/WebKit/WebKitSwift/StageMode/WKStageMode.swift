// Copyright (C) 2024 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in the
//    documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
// THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
// BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
// THE POSSIBILITY OF SUCH DAMAGE.

#if os(visionOS)

internal import CoreRE
import Combine
import Foundation
import RealityKit
import WebKitSwift
import os
import simd
internal import Spatial
@_spi(Private) @_spi(RealityKit) @_spi(CoreREAdditions) import RealityFoundation

fileprivate extension Logger {
    static let stageMode = Logger(subsystem: "com.apple.WebKit", category: "StageModeInteraction")
}

/// A driver that maps all gesture updates to the specific transform we want for the specified StageMode behavior
@MainActor
@objc(WKStageModeInteractionDriver)
public final class WKStageModeInteractionDriver: NSObject {
    private let kDragToRotationMultiplier: Float = 5.0
    
    private var stageModeOperation: WKStageModeOperation = .none
    let interactionTarget: Entity
    let modelEntity: Entity
    let turntableInteractionContainer: Entity
    let turntableAnimationProxyEntity = Entity()
    
    // Transform state machine
    private var driverInitialized: Bool = false
    private var initialManipulationPose: Transform = .identity
    private var previousManipulationPose: Transform = .identity
    private var initialTargetPose: Transform = .identity
    private var initialTurntablePose: Transform = .identity
    private var currentOrbitVelocity: simd_float2 = .zero
    
    // Animation Controllers
    private var pitchSettleAnimationController: AnimationPlaybackController? = nil
    private var yawDecelerationAnimationController: AnimationPlaybackController? = nil
    
    private var pitchAnimationIsPlaying: Bool {
        pitchSettleAnimationController?.isPlaying ?? false
    }
    
    private var yawAnimationIsPlaying: Bool {
        yawDecelerationAnimationController?.isPlaying ?? false
    }
    
    @objc override init() {
        self.interactionTarget = Entity()
        self.modelEntity = Entity()
        self.turntableInteractionContainer = Entity()
    }
    
    init(_ target: Entity, _ model: Entity, _ turntableContainer: Entity) {
        self.interactionTarget = target
        self.modelEntity = model
        self.turntableInteractionContainer = turntableContainer
    }
    
    // MARK: ObjC Exposed API
    @objc(initWithInteractionTarget:model:container:)
    convenience init(with entity: REEntityRef, model: REEntityRef, container: REEntityRef) {
        let interactionContainer = Entity.__fromCore(__EntityRef.__fromCore(entity))
        let turntableContainer = Entity()
        let modelEntity = Entity.__fromCore(__EntityRef.__fromCore(model))
        let containerEntity = Entity.__fromCore(__EntityRef.__fromCore(container))
        
        self.init(interactionContainer, modelEntity, turntableContainer)
        
        self.setupInteractionEntityHierarchy(containerEntity)
    }
    
    @objc(initWithInteractionTarget:wkModel:container:)
    convenience init(with entity: REEntityRef, wkModel: WKSRKEntity?, container: REEntityRef) {
        guard let wkModel else {
            self.init()
            return
        }
        
        let interactionContainer = Entity.__fromCore(__EntityRef.__fromCore(entity))
        let turntableContainer = Entity()
        let modelEntity = wkModel.entity
        let containerEntity = Entity.__fromCore(__EntityRef.__fromCore(container))

        self.init(interactionContainer, modelEntity, turntableContainer)

        self.setupInteractionEntityHierarchy(containerEntity)
    }

    private func setupInteractionEntityHierarchy(_ container: Entity) {
        self.turntableInteractionContainer.setPosition(modelEntity.visualBounds(relativeTo: nil).center, relativeTo: nil)
        self.interactionTarget.setPosition(modelEntity.visualBounds(relativeTo: nil).center, relativeTo: nil)

        self.turntableInteractionContainer.setParent(interactionTarget, preservingWorldTransform: true)
        self.modelEntity.setParent(turntableInteractionContainer, preservingWorldTransform: true)
        self.interactionTarget.setParent(container, preservingWorldTransform: true)

        self.turntableAnimationProxyEntity.setParent(turntableInteractionContainer)
    }
    
    @objc(stageModeInteractionInProgress)
    func stageModeInteractionInProgress() -> Bool {
        return stageModeOperation != .none && driverInitialized && (pitchAnimationIsPlaying || yawAnimationIsPlaying)
    }
    
    @objc(interactionDidBegin:)
    func interactionDidBegin(_ transform: simd_float4x4) {
        driverInitialized = true
        
        if pitchAnimationIsPlaying {
            pitchSettleAnimationController?.pause()
            self.pitchSettleAnimationController = nil
        }
        
        if yawAnimationIsPlaying {
            yawDecelerationAnimationController?.pause()
            self.yawDecelerationAnimationController = nil
        }

        let initialCenter = modelEntity.visualBounds(relativeTo: nil).center
        let initialMatrix = modelEntity.transformMatrix(relativeTo: nil)
        self.currentOrbitVelocity = .zero
        self.interactionTarget.setPosition(initialCenter, relativeTo: nil)
        self.modelEntity.setTransformMatrix(initialMatrix, relativeTo: nil)
        self.turntableAnimationProxyEntity.setPosition(.zero, relativeTo: nil)
        
        let tf = Transform(matrix: transform)
        initialManipulationPose = tf
        previousManipulationPose = tf
        initialTargetPose = interactionTarget.transform
        initialTurntablePose = turntableInteractionContainer.transform
    }
    
    @objc(interactionDidUpdate:)
    func interactionDidUpdate(_ transform: simd_float4x4) {
        let tf = Transform(matrix: transform)
        switch stageModeOperation {
        case .orbit:
            do {
                let xyDelta = (tf.translation._inMeters - initialManipulationPose.translation._inMeters).xy * kDragToRotationMultiplier
                
                // Apply pitch along global x axis
                let containerPitchQuat = Rotation3D(angle: .init(radians: xyDelta.y), axis: .x)
                self.interactionTarget.orientation = initialTargetPose.rotation * containerPitchQuat.quaternion.quatf

                // Apply yaw along local y axis
                let turntableYawQuat = Rotation3D(angle: .init(radians: xyDelta.x), axis: .y)
                self.turntableInteractionContainer.orientation = initialTurntablePose.rotation * turntableYawQuat.quaternion.quatf
                
                self.currentOrbitVelocity = (tf.translation._inMeters - previousManipulationPose.translation._inMeters).xy * kDragToRotationMultiplier
                break
            }
        default:
            break
        }

        previousManipulationPose = tf
    }
    
    @objc(interactionDidEnd)
    func interactionDidEnd() {
        initialManipulationPose = .identity
        previousManipulationPose = .identity
        pitchSettleAnimationController = self.interactionTarget.move(to: initialTargetPose, relativeTo: self.interactionTarget.parent, duration: 0.3, timingFunction: .easeOut)
        subscribeToPitchChanges()
        
        // The proxy does not actually trigger the turntable animation; we instead use it to programmatically apply a deceleration curve to the yaw
        // based on the user's current orbit velocity
        yawDecelerationAnimationController = self.turntableAnimationProxyEntity.move(to: Transform(scale: .one, rotation: .identity, translation: .init(repeating: 1)), relativeTo: nil, duration: 3, timingFunction: .linear)
        subscribeToYawChanges()
        driverInitialized = false
    }
    
    private func subscribeToYawChanges() {
        if yawAnimationIsPlaying {
            withObservationTracking {
                // By default, we do not care about the proxy, but we use the update to set the deceleration of the turntable container
                _ = turntableAnimationProxyEntity.proto_observableComponents[Transform.self]
            } onChange: {
                Task { @MainActor in
                    let deltaX = self.currentOrbitVelocity.x
                    let turntableYawQuat = Rotation3D(angle: .init(radians: deltaX), axis: .y)
                    self.turntableInteractionContainer.orientation *= turntableYawQuat.quaternion.quatf
                    self.currentOrbitVelocity *= 0.9
                    
                    // FIXME: Report transform updates back to the entityTransform
                    // Because the onChange only gets called once, we need to re-subscribe to the function while we are animating
                    self.subscribeToYawChanges()
                }
            }
        }
    }
    
    private func subscribeToPitchChanges() {
        if pitchAnimationIsPlaying {
            withObservationTracking {
                // By default, we do not care about the proxy, but we use the update to set the deceleration of the turntable container
                _ = interactionTarget.proto_observableComponents[Transform.self]
            } onChange: {
                Task { @MainActor in
                    // FIXME: Report transform updates back to the entityTransform
                    
                    self.subscribeToPitchChanges()
                }
            }
        }
    }
    
    @objc(operationDidUpdate:)
    func operationDidChange(_ operation: WKStageModeOperation) {
        self.stageModeOperation = operation
    }
    
    @objc(modelTransformDidChange)
    func modelTransformDidChange() { }
}

// MARK: - SIMD Extentions

extension simd_float3 {
    // Based on visionOS's Points Per Meter (PPM) heuristics
    var _inMeters: simd_float3 {
        self / 1360.0
    }

    var xy: simd_float2 {
        return .init(x, y)
    }
    
    var double3: simd_double3 {
        return .init(Double(x), Double(y), Double(z))
    }
}

extension simd_quatd {
    var quatf: simd_quatf {
        return .init(ix: Float(self.imag.x), iy: Float(self.imag.y), iz: Float(self.imag.z), r: Float(self.real))
    }
}

#endif // os(visionOS)

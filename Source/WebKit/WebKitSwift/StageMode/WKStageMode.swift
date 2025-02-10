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
    
    // Transform state machine
    private var driverInitialized: Bool = false
    private var initialManipulationPose: Transform = .identity
    private var previousManipulationPose: Transform = .identity
    private var initialTargetPose: Transform = .identity
    private var centerToPositionOffset: simd_float3
    
    @objc override init() {
        self.centerToPositionOffset = .zero
        self.interactionTarget = Entity()
        self.modelEntity = Entity()
    }
    
    init(_ target: Entity, _ model: Entity) {
        self.centerToPositionOffset = model.visualBounds(relativeTo: nil).center - model.position(relativeTo: nil)
        self.interactionTarget = target
        self.modelEntity = model
    }
    
    // MARK: ObjC Exposed API
    @objc(initWithInteractionTarget:model:container:)
    convenience init(with entity: REEntityRef, model: REEntityRef, container: REEntityRef) {
        let interactionContainer = Entity.__fromCore(__EntityRef.__fromCore(entity))
        let modelEntity = Entity.__fromCore(__EntityRef.__fromCore(model))
        let containerEntity = Entity.__fromCore(__EntityRef.__fromCore(container))
        
        interactionContainer.setPosition(modelEntity.visualBounds(relativeTo: nil).center, relativeTo: nil)
        modelEntity.setParent(interactionContainer, preservingWorldTransform: true)
        interactionContainer.setParent(containerEntity, preservingWorldTransform: true)
        
        self.init(interactionContainer, modelEntity)
    }
    
    @objc(initWithInteractionTarget:wkModel:container:)
    convenience init(with entity: REEntityRef, wkModel: WKSRKEntity?, container: REEntityRef) {
        guard let wkModel else {
            self.init()
            return
        }
        
        let interactionContainer = Entity.__fromCore(__EntityRef.__fromCore(entity))
        let modelEntity = wkModel.entity
        let containerEntity = Entity.__fromCore(__EntityRef.__fromCore(container))
        
        interactionContainer.setPosition(modelEntity.visualBounds(relativeTo: nil).center, relativeTo: nil)
        modelEntity.setParent(interactionContainer, preservingWorldTransform: true)
        interactionContainer.setParent(containerEntity, preservingWorldTransform: true)
        
        self.init(interactionContainer, modelEntity)
    }
    
    @objc(stageModeInteractionInProgress)
    func stageModeInteractionInProgress() -> Bool {
        return stageModeOperation != .none && driverInitialized
    }
    
    @objc(interactionDidBegin:)
    func interactionDidBegin(_ transform: simd_float4x4) {
        driverInitialized = true

        let initialCenter = modelEntity.visualBounds(relativeTo: nil).center
        let initialMatrix = modelEntity.transformMatrix(relativeTo: nil)
        self.interactionTarget.setPosition(initialCenter, relativeTo: nil)
        self.modelEntity.setTransformMatrix(initialMatrix, relativeTo: nil)
        
        let tf = Transform(matrix: transform)
        initialManipulationPose = tf
        previousManipulationPose = tf
        initialTargetPose = interactionTarget.transform
    }
    
    @objc(interactionDidUpdate:)
    func interactionDidUpdate(_ transform: simd_float4x4) {
        let tf = Transform(matrix: transform)
        switch stageModeOperation {
        case .orbit:
            do {
                let xyDelta = (tf.translation._inMeters - previousManipulationPose.translation._inMeters).xy * kDragToRotationMultiplier
                
                // Apply pitch along global x axis
                var quat = Rotation3D(angle: .init(radians: xyDelta.y), axis: .init(vector: self.interactionTarget.convert(direction: .init(1, 0, 0), from: nil).double3))
                
                // Apply yaw along local y axis
                quat = quat.rotated(by: Rotation3D(angle: .init(radians: xyDelta.x), axis: .y))
                
                self.interactionTarget.orientation *= quat.quaternion.quatf
                break
            }
        default:
            break
        }

        previousManipulationPose = tf
    }
    
    @objc(interactionDidEnd)
    func interactionDidEnd() {
        driverInitialized = false
        initialManipulationPose = .identity
        previousManipulationPose = .identity
    }
    
    @objc(operationDidUpdate:)
    func operationDidChange(_ operation: WKStageModeOperation) {
        self.stageModeOperation = operation
    }
    
    @objc(modelTransformDidChange)
    func modelTransformDidChange() {
//        Logger.stageMode.debug("WKOM: TARGET \(self.interactionTarget.position(relativeTo: nil)) entity \(self.modelEntity.visualBounds(relativeTo: nil).center)")
    }
    
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

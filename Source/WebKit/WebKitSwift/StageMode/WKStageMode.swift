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
    static let objectManipulation = Logger(subsystem: "com.apple.WebKit", category: "StageModeInteraction")
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
    
    @objc override init() {
        self.interactionTarget = Entity()
        self.modelEntity = Entity()
    }
    
    init(_ target: Entity, _ model: Entity) {
        Logger.objectManipulation.debug("WKOM: WKStageModeInteractionDriver created driver for target \(target.name)")
        self.interactionTarget = target
        self.modelEntity = model
    }
    
    // MARK: ObjC Exposed API
    @objc(initWithInteractionTarget:model:container:)
    convenience init(with entity: REEntityRef, model: REEntityRef, container: REEntityRef) {
        Logger.objectManipulation.debug("initWithInteractionTarget:model:container:")
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
        Logger.objectManipulation.debug("WKOM: initWithInteractionTarget:wkModel:container:")
        guard let wkModel else {
            Logger.objectManipulation.debug("WKOM: WKStageModeInteractionDriver could not find valid WKSRKEntity to initialize interaction container")
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
        let tf = Transform(matrix: transform)
        Logger.objectManipulation.debug("WKOM: WKStageModeInteractionDriver initializeDriver")
        initialManipulationPose = tf
        previousManipulationPose = tf
        initialTargetPose = interactionTarget.transform
        driverInitialized = true
    }
    
    @objc(interactionDidUpdate:)
    func interactionDidUpdate(_ transform: simd_float4x4) {
        let tf = Transform(matrix: transform)
        Logger.objectManipulation.debug("WKOM: WKStageModeInteractionDriver updateDriver \(self.interactionTarget.name)")
        switch stageModeOperation {
        case .orbit:
            do {
                // FIXME: Clamp pitch to 90 deg?
                let xyDelta = (tf.translation._inMeters - previousManipulationPose.translation._inMeters).xy * kDragToRotationMultiplier
                
                // Apply pitch along global x axis
                var quat = Rotation3D(angle: .init(radians: xyDelta.y), axis: .init(vector: self.interactionTarget.convert(direction: .init(1, 0, 0), from: nil).double3))
                
                // Apply yaw along local y axis
                quat = quat.rotated(by: Rotation3D(angle: .init(radians: xyDelta.x), axis: .y))
                
                self.interactionTarget.orientation *= quat.quaternion.quatf
                Logger.objectManipulation.debug("WKOM: WKStageModeInteractionDriver orbit translation \(tf.translation) delta \(xyDelta)")
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
        Logger.objectManipulation.debug("WKOM: StageModeDriver operationDidChange \(operation == .orbit)")
        self.stageModeOperation = operation
    }
    
    @objc(modelTransformDidChange)
    func modelTransformDidChange() {
        let tempCenter = modelEntity.visualBounds(relativeTo: nil).center
        let tempPosition = modelEntity.position(relativeTo: nil)
        self.interactionTarget.setPosition(tempCenter, relativeTo: nil)
        self.modelEntity.setPosition(tempPosition, relativeTo: nil)
    }
    
}

extension Point3D {
    var _cgPoint: CGPoint {
        CGPoint(x: self.x, y: self.y)
    }

    var _float3: simd_float3 {
        simd_float3(Float(x), Float(y), Float(z))
    }
}

extension Size3D {
    var _float3: simd_float3 {
        simd_float3(Float(width), Float(height), Float(depth))
    }
}

extension Vector3D {
    var _float3: simd_float3 {
        simd_float3(Float(x), Float(y), Float(z))
    }
}

extension simd_float3 {
    var _inMeters: simd_float3 {
        self / 1360.0
    }

    var _inPoints: simd_float3 {
        self * 1360.0
    }

    // Adapted from Core3DRuntime/Math/simd_extensions.h
    // scn_quat_from_euler
    // Implemented in Swift
    // Modified variable names due to odd ordering of roll, pitch, yaw in input parameters
    var quaternion: simd_quatf {
        // calculate trig identities
        let cx = cos(x / 2)
        let cy = cos(y / 2)
        let cz = cos(z / 2)

        let sx = sin(x / 2)
        let sy = sin(y / 2)
        let sz = sin(z / 2)

        let cycz = cy * cz
        let sysz = sy * sz

        let vx = sx * cycz - cx * sysz
        let vy = cx * sy * cz + sx * cy * sz
        let vz = cx * cy * sz - sx * sy * cz
        let vw = cx * cycz + sx * sysz

        return simd_quatf(vector: simd_float4(x: vx, y: vy, z: vz, w: vw))
    }

    var xy: simd_float2 {
        return .init(x, y)
    }
    
    var double3: simd_double3 {
        return .init(Double(x), Double(y), Double(z))
    }
}

extension simd_double4x4 {
    var _float4x4: simd_float4x4 {
        return simd_float4x4(simd_float4(Float(columns.0[0]), Float(columns.0[1]), Float(columns.0[2]), Float(columns.0[3])),
                             simd_float4(Float(columns.1[0]), Float(columns.1[1]), Float(columns.1[2]), Float(columns.1[3])),
                             simd_float4(Float(columns.2[0]), Float(columns.2[1]), Float(columns.2[2]), Float(columns.2[3])),
                             simd_float4(Float(columns.3[0]), Float(columns.3[1]), Float(columns.3[2]), Float(columns.3[3])))
    }
}

extension simd_quatd {
    var quatf: simd_quatf {
        return .init(ix: Float(self.imag.x), iy: Float(self.imag.y), iz: Float(self.imag.z), r: Float(self.real))
    }
}

#endif // os(visionOS)

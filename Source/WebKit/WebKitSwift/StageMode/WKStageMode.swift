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
    private var stageModeOperation: WKStageModeOperation = .none
    let interactionTarget: Entity
    
    @objc override init() {
        self.interactionTarget = Entity()
    }
    
    init(_ target: Entity) {
        Logger.objectManipulation.debug("WKOMInteraction: WKStageModeInteractionDriver created driver for target \(target.name)")
        self.interactionTarget = target
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
        
        self.init(interactionContainer)
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
        
        self.init(interactionContainer)
    }
    
    @objc(interactionDidBegin:)
    func interactionDidBegin(_ transform: simd_float4x4) {
        // TODO: rdar://141251753
    }
    
    @objc(interactionDidUpdate:)
    func interactionDidUpdate(_ transform: simd_float4x4) {
        // TODO: rdar://141251753
    }
    
    @objc(interactionDidEnd)
    func interactionDidEnd() {
        // TODO: rdar://141251753
    }
    
    @objc(operationDidUpdate:)
    func operationDidChange(_ operation: WKStageModeOperation) {
        self.stageModeOperation = operation
    }
    
}

#endif // os(visionOS)

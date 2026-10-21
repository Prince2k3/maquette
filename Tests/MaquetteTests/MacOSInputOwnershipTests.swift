#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import Maquette

@Suite("macOS input ownership")
struct MacOSInputOwnershipTests {
    @Test("Only a focused scene in the key window owns the visible scene area")
    func eligibility() {
        #expect(MacOSInputOwnership.eligible(isKeyWindow: true, isFocused: true,
            insideVisibleRect: true, excluded: false, isMomentum: false, ownsSequence: false))
        for denied in 0..<4 {
            #expect(!MacOSInputOwnership.eligible(isKeyWindow: denied != 0, isFocused: denied != 1,
                insideVisibleRect: denied != 2, excluded: denied == 3,
                isMomentum: false, ownsSequence: false))
        }
    }

    @Test("Momentum is swallowed only for a sequence already owned by the scene")
    func momentumOwnership() {
        #expect(!MacOSInputOwnership.eligible(isKeyWindow: true, isFocused: true,
            insideVisibleRect: true, excluded: false, isMomentum: true, ownsSequence: false))
        #expect(MacOSInputOwnership.eligible(isKeyWindow: true, isFocused: true,
            insideVisibleRect: true, excluded: false, isMomentum: true, ownsSequence: true))
        #expect(!MacOSInputOwnership.eligible(isKeyWindow: true, isFocused: false,
            insideVisibleRect: true, excluded: false, isMomentum: true, ownsSequence: true))
    }

    @Test("Wheel lines and natural scrolling normalize before model sensitivity")
    func wheelNormalization() {
        #expect(MacOSInputOwnership.normalizedDelta(2, precise: true, inverted: false) == 2)
        #expect(MacOSInputOwnership.normalizedDelta(2, precise: false, inverted: false) == 20)
        #expect(MacOSInputOwnership.normalizedDelta(2, precise: true, inverted: true) == -2)
    }

    @Test("Alternate modifiers switch both directions and empty disables the mapping")
    func wheelTarget() {
        var config = DioramaInputConfiguration.map
        #expect(MacOSInputOwnership.target(configuration: config, modifiers: []) == .ground)
        #expect(MacOSInputOwnership.target(configuration: config, modifiers: .shift) == .camera)
        config.wheelZoomTarget = .camera
        config.alternateWheelModifiers = [.option, .command]
        #expect(MacOSInputOwnership.target(configuration: config, modifiers: .option) == .camera)
        #expect(MacOSInputOwnership.target(configuration: config, modifiers: [.option, .command]) == .ground)
        config.alternateWheelModifiers = []
        #expect(MacOSInputOwnership.target(configuration: config, modifiers: .shift) == .camera)
    }

    @Test("Native modifiers translate without treating device flags as shortcuts")
    func nativeModifiers() {
        #expect(NSEvent.ModifierFlags([.shift, .option, .command]).dioramaEventModifiers == [.shift, .option, .command])
        #expect(NSEvent.ModifierFlags.numericPad.dioramaEventModifiers.isEmpty)
    }
}
#endif

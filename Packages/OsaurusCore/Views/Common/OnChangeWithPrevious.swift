//
//  OnChangeWithPrevious.swift
//  osaurus
//
//  Intel: macOS 13's `onChange(of:perform:)` passes only the new value, and
//  upstream's two-value `onChange(of:) { old, new in }` is macOS 14+. This
//  keeps the last seen value so code ported from upstream gets both. The
//  first change after the view appears compares against the value at appear.
//

import SwiftUI

private struct OnChangeWithPrevious<Value: Equatable>: ViewModifier {
    let value: Value
    let action: (Value, Value) -> Void
    @State private var previous: Value?

    func body(content: Content) -> some View {
        content
            .onAppear { if previous == nil { previous = value } }
            .onChange(of: value) { newValue in
                let old = previous ?? newValue
                previous = newValue
                action(old, newValue)
            }
    }
}

extension View {
    /// macOS 13 stand-in for upstream's `onChange(of:) { previous, value in }`.
    func onChangeWithPrevious<Value: Equatable>(
        of value: Value,
        perform action: @escaping (_ previous: Value, _ value: Value) -> Void
    ) -> some View {
        modifier(OnChangeWithPrevious(value: value, action: action))
    }
}

//
//  IntelOnboardingExistingInstallTests.swift
//  osaurusTests
//
//  Intel (2026-10-27): Intel builds before onboarding never recorded
//  `hasCompletedOnboarding`, so the first build with onboarding decides
//  once, from whether `~/.osaurus` already holds user data, whether an
//  install is new. Pure decision only; no defaults or files are touched.
//

import Foundation
import Testing

@testable import OsaurusCore

struct IntelOnboardingExistingInstallTests {
    @Test func anInstallWithDataIsMarkedCompleteOnce() {
        #expect(
            OnboardingService.existingInstallDecision(
                alreadyReconciled: false, isPristineInstall: false, shouldShowOnboarding: true
            ) == .markComplete)
    }

    @Test func aPristineInstallKeepsOnboarding() {
        #expect(
            OnboardingService.existingInstallDecision(
                alreadyReconciled: false, isPristineInstall: true, shouldShowOnboarding: true
            ) == .keepOnboarding)
    }

    @Test func aLaterResetIsNotUndone() {
        // Identity reset calls `resetOnboarding()`; the check already ran,
        // so the reset install goes through onboarding next launch.
        #expect(
            OnboardingService.existingInstallDecision(
                alreadyReconciled: true, isPristineInstall: false, shouldShowOnboarding: true
            ) == .alreadyReconciled)
    }

    @Test func aCompletedInstallNeedsNothing() {
        #expect(
            OnboardingService.existingInstallDecision(
                alreadyReconciled: false, isPristineInstall: false, shouldShowOnboarding: false
            ) == .keepOnboarding)
    }
}

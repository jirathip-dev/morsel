import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// Issue #125 — Sign in with Apple dead-button regression probe (source-level,
// hosted so npm test bites Swift edits on ubuntu, mirroring issue-105 style).
// SignInWithAppleButton is a UIKit-hosted ASAuthorizationAppleIDButton, so
// the #105 keyboard-dismiss tap gesture (.morselResignsKeyboardOnTap ->
// simultaneousGesture(TapGesture())) must NOT be attached to it: a SwiftUI
// tap gesture layered on a UIKit-hosted button swallows the button's own
// tap (the dead-button regression in TestFlight builds 5+6; email OTP kept
// working because those buttons are native SwiftUI). Keyboard dismissal for
// the Apple flow happens inside configureApple (the onRequest callback) via
// JournalKeyboardDismisser.resign(), which keeps the #105 AC6 intent without
// touching the hit-test. Re-adding the modifier (or moving the resign out of
// onRequest) must FAIL here.

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..')
const read = (path: string): string => readFileSync(join(repoRoot, path), 'utf8')

const auth = read('app/Sources/Morsel/AuthView.swift')
const journalFocus = read('app/Sources/Morsel/JournalFocus.swift')

describe('issue #125: Sign in with Apple button keeps its UIKit tap', () => {
  it('attaches no resign-tap gesture to the SignInWithAppleButton block', () => {
    const appleButton = auth.slice(
      auth.indexOf('SignInWithAppleButton('),
      auth.indexOf('HStack(spacing: 12)')
    )
    expect(appleButton, 'SIWA button block must exist above the "or email" row').toContain(
      'SignInWithAppleButton('
    )
    expect(
      appleButton,
      'the UIKit-hosted Apple button must not carry the resign tap gesture'
    ).not.toContain('.morselResignsKeyboardOnTap()')
    expect(
      appleButton,
      'no simultaneousGesture may wrap the UIKit-hosted Apple button'
    ).not.toContain('simultaneousGesture')
  })

  it('resigns the keyboard in configureApple (onRequest) instead of via a view gesture', () => {
    const appleRequest = auth.slice(
      auth.indexOf('private func configureApple'),
      auth.indexOf('private func completeApple')
    )
    expect(
      appleRequest,
      'configureApple must dismiss the keyboard so the #105 AC6 intent survives'
    ).toContain('JournalKeyboardDismisser.resign()')
    expect(journalFocus, 'the shared resign seam still exists').toContain(
      'enum JournalKeyboardDismisser'
    )
  })
})

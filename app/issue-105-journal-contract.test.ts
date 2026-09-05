import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// Issue #105 — journal follow-up UI contract probe (source-level, hosted so
// npm test bites Swift edits on ubuntu). Pins the shipped wiring that the
// native unit tests in app/Tests/MorselTests/JournalFollowUpTests.swift
// cannot reach from an unhosted bundle: the page-turn pager shell (the
// #111 hinged pager in the rich path, the plain non-3D fade under Reduce
// Motion), the Add Meal journal-page route (never the primary .sheet), the
// paper-native input surfaces (no stock Form cells), the shared
// keyboard/focus contract sites, and the trait-driven theme seam. A revert
// of any #105 behavior fails here.

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..')
const read = (path: string): string => readFileSync(join(repoRoot, path), 'utf8')

const morselApp = read('app/Sources/Morsel/MorselApp.swift')
const views = read('app/Sources/Morsel/Views.swift')
const journalUI = read('app/Sources/Morsel/JournalUI.swift')
const journalTexture = read('app/Sources/Morsel/JournalPaperTexture.swift')
const journalNav = read('app/Sources/Morsel/JournalNavigation.swift')
const journalFocus = read('app/Sources/Morsel/JournalFocus.swift')
const paperFields = read('app/Sources/Morsel/PaperFields.swift')
const mealCapture = read('app/Sources/Morsel/MealCaptureView.swift')
const editSheet = read('app/Sources/Morsel/MealItemEditSheet.swift')
const goals = read('app/Sources/Morsel/GoalsEditor.swift')
const auth = read('app/Sources/Morsel/AuthView.swift')
const settings = read('app/Sources/Morsel/SettingsView.swift')
const appearance = read('app/Sources/Morsel/MorselAppearance.swift')

describe('issue #105 AC1/AC2: page-turn pager wiring', () => {
  it('renders the three primary pages in the hinged pager bound to the pager model', () => {
    const shellStart = morselApp.indexOf('private struct AuthenticatedDashboardView')
    expect(shellStart, 'shell must exist').toBeGreaterThan(-1)
    const shell = morselApp.slice(shellStart)
    expect(shell).toContain('JournalTabBar(pager: pager)')
    // #111 replaced the flat page-style TabView slide with the custom hinged
    // pager; JournalPagerModel stays the ONE selection source so the visible
    // page and the tab indicator always agree (native JournalTurnRuleTests
    // pin the direction/adjacent rules; the issue #111 probe pins the hinge).
    expect(shell).toContain('JournalPageTurner(pager: pager)')
    expect(shell, 'the page-style TabView slide is gone').not.toContain('.tabViewStyle(')
    expect(shell, 'exactly one pager selection source').toMatch(
      /@StateObject private var pager = JournalPagerModel\(\)/
    )
    // The pager's page builder renders the real views per tab; the per-tab
    // switch below keeps Today · History · Goals in JournalTab.allCases order
    // so content order and the indicator order cannot drift.
    const pageBuilder = shell.slice(shell.indexOf('JournalPageTurner(pager: pager)'))
    expect(pageBuilder).toMatch(/JournalPageTurner\(pager: pager\)\s*\{\s*tab in\s*journalPage\(for: tab\)/)
  })

  it('fades to a plain content swap under Reduce Motion (non-3D fallback)', () => {
    expect(morselApp).toContain('@Environment(\\.accessibilityReduceMotion) private var reduceMotion')
    const pager = morselApp.slice(morselApp.indexOf('private var pageContent'))
    expect(pager).toMatch(/if reduceMotion\s*\{[\s\S]*?journalPage\(for: pager\.selection\)/)
    expect(pager).toMatch(/journalPage\(for: pager\.selection\)[\s\S]*?\.transition\(\.opacity\)/)
  })
})

describe('issue #105 AC3: Add Meal is a journal page route, not the primary sheet', () => {
  it('no longer presents Add Meal with .sheet from TodayView', () => {
    expect(views).not.toMatch(/\.sheet\(isPresented: \$isShowingAddMeal\)/)
  })

  it('presents the Add Meal page inside the journal flow and closes back to Today', () => {
    expect(morselApp).toContain('AddMealView(viewModel: viewModel, onClose: closeAddMeal)')
    expect(morselApp).toContain('routeModel.openAddMeal()')
    expect(morselApp).toContain('routeModel.isPresentingAddMeal')
    expect(morselApp).toContain('private func closeAddMeal()')
    // The page keeps its own Cancel/back + save header chrome.
    expect(mealCapture).toContain('JournalPageHeader(')
    expect(mealCapture).toContain('leadingTitle: "Cancel"')
  })
})

describe('issue #105 AC4/AC5: paper ground and paper-native inputs', () => {
  it('draws the deterministic restrained grain + ruled sheet on every journal page', () => {
    expect(journalTexture).toContain('struct JournalPaperTexture')
    expect(journalUI).toContain('morselJournalPaperUnderlay()')
    expect(journalTexture).toContain('MorselPalette.inkline')
    expect(journalUI).toContain('struct JournalPageFurniture')
    // Bound-edge crease wash next to the spine.
    expect(journalUI).toContain('Bound-edge crease')
  })

  it('replaces stock Form cells with the shared ruled field in Add Meal and Edit Item', () => {
    expect(mealCapture, 'Add Meal must not use a stock Form').not.toMatch(/Form \{/)
    expect(editSheet, 'Edit Item must not use a stock Form').not.toMatch(/Form \{/)
    expect(mealCapture).toContain('JournalPaperField(')
    expect(editSheet).toContain('JournalPaperField(')
    expect(goals, 'Goals edits with the same ruled language').toContain('JournalPaperField(')
    expect(paperFields).toContain('struct JournalPaperField<Key: Hashable>')
    expect(auth, 'sign-in fields use the ruled paper field too').toContain('JournalPaperField(')
  })
})

describe('issue #105 AC6: shared keyboard/focus contract wiring', () => {
  it('declares the shared resign seam and numeric Done policy once', () => {
    expect(journalFocus).toContain('#selector(UIResponder.resignFirstResponder)')
    expect(journalFocus).toContain('enum JournalKeyboardDismisser')
    expect(journalFocus).toContain('ToolbarItemGroup(placement: .keyboard)')
    expect(journalFocus).toContain('.decimalPad, .numberPad, .numbersAndPunctuation')
  })

  it('scrolls the keyboard away on every journal page', () => {
    expect(journalUI).toContain('.scrollDismissesKeyboard(.immediately)')
    expect(auth).toContain('.scrollDismissesKeyboard(.immediately)')
  })

  it('wires the Done bar and resign taps across Add Meal, Edit Item, Goals, and sign-in', () => {
    expect(mealCapture).toContain('.morselNumericDoneBar(focused: $focusedField,')
    expect(editSheet).toContain('.morselNumericDoneBar(focused: $focusedField,')
    expect(goals).toContain('.morselNumericDoneBar(focused: $focusedField)')
    expect(auth).toContain('.morselNumericDoneBar(focused: $focusedField,')
    expect(mealCapture).toContain('.morselResignsKeyboardOnTap()')
    expect(goals).toContain('.morselResignsKeyboardOnTap()')
    expect(auth).toContain('.morselResignsKeyboardOnTap()')
    // Edit Item's resign sites live in the shared page header it renders.
    expect(editSheet).toContain('JournalPageHeader(')
  })

  it('resigns the keyboard on tab-bar taps and hides it under blank page space', () => {
    const bar = morselApp.slice(morselApp.indexOf('private struct JournalTabBar'))
    expect(bar).toContain('JournalKeyboardDismisser.resign()')
    expect(journalFocus).toContain('morselBlankSpaceDismissesKeyboard()')
    expect(journalUI).toContain('.morselBlankSpaceDismissesKeyboard()')
  })
})

describe('issue #105 AC7: Paper/Night-ink immediacy through the appearance seam', () => {
  it('stores the root and Settings through one theme key so changes re-ink live', () => {
    expect(morselApp).toContain('@AppStorage(MorselAppearance.themePreferenceKey)')
    expect(settings).toContain('@AppStorage(MorselAppearance.themePreferenceKey)')
    expect(appearance).toContain('static let themePreferenceKey = "morsel.appearance.theme"')
  })

  it('resolves every journal surface through dual tokens — no system or black Form leak', () => {
    const surfaces = [mealCapture, editSheet, auth, goals, journalUI]
    const names = ['MealCaptureView', 'MealItemEditSheet', 'AuthView', 'GoalsEditor', 'JournalUI']
    for (let index = 0; index < surfaces.length; index += 1) {
      const where = names[index]
      expect(surfaces[index], `${where} must not use the system background`).not.toContain('systemBackground')
      expect(surfaces[index], `${where} must not hard-code black`).not.toMatch(/\bColor\.black\b|UIColor\.black/)
    }
    expect(journalUI).toContain('.background(Color.morselBackground.ignoresSafeArea())')
    expect(mealCapture).toContain('JournalPage(')
    expect(editSheet).toContain('JournalPage(')
  })
})

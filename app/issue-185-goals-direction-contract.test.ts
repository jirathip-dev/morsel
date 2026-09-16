import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'

const editor = readFileSync(new URL('Sources/Morsel/GoalsEditor.swift', import.meta.url), 'utf8')

describe('issue #185 native direction ownership wiring', () => {
  it('invalidates computations at the page disappearance boundary', () => {
    const boundary = editor.slice(editor.indexOf('.task(id: reloadKey)'), editor.indexOf('private var header:'))
    expect(boundary).toContain('.onDisappear { viewModel.cancelDirectionComputation() }')
  })

  it('shows pending separately from accepted selection and prevents saving old values while pending', () => {
    const directions = editor.slice(editor.indexOf('private var directions:'), editor.indexOf('private struct GoalJournalField'))
    expect(directions).toContain('viewModel.selectedDirection == direction')
    expect(directions).toContain('viewModel.pendingDirection == direction ? "Calculating…" : direction.subtitle')
    const save = editor.slice(editor.indexOf('Button(viewModel.didSave'), editor.indexOf('Text("What changes")'))
    expect(save).toContain('.disabled(!viewModel.isValid || viewModel.isSaving || viewModel.pendingDirection != nil)')
  })
})

import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// Issue #153 — photo attach + view on the Edit item sheet. Hosted source
// contract probe (npm test bites Swift edits on ubuntu, mirroring
// photo-pipeline-contract/warm-palette style). Pins the seams native XCTest
// cannot reach without a live Supabase client or a presented view:
// 1. Add Meal hands the picked photo to the SAME addMeal(photo:) seam the
//    outbox pipeline drains (issue item 1 attach-path proof).
// 2. The Edit-item sheet embeds the repository-backed photo section and
//    attaches a picked photo through the view model before the item update.
// 3. Attach/replace routes through the outbox for QUEUED rows (durable
//    payload swap + honest pending reset) and through the authenticated
//    remote upload + meal_logs.image_path update for SYNCED rows — never a
//    direct storage write outside those seams.
// Mutation contract: reverting the queued-row swap, the remote update seam,
// the view-model method, or the sheet wiring must FAIL here.

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..')
const read = (path: string): string => readFileSync(join(repoRoot, path), 'utf8')

const appShell = read('app/Sources/Morsel/MorselApp.swift')
const captureView = read('app/Sources/Morsel/MealCaptureView.swift')
const dataStore = read('app/Sources/Morsel/LocalDataStore.swift')
const editSheet = read('app/Sources/Morsel/MealItemEditSheet.swift')
const goalPage = read('app/Sources/Morsel/GoalPageContext.swift')
const localFirst = read('app/Sources/Morsel/LocalFirstRepository.swift')
const mutations = read('app/Sources/Morsel/SupabaseMealMutations.swift')
const repository = read('app/Sources/Morsel/Repository.swift')
const section = read('app/Sources/Morsel/MealPhotoEditorSection.swift')
const viewModel = read('app/Sources/Morsel/ViewModel.swift')

describe('issue #153: Add Meal hands the picked photo to the pipeline', () => {
  it('passes the prepared upload through addMeal(photo:) on save', () => {
    expect(captureView).toContain('viewModel.addMeal(draft: draft, photo: photo)')
  })
})

describe('issue #153: Edit-item sheet photo surface', () => {
  it('embeds the photo section fed by the shared view model', () => {
    expect(editSheet).toContain('@EnvironmentObject private var viewModel: DashboardViewModel')
    expect(editSheet).toContain('MealPhotoEditorSection(')
    expect(editSheet).toContain('repository: viewModel.repository')
    expect(editSheet).toContain('pendingPhoto: $pendingPhoto')
    expect(editSheet).toContain('trailingDisabled: isSaving || isProcessingPhoto')
  })

  it('attaches the picked photo through the view model before saving', () => {
    expect(editSheet).toContain('viewModel.attachPhoto(pendingPhoto, toItem: item.itemID)')
    expect(viewModel).toContain('func attachPhoto(_ photo: FoodImageUpload, toItem itemID: UUID) async -> Bool')
  })

  it('renders the existing photo through the re-minting repository pipeline', () => {
    expect(section).toContain('repository.loadMealImage(userID: userID, path: path)')
    expect(section).toContain('item.mealImage?.path')
    expect(section).toContain('The photo this meal was logged with')
  })

  it('offers library + camera attach with an honest processing state', () => {
    expect(section).toContain('PhotosPicker(selection: $pickerItem, matching: .images)')
    expect(section).toContain('CameraPicker(')
    expect(section).toContain('@Binding var pendingPhoto: FoodImageUpload?')
    expect(section).toContain('@Binding var isProcessingPhoto: Bool')
  })
})

describe('issue #153: attach/replace routes through outbox + image seams only', () => {
  it('declares the attach seam on the repository with a loud double default', () => {
    expect(repository).toContain('func attachMealPhoto(userID: UUID, itemID: UUID, photo: FoodImageUpload) async throws')
    expect(goalPage).toContain('func attachMealPhoto(userID: UUID, itemID: UUID, photo: FoodImageUpload) async throws')
    expect(goalPage).toContain('Photo attach is not supported by this repository.')
  })

  it('swaps the durable photo of a QUEUED row and resets it to honest pending', () => {
    expect(localFirst).toContain('store.replaceQueuedMealPhoto(')
    expect(localFirst).toContain('try FoodImageStore.validate(data: photo.data, mimeType: photo.mimeType)')
    expect(dataStore).toContain('func replaceQueuedMealPhoto(mealID: UUID, photo: QueuedMealPhoto, now: Date = Date()) throws')
    expect(dataStore).toContain("state = 'pending', last_error = NULL, last_error_category = NULL")
    expect(dataStore).toContain('image_path = NULL')
  })

  it('uploads a SYNCED meal photo at its canonical path and updates image_path', () => {
    expect(mutations).toContain('func attachMealPhoto(userID: UUID, itemID: UUID, photo: FoodImageUpload) async throws')
    expect(mutations).toContain('uploadMealPhoto(')
    expect(mutations).toContain('MealLogImagePathUpdate(imagePath: objectPath)')
    expect(mutations).toContain('.from("meal_logs")')
    expect(mutations).toContain('.eq("user_id", value: authenticatedUserID.uuidString)')
  })

  it('injects the shared view model into the journal shell environment', () => {
    expect(appShell).toContain('.environmentObject(viewModel)')
  })
})

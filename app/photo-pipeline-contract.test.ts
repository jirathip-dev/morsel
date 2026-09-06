import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// Issue #135 — photo-pipeline source contract probe (hosted so npm test
// bites Swift edits on ubuntu, mirroring warm-palette/issue-123 style).
// Pins the app-side data-path fixes that native XCTest cannot reach without
// a live Supabase client:
// 1. Writes store the CANONICAL #133 image path ({user_id}/{meal_id}.jpg)
//    in meal_logs.image_path / p_image_path — never a bucket-qualified
//    "food-images/..." path the server cannot sign.
// 2. Reads accept BOTH the canonical object path and the legacy
//    bucket-qualified form, so server-logged photo meals render thumbnails.
// 3. The reconciled read model carries image {path, signed_url, expires_at}
//    with per-read minting + expiry checks (MealRecordSchema.image).
// 4. Upload refusals are classified like RPC refusals: permanent denials
//    surface needs-attention instead of a silent green-pending retry loop.
// 5. Queued photo rows serve their local bytes at the deterministic path.
// The Edit-item sheet photo surface moved to the repository-backed
// MealPhotoEditorSection (issue #153 — see photo-edit-contract.test.ts).
// Mutation contract: reverting the canonical write, the tolerant read, the
// image hydration, or the needs-attention mapping must FAIL here.

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..')
const read = (path: string): string => readFileSync(join(repoRoot, path), 'utf8')

const models = read('app/Sources/Morsel/Models.swift')
const mealCapture = read('app/Sources/Morsel/MealCapture.swift')
const mealRepository = read('app/Sources/Morsel/MealRepository.swift')
const repository = read('app/Sources/Morsel/Repository.swift')
const readModel = read('app/Sources/Morsel/SupabaseMealReadModel.swift')
const syncEngine = read('app/Sources/Morsel/LocalSyncEngine.swift')
const dataStore = read('app/Sources/Morsel/LocalDataStore.swift')
const localFirst = read('app/Sources/Morsel/LocalFirstRepository.swift')

describe('issue #135 defect 1: canonical #133 image path written, legacy paths still read', () => {
  it('models the #133 image read contract on the native read model', () => {
    expect(models).toContain('struct MealImage: Equatable, Sendable, Codable')
    expect(models).toContain('func isExpired(at date: Date = Date()) -> Bool')
    expect(models).toContain('let image: MealImage?')
    expect(models).toContain('let mealImage: MealImage?')
    expect(models).toContain('func withMealImage(_ image: MealImage?) -> MealItem')
  })

  it('uploads return and commit the canonical object path, never a bucket-qualified path', () => {
    expect(mealRepository).toContain('imagePath: uploadedImage?.objectPath')
    expect(mealRepository).toMatch(/return objectPath/)
    expect(mealRepository).not.toMatch(/imagePath: uploadedImage\?\.bucketPath/)
  })

  it('validates reads tolerantly: canonical object paths AND legacy bucket-qualified paths', () => {
    expect(mealCapture).toContain('let objectComponents: [Substring]')
    expect(mealCapture).toContain('Array(components.dropFirst())')
    expect(mealCapture).toContain('guard objectComponents.count == 2')
    expect(mealCapture).toContain('components[0] == Substring(bucket)')
  })
})

describe('issue #135 defect 2: reconciled rows carry signed_url with expiry refresh', () => {
  it('mints per-read signed URLs during loadToday (MealRecordSchema.image)', () => {
    expect(repository).toContain('image: imagesByMealID[log.id]')
    expect(readModel).toContain('func parseMeal(')
    expect(readModel).toContain('func mintMealImages(')
    expect(readModel).toContain('createSignedURL(path: objectPath, expiresIn: signedTTLSeconds)')
    expect(readModel).toContain('items.map { $0.withMealImage(image) }')
  })

  it('hydrates queued journal items with the meal photo context for Edit', () => {
    expect(localFirst).toContain('.map { $0.withMealImage(image) }')
    expect(localFirst).toContain('row.photo == nil ? nil : FoodImageStore.objectPath(userID: userID, imageID: row.mealID)')
  })
})

describe('issue #135 defect 3: upload/commit refusals never silent-pending', () => {
  it('classifies photo-upload errors at the outbox delivery seam', () => {
    expect(syncEngine).toContain('throw classifyRemoteMealError(error)')
    expect(syncEngine).toContain('permanent: true, now: now()')
  })

  it('moves EVERY permanent refusal to needs-attention in the store', () => {
    expect(dataStore).toContain('permanent: Bool = false')
    expect(dataStore).toContain('let needsAttention = permanent || error == .auth || error == .validation')
  })
})

describe('issue #135 defect 4: queued photo rows render immediately at the deterministic path', () => {
  it('serves the queued photo bytes locally before any network work', () => {
    expect(localFirst).toContain('journalRecord(for: row, userID: userID)')
    expect(localFirst).toContain('func queuedPhotoData(userID: UUID, path: String) throws -> Data?')
    expect(localFirst).toContain('FoodImageStore.objectPath(userID: userID, imageID: row.mealID)')
  })
})

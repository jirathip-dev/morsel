# Issue 241 native artwork identity evidence

Base: `6f87585d2a8c1bac49237a7a4ac6654297619dbb`.
Branch: `issue/241-artwork-native`.

## Execution status — BLOCKED, not acceptance-complete

The native runner exhausted the brief's 30-minute arbitration window: all 31
`pgrep -fl "xcodebuild|xctest"` observations found other native workloads.
`python3 .lane-tools/run-native.py base-red` exited **75 before launching
xcodebuild**. This is a host-arbitration refusal, NOT a behavioral RED.
No head native run, complete native suite, or simulator capture was performed.
There are **zero rendered proof captures** in this delivery. The new native
suites have syntax-only validation, not compile/runtime verification.
The descriptions below document implemented paths and intended tests, not
successful native execution. The lane report preserves the exact gate logs.

## Live decode and rendering seams

The shipped native app does not decode MCP `get_day` responses. It reads the
same persisted rows through Supabase/PostgREST. `Repository.swift` owns the
shared `mealItemColumns` projection, `MealItemResponse.CodingKeys` decoder and
`SupabaseDashboardRepository.parseItem`. These now select/decode/carry
`artwork_id`. Today and History share `loadMealItems`; item-update readbacks
also use the shared projection and parser. This lane does not change writes.

`Models.swift` owns the optional `MealItem.artworkID` and its synthesized
Codable local-snapshot representation. Its `withMealImage` copy preserves the
identity during parent-photo hydration. Old cache objects without that property
and PostgREST rows with absent/null identity decode without an identity.
These are the only two changed decode/model files. `SupabaseMealReadModel.swift`
(the existing parent-photo hydration caller) is read-only.

Both `MealArtworkSlot` and the existing `MealPhotoEditorSection` call
`JournalRowArtwork.resolve(items:)`. The shared fix therefore reaches actual
Today/History rows and detail/edit without modifying their owners' files.
The row API still takes no photo path. Detail/edit still prefers the real photo.
No illustration upload, network generation, production write, data migration,
backfill, name edit, nutrition edit or photo-reference edit is introduced.

## Deterministic precedence

1. Exact case-sensitive identity membership in the shipped catalog wins over
   every name, including a contradictory Variant A name. IDs are never trimmed,
   lowercased, treated as filenames, or sent to a network service. A supported
   explicit neutral/category ID selects that published asset too.
2. Without a supported identity, retain the approved Variant A full-name/alias
   table, then the library's normalized full names/aliases. Name normalization
   is lowercasing and collapsed whitespace. Colliding library terms are refused.
   `Americano` is a coffee alias. A descriptive Americano is accepted only as
   the entire `Americano (<comma-separated descriptors>)` form, with each
   descriptor in `black`, `no sugar`, `homemade`, `unsweetened`, `iced`, `hot`,
   `decaf`. Empty components, unknown descriptors, nested parentheses and trailing
   dish text are refused. This does not recognize arbitrary substrings.
3. Unambiguous catalog category names/aliases use the labeled category fallback.
   Composite meals retain the existing same-category aggregation rules; a mixed
   or unidentified meal never depicts one arbitrary ingredient.
4. Otherwise use the approved neutral eating sign (Variant A `unknown` in the
   journal; explicit `fallback-neutral` keeps its published library asset).
   An empty item list remains empty.

Unsupported IDs (including future IDs in an older bundle) take steps 2–4.
The server's rejection of invalid input IDs is unchanged; tolerant native reads
are not permission to write unpublished IDs. No owner relogging is needed.

## Fixtures and render method

`ArtworkIdentityTests.swift` uses JSON decoded by the production response/parser,
not a new-API initializer, to remain base-compatible (compilation is unverified).
It covers all five positive names, negatives, identity precedence, invalid IDs,
all published IDs, a simulated older catalog, row/photo separation, preservation,
and actual Paper/Night rendered pixels against the bundled coffee asset.
`ArtworkIdentityReadTests.swift` additionally drives the real authenticated
Supabase repository through a controlled URLSession transport and checks the
actual projection, hydration, local cache round-trip, absent/null compatibility,
and ambiguous terms/categories. No live service is involved.

`ArtworkIdentitySurfaceTests.swift` mounts the real `MealItemRow` inside the
real `JournalPage`, then the real `MealItemEditSheet`, in an app-hosted UIWindow
on the dedicated simulator. It does not replace the app entry point, modify auth,
or recreate a screenshot-only renderer. Detail has a top frame and a scrolled
art/photo frame; these are different scroll positions of the same real sheet.
The host `capture.py` handshake saves unmodified `simctl io screenshot` PNGs.
XCTest also attaches the mounted frames to its xcresult. Fixture injection is
in the test target only. If run successfully, these are mounted-surface tests,
not a user tap from an authenticated live dashboard, physical-device behavior,
or a live MCP round-trip. No successful native run is claimed here.

Positive fixtures: Coffee; black coffee; กาแฟ; Americano;
Americano (black, no sugar, homemade).
Negative fixtures: coffee cake; Coffee with rice and chicken;
Uncatalogued lunar stew.
Additional fixtures: Focaccia bread with explicit coffee; Americano with
unsupported future-study; Coffee with explicit coffee and a real photo.

The original descriptive name is preserved in data assertions; existing compact
row/field layouts may truncate its visible suffix. No hidden screenshot text is
claimed as read. The negative foods are intentionally neutral, not inferred dishes.

## Public photograph fixture

`fixtures/coffee-photo.png` is the real coffee photograph by Rachel Michetti,
courtesy of Pikolo Espresso Bar, published CC0. It is not a user photo, generated
image, or illustration. Source bytes (600 × 400):
https://raw.githubusercontent.com/scikit-image/scikit-image/v0.19.3/skimage/data/coffee.png

License/source description:
https://scikit-image.org/docs/0.25.x/api/skimage.data.html#skimage.data.coffee

SHA-256: `cc02f8ca188b167c775a7101b5d767d1e71792cf762c33d6fa15a4599b5a8de7`.
The fixture is a resource of the test bundle only; an in-memory repository
serves its bytes through the normal detail photo pipeline, never live storage.

## Scope and limits

The published schema, server, database migration and approved art catalog are
read-only in this lane. None of the existing Swift-source probes pins a retired
literal; `npx vitest run app` passed without weakening or retargeting them.
No physical device, signed distribution build, live MCP-to-Supabase round-trip,
live account, deployment, or production migration/backfill is verified here.
Capture inventory: zero screenshots. The only PNG present is the public input
photograph under `fixtures/`; it is NOT rendered acceptance evidence. Native
verification and the required RED/GREEN pair remain blocked, as stated above.

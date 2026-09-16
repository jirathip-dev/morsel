# Exhaustive source coverage

Pinned base: `2d87d61e73c6c3db7bd1420294ccf1551232405d`.

36 source-derived specimen pages × Paper/Night × before/after. 72 discovered font-use/field-binding lines across 22 files; 69 mapped to visible excerpts; 3 structural/non-text exclusions. These are not counts of native screenshots.

The issue lists five affected bullets despite saying six. Weight/chart labels are split out from rows/columns; technical strings are separate. Shared sites overlap groups; never add group site counts as unique totals.

## 01 · Headline figures

2 pages; 3 unique source IDs in this group.

- [Today · Eaten / Goal](today-headline.html?theme=paper&version=after): `Views-146`. Eaten changes; the existing serif denominator stays serif. Lower specimens test width, not additional Today metrics.
- [History · Summary](history-headline.html?theme=paper&version=after): `HistoryLedgerViews-190`, `HistoryLedgerViews-212`. Only type changes. Values are fixed fictional specimens; no live account or write path.

## 02 · Rows & columns

12 pages; 26 unique source IDs in this group.

- [Today · Food rows](food-rows.html?theme=paper&version=after): `JournalFoodRow-100`, `JournalFoodRow-105`, `JournalFoodRow-62`, `JournalFoodRow-70`. Approved Variant A art: unchanged 56 px slot, 18 px/500 name, portion, right-aligned energy and macro line. No photos in rows.
- [Today’s log](today-log.html?theme=paper&version=after): `JournalFoodRow-100`, `JournalFoodRow-105`, `JournalFoodRow-62`, `JournalFoodRow-70`, `JournalUI-364`, `TodayLogViews-115`, `TodayLogViews-87`, `TodayLogViews-95`. SectionHeading detail and both time branches are included; reused food rows are also visible.
- [Macro wash columns](macro-columns.html?theme=paper&version=after): `JournalUI-233`. Shared V1MacroStrip valueText: Today and historical drill-down. The 108 px trailing column stays fixed; wash is illustrative.
- [History · Ledger](history-ledger.html?theme=paper&version=after): `HistoryLedgerViews-134`, `HistoryLedgerViews-256`, `HistoryLedgerViews-260`, `HistoryLedgerViews-34`, `JournalUI-364`. Compact date labels, numeric ledger columns and list comparison/delta. No historical-target policy change is implied.
- [12 September](day-drill.html?theme=paper&version=after): `DayDrillDown-59`, `DayDrillDown-63`, `DayDrillDown-67`, `JournalFoodRow-100`, `JournalFoodRow-105`, `JournalFoodRow-62`, `JournalFoodRow-70`. Over, on-target and zero specimens. This reproduces source wording; it is not a correction to comparison logic.
- [Journal · Gutter date](journal-folios.html?theme=paper&version=after): `JournalUI-48`. The date keeps 0.5 px tracking and its rotated gutter position. Header dates already in other faces are not changed.
- [Auth & setup labels](peripheral-labels.html?theme=paper&version=after): `AuthView-52`, `AuthView-94`, `Onboarding-205`, `Onboarding-256`, `Onboarding-271`, `Onboarding-282`, `Onboarding-369`, `Onboarding-377`. These inherited mono labels are not technical strings: the candidate moves them to diary serif. “morsel” wordmarks are retained separately, per the explicit issue inventory.
- [Existing training receipt](training-receipt.html?theme=paper&version=after): `TrainingFuelViews-87`. Baseline-only type comparison of the current receipt. Half (a) removes this from Today; this gallery does not reintroduce it or decide the half-(a) layout.
- [History · Day macros](historical-macros.html?theme=paper&version=after): `JournalUI-233`. The same three MacroWashStrip fields inside DayDrillDown. Six total static macro call sites across Today and expanded History are enumerated in COVERAGE.md.
- [Food · Missing values](food-missing.html?theme=paper&version=after): `JournalFoodRow-100`, `JournalFoodRow-105`, `JournalFoodRow-62`, `JournalFoodRow-70`. Missing calories remain an em dash; absent macros retain the source string “No macro data”. No invented zero or nutrient estimate.
- [Receipt · Unconfirmed](training-unconfirmed.html?theme=paper&version=after): `TrainingFuelViews-87`. Shared receipt branches appear in both current Today and the current editor sheet. Half (a) supersedes their placement; this is typography-only baseline evidence.
- [Shared date furniture](journal-hosts.html?theme=paper&version=after): `JournalUI-48`. All eight page-furniture hosts, enumerated explicitly. Dates are unrotated here for comparing the small type; journal-folios shows the gutter orientation. No navigation is changed.

## 03 · Weight & chart labels

4 pages; 5 unique source IDs in this group.

- [Weight trend](weight-chart.html?theme=paper&version=after): `JournalUI-364`, `WeightDeltaBand-22`, `WeightDeltaBand-58`, `WeightDeltaBand-76`. Chart text only: 9/10/12 px. Weight trace, missing-data symbols and axis positions are illustrative browser reconstructions; not Swift Charts proof.
- [16 September](weight-receipt.html?theme=paper&version=after): `WeightDeltaBand-147`. All six receipt value rows; fixed fictional historical records. Confirmed addition is a specimen, never a suggestion.
- [Unavailable records](weight-missing.html?theme=paper&version=after): `WeightDeltaBand-147`. Nil branches retain honest text. No missing value is shown as zero; no Health interpretation.
- [Weight · Caption states](weight-caption-branches.html?theme=paper&version=after): `JournalUI-364`. Current MorselFormat.number uses whole-number precision. The decimal example in the old WeightTrendView comment is stale; no formatter change is proposed.

## 04 · Calendar

1 pages; 2 unique source IDs in this group.

- [Calendar](calendar-month.html?theme=paper&version=after): `JournalCalendarView-104`, `JournalCalendarView-43`. Month-grid digits and first-log range. Only typography changes; calendar selection/flip behaviour is not implemented or proposed here.

## 05 · Goals & shared forms

4 pages; 4 unique source IDs in this group.

- [What are we aiming for?](goals-filled.html?theme=paper&version=after): `GoalsEditor-240`, `PaperFields-91`. Current Goals uses 22 px calories and 17 px macro fields. The 30 px Goals gauge named in the issue is absent at this pinned base; no fake gauge has been minted.
- [One more pass…](goals-validation.html?theme=paper&version=after): `GoalsEditor-240`, `PaperFields-66`, `PaperFields-91`. Validation strings share morselData; candidate is serif prose at the same 11 px. Blank input stays blank; source errors are shown without inventing a saved value.
- [Ruled field states](shared-field-states.html?theme=paper&version=after): `PaperFields-91`. Shared field typography only. “Optional” is a placeholder specimen, not zero. Only Goals supplies inline field errors at this base. Keyboard, focus and native Dynamic Type remain unverified.
- [Existing amount field](training-amount.html?theme=paper&version=after): `TrainingFuelViews-105`. Half-(a) overlap accounted for. The current 11 px medium font is compared without proposing its old layout for implementation. No numeric default.

## 06 · Meal, photo & menu sheets

9 pages; 24 unique source IDs in this group.

- [Add a meal](meal-capture.html?theme=paper&version=after): `MealCaptureView-116`, `MealCaptureView-209`, `MealCaptureView-214`, `MealCaptureView-221`, `MealCaptureView-226`, `PaperFields-91`. Quantity is prominent 22 px; optional nutrition is 17 px. Values are fixed input specimens, not food estimates or saved records.
- [Edit food](meal-edit.html?theme=paper&version=after): `MealItemEditSheet-106`, `MealItemEditSheet-117`, `MealItemEditSheet-131`, `MealItemEditSheet-142`, `MealItemEditSheet-147`, `MealItemEditSheet-86`, `PaperFields-91`. Same fixed data before and after; no save, mutation, photo access or database connection.
- [Food · Provenance](meal-confidence.html?theme=paper&version=after): `MealItemEditSheet-349`, `MealItemEditSheet-356`. Confidence lives in the detail sheet, never the row. The confidence formatter outputs whole percentages; both warning strings are verbatim from the pinned source.
- [Your menus](menu-list.html?theme=paper&version=after): `MealCaptureView-354`, `MenusScreen-111`. Both menu.summaryLine consumers, including counts and total energy. Names and values are fictional.
- [Edit menu](menu-editor.html?theme=paper&version=after): `MenuEditorSheet-152`, `MenuEditorSheet-169`, `PaperFields-91`. Menu quantity is 17 px, not the prominent 22 px capture/edit quantity. Unit and food name stay in their existing serif voice.
- [Add meal · Photo](add-photo.html?theme=paper&version=after): `AddMealPhotoSection-129`, `AddMealPhotoSection-156`, `AddMealPhotoSection-165`. Photo bytes are not accessed. File-size specimen and nontechnical status/control copy change; photo contents are not invented.
- [Edit · Photo & illustration](edit-photo.html?theme=paper&version=after): `MealPhotoEditorSection-101`, `MealPhotoEditorSection-153`, `MealPhotoEditorSection-312`. The food illustration remains unchanged. Detail-only photo/picker/permission states are not re-minted; text states are source-derived specimens.
- [Illustration · Provenance](illustration-provenance.html?theme=paper&version=after): `MealPhotoEditorSection-312`. All nonempty illustrationCopy families. The .none branch emits no text; it is not fabricated as a fourth visible value.
- [New menu](menu-new.html?theme=paper&version=after): `MenuEditorSheet-152`, `MenuEditorSheet-169`, `PaperFields-91`. New-menu host of the same MenuEditorSheet numeric fields. Optional calories are shown as placeholder text, not a zero default.

## Kept mono · Technical & named brand exception

4 pages; 7 unique source IDs in this group.

- [MCP endpoint](technical-endpoints.html?theme=paper&version=after): `Onboarding-329`, `SettingsView-125`, `SettingsView-136`. Unchanged mono: endpoint and its technical configuration status. URL is a display-only specimen; no link or request is made.
- [Claude · Setup prompt](technical-claudePrompt.html?theme=paper&version=after): `Onboarding-303`. Exact retained prompt text with the display endpoint substituted. Technical setup strings remain mono, including numbered steps. No commands execute.
- [ChatGPT / Others · Setup prompt](technical-chatPrompt.html?theme=paper&version=after): `Onboarding-303`. Exact retained prompt text with the display endpoint substituted. Technical setup strings remain mono, including numbered steps. No commands execute.
- [Copy & brand exceptions](technical-copy-brand.html?theme=paper&version=after): `AuthView-29`, `EndpointCopyPill-20`, `Onboarding-192`. Copy pills and the explicitly retained wordmark remain mono. Brand is the issue’s named exception, not falsely classified as numeric or technical prose.

## Every matching line

| Source | Status | Rendered page(s) / reason |
|---|---|---|
| AddMealPhotoSection.swift:129 | rendered | add-photo |
| AddMealPhotoSection.swift:156 | rendered | add-photo |
| AddMealPhotoSection.swift:165 | rendered | add-photo |
| AuthView.swift:29 | rendered | technical-copy-brand |
| AuthView.swift:52 | rendered | peripheral-labels |
| AuthView.swift:94 | rendered | peripheral-labels |
| DayDrillDown.swift:59 | rendered | day-drill |
| DayDrillDown.swift:63 | rendered | day-drill |
| DayDrillDown.swift:67 | rendered | day-drill |
| DesignSystem.swift:296 | not-visible | Unused morselTag helper: no production call site at base; no visible surface to mint. |
| EndpointCopyPill.swift:20 | rendered | technical-copy-brand |
| GoalsEditor.swift:240 | rendered | goals-filled, goals-validation |
| HistoryLedgerViews.swift:34 | rendered | history-ledger |
| HistoryLedgerViews.swift:134 | rendered | history-ledger |
| HistoryLedgerViews.swift:190 | rendered | history-headline |
| HistoryLedgerViews.swift:212 | rendered | history-headline |
| HistoryLedgerViews.swift:256 | rendered | history-ledger |
| HistoryLedgerViews.swift:260 | rendered | history-ledger |
| JournalCalendarView.swift:43 | rendered | calendar-month |
| JournalCalendarView.swift:104 | rendered | calendar-month |
| JournalFoodRow.swift:62 | rendered | food-rows, today-log, day-drill, food-missing |
| JournalFoodRow.swift:70 | rendered | food-rows, today-log, day-drill, food-missing |
| JournalFoodRow.swift:100 | rendered | food-rows, today-log, day-drill, food-missing |
| JournalFoodRow.swift:105 | rendered | food-rows, today-log, day-drill, food-missing |
| JournalUI.swift:48 | rendered | journal-folios, journal-hosts |
| JournalUI.swift:233 | rendered | macro-columns, historical-macros |
| JournalUI.swift:364 | rendered | today-log, history-ledger, weight-chart, weight-caption-branches |
| MealCaptureView.swift:116 | rendered | meal-capture |
| MealCaptureView.swift:209 | rendered | meal-capture |
| MealCaptureView.swift:214 | rendered | meal-capture |
| MealCaptureView.swift:221 | rendered | meal-capture |
| MealCaptureView.swift:226 | rendered | meal-capture |
| MealCaptureView.swift:354 | rendered | menu-list |
| MealItemEditSheet.swift:86 | rendered | meal-edit |
| MealItemEditSheet.swift:106 | rendered | meal-edit |
| MealItemEditSheet.swift:117 | rendered | meal-edit |
| MealItemEditSheet.swift:131 | rendered | meal-edit |
| MealItemEditSheet.swift:142 | rendered | meal-edit |
| MealItemEditSheet.swift:147 | rendered | meal-edit |
| MealItemEditSheet.swift:349 | rendered | meal-confidence |
| MealItemEditSheet.swift:356 | rendered | meal-confidence |
| MealPhotoEditorSection.swift:101 | rendered | edit-photo |
| MealPhotoEditorSection.swift:153 | rendered | edit-photo |
| MealPhotoEditorSection.swift:312 | rendered | edit-photo, illustration-provenance |
| MenuEditorSheet.swift:152 | rendered | menu-editor, menu-new |
| MenuEditorSheet.swift:169 | rendered | menu-editor, menu-new |
| MenusScreen.swift:111 | rendered | menu-list |
| Onboarding.swift:192 | rendered | technical-copy-brand |
| Onboarding.swift:205 | rendered | peripheral-labels |
| Onboarding.swift:256 | rendered | peripheral-labels |
| Onboarding.swift:271 | rendered | peripheral-labels |
| Onboarding.swift:282 | rendered | peripheral-labels |
| Onboarding.swift:303 | rendered | technical-claudePrompt, technical-chatPrompt |
| Onboarding.swift:329 | rendered | technical-endpoints |
| Onboarding.swift:369 | rendered | peripheral-labels |
| Onboarding.swift:377 | rendered | peripheral-labels |
| PaperFields.swift:66 | rendered | goals-validation |
| PaperFields.swift:91 | rendered | goals-filled, goals-validation, shared-field-states, meal-capture, meal-edit, menu-editor, menu-new |
| SettingsView.swift:125 | rendered | technical-endpoints |
| SettingsView.swift:136 | rendered | technical-endpoints |
| SettingsView.swift:159 | not-visible | SF Symbol chevron (replay row), not text or numeric glyph. Retain native symbol sizing; not recreated as font proof. |
| SettingsView.swift:208 | not-visible | SF Symbol chevron (delete-account row), not text or numeric glyph. Retain native symbol sizing; not recreated as font proof. |
| TodayLogViews.swift:87 | rendered | today-log |
| TodayLogViews.swift:95 | rendered | today-log |
| TodayLogViews.swift:115 | rendered | today-log |
| TrainingFuelViews.swift:87 | rendered | training-receipt, training-unconfirmed |
| TrainingFuelViews.swift:105 | rendered | training-amount |
| Views.swift:146 | rendered | today-headline |
| WeightDeltaBand.swift:22 | rendered | weight-chart |
| WeightDeltaBand.swift:58 | rendered | weight-chart |
| WeightDeltaBand.swift:76 | rendered | weight-chart |
| WeightDeltaBand.swift:147 | rendered | weight-receipt, weight-missing |

## Expanded reuse inventory

Every static helper host from the independent read-only source audit is listed below. A shared specimen demonstrates its font role once; reuse mapping does not claim an in-situ native screenshot of every host.

### AddMealPhotoSection.swift:129

Camera unavailable simulator notice
Specimen(s): add-photo.

- `app/Sources/Morsel/MealCaptureView.swift:75` — Add Meal photo section; one per presentation

### AddMealPhotoSection.swift:156

JPEG · <integer kilobytes> KB upload metadata
Specimen(s): add-photo.

- `app/Sources/Morsel/MealCaptureView.swift:75` — Add Meal photo section; one per presentation

### AddMealPhotoSection.swift:165

Remove selected photo
Specimen(s): add-photo.

- `app/Sources/Morsel/MealCaptureView.swift:75` — Add Meal photo section; one per presentation

### AuthView.swift:29

morsel wordmark
Specimen(s): technical-copy-brand.

- `app/Sources/Morsel/MorselApp.swift:78` — Root sign-in view; one per presentation
- `app/Sources/Morsel/Onboarding.swift:261` — Onboarding sign-in content; one per presentation

### AuthView.swift:52

or email separator
Specimen(s): peripheral-labels.

- `app/Sources/Morsel/MorselApp.swift:78` — Root sign-in view; one per presentation
- `app/Sources/Morsel/Onboarding.swift:261` — Onboarding sign-in content; one per presentation

### AuthView.swift:94

Use a different email button in code step
Specimen(s): peripheral-labels.

- `app/Sources/Morsel/MorselApp.swift:78` — Root sign-in view; one per presentation
- `app/Sources/Morsel/Onboarding.swift:261` — Onboarding sign-in content; one per presentation

### DayDrillDown.swift:59

Expanded-day eaten kcal
Specimen(s): day-drill.

- `app/Sources/Morsel/HistoryView.swift:230` — Expanded History chart day; conditionally for expanded day

### DayDrillDown.swift:63

vs goal calories
Specimen(s): day-drill.

- `app/Sources/Morsel/HistoryView.swift:230` — Expanded History chart day; conditionally for expanded day

### DayDrillDown.swift:67

Positive kcal delta + over, or on target text
Specimen(s): day-drill.

- `app/Sources/Morsel/HistoryView.swift:230` — Expanded History chart day; conditionally for expanded day

### EndpointCopyPill.swift:20

Copy / Copied ✓ endpoint copy action
Specimen(s): technical-copy-brand.

- `app/Sources/Morsel/Onboarding.swift:332` — MCP endpoint copy pill; one per presentation
- `app/Sources/Morsel/SettingsView.swift:141` — MCP endpoint copy pill; one per presentation

### HistoryLedgerViews.swift:34

Compact date/month labels in 30-day calorie-bar ledger
Specimen(s): history-ledger.

- `app/Sources/Morsel/HistoryView.swift:228` — Calorie history bars; per chart day; compact dates only for first/last or day-of-month % 5 == 1, never today; value column only outside thirty-day range

### HistoryLedgerViews.swift:134

Eaten-kcal right column (not shown in 30-day range)
Specimen(s): history-ledger.

- `app/Sources/Morsel/HistoryView.swift:228` — Calorie history bars; per chart day; compact dates only for first/last or day-of-month % 5 == 1, never today; value column only outside thirty-day range

### HistoryLedgerViews.swift:190

<streak>-day logging streak
Specimen(s): history-headline.

- `app/Sources/Morsel/HistoryView.swift:243` — History summary strip; one per presentation

### HistoryLedgerViews.swift:212

Large history summary values: average kcal / days over / logged
Specimen(s): history-headline.

- `app/Sources/Morsel/HistoryLedgerViews.swift:182` — Average kcal; one per presentation
- `app/Sources/Morsel/HistoryLedgerViews.swift:183` — Days over target; one per presentation
- `app/Sources/Morsel/HistoryLedgerViews.swift:184` — Days logged; one per presentation

### HistoryLedgerViews.swift:256

Days-vs-goal eaten vs target numeric row
Specimen(s): history-ledger.

- `app/Sources/Morsel/HistoryView.swift:251` — Days-vs-goal list; per visible day; see-all reveals hidden days; numbers shown only when logged

### HistoryLedgerViews.swift:260

Signed days-vs-goal calorie delta
Specimen(s): history-ledger.

- `app/Sources/Morsel/HistoryView.swift:251` — Days-vs-goal list; per visible day; see-all reveals hidden days; numbers shown only when logged

### JournalCalendarView.swift:43

Earliest logged date – today range caption
Specimen(s): calendar-month.

- `app/Sources/Morsel/HistoryView.swift:196` — History calendar toggle; one per presentation
- `app/Sources/Morsel/JournalCalendarView.swift:155` — Today calendar sheet; one per presentation

### JournalCalendarView.swift:104

Day-of-month cell labels
Specimen(s): calendar-month.

- `app/Sources/Morsel/HistoryView.swift:196` — History calendar toggle; one per presentation
- `app/Sources/Morsel/JournalCalendarView.swift:155` — Today calendar sheet; one per presentation

### JournalFoodRow.swift:62

Portion quantity and unit
Specimen(s): food-rows, today-log, day-drill, food-missing.

- `app/Sources/Morsel/TodayLogViews.swift:192` — Shared food row inside MealItemRow; every item, loose or member of a menu set; TodayLogViews:141 instantiates MealItemRow
- `app/Sources/Morsel/DayDrillDown.swift:109` — Shared food row in expanded History day; every loose item or menu-set member; DayDrillDown:92 and :96 route both

### JournalFoodRow.swift:70

Protein/carbs/fat macro line; No macro data if all macros missing
Specimen(s): food-rows, today-log, day-drill, food-missing.

- `app/Sources/Morsel/TodayLogViews.swift:192` — Shared food row inside MealItemRow; every item, loose or member of a menu set; TodayLogViews:141 instantiates MealItemRow
- `app/Sources/Morsel/DayDrillDown.swift:109` — Shared food row in expanded History day; every loose item or menu-set member; DayDrillDown:92 and :96 route both

### JournalFoodRow.swift:100

Trailing calorie value
Specimen(s): food-rows, today-log, day-drill, food-missing.

- `app/Sources/Morsel/TodayLogViews.swift:192` — Shared food row inside MealItemRow; every item, loose or member of a menu set; TodayLogViews:141 instantiates MealItemRow
- `app/Sources/Morsel/DayDrillDown.swift:109` — Shared food row in expanded History day; every loose item or menu-set member; DayDrillDown:92 and :96 route both

### JournalFoodRow.swift:105

kcal unit below numeric column
Specimen(s): food-rows, today-log, day-drill, food-missing.

- `app/Sources/Morsel/TodayLogViews.swift:192` — Shared food row inside MealItemRow; every item, loose or member of a menu set; TodayLogViews:141 instantiates MealItemRow
- `app/Sources/Morsel/DayDrillDown.swift:109` — Shared food row in expanded History day; every loose item or menu-set member; DayDrillDown:92 and :96 route both

### JournalUI.swift:48

Rotated gutter folio dd.MMM.yyyy uppercased
Specimen(s): journal-folios, journal-hosts.

- `app/Sources/Morsel/Views.swift:33` — Today journal page / selected diary date; one per presentation
- `app/Sources/Morsel/GoalsEditor.swift:57` — Goals page / current date; one per presentation
- `app/Sources/Morsel/HistoryView.swift:188` — History page / today; one per presentation
- `app/Sources/Morsel/JournalCalendarView.swift:147` — Calendar sheet / selected date; one per presentation
- `app/Sources/Morsel/MealCaptureView.swift:54` — Add Meal / eaten-at date; one per presentation
- `app/Sources/Morsel/MealItemEditSheet.swift:56` — Edit item / current date; one per presentation
- `app/Sources/Morsel/MenusScreen.swift:19` — Menus / current date; one per presentation
- `app/Sources/Morsel/SettingsView.swift:66` — Settings direct page furniture / current date; one per presentation

### JournalUI.swift:233

Macro eaten / target figures, or eaten g if no target
Specimen(s): macro-columns, historical-macros.

- `app/Sources/Morsel/Views.swift:172` — Today Protein eaten / target g; one per presentation
- `app/Sources/Morsel/Views.swift:178` — Today Carbs eaten / target g; one per presentation
- `app/Sources/Morsel/Views.swift:184` — Today Fat eaten / target g; one per presentation
- `app/Sources/Morsel/DayDrillDown.swift:72` — Expanded History Protein eaten / target g; one per presentation
- `app/Sources/Morsel/DayDrillDown.swift:76` — Expanded History Carbs eaten / target g; one per presentation
- `app/Sources/Morsel/DayDrillDown.swift:80` — Expanded History Fat eaten / target g; one per presentation

### JournalUI.swift:364

Trailing detail label in section headings
Specimen(s): today-log, history-ledger, weight-chart, weight-caption-branches.

- `app/Sources/Morsel/TodayLogViews.swift:34` — <meal count> meals · <calories> kcal; one per presentation
- `app/Sources/Morsel/HistoryView.swift:248` — kcal delta · tap to open; one per presentation
- `app/Sources/Morsel/WeightTrendView.swift:35` — kg · latest weight [today] [· delta over 30 days]; one per presentation

### MealCaptureView.swift:354

Named-menu summary: item count · total kcal
Specimen(s): menu-list.

- `app/Sources/Morsel/MealCaptureView.swift:354` — Menu summary in Log from menu picker; per NamedMenu

### MealItemEditSheet.swift:147

Corrections are saved as a manual edit; macros you change stay as you typed them.
Specimen(s): meal-edit.

- `app/Sources/Morsel/Views.swift:365` — Shell-owned edit-item sheet, requested from Today food row; one per presentation

### MealItemEditSheet.swift:349

Read-only confidence percentage or em dash
Specimen(s): meal-confidence.

- `app/Sources/Morsel/MealItemEditSheet.swift:151` — Details evidence block in edit sheet; one per presentation

### MealItemEditSheet.swift:356

confidence missing / low confidence warning cue
Specimen(s): meal-confidence.

- `app/Sources/Morsel/MealItemEditSheet.swift:151` — Details evidence block in edit sheet; one per presentation

### MealPhotoEditorSection.swift:101

Camera unavailable simulator notice
Specimen(s): edit-photo.

- `app/Sources/Morsel/MealItemEditSheet.swift:159` — Edit-item photo section; one per presentation

### MealPhotoEditorSection.swift:153

Remove pending replacement photo
Specimen(s): edit-photo.

- `app/Sources/Morsel/MealItemEditSheet.swift:159` — Edit-item photo section; one per presentation

### MealPhotoEditorSection.swift:312

Illustration · not a meal photo / Category fallback · not identified food / Neutral sign · not identified food
Specimen(s): edit-photo, illustration-provenance.

- `app/Sources/Morsel/MealItemEditSheet.swift:159` — Edit-item photo section; one per presentation

### MenusScreen.swift:111

Named-menu summary: item count · total kcal
Specimen(s): menu-list.

- `app/Sources/Morsel/MenusScreen.swift:111` — Menu summary in Manage menus list; per NamedMenu

### Onboarding.swift:192

morsel wordmark repeated across onboarding steps
Specimen(s): technical-copy-brand.

- `app/Sources/Morsel/Onboarding.swift:192` — morsel wordmark repeated across onboarding steps; one per presentation

### Onboarding.swift:205

Set up later toolbar action
Specimen(s): peripheral-labels.

- `app/Sources/Morsel/Onboarding.swift:205` — Set up later toolbar action; one per presentation

### Onboarding.swift:256

agent speaker label in signIn step
Specimen(s): peripheral-labels.

- `app/Sources/Morsel/Onboarding.swift:256` — agent speaker label in signIn step; one per presentation

### Onboarding.swift:271

agent speaker label in signedIn step
Specimen(s): peripheral-labels.

- `app/Sources/Morsel/Onboarding.swift:271` — agent speaker label in signedIn step; one per presentation

### Onboarding.swift:282

agent speaker label in connect step
Specimen(s): peripheral-labels.

- `app/Sources/Morsel/Onboarding.swift:282` — agent speaker label in connect step; one per presentation

### Onboarding.swift:303

Client setup prompt with MCP URL, tool names and optional CLI command
Specimen(s): technical-claudePrompt, technical-chatPrompt.

- `app/Sources/Morsel/Onboarding.swift:303` — Claude setup prompt; one per presentation
- `app/Sources/Morsel/Onboarding.swift:303` — ChatGPT setup prompt; one per presentation
- `app/Sources/Morsel/Onboarding.swift:303` — Others setup prompt; one per presentation

### Onboarding.swift:329

Configured MCP endpoint URL
Specimen(s): technical-endpoints.

- `app/Sources/Morsel/Onboarding.swift:287` — Onboarding connect endpoint field; one per presentation

### Onboarding.swift:369

you speaker label in confirm step
Specimen(s): peripheral-labels.

- `app/Sources/Morsel/Onboarding.swift:369` — you speaker label in confirm step; one per presentation

### Onboarding.swift:377

agent speaker label in done step
Specimen(s): peripheral-labels.

- `app/Sources/Morsel/Onboarding.swift:377` — agent speaker label in done step; one per presentation

### PaperFields.swift:66

Inline field validation beneath the rule
Specimen(s): goals-validation.

- `app/Sources/Morsel/GoalsEditor.swift:233` — Goals wrapper forwards error to paper field; four instantiated goals fields

### PaperFields.swift:91

Conditional medium value font: prominent 22 pt, otherwise 17 pt
Specimen(s): goals-filled, goals-validation, shared-field-states, meal-capture, meal-edit, menu-editor, menu-new.

- `app/Sources/Morsel/GoalsEditor.swift:233` — Four goal values via generic GoalJournalField wrapper;
- `app/Sources/Morsel/MealCaptureView.swift:114` — Add Meal Quantity input;
- `app/Sources/Morsel/MealCaptureView.swift:207` — Add Meal Calories input;
- `app/Sources/Morsel/MealCaptureView.swift:212` — Add Meal Protein input;
- `app/Sources/Morsel/MealCaptureView.swift:219` — Add Meal Carbs input;
- `app/Sources/Morsel/MealCaptureView.swift:224` — Add Meal Fat input;
- `app/Sources/Morsel/MealItemEditSheet.swift:79` — Edit item Quantity input;
- `app/Sources/Morsel/MealItemEditSheet.swift:98` — Edit item Calories input;
- `app/Sources/Morsel/MealItemEditSheet.swift:109` — Edit item Protein input;
- `app/Sources/Morsel/MealItemEditSheet.swift:123` — Edit item Carbs input;
- `app/Sources/Morsel/MealItemEditSheet.swift:134` — Edit item Fat input;
- `app/Sources/Morsel/MenuEditorSheet.swift:150` — Menu editor Quantity input;
- `app/Sources/Morsel/MenuEditorSheet.swift:167` — Menu editor Calories input;

### SettingsView.swift:125

MCP endpoint is not configured.
Specimen(s): technical-endpoints.

- `app/Sources/Morsel/SettingsView.swift:125` — MCP endpoint is not configured.; one per presentation

### SettingsView.swift:136

Configured MCP endpoint URL
Specimen(s): technical-endpoints.

- `app/Sources/Morsel/SettingsView.swift:136` — Configured MCP endpoint URL; one per presentation

### SettingsView.swift:159

Replay onboarding trailing chevron
Specimen(s): not a visible text instance; see exclusions.

- `app/Sources/Morsel/SettingsView.swift:159` — Replay onboarding trailing chevron; one per presentation

### SettingsView.swift:208

Sign out trailing chevron
Specimen(s): not a visible text instance; see exclusions.

- `app/Sources/Morsel/SettingsView.swift:208` — Sign out trailing chevron; one per presentation

### TodayLogViews.swift:87

First meal time beside group title
Specimen(s): today-log.

- `app/Sources/Morsel/TodayLogViews.swift:53` — Today log meal-type group; per meal-type group; one header per group

### TodayLogViews.swift:95

Total kcal for meal-type group
Specimen(s): today-log.

- `app/Sources/Morsel/TodayLogViews.swift:53` — Today log meal-type group; per meal-type group; one header per group

### TodayLogViews.swift:115

Per-meal eaten-at time when group contains multiple meals
Specimen(s): today-log.

- `app/Sources/Morsel/TodayLogViews.swift:53` — Today log meal-type group; per meal-type group; each meal in multi-meal group

### TrainingFuelViews.swift:87

Target / addition / total kcal values and missing-state words
Specimen(s): training-receipt, training-unconfirmed.

- `app/Sources/Morsel/TrainingFuelViews.swift:74` — Usual source target kcal; one per presentation. Host: Today TrainingFuelSection
- `app/Sources/Morsel/TrainingFuelViews.swift:75` — Confirmed day-only addition +kcal / Not confirmed; one per presentation. Host: Today TrainingFuelSection
- `app/Sources/Morsel/TrainingFuelViews.swift:76` — Today's food target kcal / Unavailable; one per presentation. Host: Today TrainingFuelSection
- `app/Sources/Morsel/TrainingFuelViews.swift:74` — Usual source target kcal; one per presentation. Host: TrainingFuelEditor sheet
- `app/Sources/Morsel/TrainingFuelViews.swift:75` — Confirmed day-only addition +kcal / Not confirmed; one per presentation. Host: TrainingFuelEditor sheet
- `app/Sources/Morsel/TrainingFuelViews.swift:76` — Today's food target kcal / Unavailable; one per presentation. Host: TrainingFuelEditor sheet

### TrainingFuelViews.swift:105

Your amount: day-only food-target addition kcal
Specimen(s): training-amount.

- `app/Sources/Morsel/TrainingFuelHost.swift:27` — Session-owned fuelling editor sheet; one per presentation

### Views.swift:146

Today / selected-day eaten calorie hero
Specimen(s): today-headline.

- `app/Sources/Morsel/Views.swift:55` — Today journal hero; one per presentation

### WeightDeltaBand.swift:22

HStack font applies to Eaten − food target · kcal label AND ±deltaLimit value
Specimen(s): weight-chart.

- `app/Sources/Morsel/WeightTrendView.swift:80` — Weight food-target comparison band; one per presentation

### WeightDeltaBand.swift:58

Chart no-data/zero markers × / · / ? / ○
Specimen(s): weight-chart.

- `app/Sources/Morsel/WeightTrendView.swift:80` — Weight food-target comparison band; per day with delta nil or zero

### WeightDeltaBand.swift:76

Date/month axis labels in delta band
Specimen(s): weight-chart.

- `app/Sources/Morsel/WeightTrendView.swift:80` — Weight food-target comparison band; per timeline.axisDates tick

### WeightDeltaBand.swift:147

Selected-day weight/food target receipt trailing values
Specimen(s): weight-receipt, weight-missing.

- `app/Sources/Morsel/WeightDeltaBand.swift:126` — Weight: one-decimal kg / no weight recorded; one per presentation
- `app/Sources/Morsel/WeightDeltaBand.swift:127` — Food recorded: kcal / day status; one per presentation
- `app/Sources/Morsel/WeightDeltaBand.swift:129` — Dated baseline: kcal / unavailable; one per presentation
- `app/Sources/Morsel/WeightDeltaBand.swift:130` — Confirmed addition: +kcal / unavailable; one per presentation
- `app/Sources/Morsel/WeightDeltaBand.swift:134` — Food target: kcal / unavailable; one per presentation
- `app/Sources/Morsel/WeightDeltaBand.swift:135` — Eaten − target: signed kcal / no food log / food log unavailable / food target unavailable; one per presentation

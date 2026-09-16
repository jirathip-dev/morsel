# Every existing `.monospacedDigit()` call site

Base: `2d87d61e73c6c3db7bd1420294ccf1551232405d`. All 1381 tracked paths considered by unfiltered git-tree search.
4 identifier mentions; 4 actual Swift call sites in 4 files.
No assumed count, untracked design outputs, or working-tree-only files are used.

This is the existing modifier inventory, NOT the deferred app-wide numeric-surface inventory.

## `app/Sources/Morsel/HistoryLedgerViews.swift:213`

```swift
 207     let label: String
 208
 209     var body: some View {
 210         VStack(alignment: .leading, spacing: 0) {
 211             Text(value)
 212                 .font(.morselGauge)
 213                 .monospacedDigit()
 214                 .foregroundStyle(Color.morselInk)
 215             Text(label)
 216                 .font(.morselFootnote)
 217                 .foregroundStyle(Color.morselInkTwo)
 218         }
 219         .frame(maxWidth: .infinity, alignment: .leading)
```

## `app/Sources/Morsel/JournalFoodRow.swift:101`

```swift
  95     /// The design's 38px column wraps the 16px Garamond chevron onto its own
  96     /// line under "kcal" — reproduced literally.
  97     private var energyColumn: some View {
  98         VStack(alignment: .trailing, spacing: 0) {
  99             Text(MorselFormat.number(item.caloriesKcal))
 100                 .font(.morselMono(size: 14))
 101                 .monospacedDigit()
 102                 .foregroundStyle(Color.morselInk)
 103                 .frame(height: energyValueLine, alignment: .trailing)
 104             Text("kcal")
 105                 .font(.morselMono(size: 10))
 106                 .foregroundStyle(Color.morselInkTwo)
 107                 .frame(height: energyUnitLine, alignment: .trailing)
```

## `app/Sources/Morsel/MealItemEditSheet.swift:350`

```swift
 344             HStack(alignment: .firstTextBaseline, spacing: 4) {
 345                 Text("Source: \(item.provenance.rawValue) · Confidence:")
 346                     .font(.morselSerif(size: 16))
 347                     .foregroundStyle(Color.morselInk)
 348                 Text(MorselFormat.confidence(item.confidence))
 349                     .font(.morselMono(size: 12))
 350                     .monospacedDigit()
 351                     .foregroundStyle(Color.morselInk)
 352                 Spacer(minLength: 0)
 353             }
 354             if let confidenceNote {
 355                 Text(confidenceNote)
 356                     .font(.morselData)
```

## `app/Sources/Morsel/Views.swift:148`

```swift
 142                     Text("Eaten · Goal")
 143                         .morselSectionLabel()
 144                     HStack(alignment: .firstTextBaseline, spacing: 6) {
 145                         Text(MorselFormat.number(viewModel.totals.caloriesKcal))
 146                             .font(.morselHero)
 147                             .foregroundStyle(Color.morselInk)
 148                             .monospacedDigit()
 149                         if let target {
 150                             Text("/ \(MorselFormat.number(target)) kcal")
 151                                 .font(.morselBody)
 152                                 .foregroundStyle(Color.morselInkTwo)
 153                         }
 154                     }
```

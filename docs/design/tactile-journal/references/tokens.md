# Token map — approved V1 field-journal roles (issue #90 → #94)

Single native token authority: `app/Sources/Morsel/DesignSystem.swift`.
Normative doc: `docs/DESIGN.md`. This map is the promoted design contract the
#94 lane implements; values are resolved from the approved palette ("Orange
Hearth + Sage", issue #32) plus the single new line token `INK_LINE`.

## Scalar palette (unchanged, locked B1)

| token | hex |
| --- | --- |
| ink | #2A261F |
| ink2 | #655A4B |
| ink3 | #756955 |
| bg | #FFF7E8 |
| surface | #FFFCF5 |
| surface2 | #F2E9D9 |
| line | #E3D2BA |
| accent | #E66A2C |
| accentSoft | #FBE1C9 |
| leaf | #5E7E57 |
| leafSoft | #E1E9D7 |
| forest | #2F654B |
| coral | #B94738 |
| mustard | #D6A62C |
| mustardDeep | #A5750B |
| review | #7A3D2B |
| over | #9C3A2F |
| **inkline** (new) | **#8B7355** warm sepia — hand rules, contours, goal ticks; never body text |

Treatments (never new hues): paper grain at opacity 0.05 (Paper) / 0.06
(Night); wash fills = palette pigments at reduced alpha (base 0.92 paper /
1.00 night) over the theme ground. Wash pigment bases on Paper: today
#E8753B, excess #A4493E, protein #BF5546, carbs #AC7F1D, fat #6B8863; Night
resolves the soft family roles (today/excess keep their pigments at full
strength on charcoal). The ink label on the accent identity surface stays the
warm dark ink (#2A261F) in both themes (cream on orange drops to ~3.05:1).

## Theme role resolution

Night roles resolve palette tokens over the ink ground (#2A261F) — see the
role table; exact resolved hexes below are what DesignSystem.swift ships as
the dark variant of each native token.

| role | Paper | Night ink (resolved) |
| --- | --- | --- |
| page bg | #FFF7E8 | #2A261F |
| surface | #FFFCF5 | #373129 (ink2 @ 0.22 over ink) |
| surface2 (fields/tracks) | #F2E9D9 | #423B31 (ink2 @ 0.40 over ink) |
| primary copy | #2A261F | #FFF7E8 |
| secondary copy | #655A4B | #F2E9D9 |
| metadata/captions | #756955 | #E3D2BA |
| hairline | #E3D2BA | #756955 |
| inkline (hand rules) | #8B7355 | #9D917F (line @ 0.62 over ink) |
| accent + ink label | #E66A2C + #2A261F | unchanged |
| active/positive text | #2F654B | #E1E9D7 |
| review text / wash | #7A3D2B / #FBE1C9 | #FBE1C9 / #7A3D2B |
| over word | #9C3A2F | #FFF7E8 (hatch carries the over mark) |
| History & fat wash | #5E7E57 | #E1E9D7 |
| provisional Today | leaf ghosted | leafSoft ghosted |
| over-excess wash | #9C3A2F + ink hatch | #9C3A2F + cream hatch |
| near-goal ring | #A5750B | #A5750B |
| Protein / Carbs / Fat wash | coral / mustardDeep / leaf | accentSoft / mustard / leafSoft |
| weight line | forest | leafSoft |

Wash fills on paper render the pigment at ~0.92 alpha with an inkline contour
and a pooled edge (the "wash" treatment); night washes are full-strength soft
pigments on charcoal. Strict text floors: ≥4.5:1; marks/contours ≥3:1 —
measured worst-case-over-grain in the design-output `contrast.md` (Paper
minimum strict pair 4.52:1 text / 3.03:1 mark; Night 4.63:1 text / 3.08:1
mark).

## Fonts (OFL, bundled by the #94 lane)

| role | family |
| --- | --- |
| hand headings / annotations / tab words | Caveat |
| body + labels (serif) | EB Garamond |
| italic captions | EB Garamond Italic |
| every visible figure (tabular) | IBM Plex Mono (Regular/Medium) |

## Locked semantics (C4 — never regressed)

Every displayed delta is **eaten minus goal** (signed: under / on target /
over). Activity/active energy is context only ("moved 386 kcal today") and is
**never subtracted** from eaten calories to form a displayed net intake.

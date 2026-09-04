# plugins/morsel/assets — provenance

Privacy-safe, reproducible assets from the issue #86 preparation only. No real
user data, no private-repo URLs, no credentials.

| File | Provenance | Reproducible from |
| --- | --- | --- |
| `icon.png` | Byte copy of the committed #86-prepped marketing icon `app/Assets.xcassets/AppIcon.appiconset/Icon-1024.png` (1024×1024 opaque PNG) | `python3 scripts/render-icon.py` over the pinned master `app/IconSource/v1-wrapped-classic.svg` (see `docs/ICON.md`; renderer validation: `python3 scripts/render-icon.py --check`) |

SHA-256 pins at issue #95 packaging time:

- `icon.png` = `1958099d8237633d8666e65c77a9dee524bde7f34e3bde06b45df3f557cbbd18`
  (identical to the committed `Icon-1024.png` — `cmp` verified)
- icon master `v1-wrapped-classic.svg` = `2cd6c86c5c77cbba33b5aeefa1a7751d9d9b7cd2d696c36625db4241fda653b4`
  (per `docs/ICON.md`)

No other assets are bundled: OpenAI publishes no logo spec beyond the square
PNG decision already recorded in `docs/CHATGPT_APPS_SUBMISSION.md`, and
screenshots are deliberately absent (they would require real user data).

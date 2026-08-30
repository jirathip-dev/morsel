# Morsel AppIcon provenance

The AppIcon is the approved V1 Wrapped classic smiling onigiri from
`jirathip-dev/design-output`, commit `7de30e9`.

- Master: `app/IconSource/v1-wrapped-classic.svg`
- Master SHA-256: `2cd6c86c5c77cbba33b5aeefa1a7751d9d9b7cd2d696c36625db4241fda653b4`
- Renderer: `python3 scripts/render-icon.py`
- Validation: `python3 scripts/render-icon.py --check`

The renderer uses the pinned master and `rsvg-convert` to generate the twelve
opaque iPhone AppIcon PNGs plus the 1024px marketing icon. `Contents.json`
assigns the generated files to the `AppIcon` set; `app/project.yml` enables
that set for the `com.jirathip.morsel` target.

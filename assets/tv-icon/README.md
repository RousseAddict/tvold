# TV App Icon — old-iOS scaffold

Source glyph: Phosphor **`television-simple`** (bold weight), the icon Phosphor's
site aliases as "tv-simple" in search. MIT-licensed, recolored white on a
navy background.

## Files

- **`icon-master.svg`** — edit this. Change `#2B3A67`/`#1B2545` (background
  gradient) or `#F5F7FA` (glyph color) to restyle, then re-run the two
  Python snippets below to regenerate every raster size from the one source.
- **`AppIcon.appiconset/`** — a ready-to-drop-in Xcode asset catalog
  (`.xcassets/AppIcon.appiconset`), sizes covering iPhone/iPad from iOS 7
  through current, plus the 1024 App Store marketing icon.
- **`legacy-loose-icons/`** — loose `Icon-*.png` files + an `Info.plist`
  snippet, for projects still targeting **iOS 5/6** before Xcode's asset
  catalog existed (`CFBundleIconFiles` wiring, no `.xcassets`).

## One design decision to make: gloss or flat?

Pre-iOS 7, the OS auto-applies a glass "shine" overlay to app icons **unless**
`UIPrerenderedIcon` is set to `true` in Info.plist. The master SVG here is
drawn flat/flat-styled on purpose (no baked-in shine, no baked-in rounded
corners — iOS masks corners itself on every version). I set
`UIPrerenderedIcon = true` in the Info.plist snippet so what you see in the
preview is exactly what renders. Flip it off if you'd rather have the
classic glossy iOS 5/6 look.

## Regenerating after edits

```bash
pip install cairosvg --break-system-packages

python3 -c "
import cairosvg
cairosvg.svg2png(url='icon-master.svg', write_to='preview.png',
                  output_width=512, output_height=512)
"
```

Re-run the appiconset/legacy-loose-icons generation scripts (same pattern:
`cairosvg.svg2png(url='icon-master.svg', write_to=..., output_width=N,
output_height=N)`) for each size after any master-SVG edit.

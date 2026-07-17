# acPNG / AlphaControls PNG registration fix — separate WIP

Status: **not implemented / disabled in the build.** Enable with `{$DEFINE INCLUDE_ACPNGFIX}`
in `Code/DDevExtensions/Source/DelphiExtension.inc` (D2009+ only). Until then the old
`FixAlphaControlsPNG` unit compiles to an empty unit and is not wired in.

## Background / the problem
- **Delphi 7 has no native `pngimage`.** AlphaControls silently ships its own **acPNG** to
  compensate.
- acPNG does **not** store real PNG data in the DFM — it stores a **BMP with a wrong header**.
- The **class name** acPNG registers in the DFM does **not** match the one used by native
  `pngimage` (Delphi 2009+). So a DFM written by one can't be read correctly by the other.
- A fix already exists **inside `pngimage` itself** (a custom D7 build) that corrects the
  old→new format when loading (old acPNG BMP-with-wrong-header → proper PNG / class name).

## What DDevExtensions should add (the helper)
A helper that inspects the **IDE's graphic file-format registration** at runtime and reconciles
AlphaControls' acPNG with native `pngimage`:

1. Detect whether **both** AlphaControls (acPNG) **and** `pngimage` are present and loaded.
2. `TPicture`/`TPicture.RegisterFileFormat` keeps an ordered list and **the first match wins**
   (by extension / graphic class). If **acPNG is registered first**, Delphi would pick acPNG
   instead of `pngimage`.
3. So, when acPNG is loaded first, the helper must **remove acPNG's registration from the list**
   (or **move it below `pngimage`**), so that `pngimage` is chosen for PNG.

Effectively: ensure `pngimage` wins the format lookup over AlphaControls' acPNG.

## Where the old attempt lives
- `Code/DDevExtensions/Source/FormDesignerHelpers/FixAlphaControlsPNG.pas`
  — the old approach: subclasses `TPngImage`/`TBitmap` as `TPNGGraphic` and calls
  `TPicture.RegisterFileFormat('', 'Portable network graphics (AlphaControls)', TPNGGraphic)`.
  This is the incomplete WIP to be replaced by the list-reconciliation helper above.
- `Code/DDevExtensions/Source/FormDesignerHelpers/__Check for Alpha installed, uTLH.FileFormatsList/uTLH.FileFormatsList.pas`
  — `TFileFormatsListHack` (a `TList`-based view of VCL's private `TFileFormatsList`) to
  add/remove/reorder registered formats by class name / extension / description. This is the
  building block for manipulating the registration list. Currently referenced nowhere.

## Notes
- This is a **D2009+ concern** (where native `pngimage` exists alongside acPNG). On D7 there is
  no native `pngimage`; the D7 side is handled by the custom `pngimage` build's load-time fix.
- Re-enabling: define `INCLUDE_ACPNGFIX`, then finish `FixAlphaControlsPNG` to use the
  `TFileFormatsListHack` reconciliation instead of just registering another format.

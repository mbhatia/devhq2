# Bundled fonts

## Terminal defaults

The terminal bundles the same default font family as native Ghostty, separate
from the editor's configurable Martian Mono font:

- `JetBrainsMono-{Regular,Bold,Italic,BoldItalic}.ttf`: JetBrains Mono 2.304.
- `SymbolsNerdFont-Regular.ttf`: Nerd Fonts Symbols Only 3.4.0, used for PUA
  symbols missing from the configured terminal font.

Licenses are included as `JetBrainsMono-OFL.txt` and `NerdFonts-LICENSE.txt`.
These assets were copied from Ghostty's dependencies at `Vendor/ghostty`
commit `41ab6c5ab650465dd65c9957ae0a95225e2c1048`; they match the font archives
and dependency hashes pinned by revision `3c47ca159368eb4a860ffe5333abdf4a85b2767b`.

## Editor font

The editor continues to use the standard-width, monospaced Martian Mono Nerd
Font faces from Nerd Fonts v3.5.1:

- `MartianMonoNerdFontMono-Regular.ttf`
- `MartianMonoNerdFontMono-Medium.ttf`
- `MartianMonoNerdFontMono-Bold.ttf`

The archive contains no italic faces; the application synthesizes oblique
styles when needed. The included license is `MartianMono-LICENSE.txt` (SIL Open
Font License 1.1).

Source: <https://github.com/ryanoasis/nerd-fonts/releases/download/v3.5.1/MartianMono.zip>
SHA-256: `bf873eaa04794d003961bfc0a1629d93207a5cb7abb5d7486e28ed6f316c5afe`

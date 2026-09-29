# DevHQ icon

Three parallel source-code branches share a common stem. The symbol is independent of any version control system. Mint (`#ABF4DC`) sits over an automatic indigo gradient based on `#2C3167`.

- `DevHQ.icon`: editable Icon Composer document, including the outlined vector artwork and native Liquid Glass settings.
- `Branches.svg`: standalone copy of the foreground vector.
- `DevHQ.png`: 1024-pixel default appearance exported with Icon Composer's bundled `ictool`.
- `../DevHQ.icns`: macOS compatibility export compiled with Apple's `actool` (minimum deployment target 13.0).

The document was previewed in default, dark, and mono appearances. Highlights, translucency, shadows, and the outer mask are supplied by Icon Composer, not baked into the SVG.

`build_installer.sh` compiles the `.icon` document with Apple's `actool`, packages both `Assets.car` and the generated `DevHQ.icns`, and sets `CFBundleIconName` to `DevHQ`. The layered source preserves native appearance variants and dynamic effects on supported macOS versions, with a compatibility icon for older versions. Packaging requires Xcode 26 or later. The checked-in `assets/DevHQ.icns` is a convenience export; the Icon Composer document is the packaging source of truth.

Guidance: [Apple app icons](https://developer.apple.com/design/human-interface-guidelines/app-icons) and [Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer).

CI uses macOS 26 and Xcode 26.6 for icon compilation. Xcode 26.3's asset runtime crashed on the macOS 15 runner while compiling the layered icon; the app's minimum deployment target remains macOS 13.

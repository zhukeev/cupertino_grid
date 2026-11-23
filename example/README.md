# cupertino_grid example

A 400-item demo grid over generated placeholder tiles — pinch with two
fingers to morph between 1, 3, 5 and 16 columns, iOS-Photos style. Uses
`reverse: true` (bottom-anchored) and a `sectionLabelFor` pill every 40
items, the same knobs a photo gallery uses.

## Run

```sh
flutter pub get
flutter run          # any iOS/Android device or simulator
```

The demo is intentionally not a workspace member — `flutter pub get` inside
this directory resolves it standalone against the parent package via
`path: ../`.

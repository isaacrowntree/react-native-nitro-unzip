# Contributing

Contributions are welcome! Please open an issue first to discuss what you would like to change.

## Development workflow

The library lives at the repo root and [`example/`](./example) is the app that
exercises it. They install **separately, on purpose**: as an npm workspace the
library's babel/jest devDependencies hoist into the app and shadow the versions
Expo's Metro expects, which breaks bundling with `Failed to collapse` errors.
npm has no `nohoist`, so the two trees stay independent.

Node 24 (see `.nvmrc`) and Java 17 are expected.

1. Fork and clone the repo
2. Install dependencies — both trees:

```bash
npm install
npm install --prefix example
```

3. Run the JS checks:

```bash
npm run typescript   # tsc --noEmit
npm run lint         # eslint (flat config, eslint.config.mjs)
npm run format       # prettier --write
npm test             # jest
```

4. Verify what actually gets published:

```bash
npm run prepare        # bob build
npm run check-exports  # validates the exports map for CJS/ESM/bundler consumers
```

### Native tests

The Swift core builds standalone via SPM — no CocoaPods or Xcode project needed:

```bash
swift test
```

The Android tests need a real Gradle project, because the library depends on
`project(":react-native-nitro-modules")`. Generate one from the example app,
then run the library's test task:

```bash
npm run prebuild:example
npm run test:android
```

CI runs all three (JS, Android, iOS) on every pull request.

### End-to-end tests (Maestro)

The JS unit tests mock the Nitro module, and the Kotlin/Swift tests cover each
native half in isolation — so the [`.maestro/`](./.maestro) flows are the only
layer that proves the whole chain works on a real device.

```bash
brew install maestro          # or: curl -Ls https://get.maestro.mobile.dev | bash

npm --prefix example run android   # or run ios — leave Metro running
npm run e2e                        # all flows against the connected device
maestro test .maestro/password.yaml
```

With both an emulator and a simulator connected, target one explicitly:

```bash
maestro --device emulator-5554 test .maestro
```

`password.yaml` asserts the exact extracted-file count on purpose — it is the
regression guard for a zero-based-index bug in SSZipArchive's unzip progress
handler that under-reported `extractedFiles` and suppressed progress callbacks
on iOS. CI runs these on demand via the **E2E (Maestro)** workflow.

### Example app

The [example app](./example) demonstrates all features. To run it:

```bash
npm --prefix example run ios      # or: run android
```

### Regenerating bindings

After changing the Nitro spec in `src/specs/Unzip.nitro.ts`, regenerate the native bindings:

```bash
npx nitrogen
```

## Commit convention

This project follows [Conventional Commits](https://www.conventionalcommits.org/). Please use the following prefixes:

- `feat:` — new feature
- `fix:` — bug fix
- `chore:` — maintenance
- `docs:` — documentation
- `test:` — tests
- `refactor:` — refactoring

## Sending a pull request

1. Create a new branch from `main`
2. Make your changes
3. Ensure `npm run typescript`, `npm run lint`, and `npm test` all pass
4. Open a pull request

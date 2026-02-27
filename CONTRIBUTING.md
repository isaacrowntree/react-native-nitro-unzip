# Contributing

Contributions are welcome! Please open an issue first to discuss what you would like to change.

## Development workflow

1. Fork and clone the repo
2. Install dependencies:

```bash
npm install
```

3. Run the type checker:

```bash
npm run typescript
```

4. Run the linter:

```bash
npm run lint
```

5. Run the tests:

```bash
npm test
```

### Example app

The [example app](./example) demonstrates all features. To run it:

```bash
cd example
npm install
npx expo run:ios   # or run:android
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

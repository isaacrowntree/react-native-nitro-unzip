import js from '@eslint/js';
import tseslint from 'typescript-eslint';
import prettierRecommended from 'eslint-plugin-prettier/recommended';

export default tseslint.config(
  {
    // Build output, native scaffolding and generated Nitro bindings are
    // never linted — nitrogen owns everything under nitrogen/generated.
    ignores: [
      'lib/**',
      'nitrogen/generated/**',
      'example/**',
      'docs/**',
      'android/**',
      'ios/**',
      'coverage/**',
    ],
  },
  js.configs.recommended,
  ...tseslint.configs.recommended,
  {
    files: ['**/*.{ts,tsx}'],
    languageOptions: {
      parserOptions: {
        projectService: true,
        tsconfigRootDir: import.meta.dirname,
      },
    },
    rules: {
      '@typescript-eslint/consistent-type-imports': [
        'error',
        { prefer: 'type-imports', fixStyle: 'inline-type-imports' },
      ],
      '@typescript-eslint/no-unused-vars': [
        'error',
        { argsIgnorePattern: '^_', varsIgnorePattern: '^_' },
      ],
    },
  },
  {
    // Tests run on Node under Jest, not in the RN runtime.
    files: ['**/__tests__/**/*.{ts,tsx}'],
    rules: {
      '@typescript-eslint/no-explicit-any': 'off',
    },
  },
  // Must stay last: turns off every stylistic rule that would fight
  // Prettier, then reports remaining formatting drift as lint errors.
  prettierRecommended,
);

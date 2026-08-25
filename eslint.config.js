import js from '@eslint/js'
import globals from 'globals'
import tseslint from 'typescript-eslint'
import { defineConfig, globalIgnores } from 'eslint/config'

export default defineConfig([
  // app/ is SwiftUI (SwiftLint's turf); **/.build is SwiftPM output.
  globalIgnores(['dist', '**/.build', 'app']),
  {
    files: ['**/*.{js,ts}'],
    extends: [js.configs.recommended, tseslint.configs.recommended],
    languageOptions: {
      // Bun is node-compatible for lint purposes.
      globals: globals.node,
    },
    rules: {
      // ANTI-SLOP (full strength — repo predates its first feature code).
      // Bans ALL `as T` (including `as unknown as T`): validate at runtime
      // seams (schema/guards) instead of asserting types into existence.
      '@typescript-eslint/consistent-type-assertions': [
        'error',
        { assertionStyle: 'never' },
      ],
      '@typescript-eslint/no-explicit-any': 'error',
      '@typescript-eslint/no-non-null-assertion': 'error',
    },
  },
  // server/ gets typed lint (no-unsafe-* suite) once it has sources; the
  // projectService resolves the root tsconfig, which includes server/.
  {
    files: ['server/**/*.ts'],
    extends: [tseslint.configs.strictTypeChecked],
    languageOptions: {
      parserOptions: {
        projectService: true,
        tsconfigRootDir: import.meta.dirname,
      },
    },
  },
])

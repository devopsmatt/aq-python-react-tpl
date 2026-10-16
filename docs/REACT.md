# React and TypeScript Standards

Scope: React components, hooks and client-side TypeScript in the web
application under `web/`. Framework concerns (routing, server components,
headers, builds, containers) are in [NEXTJS.md](NEXTJS.md).

Related: [SECURITY.md](SECURITY.md), [CICD.md](CICD.md),
[PYTHON.md](PYTHON.md) (the OpenAPI contract the client is generated from).

The key words MUST, MUST NOT, SHOULD, SHOULD NOT and MAY are used as described
in RFC 2119.

---

## 1. TypeScript

`web/tsconfig.json` compiler options, in addition to the Next.js defaults:

```json
{
  "compilerOptions": {
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "exactOptionalPropertyTypes": true,
    "noImplicitOverride": true,
    "noImplicitReturns": true,
    "noFallthroughCasesInSwitch": true,
    "useUnknownInCatchVariables": true,
    "forceConsistentCasingInFileNames": true
  }
}
```

Rules:

- `any` is banned (`@typescript-eslint/no-explicit-any: error`). Values of
  unknown shape are typed `unknown` and narrowed.
- `@ts-ignore` is banned. `@ts-expect-error` is allowed with a reason, so it
  fails loudly once the underlying error is fixed.
- Non-null assertions (`!`) need a comment explaining why the value cannot be
  null.
- API types are generated from the committed `python/api/openapi.json` with
  `openapi-typescript` into `web/src/api/schema.d.ts`. They are never
  hand-written. CI regenerates them and fails on drift, just as the backend
  spec is checked.
- Data crossing a trust boundary (API responses, URL and search params, form
  data, `localStorage`) is validated at runtime with `zod` before use. The
  static type describes what the code expects; the runtime check proves it.
- Type check: `npx tsc --noEmit` (from `web/`).

---

## 2. Component standards

- Function components with typed props. Class components are not used.
- Server Components are the default. `"use client"` goes on the smallest leaf
  that needs interactivity, state or browser APIs ([NEXTJS.md](NEXTJS.md)).
- Hooks follow the rules of hooks (`eslint-plugin-react-hooks`, errors not
  warnings).
- Components do not fetch in `useEffect` when a Server Component or a server
  action can load the data.
- The component library SHOULD be the U.S. Web Design System (USWDS) through
  its React bindings. It was built for federal accessibility and usability
  requirements, which shortens the 508 work in section 4. Any custom
  component meets section 4 on its own.

---

## 3. Client-side security

- `dangerouslySetInnerHTML` is banned (`react/no-danger: error`). The one
  exception is a single reviewed `SanitizedHtml` component that runs
  DOMPurify with a strict allowlist. Every use of that component is reviewed.
- User-supplied URLs are validated to `https:` (or relative) before they reach
  `href` or `src`. `javascript:` and `data:` URLs are rejected.
- Links that open a new tab use `rel="noopener noreferrer"`
  (`react/jsx-no-target-blank`).
- Tokens, API keys and secrets never reach the browser bundle. Auth state
  lives in `httpOnly`, `Secure`, `SameSite=Lax` (or `Strict`) cookies managed
  by the server ([NEXTJS.md](NEXTJS.md)). Access tokens are never stored in
  `localStorage` or `sessionStorage`, where any XSS can read them.
- `localStorage` holds only non-sensitive UI preferences.
- Nothing security-relevant is enforced only in the client. Hiding a button is
  UX; the server enforces the permission.
- No `eval`, `new Function`, or string arguments to `setTimeout`. This also
  keeps the CSP free of `unsafe-eval`.

---

## 4. Accessibility: Section 508 and WCAG 2.1 AA

The Revised Section 508 Standards incorporate WCAG 2.0 Level AA by reference.
This project targets WCAG 2.1 Level AA, which is a superset. Every UI change
MUST meet it before merge. Accessibility defects are functional defects, and
a failing accessibility check blocks merge like a failing unit test.

### 4.1 Build requirements

| Area | Requirement | WCAG 2.1 |
|---|---|---|
| Semantics | Native HTML elements first (`button`, `a`, `nav`, `main`, `label`, `table`). ARIA only when no native element fits, and never to relabel what HTML already conveys. | 1.3.1, 4.1.2 |
| Text alternatives | Informative images have meaningful `alt`. Decorative images use `alt=""`. Icon-only buttons have an accessible name. | 1.1.1 |
| Keyboard | Everything operable by mouse is operable by keyboard. No keyboard traps. Focus order follows reading order. | 2.1.1, 2.1.2, 2.4.3 |
| Focus visibility | Focus indicator always visible, with 3:1 contrast against adjacent colors. Never `outline: none` without a replacement. | 2.4.7, 1.4.11 |
| Skip link | A "Skip to main content" link is the first focusable element. | 2.4.1 |
| Focus management | On client-side route change, focus moves to the new page's `h1` or main region. Dialogs move focus inside on open, trap it while open, and return it to the trigger on close. | 2.4.3 |
| Page titles | Each route sets a unique, descriptive `<title>`. | 2.4.2 |
| Language | `<html lang="en">`. Passages in another language carry `lang`. | 3.1.1, 3.1.2 |
| Headings | One `h1` per page and no skipped levels. Headings describe the sections under them. | 1.3.1, 2.4.6 |
| Color contrast | Text 4.5:1. Large text (18pt, or 14pt bold) 3:1. UI components and graphics 3:1. | 1.4.3, 1.4.11 |
| Color alone | Status, errors and chart series are never distinguished by color alone. | 1.4.1 |
| Forms | Every input has a programmatic `<label>`. Required fields are marked in text. Errors are identified in text, linked with `aria-describedby`, flagged with `aria-invalid`, and summarized at the top on submit, with focus moved to the summary. | 1.3.1, 3.3.1, 3.3.2, 3.3.3 |
| Input purpose | Personal-data fields use the right `autocomplete` token. | 1.3.5 |
| Reflow and zoom | Usable at 320 CSS px wide with no two-dimensional scrolling, and at 200% text size with no loss of content. | 1.4.4, 1.4.10 |
| Text spacing | Layout survives user-increased line, paragraph, letter and word spacing. | 1.4.12 |
| Hover and focus content | Tooltips and popovers can be dismissed (Esc), hovered, and persist until dismissed. | 1.4.13 |
| Status messages | Toasts, "saved" notices and async results use a live region (`role="status"` or `role="alert"`) without stealing focus. | 4.1.3 |
| Timeouts | Before the 15-minute inactivity lock (AC-11), users get an accessible warning and can extend with a single action. | 2.2.1 |
| Motion | Nothing flashes more than 3 times per second. Auto-moving content can be paused. Animations respect `prefers-reduced-motion`. | 2.3.1, 2.2.2 |
| Orientation | No lock to portrait or landscape. | 1.3.4 |
| Tables | Data tables use `<th scope>` and a `<caption>`. Layout never uses tables. | 1.3.1 |
| Charts | Every chart has an equivalent data table or text summary. | 1.1.1 |
| Documents | Generated PDFs and other documents meet 508 as well (tagged PDF, reading order, alt text). | 508 E205.4 |

### 4.2 Testing accessibility

Automated tools catch only part of WCAG. All four layers are required:

1. **Lint:** `eslint-plugin-jsx-a11y` in `strict` mode, errors block commit.
2. **Unit:** every component test runs axe through `vitest-axe` and asserts no
   violations. Tests query with `getByRole` and `getByLabelText`; if a test
   cannot find an element by role and name, neither can a screen reader user.
3. **End-to-end:** Playwright runs `@axe-core/playwright` on every route,
   covering WCAG 2.0 and 2.1 A and AA tags, in each significant state (empty,
   loaded, error, dialog open).
4. **Manual, per release:** a keyboard-only pass, a screen reader pass (NVDA
   with Firefox or Chrome, JAWS, VoiceOver with Safari), 200% zoom, and 320 px
   reflow, following the DHS Section 508 Trusted Tester process. Results feed
   the Accessibility Conformance Report (VPAT, Section 508 edition) published
   with each release.

---

## 5. Unit and component testing (Vitest)

Stack: Vitest, React Testing Library, `@testing-library/user-event`, jsdom,
`vitest-axe`, coverage through `@vitest/coverage-v8`.

`web/vitest.config.mts`:

```ts
import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  test: {
    environment: "jsdom",
    setupFiles: ["./vitest.setup.ts"],
    include: ["src/**/*.test.{ts,tsx}"],
    coverage: {
      provider: "v8",
      reporter: ["text", "lcov"],
      include: ["src/**/*.{ts,tsx}"],
      exclude: ["src/**/*.test.{ts,tsx}", "src/api/schema.d.ts"],
      thresholds: { lines: 80, branches: 80, functions: 80, statements: 80 },
    },
  },
});
```

Rules:

- Tests exercise behavior the way a user does (`user-event` clicks and typing,
  role-based queries). They do not assert on implementation details or
  snapshot entire trees.
- Every component test includes an axe assertion.
- Network calls are mocked at the network layer (MSW) using fixtures typed
  from the generated API schema, so a contract change breaks the mock at
  compile time.
- The 80% threshold applies to lines, branches, functions and statements.
  Combined with Playwright e2e coverage it forms the frontend's share of the
  project-wide 80% requirement. Changed lines are held to 80% as well.

Commands (from `web/`):

```bash
npx vitest run                                    # whole suite once
npx vitest run --coverage                         # with coverage thresholds
npx vitest run src/components/Button.test.tsx     # one file
npx vitest run -t "shows an error summary"        # tests matching a name
npx vitest                                        # watch mode
```

---

## 6. Lint and format

ESLint flat config (`web/eslint.config.mjs`) composes:
`typescript-eslint` `strictTypeChecked` and `stylisticTypeChecked`,
`eslint-plugin-react`, `eslint-plugin-react-hooks`, `eslint-plugin-jsx-a11y`
(strict), and `eslint-config-next`. Prettier owns formatting, and
`eslint-config-prettier` turns off the rules that conflict with it.

```bash
npx eslint . --max-warnings=0
npx prettier --check .
npx tsc --noEmit
```

Warnings count as errors (`--max-warnings=0`). An inline disable needs the
rule name and a reason: `// eslint-disable-next-line <rule> -- <reason>`.

---

## 7. Frontend security battery

Runs in the hooks and in CI ([SECURITY.md](SECURITY.md)). The severity floor is
MEDIUM.

| Tool | Command (from repo root) | Blocks on |
|---|---|---|
| semgrep | `semgrep scan --config p/typescript --config p/javascript --config p/react --config p/nodejsscan --config p/owasp-top-ten --severity WARNING --severity ERROR --error web/` | any finding |
| bearer | `bearer scan web/ --severity critical,high,medium` | any finding |
| njsscan | `njsscan -w web/` | any warning or error |
| retire | `retire --path web --severity medium` | medium and above |
| npm audit | `npm audit --audit-level=moderate` (from `web/`) | moderate and above |
| osv-scanner | `osv-scanner scan source -L web/package-lock.json` | any known vulnerability |

Tool notes:

- **bearer, measured (2.0.1, 2026-09-23):** `--severity` is a list of the
  severities to include, not a floor. On a probe file with one critical and
  three medium findings, `--severity medium` reported only the three medium
  and dropped the critical. The floor MUST be written as
  `critical,high,medium`.
- **njsscan, measured:** there is no `--severity` flag. `-w` (exit non-zero on
  warnings) is how it blocks at the medium-equivalent level.
- **semgrep, measured (1.157.0):** `p/typescript`, `p/javascript`, `p/react`,
  `p/nodejsscan` and `p/owasp-top-ten` load and run with `--metrics off`.
  There is no working `p/nextjs` pack; it returned a config error.
- **npm audit:** npm's scale is low, moderate, high, critical. "Moderate" is
  the MEDIUM floor.

---

## 8. Dependencies and supply chain

- npm is the package manager. `package-lock.json` is committed and CI installs
  with `npm ci`.
- `web/.npmrc` sets `ignore-scripts=true`. Packages that truly need an
  install script are reviewed and rebuilt explicitly with
  `npm rebuild <pkg>`. Install scripts are the main way compromised npm
  packages have spread.
- Renovate applies a minimum release age (a few days) before it proposes a new
  version, so a malicious release is usually caught and unpublished before it
  reaches a PR.
- No runtime loading of scripts, styles or fonts from third-party CDNs
  ([NEXTJS.md](NEXTJS.md) section 5).

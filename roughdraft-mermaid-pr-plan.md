# PR Plan — Mermaid diagram support for Roughdraft
## Verification result
Roughdraft does **not** support Mermaid today. There is zero mention of "mermaid" anywhere in the published package, and it is not a dependency. Fenced ` ```mermaid ` blocks currently render as a syntax-highlighted code block (the renderer has highlight/`CodeBlock`/`language-` handling, but no diagram pass). No existing issue or PR proposes it. So this is a genuine, unclaimed feature.
## Repo facts (target of the PR)
- **Repo:** `github.com/Lex-Inc/roughdraft` — MIT, default branch `main`, active (last push 2026-05-24), not archived. By Nathan Baschez / Lex Inc.
  
- **Layout:** pnpm monorepo — `packages/{app, rfm, server, skill}`. Tooling: Vite, React 19, Tailwind v4, Biome (lint/format), Vitest, Knip. CI: `.github/workflows/ci.yml`.
  
- **No** `CONTRIBUTING.md`, but `AGENTS.md` encodes a strong test culture: Kent Beck's Test Desiderata, a "Prove It" workflow (reproduce with a failing test first), and realistic boundary verification before handoff.
  
- **Renderer (**`packages/app/src/markdown.ts`**):** `marked` v15 for MD→HTML and `turndown` for HTML→MD, inside a TipTap (ProseMirror) rich-text editor. It already has a **raw-block protection mechanism** (`data-markdown-raw-block`) to keep certain blocks atomic and round-trip-safe — the precedent a Mermaid node should follow.
  
## The core constraint: round-trip safety
Roughdraft isn't a one-way viewer — it round-trips Markdown ↔ rich text and saves edits back. So Mermaid support must satisfy two things at once:

1. **Render** the diagram (SVG) in the displayed document.
  
2. **Preserve the source**: the ` ```mermaid ` fence must survive the HTML→Markdown save unchanged, and must not be corrupted by being edited as rich text.
  

The existing `data-markdown-raw-block` pattern is exactly how they solve (2) for `<details>`, comments, and indented code. A Mermaid block should be an **atomic protected node** that carries its raw source and renders a diagram.
## Implementation approach
1. **Parse:** in `markdown.ts`, detect fenced code with `lang === "mermaid"` and emit a protected mermaid node (carrying the raw source, à la `createRawMarkdownBlock`) instead of `<pre><code>`.
  
2. **Render:** a React component that **lazy-imports** `mermaid` (dynamic `import()`), calls `mermaid.render()` → SVG, with `securityLevel: "strict"`. Async render with the raw code as fallback while loading and on parse error (never crash the doc). Theme follows Roughdraft's light/dark mode.
  
3. **Editor node:** a custom **atomic/leaf TipTap node** that stores the source and renders the diagram, non-editable, so commenting still works but the source is preserved. {==Render diagrams inline in the TipTap editor vs in a separate preview pane.==}{>>Biggest open design question. I haven't fully traced how the rendered doc is displayed (editor view vs preview), which determines complexity. I'd read App/editor setup (or ask the maintainers) before writing code. Which do you want me to target?<<}{id="q1" by="AI" at="2026-05-28T12:59:22.000Z"}{>>I don't understand this question<<}{id="c1" by="user" at="2026-05-28T14:47:33.360Z" re="q1"}
  
4. **Round-trip (turndown):** add a turndown rule keyed on the mermaid node so HTML→MD reproduces the exact ` ```mermaid ` fence.
  
5. **Bundle:** the lazy dynamic import keeps `mermaid` (a heavy dep, multiple MB) out of the base bundle — fetched only when a diagram is actually present.
  
## Tests (to meet their bar)
- **Unit (Vitest):** `markdown.ts` emits the mermaid node for ` ```mermaid `; round-trip MD→HTML→MD preserves the exact fence byte-for-byte; non-mermaid code blocks are unaffected; invalid mermaid falls back to the code block.
  
- **Determinism caveat:** mermaid generates non-deterministic SVG IDs and renders async — pin/seed IDs and await render in tests so they stay deterministic and isolated (per their Test Desiderata).
  
- **Realistic ("Prove It"):** at minimum a component test asserting an `<svg>` is produced; ideally an e2e that opens a doc containing a mermaid block and checks a diagram appears — they explicitly value boundary verification over mocks.
  
## PR mechanics
- **Fork** `Lex-Inc/roughdraft` under your `alexmodrono` account, branch `feat/mermaid-rendering`.
  
- Match Biome formatting; run `pnpm` install + the package's `test`/`build`; satisfy `ci.yml` and Knip (no unused deps/exports).
  
- {==Open a short issue proposing the feature + approach before the PR.==}{>>Recommended: the editor-vs-preview and round-trip approach are opinionated enough that aligning with the maintainers first avoids a large rejected PR. Alternative: go straight to a tightly-scoped PR. Preference?<<}{id="q2" by="AI" at="2026-05-28T12:59:22.000Z"}{>>I mean I would first create a fork of the app and implement an opinionated version because I also want to use it locally right now, and then do the PR and then the authors could suggest changes.<<}{id="c2" by="user" at="2026-05-28T14:47:54.094Z" re="q2"}
  
- Keep scope tight: mermaid only, lazy-loaded, with the raw-block round-trip and tests. Add a `docs/solutions/` note if the round-trip handling is non-obvious.
  
## What I'd verify before writing code
I have NOT yet traced how the rendered document is presented (TipTap editor node vs a preview pane) — that's the one unknown that determines whether this is a small or medium PR. Resolving `q1` (by reading `App`/editor setup or asking the maintainers) is the prerequisite to implementation.

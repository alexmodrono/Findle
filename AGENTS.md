# Findle agent instructions

## Project tracking

Plan and track work on the Kanvas board; follow
[the Kanvas skill](.agents/skills/kanvas/SKILL.md). Use the bundled CLI to update
`kanvas.json`, signing notes and proposals with `--as codex`. Keep descriptions
and progress notes useful for human review. Preserve authorization already
given in the conversation when adding the board during ongoing work.

Run the board locally with:

```sh
python3 .agents/skills/kanvas/kanvas.py serve
```

## Interface work

Use [unslop-ui](.agents/skills/unslop-ui/SKILL.md) as a final review when creating
or changing interface copy, controls, decorative elements, charts, or UI mockups.
This applies to both AppKit and SwiftUI work. Read the skill and follow its
count, review, edit, recount, and report procedure for the UI being changed.

- Remove redundant labels, explanatory filler, decorative badges, and indicators
  that do not reflect actual application state.
- Keep actionable sync status, authentication errors, destructive-action
  confirmations, and native macOS conventions when they serve a purpose.
- Preserve accessible names, keyboard navigation, tooltips, and help text that
  users need. Translate the skill's web accessibility guidance to AppKit or
  SwiftUI accessibility APIs as appropriate.
- The counter is a web-oriented heuristic: directory scans omit `.swift` files.
  Pass individual Swift file paths to it and manually review native controls and
  localized strings. A zero count does not establish that a native UI is clean.
- Keep the review scoped to the interface being changed. Follow the skill's
  guardrails for application logic, data, and layout.

For a targeted review, invoke `$unslop-ui` with a file, folder, or component.

## Skill installation

The project-local skill is installed at `.agents/skills/unslop-ui`, with a
Claude Code link at `.claude/skills/unslop-ui`, following the existing skill layout.
These directories are local-only under the repository's current ignore rules.

Source: <https://github.com/felipebasurto/unslop-ui>, path `skills/unslop-ui`,
revision `849909e05015625a73ab6db388b56b1125260cb7`.

If the skill is missing in another checkout, install that directory from the
upstream repository using the skill-installer workflow before using it. Keep
the upstream skill and its invocation metadata unchanged. The optional
`pstack:unslop` dependency is not required; use the bundled writing-rule fallback
when it is unavailable.

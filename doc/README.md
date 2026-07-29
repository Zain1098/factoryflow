# FactoryFlow AI Development Kit v3.0

This folder is the controlled source of truth for the FactoryFlow Android manufacturing ERP.

## Source-of-truth order
1. `01_PRODUCT_REQUIREMENTS_v3.0.md`
2. `03_BUSINESS_RULES.md`
3. `04_ARCHITECTURE.md`
4. `05_DATABASE_AND_SYNC_RULES.md`
5. `02_AI_AGENT_RULES.md`
6. `11_DECISIONS_LOG.md`
7. Current code and migrations
8. Chat messages, notes, and old prompts

If two files conflict, the earlier item wins unless a newer approved decision is recorded in `11_DECISIONS_LOG.md` and `12_CHANGELOG.md`.

## Mandatory workflow for any AI or developer
1. Read this README and files 01-12 before changing code.
2. Inspect the current repository and produce a gap report against the documents.
3. Do not rewrite architecture, database, or state management without an approved ADR.
4. Work in small vertical slices.
5. Add tests and migration notes with every behavior change.
6. Update `12_CHANGELOG.md` and `10_IMPLEMENTATION_ROADMAP.md` after completing a task.

## Files
- `00_ORIGINAL_PRD_v2.4.md`: historical reference only.
- `01_PRODUCT_REQUIREMENTS_v3.0.md`: product scope and requirements.
- `02_AI_AGENT_RULES.md`: guardrails for Cursor, Claude, ChatGPT, Gemini, Amazon Q, or human developers.
- `03_BUSINESS_RULES.md`: non-negotiable manufacturing logic.
- `04_ARCHITECTURE.md`: technical architecture and module boundaries.
- `05_DATABASE_AND_SYNC_RULES.md`: data model, ledger, offline sync, migrations, and conflict handling.
- `06_CODING_STANDARDS.md`: Flutter/Dart/Supabase coding standards.
- `07_UI_UX_GUIDELINES.md`: mobile UX rules and screen behavior.
- `08_SECURITY_AND_PERMISSIONS.md`: authentication, RLS, roles, privacy, and audit requirements.
- `09_TESTING_AND_ACCEPTANCE.md`: testing strategy and acceptance criteria.
- `10_IMPLEMENTATION_ROADMAP.md`: delivery phases and priorities.
- `11_DECISIONS_LOG.md`: locked decisions and ADR process.
- `12_CHANGELOG.md`: controlled documentation history.
- `13_MASTER_AI_PROMPT.md`: copy-paste startup prompt for an IDE AI.
- `14_DATA_DICTIONARY.md`: canonical terms and status values.
- `15_RELEASE_CHECKLIST.md`: release gate.

## Product boundary
FactoryFlow is an offline-first Android application for one manufacturing factory in Phase 1. It is designed so a second factory, web dashboard, barcode scanning, and advanced analytics can be added later without rewriting the core.

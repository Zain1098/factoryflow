# Master Prompt for IDE AI

You are working on FactoryFlow, an offline-first Flutter Android manufacturing ERP.

Before making any change:
1. Read `/docs/README.md` and documents 01-15 in order.
2. Inspect the existing code, migrations, tests, and current database implementation.
3. Treat the documents as requirements but report any conflict with current code.
4. Do not code until you provide a concise impact plan for the requested task.

Non-negotiable constraints:
- Flutter + Riverpod + Drift + Supabase.
- Stock Ledger is the only stock source of truth.
- Posted transactions are immutable; corrections use reversal/replacement events.
- No negative stock, hard delete, duplicate posting, or client-only authorization.
- All writes are offline-first, UUID-based, idempotent, and queued for sync.
- RLS and factory scoping are mandatory.
- Tests, migrations, changelog, and relevant docs must be updated with code.

For the current task, return before coding:
- understanding of the request
- current implementation found
- gaps/conflicts
- files to change
- schema/migration impact
- security and stock-integrity risks
- tests to add
- smallest safe implementation sequence

After coding, return:
- exact changes
- files changed
- migrations
- tests run/results
- manual verification steps
- remaining risks
- next recommended task

Never invent product requirements. When an unresolved decision materially affects correctness, document options and recommendation instead of silently choosing.

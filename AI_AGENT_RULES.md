# AI_AGENT_RULES.md
## Operating Rules for AI IDE — FactoryFlow Manufacturing ERP Build

**This file is not optional context. It is a binding instruction set. Read it completely, every session, before doing any work.**

---

## 1. Source of Truth Hierarchy

1. `Manufacturing_ERP_PRD_v2.2.md` — the PRD. This defines *what* gets built. It is the single source of truth for features, database schema, business rules, validation, and roles.
2. This file (`AI_AGENT_RULES.md`) — defines *how* you work: process, discipline, communication.
3. Your own judgment — used **only** to flag problems in 1 or 2, never to silently override them.

If something you're about to build isn't in the PRD, or contradicts it, **stop before writing code**. Do not improvise a feature, a table, a validation rule, or a UI pattern that "seems reasonable" — check the PRD first.

---

## 2. Session Start Ritual (every single session, no exceptions)

1. Re-read `Manufacturing_ERP_PRD_v2.2.md` in full, or at minimum the chapters relevant to today's task.
2. Re-read this file in full.
3. State back, in 1–2 lines, what today's task is and which PRD chapter/section it maps to, before doing anything else.
4. If Chapter 15 (Open Questions) contains an unanswered item that today's task directly depends on, **stop and ask that specific question** before proceeding. Do not pick a default and move on.

---

## 3. Scope Discipline — Stay On The Task

- Work on **one module/feature at a time**, exactly as scoped by the current instruction. Do not jump ahead to unrelated modules "while you're at it."
- Do not refactor code outside the current task's scope unless explicitly asked.
- Do not add libraries, packages, or dependencies not already specified in PRD Chapter 10 without asking first.
- Do not build anything listed in PRD Chapter 14 (Future Roadmap) — QR/barcode, iOS, web dashboard, workflow engine, multi-factory config UI — unless explicitly instructed to start that phase.
- Do not silently reopen and re-decide things already locked in the PRD (e.g., Flutter/Supabase/Drift/Riverpod, the batch numbering format, the RTV 3-cycle cap). Re-litigating settled decisions mid-build is the single biggest source of wasted time — don't do it.

---

## 4. Change Control — If You Think the PRD Is Wrong

You are expected to think critically, not follow blindly. But the process is fixed:

1. **Flag it** — state exactly what's wrong and why (missing case, contradiction, security/performance risk).
2. **Propose a fix** — one concrete recommendation, not a list of options to choose from unless genuinely tied.
3. **Wait for explicit confirmation** before changing any code or schema based on it.
4. Once confirmed, update the PRD itself (new version entry in the Version History table) so the document and the code never drift apart. Code changes without a matching PRD update are not allowed.

Never unilaterally change architecture, schema, or business rules mid-session, even if you're confident it's an improvement.

---

## 5. Ambiguity Protocol

If a requirement is ambiguous, incomplete, or two parts of the PRD conflict:

- **Stop. Ask a specific, answerable question.** Not "does this look right?" — ask exactly what decision you need and why.
- Never fill a gap with a silent assumption and continue, even a "reasonable" one.
- If the ambiguity blocks only part of the task, say explicitly what you can complete now and what's blocked, rather than working around it invisibly.

---

## 6. Task Workflow

**Before starting a task:**
State the task, its PRD reference, and any Chapter 15 dependency check (2.4).

**While working:**
Stay inside the stated scope (Section 3). If you discover something adjacent that also needs fixing, note it — don't silently expand the task to include it.

**After finishing a task:**
Report, plainly:
- What was built/changed, and where.
- Which PRD validation rules (Ch. 4, 7) and error-handling cases (Ch. 8) were implemented and verified for this module.
- Anything that deviates from the PRD, and why (should be rare, and only via Section 4's process).
- What's genuinely next — don't start it, just name it.

---

## 7. Definition of Done

A module is not "done" until, at minimum:

- All fields and validation rules from its PRD Chapter 4 entry are implemented.
- The relevant rows from the Chapter 8 Error Handling table are handled (not just the happy path).
- Stock-affecting actions write to `Stock_Ledger` per Chapter 7.1 — never computed by live-summing transaction tables.
- Same-day edit / post-rollover correction behavior follows Chapter 7.5 exactly.
- Offline save + sync behavior follows Chapter 7.6.

Do not report a module as "done," "production-ready," or "complete" if any of the above is untested or stubbed. Say what's actually working versus what's scaffolded but unverified.

---

## 8. Communication Rules

- Be direct. No filler, no "Great question!," no unnecessary preamble.
- No inflated status reporting — if something is 70% done, say 70% done, not "done."
- Flag real risks and problems plainly, the same way you'd flag them to a senior engineer, not softened.
- Don't ask permission for things already decided in the PRD or this file — only ask when Section 5 (Ambiguity Protocol) actually applies.
- Keep responses proportional to the task. A small fix doesn't need a lengthy explanation; a schema-affecting change does.

---

## 9. Explicit "Do Not" List

- Do not introduce new architectural patterns not in PRD Chapter 10.
- Do not build Chapter 14 (Future Roadmap) items early.
- Do not make the workflow/business-rule engine configurable (PRD 11B is explicitly out of scope) even if it seems like good practice.
- Do not hard-delete any transaction record — corrections only, per Chapter 7.5.
- Do not allow any code path that can drive `Stock_Ledger.running_balance` negative.
- Do not skip the Session Start Ritual (Section 2), even for small tasks.

---

*This file governs process. `Manufacturing_ERP_PRD_v2.2.md` governs product. Keep both open every session.*

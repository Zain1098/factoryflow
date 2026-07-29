# Mobile UI/UX Guidelines

## Principles
- Fast, one-hand-first operation for frequent tasks.
- Minimum typing through search dropdowns and remembered defaults.
- Large touch targets at least 44dp.
- Status must never rely on color alone.
- Offline/sync state always visible but not obstructive.
- Industrial clarity over decorative animation.

## Screen pattern
Each operational screen should contain:
1. Clear title and current part/batch context
2. Compact sync/connectivity indicator
3. Form with smart defaults
4. Inline validation
5. Sticky primary action
6. Draft/save state
7. Recent entries for quick verification

## Quantity entry
Use numeric keypad, positive-value validation, available-stock hint, and computed remainder/approved/reject values. Prevent accidental decimal input for PCS unless part UOM allows decimals.

## Dropdowns
Searchable, cached, recently used first, active records by default. Historical records show inactive master names without allowing new selection.

## Confirmation policy
Do not show confirmation dialogs for reversible low-risk actions. Require confirmation for posting stock, voiding, logout with unsynced data, conflict resolution, and Admin escalation decisions.

## Error messages
State what happened, why, and the next action. Example: `Dispatch blocked: 320 PCS available at BP Approved, but 400 entered.` Do not use generic `Something went wrong` when a known error exists.

## Empty/loading states
Empty state explains whether there is no data, filters hide data, or data is offline/unavailable. Use skeleton/loading indicators without blocking cached data.

## Dashboard
Cards show value, unit, filter context, last updated time, and tap-through detail. Alerts show severity and actionable destination.

## Batch timeline
Chronological grouped events with stage icon, quantity movement, user, time, status, photos, and correction/reversal links.

## Accessibility
Support text scaling, contrast, screen-reader labels, focus order, large targets, and meaningful error announcements.

## Themes
Light and dark themes with consistent semantic colors. Never encode approved/rejected solely by green/red.

## Language
Phase 1 UI may be English, but all user-facing strings must be centralized for future Urdu localization.

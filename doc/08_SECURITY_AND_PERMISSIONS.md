# Security and Permissions

## Authentication
Supabase Auth with password or approved provider. Session renewal handled safely. Cached offline session may permit local entry until expiry policy, but server sync requires valid authorization.

## Authorization
RLS is mandatory on server tables. Client role checks improve UX only. Every command verifies factory membership and role.

## Role matrix summary
- Admin: all records, masters, approvals, users, audit, adjustments.
- Production Incharge: production/downtime, same-day allowed corrections, read reports.
- Store: receive/dispatch movements and stock view.
- Quality Inspector: inspections, RTV, photos.
- Management: read-only.

## Sensitive operations
Admin approval required for after-day corrections, physical adjustments, force dispatch, scrap resolution, user role changes, and voiding posted records outside permitted window.

## Audit
Record actor, role, factory, device, action, entity, old/new values or references, reason, timestamp, and correlation/idempotency ID. Audit records are append-only.

## Secrets
No service-role keys, database passwords, OAuth client secrets, or signing secrets in Flutter source, assets, logs, screenshots, or documentation committed to the repository.

## Storage
Photo buckets use private access and signed URLs. Path includes factory and record identifiers. Upload MIME/type/size limits enforced.

## Input safety
Validate IDs, quantities, dates, file types, and text lengths. Parameterize SQL. Escape exported spreadsheet content that could become formula injection.

## Device safety
Use Android app sandbox and secure storage for tokens. Detect and warn about unsupported app versions. Provide remote session revocation through Supabase.

## Privacy
Store only operational data needed. Do not collect worker personal data beyond required name/contact/master fields without a policy.

## Security testing
Test cross-factory access, role escalation, direct API mutation, signed URL expiry, duplicate replay, and unauthorized export.

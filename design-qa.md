# Reports Design QA

**Source visual truth path:** `C:\Users\za496\Downloads\Mobile Devices\2fb00cd3-a43b-4106-a149-834be5b0a405.jpeg`

**Implementation target:** `lib/features/reports/reports_screen.dart`

**Implementation screenshot path:** unavailable

**Viewport / state:** Intended Android mobile Reports hub in light theme, with
the current report date range selected. The reference is a 736 x 552 composite
of three mobile scheduling screens; the implementation is a single ProFlow
factory-report hub, so it intentionally adapts the visual language rather than
copying calendar content or navigation.

## Findings

- [P1] Rendered mobile comparison is unavailable.
  Location: Reports hub.
  Evidence: the reference image is available, but a Flutter runtime screenshot
  could not be captured in this workspace. Focused Dart analysis also timed out
  after 60 seconds without diagnostics.
  Impact: narrow-width text truncation, vertical density, date-picker action,
  and ink states cannot be conclusively verified.
  Fix: launch the app in Chrome or on Android, open Reports at a narrow mobile
  viewport, and compare a capture against the reference before calling visual
  QA complete.

## Required Fidelity Surfaces

- **Fonts and typography:** Uses ProFlow's existing Inter theme. Report
  category and quick-range labels use the existing small-label hierarchy;
  runtime wrapping remains unverified.
- **Spacing and layout rhythm:** New 16px outer gutter, 24px hero radius,
  22px section-card radius, and compact 42px icon blocks adapt the reference's
  soft-card rhythm for dense factory use. Runtime overflow remains unverified.
- **Colors and visual tokens:** Keeps ProFlow's seeded steel-blue primary,
  semantic teal/red/green report colors, and uses the primary container for the
  soft hero. No global theme token changed.
- **Image quality and asset fidelity:** No visual-image assets are used in the
  Reports hub. Standard Material icons replace the reference's app-specific
  icons, appropriate for an ERP navigation surface.
- **Copy and content:** Existing report names, descriptions, date-range
  provider, navigation callbacks, and report destinations are retained.

## Implementation Checklist

1. Capture the signed-in Reports hub in a mobile-size Chrome or Android view.
2. Test every quick-range chip and both date-range entry points.
3. Open each report card and confirm its existing destination still opens.
4. Fix any observed overflow before changing `final result`.

final result: blocked

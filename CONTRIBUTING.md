# Contributing to Shepherd

Thanks for wanting to help. Shepherd is MIT-licensed — fork the repo,
branch, and open a pull request. Small, focused PRs merge fastest.

## What we're looking for

- **New radio / sensor drivers** — the multi-driver framework in
  `lib/services/` is built for this. Follow the existing driver pattern
  (per-driver poller, driver-namespaced node IDs so link keys can't
  collide).
- **Field testing and bug reports** — especially real-world link data.
- **Docs and specs** — `docs/` holds the driver and mode specs.

## Hard boundaries (non-negotiable)

Shepherd is a **defensive-only** sensing tool. It detects; it never
transmits to disrupt.

- No jamming, deauthentication, spoofing, or any transmit-to-disrupt
  code. PRs adding offensive capability will be declined, no exceptions.
- Sensing claims must stay honest: the app reports disturbances, blobs,
  trails, bearings, and estimates — never identities, silhouettes, or
  unsupported precision. New features must label estimates as estimates.

## Before you open the PR

- `flutter analyze` clean, full test suite green.
- New drivers need at least a bench-level demonstration (see
  `docs/shepherd_cot_output_spec.md` for the pattern).
- Keep the dark-mode, minimal UI language; advanced settings go behind
  the gear.

By contributing, you agree your work is licensed under the repo's MIT
license.

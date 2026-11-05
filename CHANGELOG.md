# Changelog

## [0.2.1] — 2026-11-05

### Fixed

- Assigning or removing a user from an issue or pull request no longer fails
  with `Field 'id' doesn't exist on type 'Assignable'`. Both operations keep
  GitHub's atomic add/remove behavior and preserve other assignees.
- Regression coverage now exercises assignment and removal for both issues
  and pull requests against the corrected response fields.

## [0.2.0] — 2026-11-04

- Initial public community release: native GitHub Projects boards, issues,
  drafts, project conversations, optional Slack and signed Sparkle updates.

[0.2.1]: https://github.com/oddmundleikvoll/sprintwake-projects/releases/tag/v0.2.1
[0.2.0]: https://github.com/oddmundleikvoll/sprintwake-projects/releases/tag/v0.2.0

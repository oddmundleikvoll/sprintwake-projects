# Changelog

## [0.3.0] — 2026-11-06

### Added

- Drag column headings to change their order on this Mac, remembered per GitHub
  account, project and grouping field without replacing GitHub field options.
- Reorder cards within a column or place them precisely in another column;
  task priority order is saved on GitHub after confirmation. Context menus offer
  card up/down and column left/right actions. Conversation messages keep time order.
- Preserve a confirmed column move if saving card order fails, and reject stale
  drops after changing session, project or grouping.

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

[0.3.0]: https://github.com/oddmundleikvoll/sprintwake-projects/releases/tag/v0.3.0
[0.2.1]: https://github.com/oddmundleikvoll/sprintwake-projects/releases/tag/v0.2.1
[0.2.0]: https://github.com/oddmundleikvoll/sprintwake-projects/releases/tag/v0.2.0

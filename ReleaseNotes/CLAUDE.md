# Release notes

Every commit adds a line here. Every release consumes them.

## When you commit

Append **one line** to `Unreleased.md`, under the right heading. Do it in the
same commit as the change — a note added later is a note written from memory.

```markdown
### Fixed
- Settings no longer crashes when opened.
```

Headings, in the order they appear on a release page:

| Heading | For |
|---|---|
| `### Added` | something you can now do that you could not before |
| `### Changed` | different behaviour, same capability |
| `### Fixed` | it was broken, now it is not |

Skip a heading entirely if it has no entries. Do not leave empty sections.

## One sentence. Genuinely one.

The commit message is where reasoning belongs — often at length, and that is
right. A release note is not that. It tells someone deciding whether to
download this build what changed, and nothing else.

**Write for the reader, not the author.** Say what is different for them, not
what you did to the code.

Good:

- `Settings no longer crashes when opened.`
- `Rate limits now show a live countdown instead of empty rings.`
- `Releases ship a disk image only; the zip is gone.`

Bad:

- `Fixed a crash caused by initialising @State from CredentialStore.hasCredentials, which spawns a subprocess that SwiftUI re-runs on every view update.`
  — that is a commit message. The reader does not have the file open.
- `Various fixes and improvements.` — says nothing; delete it instead.
- `Refactored UsageCoordinator.` — invisible to the reader. Internal-only work
  needs no note at all.

If a change is not user-visible, **write nothing**. An empty release section is
better than filler.

## Rules

- One line per change. If a change genuinely needs two, it is two changes.
- No trailing full-stop-free fragments; write a sentence.
- No version numbers, dates, or commit hashes — the release supplies those.
- No markdown beyond the leading `- ` and inline `code`.
- Never edit an archived `v*.md`. Those are published; they are history.

## When you cut a release

`./Scripts/release.sh <version>` does this for you:

1. reads `Unreleased.md`,
2. writes it to `ReleaseNotes/v<version>.md`,
3. puts it in the GitHub release body,
4. resets `Unreleased.md` to the empty template.

So the only manual step is keeping `Unreleased.md` honest as you go. If it is
empty at release time the script stops and says so, rather than publishing a
build nobody can describe.

# Notes: Migration from sudoer strings to typed commands

> **Status:** Deferred. Not scheduled. This file holds the design notes so
> the decision history survives and the future feature can start from a
> warm place. No problem.md / plan.md until the feature is scheduled.

## Index

- [Why this is deferred](#why-this-is-deferred)
- [Today's contract (feature 02 baseline)](#todays-contract-feature-02-baseline)
- [What the typed shape would look like](#what-the-typed-shape-would-look-like)
- [Tradeoffs](#tradeoffs)
- [Triggers — when to actually do this](#triggers--when-to-actually-do-this)
- [Migration considerations](#migration-considerations)

---

## Why this is deferred

Feature 02 ships `roles/sudoers` with the **verbatim** input shape — the
operator owns the exact lines that land in `/etc/sudoers.d/{username}`,
and `visudo -cf %s` is the authoritative validator. This matches the
`Infrastructure-Vm-Users` contract today exactly.

Switching to a typed input shape (user/host/runas/commands as separate
fields) is a **breaking change to the config schema** and provides no
new validation guarantee — `visudo -cf` already catches everything that
matters before the file is swapped into place. The only thing a typed
shape adds is earlier feedback on typos, which is a small win for a
non-zero cost.

Defer until either (a) operators report typo pain in practice, or
(b) a feature needs to introspect sudoers rules (e.g. compute which
users can `sudo` as which other users for a permissions audit) — the
verbatim string is opaque to introspection.

## Today's contract (feature 02 baseline)

```jsonc
{
  "users": [
    {
      "username": "u-runner-deploy",
      "sudoersRules": [
        "u-runner-deploy ALL=(u-actions-runner) NOPASSWD: /usr/bin/mkdir",
        "u-runner-deploy ALL=(root) NOPASSWD: /usr/bin/rm -rf /opt/runners/*"
      ]
    }
  ]
}
```

`roles/sudoers` writes each line verbatim, prepended only by a header
comment for traceability, then runs `visudo -cf` on the temp file before
the atomic move.

## What the typed shape would look like

```jsonc
{
  "users": [
    {
      "username": "u-runner-deploy",
      "sudoersRules": [
        {
          "runAs":    "u-actions-runner",
          "host":     "ALL",
          "noPasswd": true,
          "commands": ["/usr/bin/mkdir"]
        },
        {
          "runAs":    "root",
          "host":     "ALL",
          "noPasswd": true,
          "commands": ["/usr/bin/rm -rf /opt/runners/*"]
        }
      ]
    }
  ]
}
```

The role assembles each entry into the canonical
`{username} {host}=({runAs}) [NOPASSWD:] {commands}` line, writes the
file, and validates with `visudo -cf` exactly as today.

| Field | Required | Notes |
|-------|----------|-------|
| `runAs`    | yes | Single target user. A list is rejected in v1; multi-target is its own future shape. |
| `host`     | no  | Defaults to `ALL`. |
| `noPasswd` | no  | Defaults to `true` (matches every existing rule today). |
| `commands` | yes | Array of absolute command paths with optional fixed args. Sudo wildcard rules (`*`) preserved as-is — sudo's `*` matches a single path component and the operator is responsible for understanding that. |

Mixed shapes (verbatim + typed in the same array) are explicitly
rejected so the schema stays unambiguous; the migration to typed is
all-or-nothing per `users[]` entry.

## Tradeoffs

| | Verbatim (today) | Typed |
|---|------------------|-------|
| Schema simplicity | one string per rule | five fields per rule |
| Typo catch latency | `visudo -cf` at write time | jsonschema at config load time + `visudo -cf` |
| Introspection | none — opaque strings | natural — query by field |
| Migration cost | none | breaking schema change for every existing `sudoersRules` entry |
| Vault config size | small | ~3x larger for same content |
| Operator mental model | "I am writing a sudoers file" | "I am declaring a permission grant" |

## Triggers — when to actually do this

Schedule this feature when **any one** of these is true:

1. Operators have reported (more than once) that a sudoers typo cost
   them a wasted reconcile run.
2. A new feature needs to introspect or derive sudoers rules
   programmatically (e.g. an audit report, a permissions diff
   between two configs).
3. The number of distinct sudoers rules across all configs exceeds
   ~50 — at that scale, copy-paste drift becomes likely and typed
   parsing helps factor common patterns into role-level templates.

Until at least one of those is true, the verbatim shape is fine and
the breaking change isn't earned.

## Migration considerations

When this feature is scheduled:

- Provide a one-shot converter script (`scripts/convert-sudoers-to-typed.sh`)
  that reads the existing `VmUsersConfig`, parses each verbatim line,
  and emits the typed shape. The script fails loudly on any line it
  can't parse (e.g. unusual sudoers syntax) rather than silently
  dropping it.
- Run the converter against every operator's current config in dev
  before merging the schema change. If any config fails to convert,
  resolve those cases first (they are exactly the cases a typed shape
  would have rejected anyway).
- Provide a deprecation window: the role accepts both shapes for one
  release, warns on verbatim, then drops verbatim in the following
  release.

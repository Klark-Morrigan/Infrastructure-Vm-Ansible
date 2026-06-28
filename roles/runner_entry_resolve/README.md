# Role: runner_entry_resolve

Repo-internal helper. Resolves the `GitHubRunnersConfig` slice for the
current host into the shared `vm_runner_entries` fact, used by
[`roles/runner_binary`](../runner_binary/README.md) (and, once they
land, `roles/runner_registration` and `roles/runner_service`) via meta
dependency.

## Index

- [Why this role exists](#why-this-role-exists)
- [Var contract](#var-contract)

## Why this role exists

Each of the three runner roles needs the same host slice of
`github_runners_config`: the entries whose `vmName` matches
`inventory_hostname`. Without this helper, each role would carry its
own copy of the same selectattr expression under a different fact
name - exactly the duplication a single shared entry-resolver role
avoids. Changing the selector (vault schema rename,
swapping `vmName` for some other key) now touches one file instead of
three. Ansible deduplicates meta-dependency invocations within a play,
so the helper still runs exactly once even when all three consumers
are applied in sequence.

The fact is a **list**, not an object: a single VM commonly hosts
several runners (multi-repo / multi-purpose hosts), so consumers loop
over the slice rather than reading a single record.

## Var contract

- **Reads**: `github_runners_config` (the verbatim
  `GitHubRunnersConfig-<Suffix>` JSON array written into extra-vars by
  the bash bridge). Absent or empty is the legitimate
  "this host has no declared runners" case and resolves to `[]`.
- **Sets**: `vm_runner_entries` - the list of entries whose `vmName`
  equals `inventory_hostname`. Consumer roles read
  `vm_runner_entries[*].runnerName`, `.runnerUsername`, etc. directly.

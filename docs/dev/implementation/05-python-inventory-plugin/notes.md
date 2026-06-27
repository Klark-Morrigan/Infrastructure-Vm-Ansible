# Notes: Migration from JSON-driven inventory YML generation to custom Python plugin

> **Status:** Deferred. Not scheduled. This file holds the design notes so
> the decision history survives and the future feature can start from a
> warm place. No problem.md / plan.md until the feature is scheduled.

## Index

- [Why this is deferred](#why-this-is-deferred)
- [Today's approach (feature 02 baseline)](#todays-approach-feature-02-baseline)
- [What the plugin would look like](#what-the-plugin-would-look-like)
- [Tradeoffs](#tradeoffs)
- [Triggers — when to actually do this](#triggers--when-to-actually-do-this)
- [Migration considerations](#migration-considerations)

---

## Why this is deferred

Feature 02 ships inventory as **YAML regenerated each run** by
`scripts/run-playbook.sh` from the vault JSON. The bridge already runs
on every invocation, so regeneration is free; the generated file is
plain YAML on tmpfs that can be inspected with `cat` while debugging;
and there is no Python in the repo to maintain.

A custom Python inventory plugin is the idiomatic Ansible answer to
"dynamic inventory from a custom source," but the idiom assumes more
than one consumer reads the inventory and that the source needs richer
filtering than a `jq` pipeline can express comfortably. Neither is true
in v1.

Defer until one of the [triggers](#triggers--when-to-actually-do-this)
fires.

## Today's approach (feature 02 baseline)

The bridge writes two files in tmpfs each run:

1. `extra-vars.json` — consumed via `--extra-vars @file`.
2. `hosts.yml` — generated from the same vault JSON by a `jq` pipeline,
   passed to `ansible-playbook` via `-i`.

`hosts.yml` is a flat constructed inventory:

```yaml
all:
  children:
    vm_provisioner_hosts:
      hosts:
        ubuntu-01-ci:
          ansible_host: 192.168.1.101
          ansible_user: u-admin
          ansible_become: true
          ansible_become_method: sudo
          ansible_become_pass: "..."
        ubuntu-02-ci:
          ...
```

Both files are deleted by the bridge's `trap EXIT`.

## What the plugin would look like

Three checked-in files replace the `jq` step in the bridge:

```
Common-Ansible/
├── ansible.cfg                                # plugin discovery + default inventory
├── inventory/
│   ├── vm_provisioner.yml                     # plugin config (checked in)
│   └── plugins/
│       └── inventory/
│           └── vm_provisioner.py              # the plugin
```

### `ansible.cfg`

```ini
[defaults]
inventory = inventory/vm_provisioner.yml

[inventory]
enable_plugins = vm_provisioner
```

### `inventory/vm_provisioner.yml`

```yaml
plugin: vm_provisioner
# Path the bridge populates per-run via env var; resolved at parse time.
vault_data_path: "{{ lookup('env', 'VM_ANSIBLE_VAULT_DATA') }}"
```

### `inventory/plugins/inventory/vm_provisioner.py` (sketch)

```python
from ansible.plugins.inventory import BaseInventoryPlugin
import json

DOCUMENTATION = '''
    name: vm_provisioner
    plugin_type: inventory
    short_description: Inventory from VmProvisionerConfig vault JSON.
    options:
      plugin:
        required: true
        choices: ['vm_provisioner']
      vault_data_path:
        required: true
        description: Path to bridge-written JSON.
'''

class InventoryModule(BaseInventoryPlugin):
    NAME = 'vm_provisioner'

    def verify_file(self, path):
        return path.endswith('vm_provisioner.yml')

    def parse(self, inventory, loader, path, cache=False):
        super().parse(inventory, loader, path)
        self._read_config_data(path)

        with open(self.get_option('vault_data_path')) as f:
            data = json.load(f)

        inventory.add_group('vm_provisioner_hosts')
        for vm in data['vm_provisioner_config']:
            name = vm['vmName']
            inventory.add_host(name, group='vm_provisioner_hosts')
            inventory.set_variable(name, 'ansible_host', vm['ipAddress'])
            inventory.set_variable(name, 'ansible_user', vm['adminUsername'])
            inventory.set_variable(name, 'ansible_become', True)
            inventory.set_variable(name, 'ansible_become_method', 'sudo')
            inventory.set_variable(name, 'ansible_become_pass', vm['adminPassword'])
```

The bridge then just exports `VM_ANSIBLE_VAULT_DATA="$tmpdir/vault_data.json"`
and invokes `ansible-playbook` without `-i` — the plugin loads from the
checked-in config file.

## Tradeoffs

| | YAML regen (today) | Python plugin |
|---|--------------------|---------------|
| Files in repo | none (generated) | `ansible.cfg`, plugin config, plugin code |
| Lines of code | ~15 lines `jq` in bridge | ~60-80 lines Python |
| Languages | bash + YAML | bash + YAML + Python |
| Debugging | `cat $tmpdir/hosts.yml` | `ansible-inventory --list` |
| Per-host conditionals | messy in `jq` | clean Python |
| Cache support | n/a | yes, but disabled because bridge regen is free |
| `ansible <host> -m ping` ad-hoc | needs `-i $tmpdir/hosts.yml` | works because `ansible.cfg` points at the plugin |
| Stack trace on bad input | `jq` errors with a line number | Python exception inside Ansible |
| Idiomatic Ansible | borderline | yes |

## Triggers — when to actually do this

Schedule this feature when **any one** of these is true:

1. The `jq` pipeline in the bridge exceeds ~30 lines or contains nested
   conditionals that are hard to reason about. Common cause: per-host
   group derivation (e.g. environment tags, role tags from `VmUsersConfig`
   joined into `vm_provisioner_hosts`).
2. A second consumer of the inventory exists that does **not** go
   through `run-playbook.sh`. Most likely cause: operators running
   ad-hoc `ansible <host> -m ping` or `ansible-playbook` directly.
   Today's design requires those callers to know about the generated
   tmpfs path; a plugin lets them just work.
3. Inventory needs to be queryable independent of running a playbook
   (e.g. a CI step that lists hosts for a Slack notification).
4. The vault JSON shape diverges from the inventory shape enough that
   `jq` is doing real translation work rather than field-renaming.

Until one of those fires, the YAML regen is cheaper and more
inspectable.

## Migration considerations

When this feature is scheduled:

- The plugin's input contract is the same JSON the bridge already
  writes — `data['vm_provisioner_config']` is the same array shape.
  No vault changes; no schema changes for any consuming repo.
- Roles and playbooks don't change. They only see hosts and variables,
  not where they came from. Verify in a test run with both inventories
  (YAML and plugin) that produced host/var sets are identical.
- Drop the `jq` block from `scripts/run-playbook.sh`; export
  `VM_ANSIBLE_VAULT_DATA` instead of writing `hosts.yml`. The bridge's
  `trap EXIT` cleanup still applies to `vault_data.json`.
- The bridge no longer needs `yq` (if it was ever installed for the
  YAML conversion) — JSON is the only intermediate format.
- Update `ops/_bootstrap-controller-wsl.sh` to include the plugin
  collection path on `ANSIBLE_INVENTORY_PLUGINS` if not already
  covered by `ansible.cfg`.
- Ansible's `ansible-inventory --graph` against the plugin during
  development is the fastest feedback loop — use it before wiring up
  the bridge.

# ansible/AGENTS.md

Subtree rules for `ansible/` (the roles that rebuild orcrist, epic ds-nhh.4). Root `AGENTS.md` still applies, in
particular hard rule 6 (public repo, no secrets or instance data). Paths here are repo-root-relative.

## Layout

- `ansible/site.yml`: the play. Roles are listed there in order, each tagged with its own name.
- `ansible/roles/<role>/{tasks,templates,files,defaults,handlers,meta}/`.
- `ansible/requirements.yml` (collections) and `ansible/python-requirements.txt` (ansible-core, ansible-lint): exact
  pins. Bump them in a PR of their own.
- Instance values, inventory and secrets live in the private homelab-site repo. Its `site.yml` loads them and imports
  `ansible/site.yml` from this repo (the deploy checkout on orcrist, so applied roles match deployed master; an agent
  clone via `DOCKER_SERVICES_DIR` while developing).

## Role conventions

- `defaults/main.yml` holds only safe, generic values. Instance values (addresses, user names, interfaces) are required
  variables with no default, checked by an `ansible.builtin.assert` at the top of `tasks/main.yml`.
- Capture first: a template reproduces today's live file byte for byte before it changes anything. Check with
  `--check --diff` on orcrist: no diff means the role matches the host.
- Every template starts with `# Managed by Ansible (docker-services/ansible/roles/<role>)`, in the file's own comment
  syntax.
- Never `state: mounted`, `state: restarted` or a reboot on a live path: use `state: present` and let the next boot or
  jalance apply it. Handlers are limited to `systemd daemon-reload`.
- `no_log: true` on every task that receives a secret.
- Shell scripts under `roles/*/files/` are verbatim copies of live scripts: they pass shellcheck at severity `info`
  like any other script, or are excluded in `lint.yml` with a reason.
- Every role ships for Ubuntu 24.04 only (`site.yml` asserts it).

## Running

- Agents: lint and syntax check only, from `ansible/` (see the root validation matrix). Install the pins into a venv in
  your scratchpad, never into the user's environment.
- jalance runs anything that needs root (`--check --diff` and the apply) from homelab-site, in a terminal, with
  `--ask-become-pass`. Agents prepare the change and read the output jalance pastes back. Not via `agent-sudo`: each
  task would be its own approval prompt showing an opaque `/bin/sh -c '... AnsiballZ_*.py'` line, so approving it
  approves nothing in particular. Do not route around this.
- The real integration test is the DR drill on a fresh VM (ds-nhh.4.10). Molecule is optional per role.

# 0012: Secrets in SOPS with age as the single encrypted source of truth

- **Status:** Proposed
- **Date:** 2026-11-07 (recorded; not implemented)
- **Links:** Beads `ds-nhh.3` (open) and its children `ds-nhh.3.1`, `ds-nhh.3.2`, `ds-oko`; ADR 0001 (left the
  secrets tooling open); `REBUILD.md` §1; `env.example`

**This is planned work, not current practice.** Today there is no SOPS or age in the repo; secrets are plaintext on
the host.

## Context

Per `ds-nhh.3` (verified 2026-11-07, names only), secrets are spread across a plaintext `.env` in the deploy
checkout, three untracked plaintext `.env` backups beside it, and host files outside the repo: the CIFS credentials,
the restic environment and repository password, the SMTP relay credentials, the Beads credentials file, `acme.json`,
the Dolt TLS material and Tailscale state. `env.example` is missing some variables the compose file uses. The repo is
public (ADR 0001), so secrets cannot live in it as plaintext, and ADR 0001 left the tooling for the private repo
undecided.

## Decision (proposed)

1. One age identity for the site; a second recipient (hardware key or a laptop key) is optional.
2. `.env` as a SOPS dotenv file (keys stay plaintext, values are encrypted, so a diff shows which variable changed
   and `sops -d` emits a ready `.env`). Host secrets as YAML with `encrypted_regex`.
3. Consumers: the private deploy workflow (renders `.env`), Ansible through the `community.sops` collection, and
   Flux's native SOPS decryption later.
4. Bootstrap order on a dead host: age key from the password manager, clone the private repo, decrypt the restic
   credentials, mount the NAS, restic restore, Ansible. The age key must never be recoverable only from restic or only
   from the NAS.
5. Leftover plaintext copies are deleted at the end.

## Alternatives considered

The `ds-nhh.3` text does not record other tools as evaluated. The obvious alternatives, not evaluated here, are:
git-crypt, Ansible Vault, and keeping secrets only in a password manager.

## Consequences (if accepted)

- One place to rotate and audit secrets, and a rebuild that needs one key from outside the system.
- The age key becomes the root secret; losing it with no second recipient loses every secret.
- The private repo from ADR 0001 must exist first (`ds-nhh.2`).

## What would make this Accepted

The age key exists and is stored off-host (`ds-nhh.3.1`), the SOPS tooling and leak guards are in place
(`ds-nhh.3.2`), and `.env` is read from SOPS with the plaintext copies removed. Until then, this stays Proposed.

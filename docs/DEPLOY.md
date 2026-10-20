# Automatic deploys

A merge to `master` updates the running stack on orcrist. Nothing else deploys.

## How it works

1. A PR is opened. `.github/workflows/lint.yml` runs shellcheck and `docker compose config` on
   **GitHub-hosted** runners (`ubuntu-latest`).
2. The PR is merged to protected `master`. `.github/workflows/deploy.yml` runs on the
   **self-hosted** runner labeled `orcrist` (`concurrency: deploy-orcrist`, so deploys queue and never overlap).
3. The job runs `scripts/deploy.sh` from the existing checkout at
   `/home/jalance/Projects/docker-services`. It does not use `actions/checkout`, because that
   directory holds `.env` and the gitignored service data. The script:
   - refuses to run unless the checkout is on `master` with no tracked modifications (untracked files are fine)
   - fetches `master` over HTTPS and fast-forwards (`--ff-only`) to exactly `$GITHUB_SHA`. If HEAD
     already contains that commit (a newer one is deployed), it exits without doing anything.
   - runs `docker compose config --quiet`, then `docker compose up -d --build --remove-orphans`
   - prints the old→new commits, the changed files and `docker compose ps`

   `up -d` only recreates containers whose configuration changed. It never pulls newer images;
   see [Image upgrades](#image-upgrades). `--remove-orphans` only removes containers that belong to
   the `docker-services` compose project (named after the directory) but are no longer in
   `docker-compose.yml`, i.e. a service you deleted. Other projects such as `pi_slide_show` and
   `games` have their own project names and are never touched.

The script runs from the deploy checkout, so each deploy executes the `deploy.sh` that was there
*before* the fast-forward. A change to `deploy.sh` takes effect on the deploy after the one that
ships it.

Working on a feature branch in the deploy checkout pauses auto-deploys: `deploy.sh` exits unless the checkout is on `master`. Switch back to `master` before merging.

To run a deploy by hand: `./scripts/deploy.sh` (deploys the tip of `master`), or use
**Actions > Deploy > Run workflow** on `master`.

## Security model

- The repo is public. GitHub [advises against](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/about-self-hosted-runners#self-hosted-runner-security)
  self-hosted runners on public repos, because a PR can add a workflow that targets the runner.
  The protections here are:
  - `deploy.yml` triggers only on `push` to `master` and on `workflow_dispatch`, never on
    `pull_request` or `pull_request_target`. It also checks `github.ref`, and `deploy.sh` refuses
    any commit that isn't on `master`.
  - `master` is protected, so changes land only through reviewed PRs.
  - PR checks (`lint.yml`) use GitHub-hosted runners only.
  - Workflow runs from fork PRs need manual approval (see [Repo settings](#repo-settings)).
    **A PR that changes anything under `.github/` can target the self-hosted runner. Read it
    before you approve its workflow run.**
  - Token permissions are `contents: read`. The deploy needs no GitHub credentials: it fetches the public repo over HTTPS.
- The runner runs as `jalance`, who is in the `docker` group. **Docker access is effectively
  root on orcrist.** Anything merged to `master` runs with that access, including compose
  changes (volume mounts, `privileged`, `build:` contexts) and edits to the workflow files.
  Review merges with that in mind.
- Only you should have write access to the repo. A collaborator with write access could push a
  branch containing a workflow that runs on the runner.

## Runner install (orcrist, once)

Run as `jalance`:

1. Prepare the deploy checkout. It must be on `master` and include `scripts/deploy.sh`:
   ```bash
   cd /home/jalance/Projects/docker-services
   git switch master && git pull --ff-only
   git status --short --untracked-files=no   # must print nothing
   id -nG | grep -qw docker && echo "docker group OK"
   ```
2. On GitHub: **Settings > Actions > Runners > New self-hosted runner**, Linux x64. Use the
   download commands from that page, because they pin the current version and checksum:
   ```bash
   mkdir -p ~/actions-runner && cd ~/actions-runner
   curl -o actions-runner-linux-x64-<ver>.tar.gz -L https://github.com/actions/runner/releases/download/v<ver>/actions-runner-linux-x64-<ver>.tar.gz
   tar xzf actions-runner-linux-x64-<ver>.tar.gz
   ```
3. Register it with the `orcrist` label, using the token shown on that page:
   ```bash
   ./config.sh --url https://github.com/neybar/docker-services --token <TOKEN> \
       --name orcrist --labels orcrist --unattended
   ```
   (`self-hosted`, `Linux` and `X64` labels are added automatically.)
4. Install and start it as a systemd service that runs as `jalance`:
   ```bash
   sudo ./svc.sh install jalance
   sudo ./svc.sh start
   sudo ./svc.sh status
   ```
   The runner should show as **Idle** under **Settings > Actions > Runners**.
5. Test it: **Actions > Deploy > Run workflow** on `master`. With no new commits, the run just
   reconciles the containers and prints `docker compose ps`.

The runner updates itself. To remove it: `sudo ./svc.sh stop && sudo ./svc.sh uninstall && ./config.sh remove --token <TOKEN>`.

## Repo settings

- **Settings > Actions > General > Approval for running fork pull request workflows from
  contributors**: *Require approval for all external contributors* (older UI: "all outside collaborators").
- **Settings > Code security**: make sure Dependabot is enabled. `.github/dependabot.yml` opens weekly
  PRs that update the action versions in the workflows. Those PRs run only on GitHub-hosted runners.
- Keep branch protection on `master` (PR required).

## Rolling back

A failed deploy leaves the checkout at the new commit and prints the commits it contained. It
never resets automatically.

**CrowdSec WAF:** rolling it back and merging its PR both have a mandatory order; follow `REBUILD.md` §7 before reverting or running `docker compose up` from `master`.

**Normal path:** revert on `master` through a PR. Merging it deploys the revert.
```bash
git switch -c revert-<thing> origin/master
git revert --no-edit -m 1 <merge-commit>      # PR merge commits need -m 1
git push -u origin HEAD && gh pr create
```

**Emergency, by hand** (only tracked files are touched; `.env` and data are untracked):
```bash
cd /home/jalance/Projects/docker-services
git reset --hard <previous-good-sha>
docker compose up -d --build --remove-orphans
```
Then still revert on `master`. Otherwise the next deploy fast-forwards straight back to the bad
commit. Because your local `master` is behind `origin/master`, that fast-forward will succeed.

## Image upgrades

Deploys never pull images. Upgrade deliberately, on the host:
```bash
cd /home/jalance/Projects/docker-services
docker compose pull <service>        # or omit <service> for everything
docker compose up -d <service>
```
Exceptions: a service whose image isn't present locally (e.g. a newly added one) is pulled on
first `up`, and Plex (`VERSION=public`) updates itself whenever its container restarts.
Changing an image tag in `docker-compose.yml` through a PR is the reproducible way to upgrade:
the deploy pulls the new tag because it isn't present locally.

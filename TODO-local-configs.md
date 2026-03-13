# Fix SQLite-over-NFS Crashes

Sonarr and Radarr are experiencing recurring SQLite `disk I/O error` crashes because their
databases live on NFS. The fix is to move ALL service configs (~85GB) to local NVME storage
and rsync to Synology NAS every 4 hours.

> Detailed plan: `.claude/plans/typed-wondering-hennessy.md`

---

## Step 1: Create Feature Branch & Scripts

- [ ] Create feature branch (e.g. `migrate-configs-to-local`)
- [ ] Create `scripts/migrate-nfs-to-local.sh` — one-time rsync from NFS to local
- [ ] Create `scripts/backup-configs.sh` — recurring rsync from local to NFS (every 4 hours via cron)

## Step 2: Modify docker-compose.yml

- [ ] Remove 16 NFS config volume definitions (lines 29-108)
- [ ] Remove dead `traefik_acme_config` NFS volume definition
- [ ] Keep media NFS volumes (video, audiobooks, music, photo, ebooks, downloads)
- [ ] Switch all 15 services from named volumes to `$LOCALDOCKERDIR` bind mounts

## Step 3: Update env.example

- [ ] Clarify `LOCALDOCKERDIR` = local config storage (e.g. `/usr/local/docker`)
- [ ] Clarify `DOCKERDIR` = NFS mount, now backup destination only (e.g. `/mnt/docker`)

## Step 4: Migration Execution (requires downtime)

- [ ] `docker compose down`
- [ ] Create local directories under `$LOCALDOCKERDIR`
- [ ] Set ownership: `chown -R $PUID:$PGID $LOCALDOCKERDIR/`
- [ ] Run migration script (rsync NFS → local, ~85 GB)
- [ ] Deploy updated docker-compose.yml
- [ ] Remove old Docker named volumes
- [ ] `docker compose up -d`
- [ ] Verify each service has data intact
- [ ] Install host cron job for backup script

## Step 5: Update CLAUDE.md

- [ ] Update Storage Strategy section
- [ ] Update Adding New Services section to use `$LOCALDOCKERDIR` bind mounts
- [ ] Document backup script and cron schedule

## Verification

- [ ] Each service's web UI loads with data intact
- [ ] `scripts/validate-traefik.sh` passes
- [ ] NFS backup directories updating after first cron run
- [ ] No SQLite I/O errors after 24-48 hours

## Rollback

If something goes wrong: revert docker-compose.yml to NFS volumes — original NFS data is untouched.

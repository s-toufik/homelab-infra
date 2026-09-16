# PostgreSQL

PostgreSQL 17, tuned lightly for a 4 GiB container on a 32 GiB host (`shared_buffers=1GB`, `effective_cache_size=3GB`).

- Host access: `psql -h <server> -U $POSTGRES_USER -d $POSTGRES_DB`
- From containers: `postgresql://$POSTGRES_USER:$POSTGRES_PASSWORD@postgres:5432/$POSTGRES_DB`

## Backup / restore

```bash
# Backup (custom format, compressed)
docker exec postgres pg_dump -U homelab -Fc homelab > backups/homelab_$(date +%F).dump

# Restore
docker exec -i postgres pg_restore -U homelab -d homelab --clean < backups/homelab_2026-01-01.dump
```

## Notes

- Credentials are only applied on **first** initialisation of the volume. Changing `POSTGRES_PASSWORD` later requires `ALTER USER ... PASSWORD`.
- Major version upgrades (17 → 18) need `pg_upgrade` or dump/restore; do not just bump the tag. PostgreSQL 18 images also moved the data directory.
- Want metrics? Add `prometheuscommunity/postgres-exporter` and a scrape job.

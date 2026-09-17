# MongoDB

MongoDB standalone with root authentication (version pinned via `MONGO_TAG` in `.env`, currently `7.0`). WiredTiger cache is capped at 1 GiB so it doesn't compete with the rest of the stack (the default is 50% of RAM minus 1 GiB, i.e. it would believe it can use ~15 GiB).

- Host access: `mongosh "mongodb://$MONGO_ROOT_USER:$MONGO_ROOT_PASSWORD@<server>:27017/?authSource=admin"`
- From containers: `mongodb://$MONGO_ROOT_USER:$MONGO_ROOT_PASSWORD@mongodb:27017/?authSource=admin`

## Backup / restore

```bash
docker exec mongodb sh -c 'mongodump -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin --archive --gzip' > backups/mongo_$(date +%F).archive
docker exec -i mongodb sh -c 'mongorestore -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin --archive --gzip --drop' < backups/mongo_2026-01-01.archive
```

## Notes

- Root credentials are only applied on first init of the volume.
- Create a dedicated user per application instead of using root.
- Change streams / transactions need a replica set; convert with `--replSet rs0` + `rs.initiate()` if you need them.

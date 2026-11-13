# rds-to-k8s-migration

Moving relational databases from Amazon RDS to operators on Kubernetes,
under live writes, with a rollback that loses nothing and a restore drill
at the end. PostgreSQL goes to **CloudNativePG**, MySQL to **MOCO**.

Everything runs on a local kind cluster. The "RDS" instances are stand-ins
that only allow what RDS allows (no superuser, TLS required, RDS stored
procedures for the privileged operations), so the procedure is the one you
would run against the real thing. See [legacy/README.md](legacy/README.md).

## PostgreSQL: RDS -> CloudNativePG

```
legacy (RDS)  --publication to_k8s-->  orders-db (CNPG, 2 instances, backups to S3)
              <--publication to_legacy-- (after cutover, for rollback)
application -> orders-db.app.svc (one name; cutover repoints it)
```

| Step | Script | What it does |
|---|---|---|
| Preflight + publication | `migrate/postgres/10-prepare-source.sh` | `wal_level`, tables without a primary key, large objects, unlogged tables; publication for every table |
| Target | `migrate/postgres/15-create-target.sh` | CNPG cluster bootstrapped with the schema only (`pg_dump` through `initdb.import`), declarative `Subscription` for the data |
| Status | `migrate/postgres/20-status.sh` | per-table sync state, lag in bytes |
| Cutover | `migrate/postgres/30-cutover.sh` | freeze writes on legacy, wait for the slot to confirm the last LSN, copy sequences, compare checksums, start reverse replication, repoint the name |
| Rollback | `migrate/postgres/40-rollback.sh` | the same in the other direction |
| Finalize | `migrate/postgres/50-finalize.sh` | drop replication, first full backup |
| Restore drill | `migrate/postgres/60-restore-drill.sh` | checksums under a share lock + named restore point, recover a throwaway cluster to it, compare |

Details that bite in practice and are handled here:

- **Sequences are not replicated** by logical replication. Without the copy,
  the first insert after cutover fails on a duplicate key; the load
  generator inserts through the sequence to prove it.
- **Writes are frozen by revoking them from the application role**, not by
  stopping the database: RDS gives no superuser, and reads keep working.
  `pg_terminate_backend` only signals, so the cutover waits until every
  session that started before the revoke has exited before reading the LSN.
- **Checksums** compare `md5` over every row with a fixed collation, time
  zone and date style; the two sides use different default collations.
- **The rollback path exists before the switch**: forward subscription
  dropped, reverse subscription (`origin = none`) created, then the name is
  repointed. Writes made on the target during the soak flow back.
- **One backup archive per attempt**: a target rebuilt after a rollback must
  not archive into the previous one (the archive has to start empty).

## MySQL: RDS -> MOCO (in progress)

MOCO seeds a cluster with the clone plugin, which RDS does not offer, so the
data takes two hops with GTIDs preserved end to end:

```
legacy (RDS) --mysqldump --single-transaction + GTID replication (TLS)--> relay --clone + GTID replication--> appointments-db (MOCO, 3 instances)
```

Done and verified locally: the RDS stand-in with the master user's grants
and the `mysql.rds_*` procedures, preflight checks, loading the relay
without a global read lock and replicating from legacy over verified TLS.
Not finished yet: MOCO's clone from the relay, cutover, rollback through
`mysql.rds_set_external_source_with_auto_position`, and the backup/PITR
drill. The relay is created without GTIDs of its own so that RDS can
replicate back from MOCO during a rollback.

## Run it

```bash
make cluster platform legacy   # kind, operators, local S3, the two "RDS" instances
make postgres-test             # full PostgreSQL migration under load
make down
```

Needs Docker, kind, kubectl, helm. Pinned versions are in
[versions.env](versions.env). CI runs lint and the PostgreSQL end-to-end
test on every push.

## Not verified

Nothing here has run against a real RDS instance or EKS. The RDS
differences that matter (stored procedures instead of `SUPER`, no custom CA
file for an RDS-side subscription, `rds.logical_replication`) are written
into the scripts and the stand-ins, not tested on AWS.

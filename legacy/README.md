# legacy: the databases being migrated

Stand-ins for Amazon RDS for PostgreSQL and RDS for MySQL, running in the
`legacy` namespace. They are configured the way the RDS instances are, and,
more importantly, the migration only uses what RDS allows:

| | RDS | here |
|---|---|---|
| PostgreSQL admin | `rds_superuser`, never a real superuser | `master`: owns the schema, `CREATEROLE`, `REPLICATION`, `pg_create_subscription`; no `SUPERUSER` |
| Logical decoding | `rds.logical_replication = 1` | `wal_level = logical` |
| Replication user | member of `rds_replication` | `migrator`: `REPLICATION` + `SELECT` |
| TLS | `rds.force_ssl = 1` | `hostssl` only, certificate from cert-manager |
| MySQL admin | master user: no `SUPER`, no `FLUSH TABLES WITH READ LOCK`, no clone plugin | `admin` with the RDS master user's grants |
| Binlog | GTID mode on, row format, retention set with `mysql.rds_set_configuration` | `gtid_mode=ON`, `binlog_format=ROW`, 24 h retention |
| TLS | `require_secure_transport` parameter | `require_secure_transport=ON` |

The real superuser (`postgres`, MySQL `root`) exists only because the
container images need it to initialise; no migration script uses it. The
places where RDS needs a stored procedure instead of plain SQL are listed in
[docs/rds-differences.md](../docs/rds-differences.md).

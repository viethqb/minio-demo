# MinIO Pool Decommission Demo

Demonstrates how to **add a new server pool** to an existing MinIO cluster and
**decommission the old pool** — migrating all data with zero downtime.

## Architecture

```text
Phase 1 (initial)        Expand (transition)              Phase 2 (final)
┌──────────────────┐     ┌──────────────────────────┐     ┌──────────────────┐
│ Pool 1           │     │ Pool 1    │ Pool 2       │     │ Pool 2           │
│ minio{1..4}      │ ──► │ minio{1..4} minio{5..8}  │ ──► │ minio{5..8}      │
│ 4 nodes x 4 drv  │     │ 16 drv    │ 32 drv       │     │ 4 nodes x 8 drv  │
│ = 16 drives      │     │ = 48 drives total        │     │ = 32 drives      │
└──────────────────┘     └──────────────────────────┘     └──────────────────┘
                              ▲ decommission pool 1
```

## Files

| File | Description |
|---|---|
| `docker-compose.phase1.yml` | Pool 1 only — 4 nodes × 4 drives (16 drives) |
| `docker-compose.expand.yml` | Pool 1 + Pool 2 — 8 nodes total (48 drives). Used during expansion and decommission |
| `docker-compose.phase2.yml` | Pool 2 only — 4 nodes × 8 drives (32 drives). Final state after decommission |

## Prerequisites

- Docker and Docker Compose v2
- Ports 9000–9001 available on the host

## Step-by-Step Guide

### Step 1 — Start with Pool 1

```bash
docker compose -f docker-compose.phase1.yml up -d
```

Wait for all nodes to be healthy, then upload some test data:

```bash
docker exec -it mc /bin/sh
```

```bash
# Inside the mc container
mc mb myminio/test-bucket

# Upload sample files
for i in $(seq 1 100); do
  mc cp /etc/os-release myminio/test-bucket/file-$i.txt
done

mc ls myminio/test-bucket/ --summarize
```

Access the MinIO Console at <http://localhost:9001> (admin / password123).

### Step 2 — Expand: Add Pool 2

Shut down Pool 1, then bring up the expanded cluster with both pools:

```bash
docker compose -f docker-compose.phase1.yml down
docker compose -f docker-compose.expand.yml up -d
```

> **What changes:** All 8 nodes (minio1–minio8) now run the same server command
> that references **both** pools. MinIO recognizes the cluster has expanded.

Verify the two pools are visible:

```bash
docker exec -it mc mc admin info myminio
```

You should see **48 drives** total (16 from Pool 1 + 32 from Pool 2) and all
data from Step 1 is still accessible.

### Step 3 — Decommission Pool 1

Start the decommission process. MinIO will migrate all objects from Pool 1 to
Pool 2 in the background:

```bash
docker exec -it mc mc admin decommission start myminio http://minio{1...4}/data{1...4}
```

Monitor progress:

```bash
docker exec -it mc mc admin decommission status myminio
```

Example output during migration:

```text
┌──────┬──────────────────────────────────────┬──────────┬──────────┐
│ Pool │ Endpoint                             │ Capacity │ Status   │
├──────┼──────────────────────────────────────┼──────────┼──────────┤
│    1 │ http://minio{1...4}/data{1...4}      │  16 drv  │ Draining │
│    2 │ http://minio{5...8}/data{1...8}      │  32 drv  │ Active   │
└──────┴──────────────────────────────────────┴──────────┴──────────┘
```

Wait until Pool 1 status shows **`Complete`**.

### Step 4 — Remove Pool 1

Once decommission is complete, switch to Pool 2 only:

```bash
docker compose -f docker-compose.expand.yml down
docker compose -f docker-compose.phase2.yml up -d
```

Verify all data is intact:

```bash
docker exec -it mc mc ls myminio/test-bucket/ --summarize
```

The console is now available at <http://localhost:9001> (served by minio5).

### Cleanup

```bash
docker compose -f docker-compose.phase2.yml down

# Remove all data
rm -rf data/
```

## Key Concepts

- **Pool**: A set of nodes and drives added to a cluster at the same time. Each
  pool operates independently for erasure coding.
- **Decommission**: Gracefully drains a pool by migrating all objects to the
  remaining pools. Reads and writes continue during the process.
- **Server command**: When adding a new pool, **every node** in the cluster must
  be updated to include both pool endpoints in the `server` command. This is why
  the expand phase restarts the existing nodes.
- **Erasure coding**: Pool 1 uses EC:2 (4 nodes × 4 drives), Pool 2 uses EC:4
  (4 nodes × 8 drives). Pools can have different erasure set sizes.

## Network Layout

All nodes share a single Docker bridge network (`172.16.0.0/24`):

| Container | IP Address |
|---|---|
| minio1 | 172.16.0.11 |
| minio2 | 172.16.0.12 |
| minio3 | 172.16.0.13 |
| minio4 | 172.16.0.14 |
| minio5 | 172.16.0.15 |
| minio6 | 172.16.0.16 |
| minio7 | 172.16.0.17 |
| minio8 | 172.16.0.18 |

## Troubleshooting

**Decommission won't start**
- Ensure the target pool endpoint matches exactly:
  `http://minio{1...4}/data{1...4}` (use `...` not `..`)
- The destination pool must have enough free capacity to absorb all data

**Nodes fail to start after expansion**
- All nodes must use the **identical** `server` command with both pool endpoints
- All `MINIO_*` environment variables must be the same across all nodes

**Data not accessible after Phase 2**
- Decommission must show `Complete` before removing Pool 1 nodes
- If interrupted, restart the expand compose and resume decommission

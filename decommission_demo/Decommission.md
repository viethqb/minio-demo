# MinIO Decommission Feature

## What is Decommission?

Decommission allows you to gracefully remove an old pool from a cluster by
migrating all data to the remaining pools — with zero downtime.

---

## State Machine (Lifecycle)

```text
IDLE → START → RUNNING → COMPLETE
                  ↓
               FAILED ← (error)
                  ↓
              CANCEL / RESUME
```

Reference: `cmd/erasure-server-pool-decom.go:188-221`

| State | Description |
|---|---|
| Start | Marks the pool as suspended, begins migration |
| Running | Migrates objects bucket by bucket |
| Complete | All objects migrated, pool can be safely removed |
| Failed | Error during migration, can be resumed |
| Canceled | Manually canceled by admin |

---

## Constraints & Requirements

| Constraint | Details |
|---|---|
| Minimum 2 pools | Cannot decommission if only 1 pool exists |
| Cannot run alongside rebalance | Rebalance must finish before decommission can start |
| Remaining pools must have enough capacity | All data from the old pool must fit on the remaining pools |

---

## How Data Migration Works

**Regular objects** (`decom.go:673-697`):
Read object from old pool → PutObject to another pool (`DataMovement=true`)

**Multipart objects** (`decom.go:621-671`):

1. CreateMultipart on the destination pool
2. PutObjectPart for each part (preserving ETags)
3. CompleteMultipartUpload

**Delete markers** (`decom.go:860-901`):
Replicate delete markers to the new pool (preserving version IDs)

**Tiered objects** (data stored on a remote tier):
Only metadata is migrated — actual data remains on the tier

---

## Error Handling & Retry

| Mechanism | Details |
|---|---|
| Retry per object | 3 attempts per object (`decom.go:904`) |
| Skippable errors | Object already deleted, version doesn't exist, already migrated |
| List retry | Infinite retry with 0–5s jitter on listing errors |
| Resume after restart | Automatically resumes 3 minutes after MinIO restarts |
| Metadata saved every 30s | Progress is not lost on crash |

---

## Read/Write Behavior During Decommission

| Operation | Pool being decommissioned | Other pools |
|---|---|---|
| Read | Still readable (for objects not yet migrated) | Normal reads |
| New writes | Skipped — does not accept new writes | Receives all new writes |
| Delete | Works normally | Works normally |

**Zero downtime** — clients are not affected during the entire process.

---

## Concurrency & Performance

```bash
# Adjust worker count (default = 2 × number of erasure sets)
export _MINIO_DECOMMISSION_WORKERS=32
```

---

## Bucket Processing Order

As defined in `decom.go:1449-1476`:

1. **Config metadata** (internal configuration)
2. **Bucket metadata** (policies, lifecycle, replication rules)
3. **User buckets** (actual data)

---

## CLI Commands

```bash
# 1. Start decommissioning the old pool
mc admin decommission start myminio http://node{1...4}/data{1...4}

# 2. Check progress
mc admin decommission status myminio

# 3. Cancel if needed
mc admin decommission cancel myminio http://node{1...4}/data{1...4}

# 4. List all pools
mc admin decommission status myminio --list
```

---

## Practical Example

**Old pool:** 4 nodes × 4 drives × 500 GB = 8 TB raw (~6 TB usable, 90% full ≈ 5.4 TB data)
**New pool:** 4 nodes × 8 drives × 2500 GB = 80 TB raw (~60 TB usable)

### Execution Plan

```bash
# Step 1: Add the new pool (update server command on ALL nodes)
minio server http://node{1...4}/data{1...4} http://new-node{1...4}/data{1...8}

# Step 2: Wait for the cluster to stabilize — new writes automatically go to the new pool

# Step 3: Start decommissioning the old hardware
mc admin decommission start myminio http://node{1...4}/data{1...4}

# Step 4: Monitor progress (~5.4 TB to migrate)
mc admin decommission status myminio

# Step 5: Once complete → shut down the 4 old nodes, update the server command
minio server http://new-node{1...4}/data{1...8}
```

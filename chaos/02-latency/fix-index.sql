-- Failure drill 2 fix: the auto-assign query filters tickets by status and groups by assignee.
-- Without this index it sequential-scans the whole table (seed 200k rows to see it).
-- Run BEFORE: EXPLAIN ANALYZE <query from the trace>  -> Seq Scan on tickets
-- Run AFTER:  same EXPLAIN                              -> Index Only Scan
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_tickets_status_assignee
    ON tickets (status, assignee_id);

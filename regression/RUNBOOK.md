# Connector-driven regression runbook

Command intent: `Run WMS regression`.

Required order:

1. Project Lock
   - Confirm GitHub LIVE = `jemagno1030/warehouse-wms`.
   - Confirm GitHub TEST = `jemagno1030/IFTC-WMS-TEST-REGRESSION`.
   - Confirm Supabase LIVE = `sqpxgwhhfxojzblitnni`.
   - Confirm Supabase TEST = `gfswztynzocobxbtaitc`.
   - Any mismatch => ABORT. No SQL or writes.

2. GitHub read-only comparison
   - Compare parity-target files.
   - Allow only documented environment-specific differences.
   - Record current branch heads and file blob SHAs.

3. Supabase LIVE read-only baseline
   - Run `sql/01-readonly-regression-baseline.sql`.
   - Never write to LIVE during automated regression.

4. Supabase TEST read-only baseline
   - Run the same SQL.

5. Compare structural fingerprints
   - columns
   - constraints
   - indexes
   - triggers
   - policies
   - RLS state
   - public function count/body hash
   - critical protected function hashes
   - UOM variance trigger
   - function EXECUTE privilege counts

6. Integrity checks
   - checked orphan counts must be zero
   - active location locks should normally be zero before transactional TEST regression
   - report operational mode separately for LIVE and TEST

7. Result
   - PASS = no unexpected drift, no protected-hash mismatch, no checked orphans, project lock intact.
   - WARNING = known security/performance advisor findings or expected data-count differences.
   - FAIL = project mismatch, unexpected GitHub drift, schema drift, protected function mismatch, permission drift, missing trigger, or orphan rows.

8. Future TEST transactional suite
   - May run only after read-only baseline passes.
   - Never reuse LIVE identifiers or data as writable fixtures.
   - Must use clearly prefixed synthetic fixtures and clean up after itself.
   - LIVE stays read-only.

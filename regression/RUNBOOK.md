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

## AR-3 TEST-only operational regression

1. Project Lock: repository `jemagno1030/IFTC-WMS-TEST-REGRESSION`,
   Supabase project `gfswztynzocobxbtaitc`. Confirm connector identity before SQL.
2. GitHub parity and the existing LIVE/TEST read-only baseline must PASS.
   Compare the protected fingerprints in `AR3-SUITE-MANIFEST.json`.
3. TEST must be ACTIVE, have zero active locks, and exactly one active Owner.
   Run SQL 10 before the suites too; its complete shell/identity checks must PASS.
4. Run SQL 03 through 09 in order, each as a complete file in a single
   SQL-editor/connector connection. Use the privileged runner for preflight;
   each file resolves the Owner dynamically and switches locally to
   `authenticated` for operational RPCs.
5. Require every suite's `fail=0`, its expected total, and cumulative **85/85**.
   Missing output, a SQL error, a failed preflight, or any FAIL is a stop condition.
6. Run `sql/10-ar3-zero-residue-readonly.sql` with the privileged read-only runner.
7. Require zero residue and restoration of the entire expected baseline shell.
8. LIVE never gets transactional fixtures.
9. After releases, LIVE only gets the existing read-only regression/postcheck.
10. Manual smoke remains for camera, QR, printing/PDF, and visual/touch/modal
    presentation. See the manifest's `manual_only` list.

### Runner behavior and evidence

Each operational file has an outer `BEGIN; ... ROLLBACK;`. A scenario also
uses an exception subtransaction: assertions run against its own synthetic
fixtures, then the deliberate private exception rolls those fixtures back.
A temporary result row records success or the actual error. This keeps scenarios
independent while still exercising each required multi-step operational flow.

All ordinary fixture operations use application RPCs under the simulated Owner.
Physical-rack cases alone temporarily restore the original runner role to set
Administrative Pause inside the scenario rollback scope. No permanent database
objects are installed. Negative tests compare observable state before and after
the rejection, including correction/configuration reporting RPC output.

The cluster system identifier is an additional TEST-only guard. A rebuilt TEST
database may legitimately change it; stop and independently reverify the project
and baseline before reviewing an update to the manifest and suite guards.
Never bypass the guard or edit it merely to make a failed run continue.
Expiry fixtures use 2098/2099; stop and refresh the reviewed design before 2098.

Run complete files; never execute selected fragments. If a client stops on a
fatal error before the final rollback, issue `ROLLBACK;` in the same connection
and run SQL 10. Never commit an operational suite transaction. Do not reset
sequences: PostgreSQL sequences may advance despite rollback.

The 85/85 development results in `AR3-VALIDATED-RESULTS.md` are attributed to
the supplied connector-driven validation record dated 2026-09-23. They do not
claim execution of these packaged files. Independent post-PR connector review
and execution must PASS before merge. Do not merge as part of packaging.

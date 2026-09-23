# AR-3 validated scenario design

The supplied AR-3 packaging instructions report that the scenario design was
validated through connector-driven execution on **2026-09-23** in TEST.
The results below record that development evidence; they are not execution
results for the newly packaged SQL files.

| Suite | Result |
| --- | --- |
| AR-3.2 Put-away | 12/12 PASS |
| AR-3.3 Stock Transfer | 10/10 PASS |
| AR-3.4 Picking / SO / SO-0 | 9/9 PASS |
| AR-3.5 FEFO + Container Priority | 10/10 PASS |
| AR-3.6 Saved Pick Correction | 12/12 PASS |
| AR-3.7 UOM BREAK / REPACK | 15/15 PASS |
| AR-3.8 Physical Rack Safeguards | 17/17 PASS |
| TOTAL | **85/85 PASS** |

Reported zero-residue development verification: ACTIVE, 0 locks, 0 AR3
SKUs/stock/SOs/corrections/approvals/FEFO events/audit residue, 0 XR8 locations,
and all checked orphans zero. The expected restored shell and identities are
encoded in `sql/10-ar3-zero-residue-readonly.sql`.

The newly packaged SQL files have **not been executed during packaging**.
PR files still require independent post-PR connector review and execution PASS
before merge. Static validation is not a substitute for that execution.

## Packaging and execution boundaries

- Only `jemagno1030/IFTC-WMS-TEST-REGRESSION` is changed.
- Operational WMS code and database installers are unchanged.
- Each operational file runs inside an outer `BEGIN; ... ROLLBACK;`.
  Each scenario additionally rolls back its own fixtures on either PASS or FAIL.
  Temporary result rows survive that inner rollback so all scenarios can report.
- A PASS is recorded only after executable assertions succeed. Negative calls
  must return the expected SQLSTATE/message and leave the compared state unchanged.
- Fixture counts are captured before each scenario rollback. Final in-transaction
  counts are taken after all scenario rollbacks, before the outer rollback.
- Owner identity is resolved dynamically after requiring exactly one active Owner.
  Application operations run with `request.jwt.claim.sub` and local role
  `authenticated`. Correction and UOM-configuration assertions use reporting RPCs.
- Physical-rack cases set Administrative Pause only within their rollback-scoped
  fixture, using the original SQL runner role, then restore `authenticated`
  before calling the safeguard RPCs.
- Cluster identity, owner/location identities, the protected function fingerprint,
  ACTIVE mode, empty operational shell, and zero locks are fail-closed prerequisites.
  SQL 10 additionally verifies the complete expected shell and residue categories.
- PostgreSQL sequences may advance despite rollback. Development observed
  `wms_tx_seq_last=77`; this is informational only and must never be reset or gated.
- The 2098/2099 expiry fixtures require execution before 2098-01-01.
- Camera barcode scanning, QR camera scanning, actual QR/label printing,
  printer/PDF visual layout, mobile/touch visual layout, and modal/visual
  confirmation presentation remain manual-only.

Do not merge until independent connector review and execution PASS.

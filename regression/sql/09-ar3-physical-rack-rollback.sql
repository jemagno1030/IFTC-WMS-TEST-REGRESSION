-- AR-3.8 Physical Rack Safeguards: 17 scenarios.
-- TEST ONLY: jemagno1030/IFTC-WMS-TEST-REGRESSION
-- Supabase project: gfswztynzocobxbtaitc
-- Packaging only: these exact files still require independent execution/review.
-- Each scenario rolls back its own fixtures using a caught private exception.
-- Result rows survive the scenario subtransaction; final ROLLBACK removes them.
-- No database objects are installed. Sequence gaps are expected; never reset them.

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '120s';
-- Execute the entire file in ONE connection as the SQL-editor/connector runner.
-- Never select and execute just a scenario. External Project Lock and baseline
-- comparisons in RUNBOOK.md are mandatory. Cluster identity is an additional
-- fail-closed guard, not a substitute for verifying the connector project.
DO $preflight$
DECLARE owner_id uuid;
BEGIN
IF ((SELECT system_identifier::text FROM pg_control_system())='7678069749886157684') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: TEST database cluster identity'; END IF;

IF (pg_try_advisory_xact_lock(830320260923::bigint)) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: another AR3 suite is running'; END IF;

IF ((SELECT operational_mode FROM public.app_settings WHERE id=1)='ACTIVE') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: TEST must be ACTIVE'; END IF;

IF (NOT EXISTS(SELECT 1 FROM public.location_locks WHERE expires_at>now())) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: zero active locks required'; END IF;

IF ((SELECT count(*) FROM public.profiles WHERE lower(role)='owner' AND is_active)=1) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: exactly one active Owner'; END IF;

IF ((SELECT md5(coalesce(string_agg(id::text,E'\n' ORDER BY id::text),'')) FROM public.profiles WHERE lower(role)='owner')='8efe2f577bc98e25a9837ef275c7ae1a') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: TEST owner identity'; END IF;

IF ((SELECT md5(coalesce(string_agg(
id::text||'|'||coalesce(code,'')||'|'||coalesce(display_name,'')||'|'||
coalesce(zone,'')||'|'||coalesce(row_label,'')||'|'||coalesce(bay_label,'')||'|'||
coalesce(level_label,'')||'|'||coalesce(sort_order::text,'')||'|'||
coalesce(is_pending::text,'')||'|'||coalesce(is_active::text,''),
E'\n' ORDER BY id::text),'')) FROM public.locations)='13e82ec85bae291a5c61fd8fff41abf8') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: TEST location identity'; END IF;

IF ((SELECT md5(coalesce(string_agg(
p.proname||'('||pg_get_function_identity_arguments(p.oid)||')|'||pg_get_functiondef(p.oid),
E'\n' ORDER BY p.proname,pg_get_function_identity_arguments(p.oid)),'')) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public')='8a82ab6596d917ce41b94cc10a1f60ab') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: protected function-body fingerprint'; END IF;

IF (NOT EXISTS(SELECT 1 FROM public.skus) AND NOT EXISTS(SELECT 1 FROM public.stock_lots) AND NOT EXISTS(SELECT 1 FROM public.pick_sales_orders)) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: empty TEST operational shell required'; END IF;

IF (NOT EXISTS(SELECT 1 FROM public.locations WHERE code LIKE 'XR8%')) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: fixture rack prefix must be unused'; END IF;

IF current_date >= DATE '2098-01-01' THEN RAISE EXCEPTION 'AR3 expiry fixture horizon exceeded'; END IF;
SELECT id INTO STRICT owner_id FROM public.profiles WHERE lower(role)='owner' AND is_active;
PERFORM set_config('request.jwt.claim.sub',owner_id::text,true);
PERFORM set_config('request.jwt.claim.role','authenticated',true);
PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',owner_id,'role','authenticated')::text,true);
END;
$preflight$;
SET LOCAL ROLE authenticated;
CREATE TEMP TABLE ar3_results (
  test_no integer PRIMARY KEY, test_id text NOT NULL, scenario text NOT NULL,
  passed boolean NOT NULL, detail text NOT NULL, in_tx_fixture_counts jsonb
) ON COMMIT DROP;

-- R01: Rack addition normalizes case and metadata
DO $scenario$
DECLARE
  a uuid; b uuid; c uuid; d uuid; sku uuid; lot uuid; token uuid;
  tx uuid; corr uuid; line uuid;
  r record; item jsonb; rows_json jsonb;
  before_state jsonb; after_state jsonb; counts_json jsonb;
  so text; session_key text; old_key text; rack_code text; status_text text;
  rel text; err text; err_code text; n numeric; flag boolean;
  scenario_ok boolean := false;
BEGIN
  BEGIN
a:=public.add_location('xr801'); b:=public.add_location('XR802');
IF (EXISTS(SELECT 1 FROM public.locations WHERE id=a AND code='XR801' AND row_label='XR' AND bay_label='801' AND display_name='Rack XR801' AND is_active AND NOT is_pending)) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: rack metadata'; END IF;
IF (EXISTS (SELECT 1 FROM public.audit_log WHERE action='ADD_LOCATION' AND entity_id=a::text)) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: audit ADD_LOCATION'; END IF;
IF (EXISTS (SELECT 1 FROM public.audit_log WHERE action='ADD_LOCATION' AND entity_id=b::text)) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: audit ADD_LOCATION'; END IF;

    counts_json := jsonb_build_object(
  'skus',(SELECT count(*) FROM public.skus WHERE brand LIKE 'AR3%'),
  'stock_lots',(SELECT count(*) FROM public.stock_lots s JOIN public.skus k ON k.id=s.sku_id WHERE k.brand LIKE 'AR3%'),
  'rack_rows',(SELECT count(*) FROM public.locations WHERE code LIKE 'XR8%'),
  'sales_orders',(SELECT count(*) FROM public.pick_sales_orders),
  'transactions',(SELECT count(*) FROM public.transactions),
  'active_locks',(SELECT count(*) FROM public.location_locks WHERE expires_at>now()),
  'operational_mode',(SELECT operational_mode FROM public.app_settings WHERE id=1));
    scenario_ok := true;
    -- A deliberate exception rolls successful fixture writes back as well.
    RAISE EXCEPTION USING ERRCODE='ZAR03', MESSAGE='AR3 scenario complete';
  EXCEPTION
    WHEN SQLSTATE 'ZAR03' THEN
      INSERT INTO pg_temp.ar3_results VALUES (1,'R01','Rack addition normalizes case and metadata',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (1,'R01','Rack addition normalizes case and metadata',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

-- R02: Invalid rack code
DO $scenario$
DECLARE
  a uuid; b uuid; c uuid; d uuid; sku uuid; lot uuid; token uuid;
  tx uuid; corr uuid; line uuid;
  r record; item jsonb; rows_json jsonb;
  before_state jsonb; after_state jsonb; counts_json jsonb;
  so text; session_key text; old_key text; rack_code text; status_text text;
  rel text; err text; err_code text; n numeric; flag boolean;
  scenario_ok boolean := false;
BEGIN
  BEGIN

before_state := '{}'::jsonb;
FOREACH rel IN ARRAY ARRAY['app_settings','skus','stock_lots','locations','transactions','transaction_lines','transaction_line_user_remarks','transaction_user_remarks','location_locks','pick_sales_orders','audit_log','fefo_override_events','inventory_lot_remark_overrides'] LOOP
  EXECUTE format('SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text), ''[]''::jsonb) FROM public.%I t',rel) INTO rows_json;
  before_state := before_state || jsonb_build_object(rel,rows_json);
END LOOP;
SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb)
INTO rows_json FROM public.pick_sales_orders s
CROSS JOIN LATERAL public.get_saved_pick_corrections(s.sales_order) x
WHERE s.sales_order LIKE 'AR3%';
before_state := before_state || jsonb_build_object('correction_reports',rows_json);
SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb)
INTO rows_json FROM public.skus s
CROSS JOIN LATERAL public.get_sku_uom_conversion_config_v1(s.id) x
WHERE s.brand LIKE 'AR3%';
before_state := before_state || jsonb_build_object('uom_config_reports',rows_json);

err := NULL; err_code := NULL;
BEGIN
PERFORM public.add_location('XR8-BAD');
EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS err = MESSAGE_TEXT, err_code = RETURNED_SQLSTATE;
END;
IF (err IS NOT NULL) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: negative call must reject'; END IF;
IF (err_code='P0001') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected SQLSTATE P0001'; END IF;
IF (err='PHYSICAL_RACK_CODE_FORMAT: Use letters followed by a positive number, for example A1, C97, or L12.') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected rejection: PHYSICAL_RACK_CODE_FORMAT: Use letters followed by a positive number, for example A1, C97, or L12.'; END IF;

after_state := '{}'::jsonb;
FOREACH rel IN ARRAY ARRAY['app_settings','skus','stock_lots','locations','transactions','transaction_lines','transaction_line_user_remarks','transaction_user_remarks','location_locks','pick_sales_orders','audit_log','fefo_override_events','inventory_lot_remark_overrides'] LOOP
  EXECUTE format('SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text), ''[]''::jsonb) FROM public.%I t',rel) INTO rows_json;
  after_state := after_state || jsonb_build_object(rel,rows_json);
END LOOP;
SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb)
INTO rows_json FROM public.pick_sales_orders s
CROSS JOIN LATERAL public.get_saved_pick_corrections(s.sales_order) x
WHERE s.sales_order LIKE 'AR3%';
after_state := after_state || jsonb_build_object('correction_reports',rows_json);
SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb)
INTO rows_json FROM public.skus s
CROSS JOIN LATERAL public.get_sku_uom_conversion_config_v1(s.id) x
WHERE s.brand LIKE 'AR3%';
after_state := after_state || jsonb_build_object('uom_config_reports',rows_json);
IF (before_state=after_state) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: rejected operation leaves observable state unchanged'; END IF;

    counts_json := jsonb_build_object(
  'skus',(SELECT count(*) FROM public.skus WHERE brand LIKE 'AR3%'),
  'stock_lots',(SELECT count(*) FROM public.stock_lots s JOIN public.skus k ON k.id=s.sku_id WHERE k.brand LIKE 'AR3%'),
  'rack_rows',(SELECT count(*) FROM public.locations WHERE code LIKE 'XR8%'),
  'sales_orders',(SELECT count(*) FROM public.pick_sales_orders),
  'transactions',(SELECT count(*) FROM public.transactions),
  'active_locks',(SELECT count(*) FROM public.location_locks WHERE expires_at>now()),
  'operational_mode',(SELECT operational_mode FROM public.app_settings WHERE id=1));
    scenario_ok := true;
    -- A deliberate exception rolls successful fixture writes back as well.
    RAISE EXCEPTION USING ERRCODE='ZAR03', MESSAGE='AR3 scenario complete';
  EXCEPTION
    WHEN SQLSTATE 'ZAR03' THEN
      INSERT INTO pg_temp.ar3_results VALUES (2,'R02','Invalid rack code',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (2,'R02','Invalid rack code',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

-- R03: Rename requires pause
DO $scenario$
DECLARE
  a uuid; b uuid; c uuid; d uuid; sku uuid; lot uuid; token uuid;
  tx uuid; corr uuid; line uuid;
  r record; item jsonb; rows_json jsonb;
  before_state jsonb; after_state jsonb; counts_json jsonb;
  so text; session_key text; old_key text; rack_code text; status_text text;
  rel text; err text; err_code text; n numeric; flag boolean;
  scenario_ok boolean := false;
BEGIN
  BEGIN
a:=public.add_location('xr801'); b:=public.add_location('XR802');

before_state := '{}'::jsonb;
FOREACH rel IN ARRAY ARRAY['app_settings','skus','stock_lots','locations','transactions','transaction_lines','transaction_line_user_remarks','transaction_user_remarks','location_locks','pick_sales_orders','audit_log','fefo_override_events','inventory_lot_remark_overrides'] LOOP
  EXECUTE format('SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text), ''[]''::jsonb) FROM public.%I t',rel) INTO rows_json;
  before_state := before_state || jsonb_build_object(rel,rows_json);
END LOOP;
SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb)
INTO rows_json FROM public.pick_sales_orders s
CROSS JOIN LATERAL public.get_saved_pick_corrections(s.sales_order) x
WHERE s.sales_order LIKE 'AR3%';
before_state := before_state || jsonb_build_object('correction_reports',rows_json);
SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb)
INTO rows_json FROM public.skus s
CROSS JOIN LATERAL public.get_sku_uom_conversion_config_v1(s.id) x
WHERE s.brand LIKE 'AR3%';
before_state := before_state || jsonb_build_object('uom_config_reports',rows_json);

err := NULL; err_code := NULL;
BEGIN
PERFORM public.owner_rename_physical_location_v1(a,'XR811',NULL,'AR3 rename');

EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS err = MESSAGE_TEXT, err_code = RETURNED_SQLSTATE;
END;
IF (err IS NOT NULL) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: negative call must reject'; END IF;
IF (err_code='P0001') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected SQLSTATE P0001'; END IF;
IF (err='LOCATION_MAINTENANCE_PAUSE_REQUIRED: Activate Administrative Pause before renaming a physical rack.') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected rejection: LOCATION_MAINTENANCE_PAUSE_REQUIRED: Activate Administrative Pause before renaming a physical rack.'; END IF;

after_state := '{}'::jsonb;
FOREACH rel IN ARRAY ARRAY['app_settings','skus','stock_lots','locations','transactions','transaction_lines','transaction_line_user_remarks','transaction_user_remarks','location_locks','pick_sales_orders','audit_log','fefo_override_events','inventory_lot_remark_overrides'] LOOP
  EXECUTE format('SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text), ''[]''::jsonb) FROM public.%I t',rel) INTO rows_json;
  after_state := after_state || jsonb_build_object(rel,rows_json);
END LOOP;
SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb)
INTO rows_json FROM public.pick_sales_orders s
CROSS JOIN LATERAL public.get_saved_pick_corrections(s.sales_order) x
WHERE s.sales_order LIKE 'AR3%';
after_state := after_state || jsonb_build_object('correction_reports',rows_json);
SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb)
INTO rows_json FROM public.skus s
CROSS JOIN LATERAL public.get_sku_uom_conversion_config_v1(s.id) x
WHERE s.brand LIKE 'AR3%';
after_state := after_state || jsonb_build_object('uom_config_reports',rows_json);
IF (before_state=after_state) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: rejected operation leaves observable state unchanged'; END IF;

    counts_json := jsonb_build_object(
  'skus',(SELECT count(*) FROM public.skus WHERE brand LIKE 'AR3%'),
  'stock_lots',(SELECT count(*) FROM public.stock_lots s JOIN public.skus k ON k.id=s.sku_id WHERE k.brand LIKE 'AR3%'),
  'rack_rows',(SELECT count(*) FROM public.locations WHERE code LIKE 'XR8%'),
  'sales_orders',(SELECT count(*) FROM public.pick_sales_orders),
  'transactions',(SELECT count(*) FROM public.transactions),
  'active_locks',(SELECT count(*) FROM public.location_locks WHERE expires_at>now()),
  'operational_mode',(SELECT operational_mode FROM public.app_settings WHERE id=1));
    scenario_ok := true;
    -- A deliberate exception rolls successful fixture writes back as well.
    RAISE EXCEPTION USING ERRCODE='ZAR03', MESSAGE='AR3 scenario complete';
  EXCEPTION
    WHEN SQLSTATE 'ZAR03' THEN
      INSERT INTO pg_temp.ar3_results VALUES (3,'R03','Rename requires pause',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (3,'R03','Rename requires pause',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

-- R04: Delete requires pause
DO $scenario$
DECLARE
  a uuid; b uuid; c uuid; d uuid; sku uuid; lot uuid; token uuid;
  tx uuid; corr uuid; line uuid;
  r record; item jsonb; rows_json jsonb;
  before_state jsonb; after_state jsonb; counts_json jsonb;
  so text; session_key text; old_key text; rack_code text; status_text text;
  rel text; err text; err_code text; n numeric; flag boolean;
  scenario_ok boolean := false;
BEGIN
  BEGIN
a:=public.add_location('xr801'); b:=public.add_location('XR802');

before_state := '{}'::jsonb;
FOREACH rel IN ARRAY ARRAY['app_settings','skus','stock_lots','locations','transactions','transaction_lines','transaction_line_user_remarks','transaction_user_remarks','location_locks','pick_sales_orders','audit_log','fefo_override_events','inventory_lot_remark_overrides'] LOOP
  EXECUTE format('SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text), ''[]''::jsonb) FROM public.%I t',rel) INTO rows_json;
  before_state := before_state || jsonb_build_object(rel,rows_json);
END LOOP;
SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb)
INTO rows_json FROM public.pick_sales_orders s
CROSS JOIN LATERAL public.get_saved_pick_corrections(s.sales_order) x
WHERE s.sales_order LIKE 'AR3%';
before_state := before_state || jsonb_build_object('correction_reports',rows_json);
SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb)
INTO rows_json FROM public.skus s
CROSS JOIN LATERAL public.get_sku_uom_conversion_config_v1(s.id) x
WHERE s.brand LIKE 'AR3%';
before_state := before_state || jsonb_build_object('uom_config_reports',rows_json);

err := NULL; err_code := NULL;
BEGIN
PERFORM public.owner_delete_physical_location_v1(a,'AR3 delete');

EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS err = MESSAGE_TEXT, err_code = RETURNED_SQLSTATE;
END;
IF (err IS NOT NULL) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: negative call must reject'; END IF;
IF (err_code='P0001') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected SQLSTATE P0001'; END IF;
IF (err='LOCATION_MAINTENANCE_PAUSE_REQUIRED: Activate Administrative Pause before deleting a physical rack.') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected rejection: LOCATION_MAINTENANCE_PAUSE_REQUIRED: Activate Administrative Pause before deleting a physical rack.'; END IF;

after_state := '{}'::jsonb;
FOREACH rel IN ARRAY ARRAY['app_settings','skus','stock_lots','locations','transactions','transaction_lines','transaction_line_user_remarks','transaction_user_remarks','location_locks','pick_sales_orders','audit_log','fefo_override_events','inventory_lot_remark_overrides'] LOOP
  EXECUTE format('SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text), ''[]''::jsonb) FROM public.%I t',rel) INTO rows_json;
  after_state := after_state || jsonb_build_object(rel,rows_json);
END LOOP;
SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb)
INTO rows_json FROM public.pick_sales_orders s
CROSS JOIN LATERAL public.get_saved_pick_corrections(s.sales_order) x
WHERE s.sales_order LIKE 'AR3%';
after_state := after_state || jsonb_build_object('correction_reports',rows_json);
SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb)
INTO rows_json FROM public.skus s
CROSS JOIN LATERAL public.get_sku_uom_conversion_config_v1(s.id) x
WHERE s.brand LIKE 'AR3%';
after_state := after_state || jsonb_build_object('uom_config_reports',rows_json);
IF (before_state=after_state) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: rejected operation leaves observable state unchanged'; END IF;

    counts_json := jsonb_build_object(
  'skus',(SELECT count(*) FROM public.skus WHERE brand LIKE 'AR3%'),
  'stock_lots',(SELECT count(*) FROM public.stock_lots s JOIN public.skus k ON k.id=s.sku_id WHERE k.brand LIKE 'AR3%'),
  'rack_rows',(SELECT count(*) FROM public.locations WHERE code LIKE 'XR8%'),
  'sales_orders',(SELECT count(*) FROM public.pick_sales_orders),
  'transactions',(SELECT count(*) FROM public.transactions),
  'active_locks',(SELECT count(*) FROM public.location_locks WHERE expires_at>now()),
  'operational_mode',(SELECT operational_mode FROM public.app_settings WHERE id=1));
    scenario_ok := true;
    -- A deliberate exception rolls successful fixture writes back as well.
    RAISE EXCEPTION USING ERRCODE='ZAR03', MESSAGE='AR3 scenario complete';
  EXCEPTION
    WHEN SQLSTATE 'ZAR03' THEN
      INSERT INTO pg_temp.ar3_results VALUES (4,'R04','Delete requires pause',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (4,'R04','Delete requires pause',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

-- R05: Reactivate requires pause
DO $scenario$
DECLARE
  a uuid; b uuid; c uuid; d uuid; sku uuid; lot uuid; token uuid;
  tx uuid; corr uuid; line uuid;
  r record; item jsonb; rows_json jsonb;
  before_state jsonb; after_state jsonb; counts_json jsonb;
  so text; session_key text; old_key text; rack_code text; status_text text;
  rel text; err text; err_code text; n numeric; flag boolean;
  scenario_ok boolean := false;
BEGIN
  BEGIN
SELECT id INTO STRICT a FROM public.locations WHERE NOT is_active AND NOT is_pending ORDER BY code LIMIT 1;

before_state := '{}'::jsonb;
FOREACH rel IN ARRAY ARRAY['app_settings','skus','stock_lots','locations','transactions','transaction_lines','transaction_line_user_remarks','transaction_user_remarks','location_locks','pick_sales_orders','audit_log','fefo_override_events','inventory_lot_remark_overrides'] LOOP
  EXECUTE format('SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text), ''[]''::jsonb) FROM public.%I t',rel) INTO rows_json;
  before_state := before_state || jsonb_build_object(rel,rows_json);
END LOOP;
SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb)
INTO rows_json FROM public.pick_sales_orders s
CROSS JOIN LATERAL public.get_saved_pick_corrections(s.sales_order) x
WHERE s.sales_order LIKE 'AR3%';
before_state := before_state || jsonb_build_object('correction_reports',rows_json);
SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb)
INTO rows_json FROM public.skus s
CROSS JOIN LATERAL public.get_sku_uom_conversion_config_v1(s.id) x
WHERE s.brand LIKE 'AR3%';
before_state := before_state || jsonb_build_object('uom_config_reports',rows_json);

err := NULL; err_code := NULL;
BEGIN
PERFORM public.owner_reactivate_physical_location_v1(a,'AR3 reactivate');

EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS err = MESSAGE_TEXT, err_code = RETURNED_SQLSTATE;
END;
IF (err IS NOT NULL) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: negative call must reject'; END IF;
IF (err_code='P0001') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected SQLSTATE P0001'; END IF;
IF (err='LOCATION_MAINTENANCE_PAUSE_REQUIRED: Activate Administrative Pause before reactivating a physical rack.') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected rejection: LOCATION_MAINTENANCE_PAUSE_REQUIRED: Activate Administrative Pause before reactivating a physical rack.'; END IF;

after_state := '{}'::jsonb;
FOREACH rel IN ARRAY ARRAY['app_settings','skus','stock_lots','locations','transactions','transaction_lines','transaction_line_user_remarks','transaction_user_remarks','location_locks','pick_sales_orders','audit_log','fefo_override_events','inventory_lot_remark_overrides'] LOOP
  EXECUTE format('SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text), ''[]''::jsonb) FROM public.%I t',rel) INTO rows_json;
  after_state := after_state || jsonb_build_object(rel,rows_json);
END LOOP;
SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb)
INTO rows_json FROM public.pick_sales_orders s
CROSS JOIN LATERAL public.get_saved_pick_corrections(s.sales_order) x
WHERE s.sales_order LIKE 'AR3%';
after_state := after_state || jsonb_build_object('correction_reports',rows_json);
SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb)
INTO rows_json FROM public.skus s
CROSS JOIN LATERAL public.get_sku_uom_conversion_config_v1(s.id) x
WHERE s.brand LIKE 'AR3%';
after_state := after_state || jsonb_build_object('uom_config_reports',rows_json);
IF (before_state=after_state) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: rejected operation leaves observable state unchanged'; END IF;

    counts_json := jsonb_build_object(
  'skus',(SELECT count(*) FROM public.skus WHERE brand LIKE 'AR3%'),
  'stock_lots',(SELECT count(*) FROM public.stock_lots s JOIN public.skus k ON k.id=s.sku_id WHERE k.brand LIKE 'AR3%'),
  'rack_rows',(SELECT count(*) FROM public.locations WHERE code LIKE 'XR8%'),
  'sales_orders',(SELECT count(*) FROM public.pick_sales_orders),
  'transactions',(SELECT count(*) FROM public.transactions),
  'active_locks',(SELECT count(*) FROM public.location_locks WHERE expires_at>now()),
  'operational_mode',(SELECT operational_mode FROM public.app_settings WHERE id=1));
    scenario_ok := true;
    -- A deliberate exception rolls successful fixture writes back as well.
    RAISE EXCEPTION USING ERRCODE='ZAR03', MESSAGE='AR3 scenario complete';
  EXCEPTION
    WHEN SQLSTATE 'ZAR03' THEN
      INSERT INTO pg_temp.ar3_results VALUES (5,'R05','Reactivate requires pause',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (5,'R05','Reactivate requires pause',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

-- R06: Locked rack rename blocked
DO $scenario$
DECLARE
  a uuid; b uuid; c uuid; d uuid; sku uuid; lot uuid; token uuid;
  tx uuid; corr uuid; line uuid;
  r record; item jsonb; rows_json jsonb;
  before_state jsonb; after_state jsonb; counts_json jsonb;
  so text; session_key text; old_key text; rack_code text; status_text text;
  rel text; err text; err_code text; n numeric; flag boolean;
  scenario_ok boolean := false;
BEGIN
  BEGIN
a:=public.add_location('xr801'); b:=public.add_location('XR802');
SELECT x.lock_token INTO STRICT token FROM public.acquire_location_lock('XR801','TRANSFER',NULL) x;
-- Harness-only mode fixture; runner authority is restored only for this rollback-scoped setting.
SET LOCAL ROLE NONE;
UPDATE public.app_settings SET operational_mode='ADMINISTRATIVE_PAUSE' WHERE id=1;
SET LOCAL ROLE authenticated;

before_state := '{}'::jsonb;
FOREACH rel IN ARRAY ARRAY['app_settings','skus','stock_lots','locations','transactions','transaction_lines','transaction_line_user_remarks','transaction_user_remarks','location_locks','pick_sales_orders','audit_log','fefo_override_events','inventory_lot_remark_overrides'] LOOP
  EXECUTE format('SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text), ''[]''::jsonb) FROM public.%I t',rel) INTO rows_json;
  before_state := before_state || jsonb_build_object(rel,rows_json);
END LOOP;
SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb)
INTO rows_json FROM public.pick_sales_orders s
CROSS JOIN LATERAL public.get_saved_pick_corrections(s.sales_order) x
WHERE s.sales_order LIKE 'AR3%';
before_state := before_state || jsonb_build_object('correction_reports',rows_json);
SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb)
INTO rows_json FROM public.skus s
CROSS JOIN LATERAL public.get_sku_uom_conversion_config_v1(s.id) x
WHERE s.brand LIKE 'AR3%';
before_state := before_state || jsonb_build_object('uom_config_reports',rows_json);

err := NULL; err_code := NULL;
BEGIN
PERFORM public.owner_rename_physical_location_v1(a,'XR811',NULL,'AR3 rename');

EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS err = MESSAGE_TEXT, err_code = RETURNED_SQLSTATE;
END;
IF (err IS NOT NULL) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: negative call must reject'; END IF;
IF (err_code='P0001') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected SQLSTATE P0001'; END IF;
IF (err='LOCATION_IN_USE: This physical rack still has an active warehouse-operation lock. Cancel the rack session or wait for the lock to expire.') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected rejection: LOCATION_IN_USE: This physical rack still has an active warehouse-operation lock. Cancel the rack session or wait for the lock to expire.'; END IF;

after_state := '{}'::jsonb;
FOREACH rel IN ARRAY ARRAY['app_settings','skus','stock_lots','locations','transactions','transaction_lines','transaction_line_user_remarks','transaction_user_remarks','location_locks','pick_sales_orders','audit_log','fefo_override_events','inventory_lot_remark_overrides'] LOOP
  EXECUTE format('SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text), ''[]''::jsonb) FROM public.%I t',rel) INTO rows_json;
  after_state := after_state || jsonb_build_object(rel,rows_json);
END LOOP;
SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb)
INTO rows_json FROM public.pick_sales_orders s
CROSS JOIN LATERAL public.get_saved_pick_corrections(s.sales_order) x
WHERE s.sales_order LIKE 'AR3%';
after_state := after_state || jsonb_build_object('correction_reports',rows_json);
SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb)
INTO rows_json FROM public.skus s
CROSS JOIN LATERAL public.get_sku_uom_conversion_config_v1(s.id) x
WHERE s.brand LIKE 'AR3%';
after_state := after_state || jsonb_build_object('uom_config_reports',rows_json);
IF (before_state=after_state) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: rejected operation leaves observable state unchanged'; END IF;

    counts_json := jsonb_build_object(
  'skus',(SELECT count(*) FROM public.skus WHERE brand LIKE 'AR3%'),
  'stock_lots',(SELECT count(*) FROM public.stock_lots s JOIN public.skus k ON k.id=s.sku_id WHERE k.brand LIKE 'AR3%'),
  'rack_rows',(SELECT count(*) FROM public.locations WHERE code LIKE 'XR8%'),
  'sales_orders',(SELECT count(*) FROM public.pick_sales_orders),
  'transactions',(SELECT count(*) FROM public.transactions),
  'active_locks',(SELECT count(*) FROM public.location_locks WHERE expires_at>now()),
  'operational_mode',(SELECT operational_mode FROM public.app_settings WHERE id=1));
    scenario_ok := true;
    -- A deliberate exception rolls successful fixture writes back as well.
    RAISE EXCEPTION USING ERRCODE='ZAR03', MESSAGE='AR3 scenario complete';
  EXCEPTION
    WHEN SQLSTATE 'ZAR03' THEN
      INSERT INTO pg_temp.ar3_results VALUES (6,'R06','Locked rack rename blocked',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (6,'R06','Locked rack rename blocked',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

-- R07: Locked rack deletion blocked
DO $scenario$
DECLARE
  a uuid; b uuid; c uuid; d uuid; sku uuid; lot uuid; token uuid;
  tx uuid; corr uuid; line uuid;
  r record; item jsonb; rows_json jsonb;
  before_state jsonb; after_state jsonb; counts_json jsonb;
  so text; session_key text; old_key text; rack_code text; status_text text;
  rel text; err text; err_code text; n numeric; flag boolean;
  scenario_ok boolean := false;
BEGIN
  BEGIN
a:=public.add_location('xr801'); b:=public.add_location('XR802');
SELECT x.lock_token INTO STRICT token FROM public.acquire_location_lock('XR801','TRANSFER',NULL) x;
-- Harness-only mode fixture; runner authority is restored only for this rollback-scoped setting.
SET LOCAL ROLE NONE;
UPDATE public.app_settings SET operational_mode='ADMINISTRATIVE_PAUSE' WHERE id=1;
SET LOCAL ROLE authenticated;

before_state := '{}'::jsonb;
FOREACH rel IN ARRAY ARRAY['app_settings','skus','stock_lots','locations','transactions','transaction_lines','transaction_line_user_remarks','transaction_user_remarks','location_locks','pick_sales_orders','audit_log','fefo_override_events','inventory_lot_remark_overrides'] LOOP
  EXECUTE format('SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text), ''[]''::jsonb) FROM public.%I t',rel) INTO rows_json;
  before_state := before_state || jsonb_build_object(rel,rows_json);
END LOOP;
SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb)
INTO rows_json FROM public.pick_sales_orders s
CROSS JOIN LATERAL public.get_saved_pick_corrections(s.sales_order) x
WHERE s.sales_order LIKE 'AR3%';
before_state := before_state || jsonb_build_object('correction_reports',rows_json);
SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb)
INTO rows_json FROM public.skus s
CROSS JOIN LATERAL public.get_sku_uom_conversion_config_v1(s.id) x
WHERE s.brand LIKE 'AR3%';
before_state := before_state || jsonb_build_object('uom_config_reports',rows_json);

err := NULL; err_code := NULL;
BEGIN
PERFORM public.owner_delete_physical_location_v1(a,'AR3 delete');

EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS err = MESSAGE_TEXT, err_code = RETURNED_SQLSTATE;
END;
IF (err IS NOT NULL) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: negative call must reject'; END IF;
IF (err_code='P0001') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected SQLSTATE P0001'; END IF;
IF (err='LOCATION_IN_USE: This physical rack still has an active warehouse-operation lock. Cancel the rack session or wait for the lock to expire.') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected rejection: LOCATION_IN_USE: This physical rack still has an active warehouse-operation lock. Cancel the rack session or wait for the lock to expire.'; END IF;

after_state := '{}'::jsonb;
FOREACH rel IN ARRAY ARRAY['app_settings','skus','stock_lots','locations','transactions','transaction_lines','transaction_line_user_remarks','transaction_user_remarks','location_locks','pick_sales_orders','audit_log','fefo_override_events','inventory_lot_remark_overrides'] LOOP
  EXECUTE format('SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text), ''[]''::jsonb) FROM public.%I t',rel) INTO rows_json;
  after_state := after_state || jsonb_build_object(rel,rows_json);
END LOOP;
SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb)
INTO rows_json FROM public.pick_sales_orders s
CROSS JOIN LATERAL public.get_saved_pick_corrections(s.sales_order) x
WHERE s.sales_order LIKE 'AR3%';
after_state := after_state || jsonb_build_object('correction_reports',rows_json);
SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb)
INTO rows_json FROM public.skus s
CROSS JOIN LATERAL public.get_sku_uom_conversion_config_v1(s.id) x
WHERE s.brand LIKE 'AR3%';
after_state := after_state || jsonb_build_object('uom_config_reports',rows_json);
IF (before_state=after_state) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: rejected operation leaves observable state unchanged'; END IF;

    counts_json := jsonb_build_object(
  'skus',(SELECT count(*) FROM public.skus WHERE brand LIKE 'AR3%'),
  'stock_lots',(SELECT count(*) FROM public.stock_lots s JOIN public.skus k ON k.id=s.sku_id WHERE k.brand LIKE 'AR3%'),
  'rack_rows',(SELECT count(*) FROM public.locations WHERE code LIKE 'XR8%'),
  'sales_orders',(SELECT count(*) FROM public.pick_sales_orders),
  'transactions',(SELECT count(*) FROM public.transactions),
  'active_locks',(SELECT count(*) FROM public.location_locks WHERE expires_at>now()),
  'operational_mode',(SELECT operational_mode FROM public.app_settings WHERE id=1));
    scenario_ok := true;
    -- A deliberate exception rolls successful fixture writes back as well.
    RAISE EXCEPTION USING ERRCODE='ZAR03', MESSAGE='AR3 scenario complete';
  EXCEPTION
    WHEN SQLSTATE 'ZAR03' THEN
      INSERT INTO pg_temp.ar3_results VALUES (7,'R07','Locked rack deletion blocked',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (7,'R07','Locked rack deletion blocked',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

-- R08: Positive stock prevents deletion
DO $scenario$
DECLARE
  a uuid; b uuid; c uuid; d uuid; sku uuid; lot uuid; token uuid;
  tx uuid; corr uuid; line uuid;
  r record; item jsonb; rows_json jsonb;
  before_state jsonb; after_state jsonb; counts_json jsonb;
  so text; session_key text; old_key text; rack_code text; status_text text;
  rel text; err text; err_code text; n numeric; flag boolean;
  scenario_ok boolean := false;
BEGIN
  BEGIN
a := public.add_location('XR801');
b := public.add_location('XR802');
item := '{"brand":"AR3R08","description":"AR3R08 regression","variant":"AR3R08","size":"AR3","case_barcode":"AR3R08C","pack_barcode":"AR3R08P","piece_barcode":"AR3R08E","container_no":"AR3R08BOX","expiry_date":"2099-12-31","case_qty":5,"pack_qty":0,"piece_qty":0,"user_remark":"AR3R08 remark"}'::jsonb;
SELECT x.transaction_id INTO tx FROM public.complete_putaway_with_user_remarks('XR801',jsonb_build_array(item)) x;
SELECT id INTO STRICT sku FROM public.skus WHERE brand='AR3R08';
SELECT id INTO STRICT lot FROM public.stock_lots WHERE sku_id=sku AND location_id=a AND uom='CASE';
-- Harness-only mode fixture; runner authority is restored only for this rollback-scoped setting.
SET LOCAL ROLE NONE;
UPDATE public.app_settings SET operational_mode='ADMINISTRATIVE_PAUSE' WHERE id=1;
SET LOCAL ROLE authenticated;

before_state := '{}'::jsonb;
FOREACH rel IN ARRAY ARRAY['app_settings','skus','stock_lots','locations','transactions','transaction_lines','transaction_line_user_remarks','transaction_user_remarks','location_locks','pick_sales_orders','audit_log','fefo_override_events','inventory_lot_remark_overrides'] LOOP
  EXECUTE format('SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text), ''[]''::jsonb) FROM public.%I t',rel) INTO rows_json;
  before_state := before_state || jsonb_build_object(rel,rows_json);
END LOOP;
SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb)
INTO rows_json FROM public.pick_sales_orders s
CROSS JOIN LATERAL public.get_saved_pick_corrections(s.sales_order) x
WHERE s.sales_order LIKE 'AR3%';
before_state := before_state || jsonb_build_object('correction_reports',rows_json);
SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb)
INTO rows_json FROM public.skus s
CROSS JOIN LATERAL public.get_sku_uom_conversion_config_v1(s.id) x
WHERE s.brand LIKE 'AR3%';
before_state := before_state || jsonb_build_object('uom_config_reports',rows_json);

err := NULL; err_code := NULL;
BEGIN
PERFORM public.owner_delete_physical_location_v1(a,'AR3 delete');

EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS err = MESSAGE_TEXT, err_code = RETURNED_SQLSTATE;
END;
IF (err IS NOT NULL) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: negative call must reject'; END IF;
IF (err_code='P0001') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected SQLSTATE P0001'; END IF;
IF (err='PHYSICAL_RACK_NOT_EMPTY: Move or consume all positive inventory from XR801 before deleting it.') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected rejection: PHYSICAL_RACK_NOT_EMPTY: Move or consume all positive inventory from XR801 before deleting it.'; END IF;

after_state := '{}'::jsonb;
FOREACH rel IN ARRAY ARRAY['app_settings','skus','stock_lots','locations','transactions','transaction_lines','transaction_line_user_remarks','transaction_user_remarks','location_locks','pick_sales_orders','audit_log','fefo_override_events','inventory_lot_remark_overrides'] LOOP
  EXECUTE format('SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text), ''[]''::jsonb) FROM public.%I t',rel) INTO rows_json;
  after_state := after_state || jsonb_build_object(rel,rows_json);
END LOOP;
SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb)
INTO rows_json FROM public.pick_sales_orders s
CROSS JOIN LATERAL public.get_saved_pick_corrections(s.sales_order) x
WHERE s.sales_order LIKE 'AR3%';
after_state := after_state || jsonb_build_object('correction_reports',rows_json);
SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb)
INTO rows_json FROM public.skus s
CROSS JOIN LATERAL public.get_sku_uom_conversion_config_v1(s.id) x
WHERE s.brand LIKE 'AR3%';
after_state := after_state || jsonb_build_object('uom_config_reports',rows_json);
IF (before_state=after_state) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: rejected operation leaves observable state unchanged'; END IF;

    counts_json := jsonb_build_object(
  'skus',(SELECT count(*) FROM public.skus WHERE brand LIKE 'AR3%'),
  'stock_lots',(SELECT count(*) FROM public.stock_lots s JOIN public.skus k ON k.id=s.sku_id WHERE k.brand LIKE 'AR3%'),
  'rack_rows',(SELECT count(*) FROM public.locations WHERE code LIKE 'XR8%'),
  'sales_orders',(SELECT count(*) FROM public.pick_sales_orders),
  'transactions',(SELECT count(*) FROM public.transactions),
  'active_locks',(SELECT count(*) FROM public.location_locks WHERE expires_at>now()),
  'operational_mode',(SELECT operational_mode FROM public.app_settings WHERE id=1));
    scenario_ok := true;
    -- A deliberate exception rolls successful fixture writes back as well.
    RAISE EXCEPTION USING ERRCODE='ZAR03', MESSAGE='AR3 scenario complete';
  EXCEPTION
    WHEN SQLSTATE 'ZAR03' THEN
      INSERT INTO pg_temp.ar3_results VALUES (8,'R08','Positive stock prevents deletion',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (8,'R08','Positive stock prevents deletion',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

-- R09: Invalid rename format
DO $scenario$
DECLARE
  a uuid; b uuid; c uuid; d uuid; sku uuid; lot uuid; token uuid;
  tx uuid; corr uuid; line uuid;
  r record; item jsonb; rows_json jsonb;
  before_state jsonb; after_state jsonb; counts_json jsonb;
  so text; session_key text; old_key text; rack_code text; status_text text;
  rel text; err text; err_code text; n numeric; flag boolean;
  scenario_ok boolean := false;
BEGIN
  BEGIN
a:=public.add_location('xr801'); b:=public.add_location('XR802');
-- Harness-only mode fixture; runner authority is restored only for this rollback-scoped setting.
SET LOCAL ROLE NONE;
UPDATE public.app_settings SET operational_mode='ADMINISTRATIVE_PAUSE' WHERE id=1;
SET LOCAL ROLE authenticated;

before_state := '{}'::jsonb;
FOREACH rel IN ARRAY ARRAY['app_settings','skus','stock_lots','locations','transactions','transaction_lines','transaction_line_user_remarks','transaction_user_remarks','location_locks','pick_sales_orders','audit_log','fefo_override_events','inventory_lot_remark_overrides'] LOOP
  EXECUTE format('SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text), ''[]''::jsonb) FROM public.%I t',rel) INTO rows_json;
  before_state := before_state || jsonb_build_object(rel,rows_json);
END LOOP;
SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb)
INTO rows_json FROM public.pick_sales_orders s
CROSS JOIN LATERAL public.get_saved_pick_corrections(s.sales_order) x
WHERE s.sales_order LIKE 'AR3%';
before_state := before_state || jsonb_build_object('correction_reports',rows_json);
SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb)
INTO rows_json FROM public.skus s
CROSS JOIN LATERAL public.get_sku_uom_conversion_config_v1(s.id) x
WHERE s.brand LIKE 'AR3%';
before_state := before_state || jsonb_build_object('uom_config_reports',rows_json);

err := NULL; err_code := NULL;
BEGIN
PERFORM public.owner_rename_physical_location_v1(a,'XR8-BAD',NULL,'AR3 rename');

EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS err = MESSAGE_TEXT, err_code = RETURNED_SQLSTATE;
END;
IF (err IS NOT NULL) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: negative call must reject'; END IF;
IF (err_code='P0001') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected SQLSTATE P0001'; END IF;
IF (err='PHYSICAL_RACK_CODE_FORMAT: Use letters followed by a positive number, for example A1, C97, or L12.') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected rejection: PHYSICAL_RACK_CODE_FORMAT: Use letters followed by a positive number, for example A1, C97, or L12.'; END IF;

after_state := '{}'::jsonb;
FOREACH rel IN ARRAY ARRAY['app_settings','skus','stock_lots','locations','transactions','transaction_lines','transaction_line_user_remarks','transaction_user_remarks','location_locks','pick_sales_orders','audit_log','fefo_override_events','inventory_lot_remark_overrides'] LOOP
  EXECUTE format('SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text), ''[]''::jsonb) FROM public.%I t',rel) INTO rows_json;
  after_state := after_state || jsonb_build_object(rel,rows_json);
END LOOP;
SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb)
INTO rows_json FROM public.pick_sales_orders s
CROSS JOIN LATERAL public.get_saved_pick_corrections(s.sales_order) x
WHERE s.sales_order LIKE 'AR3%';
after_state := after_state || jsonb_build_object('correction_reports',rows_json);
SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb)
INTO rows_json FROM public.skus s
CROSS JOIN LATERAL public.get_sku_uom_conversion_config_v1(s.id) x
WHERE s.brand LIKE 'AR3%';
after_state := after_state || jsonb_build_object('uom_config_reports',rows_json);
IF (before_state=after_state) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: rejected operation leaves observable state unchanged'; END IF;

    counts_json := jsonb_build_object(
  'skus',(SELECT count(*) FROM public.skus WHERE brand LIKE 'AR3%'),
  'stock_lots',(SELECT count(*) FROM public.stock_lots s JOIN public.skus k ON k.id=s.sku_id WHERE k.brand LIKE 'AR3%'),
  'rack_rows',(SELECT count(*) FROM public.locations WHERE code LIKE 'XR8%'),
  'sales_orders',(SELECT count(*) FROM public.pick_sales_orders),
  'transactions',(SELECT count(*) FROM public.transactions),
  'active_locks',(SELECT count(*) FROM public.location_locks WHERE expires_at>now()),
  'operational_mode',(SELECT operational_mode FROM public.app_settings WHERE id=1));
    scenario_ok := true;
    -- A deliberate exception rolls successful fixture writes back as well.
    RAISE EXCEPTION USING ERRCODE='ZAR03', MESSAGE='AR3 scenario complete';
  EXCEPTION
    WHEN SQLSTATE 'ZAR03' THEN
      INSERT INTO pg_temp.ar3_results VALUES (9,'R09','Invalid rename format',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (9,'R09','Invalid rename format',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

-- R10: Existing A1 code reserved
DO $scenario$
DECLARE
  a uuid; b uuid; c uuid; d uuid; sku uuid; lot uuid; token uuid;
  tx uuid; corr uuid; line uuid;
  r record; item jsonb; rows_json jsonb;
  before_state jsonb; after_state jsonb; counts_json jsonb;
  so text; session_key text; old_key text; rack_code text; status_text text;
  rel text; err text; err_code text; n numeric; flag boolean;
  scenario_ok boolean := false;
BEGIN
  BEGIN
a:=public.add_location('xr801'); b:=public.add_location('XR802');
-- Harness-only mode fixture; runner authority is restored only for this rollback-scoped setting.
SET LOCAL ROLE NONE;
UPDATE public.app_settings SET operational_mode='ADMINISTRATIVE_PAUSE' WHERE id=1;
SET LOCAL ROLE authenticated;
IF (EXISTS(SELECT 1 FROM public.locations WHERE code='A1')) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: A1 prerequisite'; END IF;

before_state := '{}'::jsonb;
FOREACH rel IN ARRAY ARRAY['app_settings','skus','stock_lots','locations','transactions','transaction_lines','transaction_line_user_remarks','transaction_user_remarks','location_locks','pick_sales_orders','audit_log','fefo_override_events','inventory_lot_remark_overrides'] LOOP
  EXECUTE format('SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text), ''[]''::jsonb) FROM public.%I t',rel) INTO rows_json;
  before_state := before_state || jsonb_build_object(rel,rows_json);
END LOOP;
SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb)
INTO rows_json FROM public.pick_sales_orders s
CROSS JOIN LATERAL public.get_saved_pick_corrections(s.sales_order) x
WHERE s.sales_order LIKE 'AR3%';
before_state := before_state || jsonb_build_object('correction_reports',rows_json);
SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb)
INTO rows_json FROM public.skus s
CROSS JOIN LATERAL public.get_sku_uom_conversion_config_v1(s.id) x
WHERE s.brand LIKE 'AR3%';
before_state := before_state || jsonb_build_object('uom_config_reports',rows_json);

err := NULL; err_code := NULL;
BEGIN
PERFORM public.owner_rename_physical_location_v1(a,'A1',NULL,'AR3 rename');

EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS err = MESSAGE_TEXT, err_code = RETURNED_SQLSTATE;
END;
IF (err IS NOT NULL) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: negative call must reject'; END IF;
IF (err_code='P0001') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected SQLSTATE P0001'; END IF;
IF (err='LOCATION_CODE_EXISTS: Location code A1 already exists or is reserved.') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected rejection: LOCATION_CODE_EXISTS: Location code A1 already exists or is reserved.'; END IF;

after_state := '{}'::jsonb;
FOREACH rel IN ARRAY ARRAY['app_settings','skus','stock_lots','locations','transactions','transaction_lines','transaction_line_user_remarks','transaction_user_remarks','location_locks','pick_sales_orders','audit_log','fefo_override_events','inventory_lot_remark_overrides'] LOOP
  EXECUTE format('SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text), ''[]''::jsonb) FROM public.%I t',rel) INTO rows_json;
  after_state := after_state || jsonb_build_object(rel,rows_json);
END LOOP;
SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb)
INTO rows_json FROM public.pick_sales_orders s
CROSS JOIN LATERAL public.get_saved_pick_corrections(s.sales_order) x
WHERE s.sales_order LIKE 'AR3%';
after_state := after_state || jsonb_build_object('correction_reports',rows_json);
SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb)
INTO rows_json FROM public.skus s
CROSS JOIN LATERAL public.get_sku_uom_conversion_config_v1(s.id) x
WHERE s.brand LIKE 'AR3%';
after_state := after_state || jsonb_build_object('uom_config_reports',rows_json);
IF (before_state=after_state) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: rejected operation leaves observable state unchanged'; END IF;

    counts_json := jsonb_build_object(
  'skus',(SELECT count(*) FROM public.skus WHERE brand LIKE 'AR3%'),
  'stock_lots',(SELECT count(*) FROM public.stock_lots s JOIN public.skus k ON k.id=s.sku_id WHERE k.brand LIKE 'AR3%'),
  'rack_rows',(SELECT count(*) FROM public.locations WHERE code LIKE 'XR8%'),
  'sales_orders',(SELECT count(*) FROM public.pick_sales_orders),
  'transactions',(SELECT count(*) FROM public.transactions),
  'active_locks',(SELECT count(*) FROM public.location_locks WHERE expires_at>now()),
  'operational_mode',(SELECT operational_mode FROM public.app_settings WHERE id=1));
    scenario_ok := true;
    -- A deliberate exception rolls successful fixture writes back as well.
    RAISE EXCEPTION USING ERRCODE='ZAR03', MESSAGE='AR3 scenario complete';
  EXCEPTION
    WHEN SQLSTATE 'ZAR03' THEN
      INSERT INTO pg_temp.ar3_results VALUES (10,'R10','Existing A1 code reserved',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (10,'R10','Existing A1 code reserved',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

-- R11: Rename retains UUID and stock relationship
DO $scenario$
DECLARE
  a uuid; b uuid; c uuid; d uuid; sku uuid; lot uuid; token uuid;
  tx uuid; corr uuid; line uuid;
  r record; item jsonb; rows_json jsonb;
  before_state jsonb; after_state jsonb; counts_json jsonb;
  so text; session_key text; old_key text; rack_code text; status_text text;
  rel text; err text; err_code text; n numeric; flag boolean;
  scenario_ok boolean := false;
BEGIN
  BEGIN
a := public.add_location('XR801');
b := public.add_location('XR802');
item := '{"brand":"AR3R11","description":"AR3R11 regression","variant":"AR3R11","size":"AR3","case_barcode":"AR3R11C","pack_barcode":"AR3R11P","piece_barcode":"AR3R11E","container_no":"AR3R11BOX","expiry_date":"2099-12-31","case_qty":5,"pack_qty":0,"piece_qty":0,"user_remark":"AR3R11 remark"}'::jsonb;
SELECT x.transaction_id INTO tx FROM public.complete_putaway_with_user_remarks('XR801',jsonb_build_array(item)) x;
SELECT id INTO STRICT sku FROM public.skus WHERE brand='AR3R11';
SELECT id INTO STRICT lot FROM public.stock_lots WHERE sku_id=sku AND location_id=a AND uom='CASE';
-- Harness-only mode fixture; runner authority is restored only for this rollback-scoped setting.
SET LOCAL ROLE NONE;
UPDATE public.app_settings SET operational_mode='ADMINISTRATIVE_PAUSE' WHERE id=1;
SET LOCAL ROLE authenticated;
PERFORM public.owner_rename_physical_location_v1(a,'XR812',NULL,'AR3 rename');
IF (EXISTS(SELECT 1 FROM public.locations WHERE id=a AND code='XR812' AND row_label='XR' AND bay_label='812' AND display_name='Rack XR812')) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: renamed metadata'; END IF;
IF (EXISTS(SELECT 1 FROM public.stock_lots WHERE id=lot AND location_id=a AND qty=5)) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: stock relationship'; END IF;
IF (EXISTS (SELECT 1 FROM public.audit_log WHERE action='RENAME_PHYSICAL_LOCATION' AND entity_id=a::text AND after_data @> '{"inventory_relationship_preserved":true}'::jsonb)) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: audit RENAME_PHYSICAL_LOCATION'; END IF;

    counts_json := jsonb_build_object(
  'skus',(SELECT count(*) FROM public.skus WHERE brand LIKE 'AR3%'),
  'stock_lots',(SELECT count(*) FROM public.stock_lots s JOIN public.skus k ON k.id=s.sku_id WHERE k.brand LIKE 'AR3%'),
  'rack_rows',(SELECT count(*) FROM public.locations WHERE code LIKE 'XR8%'),
  'sales_orders',(SELECT count(*) FROM public.pick_sales_orders),
  'transactions',(SELECT count(*) FROM public.transactions),
  'active_locks',(SELECT count(*) FROM public.location_locks WHERE expires_at>now()),
  'operational_mode',(SELECT operational_mode FROM public.app_settings WHERE id=1));
    scenario_ok := true;
    -- A deliberate exception rolls successful fixture writes back as well.
    RAISE EXCEPTION USING ERRCODE='ZAR03', MESSAGE='AR3 scenario complete';
  EXCEPTION
    WHEN SQLSTATE 'ZAR03' THEN
      INSERT INTO pg_temp.ar3_results VALUES (11,'R11','Rename retains UUID and stock relationship',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (11,'R11','Rename retains UUID and stock relationship',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

-- R12: Empty rack soft-delete retains identity
DO $scenario$
DECLARE
  a uuid; b uuid; c uuid; d uuid; sku uuid; lot uuid; token uuid;
  tx uuid; corr uuid; line uuid;
  r record; item jsonb; rows_json jsonb;
  before_state jsonb; after_state jsonb; counts_json jsonb;
  so text; session_key text; old_key text; rack_code text; status_text text;
  rel text; err text; err_code text; n numeric; flag boolean;
  scenario_ok boolean := false;
BEGIN
  BEGIN
a:=public.add_location('xr801'); b:=public.add_location('XR802');
-- Harness-only mode fixture; runner authority is restored only for this rollback-scoped setting.
SET LOCAL ROLE NONE;
UPDATE public.app_settings SET operational_mode='ADMINISTRATIVE_PAUSE' WHERE id=1;
SET LOCAL ROLE authenticated;
PERFORM public.owner_delete_physical_location_v1(a,'AR3 delete');
IF (EXISTS(SELECT 1 FROM public.locations WHERE id=a AND code='XR801' AND NOT is_active)) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: same reserved row'; END IF;
IF (EXISTS (SELECT 1 FROM public.audit_log WHERE action='DELETE_PHYSICAL_LOCATION' AND entity_id=a::text AND after_data @> '{"soft_deleted":true,"history_preserved":true,"location_code_reserved":true}'::jsonb)) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: audit DELETE_PHYSICAL_LOCATION'; END IF;

    counts_json := jsonb_build_object(
  'skus',(SELECT count(*) FROM public.skus WHERE brand LIKE 'AR3%'),
  'stock_lots',(SELECT count(*) FROM public.stock_lots s JOIN public.skus k ON k.id=s.sku_id WHERE k.brand LIKE 'AR3%'),
  'rack_rows',(SELECT count(*) FROM public.locations WHERE code LIKE 'XR8%'),
  'sales_orders',(SELECT count(*) FROM public.pick_sales_orders),
  'transactions',(SELECT count(*) FROM public.transactions),
  'active_locks',(SELECT count(*) FROM public.location_locks WHERE expires_at>now()),
  'operational_mode',(SELECT operational_mode FROM public.app_settings WHERE id=1));
    scenario_ok := true;
    -- A deliberate exception rolls successful fixture writes back as well.
    RAISE EXCEPTION USING ERRCODE='ZAR03', MESSAGE='AR3 scenario complete';
  EXCEPTION
    WHEN SQLSTATE 'ZAR03' THEN
      INSERT INTO pg_temp.ar3_results VALUES (12,'R12','Empty rack soft-delete retains identity',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (12,'R12','Empty rack soft-delete retains identity',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

-- R13: Soft-deleted code cannot be reused
DO $scenario$
DECLARE
  a uuid; b uuid; c uuid; d uuid; sku uuid; lot uuid; token uuid;
  tx uuid; corr uuid; line uuid;
  r record; item jsonb; rows_json jsonb;
  before_state jsonb; after_state jsonb; counts_json jsonb;
  so text; session_key text; old_key text; rack_code text; status_text text;
  rel text; err text; err_code text; n numeric; flag boolean;
  scenario_ok boolean := false;
BEGIN
  BEGIN
a:=public.add_location('xr801'); b:=public.add_location('XR802');
-- Harness-only mode fixture; runner authority is restored only for this rollback-scoped setting.
SET LOCAL ROLE NONE;
UPDATE public.app_settings SET operational_mode='ADMINISTRATIVE_PAUSE' WHERE id=1;
SET LOCAL ROLE authenticated;
PERFORM public.owner_delete_physical_location_v1(a,'AR3 delete');

before_state := '{}'::jsonb;
FOREACH rel IN ARRAY ARRAY['app_settings','skus','stock_lots','locations','transactions','transaction_lines','transaction_line_user_remarks','transaction_user_remarks','location_locks','pick_sales_orders','audit_log','fefo_override_events','inventory_lot_remark_overrides'] LOOP
  EXECUTE format('SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text), ''[]''::jsonb) FROM public.%I t',rel) INTO rows_json;
  before_state := before_state || jsonb_build_object(rel,rows_json);
END LOOP;
SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb)
INTO rows_json FROM public.pick_sales_orders s
CROSS JOIN LATERAL public.get_saved_pick_corrections(s.sales_order) x
WHERE s.sales_order LIKE 'AR3%';
before_state := before_state || jsonb_build_object('correction_reports',rows_json);
SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb)
INTO rows_json FROM public.skus s
CROSS JOIN LATERAL public.get_sku_uom_conversion_config_v1(s.id) x
WHERE s.brand LIKE 'AR3%';
before_state := before_state || jsonb_build_object('uom_config_reports',rows_json);

err := NULL; err_code := NULL;
BEGIN
PERFORM public.add_location('XR801');
EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS err = MESSAGE_TEXT, err_code = RETURNED_SQLSTATE;
END;
IF (err IS NOT NULL) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: negative call must reject'; END IF;
IF (err_code='23505') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected SQLSTATE 23505'; END IF;
IF (left(err,0)='') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected rejection: '; END IF;

after_state := '{}'::jsonb;
FOREACH rel IN ARRAY ARRAY['app_settings','skus','stock_lots','locations','transactions','transaction_lines','transaction_line_user_remarks','transaction_user_remarks','location_locks','pick_sales_orders','audit_log','fefo_override_events','inventory_lot_remark_overrides'] LOOP
  EXECUTE format('SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text), ''[]''::jsonb) FROM public.%I t',rel) INTO rows_json;
  after_state := after_state || jsonb_build_object(rel,rows_json);
END LOOP;
SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb)
INTO rows_json FROM public.pick_sales_orders s
CROSS JOIN LATERAL public.get_saved_pick_corrections(s.sales_order) x
WHERE s.sales_order LIKE 'AR3%';
after_state := after_state || jsonb_build_object('correction_reports',rows_json);
SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb)
INTO rows_json FROM public.skus s
CROSS JOIN LATERAL public.get_sku_uom_conversion_config_v1(s.id) x
WHERE s.brand LIKE 'AR3%';
after_state := after_state || jsonb_build_object('uom_config_reports',rows_json);
IF (before_state=after_state) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: rejected operation leaves observable state unchanged'; END IF;

    counts_json := jsonb_build_object(
  'skus',(SELECT count(*) FROM public.skus WHERE brand LIKE 'AR3%'),
  'stock_lots',(SELECT count(*) FROM public.stock_lots s JOIN public.skus k ON k.id=s.sku_id WHERE k.brand LIKE 'AR3%'),
  'rack_rows',(SELECT count(*) FROM public.locations WHERE code LIKE 'XR8%'),
  'sales_orders',(SELECT count(*) FROM public.pick_sales_orders),
  'transactions',(SELECT count(*) FROM public.transactions),
  'active_locks',(SELECT count(*) FROM public.location_locks WHERE expires_at>now()),
  'operational_mode',(SELECT operational_mode FROM public.app_settings WHERE id=1));
    scenario_ok := true;
    -- A deliberate exception rolls successful fixture writes back as well.
    RAISE EXCEPTION USING ERRCODE='ZAR03', MESSAGE='AR3 scenario complete';
  EXCEPTION
    WHEN SQLSTATE 'ZAR03' THEN
      INSERT INTO pg_temp.ar3_results VALUES (13,'R13','Soft-deleted code cannot be reused',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (13,'R13','Soft-deleted code cannot be reused',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

-- R14: Reactivate preserves UUID and history
DO $scenario$
DECLARE
  a uuid; b uuid; c uuid; d uuid; sku uuid; lot uuid; token uuid;
  tx uuid; corr uuid; line uuid;
  r record; item jsonb; rows_json jsonb;
  before_state jsonb; after_state jsonb; counts_json jsonb;
  so text; session_key text; old_key text; rack_code text; status_text text;
  rel text; err text; err_code text; n numeric; flag boolean;
  scenario_ok boolean := false;
BEGIN
  BEGIN
a:=public.add_location('xr801'); b:=public.add_location('XR802');
-- Harness-only mode fixture; runner authority is restored only for this rollback-scoped setting.
SET LOCAL ROLE NONE;
UPDATE public.app_settings SET operational_mode='ADMINISTRATIVE_PAUSE' WHERE id=1;
SET LOCAL ROLE authenticated;
PERFORM public.owner_delete_physical_location_v1(a,'AR3 delete');
PERFORM public.owner_reactivate_physical_location_v1(a,'AR3 reactivate');
IF (EXISTS(SELECT 1 FROM public.locations WHERE id=a AND code='XR801' AND is_active)) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: same reactivated rack'; END IF;
IF (EXISTS (SELECT 1 FROM public.audit_log WHERE action='REACTIVATE_PHYSICAL_LOCATION' AND entity_id=a::text AND after_data @> '{"reactivated_same_location_id":true,"historical_identity_preserved":true}'::jsonb)) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: audit REACTIVATE_PHYSICAL_LOCATION'; END IF;

    counts_json := jsonb_build_object(
  'skus',(SELECT count(*) FROM public.skus WHERE brand LIKE 'AR3%'),
  'stock_lots',(SELECT count(*) FROM public.stock_lots s JOIN public.skus k ON k.id=s.sku_id WHERE k.brand LIKE 'AR3%'),
  'rack_rows',(SELECT count(*) FROM public.locations WHERE code LIKE 'XR8%'),
  'sales_orders',(SELECT count(*) FROM public.pick_sales_orders),
  'transactions',(SELECT count(*) FROM public.transactions),
  'active_locks',(SELECT count(*) FROM public.location_locks WHERE expires_at>now()),
  'operational_mode',(SELECT operational_mode FROM public.app_settings WHERE id=1));
    scenario_ok := true;
    -- A deliberate exception rolls successful fixture writes back as well.
    RAISE EXCEPTION USING ERRCODE='ZAR03', MESSAGE='AR3 scenario complete';
  EXCEPTION
    WHEN SQLSTATE 'ZAR03' THEN
      INSERT INTO pg_temp.ar3_results VALUES (14,'R14','Reactivate preserves UUID and history',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (14,'R14','Reactivate preserves UUID and history',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

-- R15: Already active reactivate blocked
DO $scenario$
DECLARE
  a uuid; b uuid; c uuid; d uuid; sku uuid; lot uuid; token uuid;
  tx uuid; corr uuid; line uuid;
  r record; item jsonb; rows_json jsonb;
  before_state jsonb; after_state jsonb; counts_json jsonb;
  so text; session_key text; old_key text; rack_code text; status_text text;
  rel text; err text; err_code text; n numeric; flag boolean;
  scenario_ok boolean := false;
BEGIN
  BEGIN
a:=public.add_location('xr801'); b:=public.add_location('XR802');
-- Harness-only mode fixture; runner authority is restored only for this rollback-scoped setting.
SET LOCAL ROLE NONE;
UPDATE public.app_settings SET operational_mode='ADMINISTRATIVE_PAUSE' WHERE id=1;
SET LOCAL ROLE authenticated;

before_state := '{}'::jsonb;
FOREACH rel IN ARRAY ARRAY['app_settings','skus','stock_lots','locations','transactions','transaction_lines','transaction_line_user_remarks','transaction_user_remarks','location_locks','pick_sales_orders','audit_log','fefo_override_events','inventory_lot_remark_overrides'] LOOP
  EXECUTE format('SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text), ''[]''::jsonb) FROM public.%I t',rel) INTO rows_json;
  before_state := before_state || jsonb_build_object(rel,rows_json);
END LOOP;
SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb)
INTO rows_json FROM public.pick_sales_orders s
CROSS JOIN LATERAL public.get_saved_pick_corrections(s.sales_order) x
WHERE s.sales_order LIKE 'AR3%';
before_state := before_state || jsonb_build_object('correction_reports',rows_json);
SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb)
INTO rows_json FROM public.skus s
CROSS JOIN LATERAL public.get_sku_uom_conversion_config_v1(s.id) x
WHERE s.brand LIKE 'AR3%';
before_state := before_state || jsonb_build_object('uom_config_reports',rows_json);

err := NULL; err_code := NULL;
BEGIN
PERFORM public.owner_reactivate_physical_location_v1(a,'AR3 reactivate');

EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS err = MESSAGE_TEXT, err_code = RETURNED_SQLSTATE;
END;
IF (err IS NOT NULL) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: negative call must reject'; END IF;
IF (err_code='P0001') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected SQLSTATE P0001'; END IF;
IF (err='This physical rack is already active.') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected rejection: This physical rack is already active.'; END IF;

after_state := '{}'::jsonb;
FOREACH rel IN ARRAY ARRAY['app_settings','skus','stock_lots','locations','transactions','transaction_lines','transaction_line_user_remarks','transaction_user_remarks','location_locks','pick_sales_orders','audit_log','fefo_override_events','inventory_lot_remark_overrides'] LOOP
  EXECUTE format('SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text), ''[]''::jsonb) FROM public.%I t',rel) INTO rows_json;
  after_state := after_state || jsonb_build_object(rel,rows_json);
END LOOP;
SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb)
INTO rows_json FROM public.pick_sales_orders s
CROSS JOIN LATERAL public.get_saved_pick_corrections(s.sales_order) x
WHERE s.sales_order LIKE 'AR3%';
after_state := after_state || jsonb_build_object('correction_reports',rows_json);
SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb)
INTO rows_json FROM public.skus s
CROSS JOIN LATERAL public.get_sku_uom_conversion_config_v1(s.id) x
WHERE s.brand LIKE 'AR3%';
after_state := after_state || jsonb_build_object('uom_config_reports',rows_json);
IF (before_state=after_state) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: rejected operation leaves observable state unchanged'; END IF;

    counts_json := jsonb_build_object(
  'skus',(SELECT count(*) FROM public.skus WHERE brand LIKE 'AR3%'),
  'stock_lots',(SELECT count(*) FROM public.stock_lots s JOIN public.skus k ON k.id=s.sku_id WHERE k.brand LIKE 'AR3%'),
  'rack_rows',(SELECT count(*) FROM public.locations WHERE code LIKE 'XR8%'),
  'sales_orders',(SELECT count(*) FROM public.pick_sales_orders),
  'transactions',(SELECT count(*) FROM public.transactions),
  'active_locks',(SELECT count(*) FROM public.location_locks WHERE expires_at>now()),
  'operational_mode',(SELECT operational_mode FROM public.app_settings WHERE id=1));
    scenario_ok := true;
    -- A deliberate exception rolls successful fixture writes back as well.
    RAISE EXCEPTION USING ERRCODE='ZAR03', MESSAGE='AR3 scenario complete';
  EXCEPTION
    WHEN SQLSTATE 'ZAR03' THEN
      INSERT INTO pg_temp.ar3_results VALUES (15,'R15','Already active reactivate blocked',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (15,'R15','Already active reactivate blocked',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

-- R16: Pending location rename protected
DO $scenario$
DECLARE
  a uuid; b uuid; c uuid; d uuid; sku uuid; lot uuid; token uuid;
  tx uuid; corr uuid; line uuid;
  r record; item jsonb; rows_json jsonb;
  before_state jsonb; after_state jsonb; counts_json jsonb;
  so text; session_key text; old_key text; rack_code text; status_text text;
  rel text; err text; err_code text; n numeric; flag boolean;
  scenario_ok boolean := false;
BEGIN
  BEGIN
SELECT id INTO STRICT a FROM public.locations WHERE is_pending AND is_active ORDER BY code LIMIT 1;
-- Harness-only mode fixture; runner authority is restored only for this rollback-scoped setting.
SET LOCAL ROLE NONE;
UPDATE public.app_settings SET operational_mode='ADMINISTRATIVE_PAUSE' WHERE id=1;
SET LOCAL ROLE authenticated;

before_state := '{}'::jsonb;
FOREACH rel IN ARRAY ARRAY['app_settings','skus','stock_lots','locations','transactions','transaction_lines','transaction_line_user_remarks','transaction_user_remarks','location_locks','pick_sales_orders','audit_log','fefo_override_events','inventory_lot_remark_overrides'] LOOP
  EXECUTE format('SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text), ''[]''::jsonb) FROM public.%I t',rel) INTO rows_json;
  before_state := before_state || jsonb_build_object(rel,rows_json);
END LOOP;
SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb)
INTO rows_json FROM public.pick_sales_orders s
CROSS JOIN LATERAL public.get_saved_pick_corrections(s.sales_order) x
WHERE s.sales_order LIKE 'AR3%';
before_state := before_state || jsonb_build_object('correction_reports',rows_json);
SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb)
INTO rows_json FROM public.skus s
CROSS JOIN LATERAL public.get_sku_uom_conversion_config_v1(s.id) x
WHERE s.brand LIKE 'AR3%';
before_state := before_state || jsonb_build_object('uom_config_reports',rows_json);

err := NULL; err_code := NULL;
BEGIN
PERFORM public.owner_rename_physical_location_v1(a,'XR811',NULL,'AR3 rename');

EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS err = MESSAGE_TEXT, err_code = RETURNED_SQLSTATE;
END;
IF (err IS NOT NULL) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: negative call must reject'; END IF;
IF (err_code='P0001') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected SQLSTATE P0001'; END IF;
IF (err='PENDING_LOCATION_PROTECTED: Use the existing virtual/pending location manager for this location.') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected rejection: PENDING_LOCATION_PROTECTED: Use the existing virtual/pending location manager for this location.'; END IF;

after_state := '{}'::jsonb;
FOREACH rel IN ARRAY ARRAY['app_settings','skus','stock_lots','locations','transactions','transaction_lines','transaction_line_user_remarks','transaction_user_remarks','location_locks','pick_sales_orders','audit_log','fefo_override_events','inventory_lot_remark_overrides'] LOOP
  EXECUTE format('SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text), ''[]''::jsonb) FROM public.%I t',rel) INTO rows_json;
  after_state := after_state || jsonb_build_object(rel,rows_json);
END LOOP;
SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb)
INTO rows_json FROM public.pick_sales_orders s
CROSS JOIN LATERAL public.get_saved_pick_corrections(s.sales_order) x
WHERE s.sales_order LIKE 'AR3%';
after_state := after_state || jsonb_build_object('correction_reports',rows_json);
SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb)
INTO rows_json FROM public.skus s
CROSS JOIN LATERAL public.get_sku_uom_conversion_config_v1(s.id) x
WHERE s.brand LIKE 'AR3%';
after_state := after_state || jsonb_build_object('uom_config_reports',rows_json);
IF (before_state=after_state) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: rejected operation leaves observable state unchanged'; END IF;

    counts_json := jsonb_build_object(
  'skus',(SELECT count(*) FROM public.skus WHERE brand LIKE 'AR3%'),
  'stock_lots',(SELECT count(*) FROM public.stock_lots s JOIN public.skus k ON k.id=s.sku_id WHERE k.brand LIKE 'AR3%'),
  'rack_rows',(SELECT count(*) FROM public.locations WHERE code LIKE 'XR8%'),
  'sales_orders',(SELECT count(*) FROM public.pick_sales_orders),
  'transactions',(SELECT count(*) FROM public.transactions),
  'active_locks',(SELECT count(*) FROM public.location_locks WHERE expires_at>now()),
  'operational_mode',(SELECT operational_mode FROM public.app_settings WHERE id=1));
    scenario_ok := true;
    -- A deliberate exception rolls successful fixture writes back as well.
    RAISE EXCEPTION USING ERRCODE='ZAR03', MESSAGE='AR3 scenario complete';
  EXCEPTION
    WHEN SQLSTATE 'ZAR03' THEN
      INSERT INTO pg_temp.ar3_results VALUES (16,'R16','Pending location rename protected',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (16,'R16','Pending location rename protected',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

-- R17: Pending location delete protected
DO $scenario$
DECLARE
  a uuid; b uuid; c uuid; d uuid; sku uuid; lot uuid; token uuid;
  tx uuid; corr uuid; line uuid;
  r record; item jsonb; rows_json jsonb;
  before_state jsonb; after_state jsonb; counts_json jsonb;
  so text; session_key text; old_key text; rack_code text; status_text text;
  rel text; err text; err_code text; n numeric; flag boolean;
  scenario_ok boolean := false;
BEGIN
  BEGIN
SELECT id INTO STRICT a FROM public.locations WHERE is_pending AND is_active ORDER BY code LIMIT 1;
-- Harness-only mode fixture; runner authority is restored only for this rollback-scoped setting.
SET LOCAL ROLE NONE;
UPDATE public.app_settings SET operational_mode='ADMINISTRATIVE_PAUSE' WHERE id=1;
SET LOCAL ROLE authenticated;

before_state := '{}'::jsonb;
FOREACH rel IN ARRAY ARRAY['app_settings','skus','stock_lots','locations','transactions','transaction_lines','transaction_line_user_remarks','transaction_user_remarks','location_locks','pick_sales_orders','audit_log','fefo_override_events','inventory_lot_remark_overrides'] LOOP
  EXECUTE format('SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text), ''[]''::jsonb) FROM public.%I t',rel) INTO rows_json;
  before_state := before_state || jsonb_build_object(rel,rows_json);
END LOOP;
SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb)
INTO rows_json FROM public.pick_sales_orders s
CROSS JOIN LATERAL public.get_saved_pick_corrections(s.sales_order) x
WHERE s.sales_order LIKE 'AR3%';
before_state := before_state || jsonb_build_object('correction_reports',rows_json);
SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb)
INTO rows_json FROM public.skus s
CROSS JOIN LATERAL public.get_sku_uom_conversion_config_v1(s.id) x
WHERE s.brand LIKE 'AR3%';
before_state := before_state || jsonb_build_object('uom_config_reports',rows_json);

err := NULL; err_code := NULL;
BEGIN
PERFORM public.owner_delete_physical_location_v1(a,'AR3 delete');

EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS err = MESSAGE_TEXT, err_code = RETURNED_SQLSTATE;
END;
IF (err IS NOT NULL) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: negative call must reject'; END IF;
IF (err_code='P0001') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected SQLSTATE P0001'; END IF;
IF (err='PENDING_LOCATION_PROTECTED: Use the existing virtual/pending location manager for this location.') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected rejection: PENDING_LOCATION_PROTECTED: Use the existing virtual/pending location manager for this location.'; END IF;

after_state := '{}'::jsonb;
FOREACH rel IN ARRAY ARRAY['app_settings','skus','stock_lots','locations','transactions','transaction_lines','transaction_line_user_remarks','transaction_user_remarks','location_locks','pick_sales_orders','audit_log','fefo_override_events','inventory_lot_remark_overrides'] LOOP
  EXECUTE format('SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text), ''[]''::jsonb) FROM public.%I t',rel) INTO rows_json;
  after_state := after_state || jsonb_build_object(rel,rows_json);
END LOOP;
SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb)
INTO rows_json FROM public.pick_sales_orders s
CROSS JOIN LATERAL public.get_saved_pick_corrections(s.sales_order) x
WHERE s.sales_order LIKE 'AR3%';
after_state := after_state || jsonb_build_object('correction_reports',rows_json);
SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb)
INTO rows_json FROM public.skus s
CROSS JOIN LATERAL public.get_sku_uom_conversion_config_v1(s.id) x
WHERE s.brand LIKE 'AR3%';
after_state := after_state || jsonb_build_object('uom_config_reports',rows_json);
IF (before_state=after_state) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: rejected operation leaves observable state unchanged'; END IF;

    counts_json := jsonb_build_object(
  'skus',(SELECT count(*) FROM public.skus WHERE brand LIKE 'AR3%'),
  'stock_lots',(SELECT count(*) FROM public.stock_lots s JOIN public.skus k ON k.id=s.sku_id WHERE k.brand LIKE 'AR3%'),
  'rack_rows',(SELECT count(*) FROM public.locations WHERE code LIKE 'XR8%'),
  'sales_orders',(SELECT count(*) FROM public.pick_sales_orders),
  'transactions',(SELECT count(*) FROM public.transactions),
  'active_locks',(SELECT count(*) FROM public.location_locks WHERE expires_at>now()),
  'operational_mode',(SELECT operational_mode FROM public.app_settings WHERE id=1));
    scenario_ok := true;
    -- A deliberate exception rolls successful fixture writes back as well.
    RAISE EXCEPTION USING ERRCODE='ZAR03', MESSAGE='AR3 scenario complete';
  EXCEPTION
    WHEN SQLSTATE 'ZAR03' THEN
      INSERT INTO pg_temp.ar3_results VALUES (17,'R17','Pending location delete protected',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (17,'R17','Pending location delete protected',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

SELECT jsonb_build_object(
  'suite','AR-3.8 Physical Rack Safeguards',
  'expected_total',17,
  'total',count(*),
  'pass',count(*) FILTER (WHERE passed),
  'fail',count(*) FILTER (WHERE NOT passed),
  'results',jsonb_agg(jsonb_build_object('test_no',test_no,'test_id',test_id,
    'scenario',scenario,'pass',passed,'detail',detail,
    'in_tx_fixture_counts',in_tx_fixture_counts) ORDER BY test_no),
  'in_tx_fixture_counts',jsonb_build_object(
  'skus',(SELECT count(*) FROM public.skus WHERE brand LIKE 'AR3%'),
  'stock_lots',(SELECT count(*) FROM public.stock_lots s JOIN public.skus k ON k.id=s.sku_id WHERE k.brand LIKE 'AR3%'),
  'rack_rows',(SELECT count(*) FROM public.locations WHERE code LIKE 'XR8%'),
  'sales_orders',(SELECT count(*) FROM public.pick_sales_orders),
  'transactions',(SELECT count(*) FROM public.transactions),
  'active_locks',(SELECT count(*) FROM public.location_locks WHERE expires_at>now()),
  'operational_mode',(SELECT operational_mode FROM public.app_settings WHERE id=1)),
  'sequence_note','PostgreSQL sequences may advance despite rollback'
) AS ar3_result FROM pg_temp.ar3_results;
ROLLBACK;

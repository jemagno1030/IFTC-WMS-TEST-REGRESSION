-- AR-3.5 FEFO + Container Priority: 10 scenarios.
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

-- F01: Earliest expiry normal
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
item := '{"brand":"AR3F01","description":"AR3F01 regression","variant":"AR3F01","size":"AR3","case_barcode":"AR3F01C","pack_barcode":"AR3F01P","piece_barcode":"AR3F01E","container_no":"AR3F01EARLY","expiry_date":"2098-01-01","case_qty":5,"pack_qty":0,"piece_qty":0,"user_remark":"AR3F01 remark"}'::jsonb;
SELECT x.transaction_id INTO tx FROM public.complete_putaway_with_user_remarks('XR801',jsonb_build_array(item)) x;
SELECT id INTO STRICT sku FROM public.skus WHERE brand='AR3F01';
SELECT id INTO STRICT lot FROM public.stock_lots WHERE sku_id=sku AND location_id=a AND uom='CASE';
c:=lot;
PERFORM public.complete_putaway_with_user_remarks('XR801',jsonb_build_array(item || jsonb_build_object('expiry_date','2099-01-01','container_no','AR3F01LATE')));
SELECT id INTO STRICT d FROM public.stock_lots WHERE sku_id=sku AND container_no='AR3F01LATE';
so := 'AR3F01SO';
SELECT x.lock_token INTO STRICT token FROM public.acquire_location_lock('XR801','PICK',so) x;
SELECT x.transaction_id, x.fefo_overridden INTO tx, flag FROM public.complete_picking_with_approvals_and_container_audit('XR801',token,so,jsonb_build_array(jsonb_build_object('lot_id',lot,'qty',1,'barcode','AR3F01C') ||  '{}'::jsonb),false,NULL,'AR3F01 pick') x;
IF (flag=false) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: no FEFO override'; END IF;
IF (NOT EXISTS(SELECT 1 FROM public.fefo_override_events WHERE transaction_id=tx)) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: no FEFO event'; END IF;
IF (NOT EXISTS(SELECT 1 FROM public.audit_log WHERE action='PICK_CONTAINER_PRIORITY_OVERRIDE' AND entity_id=tx::text)) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: no container override'; END IF;
IF ((SELECT s.qty FROM public.stock_lots s WHERE s.id=lot)=4) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: source quantity 4'; END IF;

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
      INSERT INTO pg_temp.ar3_results VALUES (1,'F01','Earliest expiry normal',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (1,'F01','Earliest expiry normal',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

-- F02: Later expiry needs line confirmation
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
item := '{"brand":"AR3F02","description":"AR3F02 regression","variant":"AR3F02","size":"AR3","case_barcode":"AR3F02C","pack_barcode":"AR3F02P","piece_barcode":"AR3F02E","container_no":"AR3F02EARLY","expiry_date":"2098-01-01","case_qty":5,"pack_qty":0,"piece_qty":0,"user_remark":"AR3F02 remark"}'::jsonb;
SELECT x.transaction_id INTO tx FROM public.complete_putaway_with_user_remarks('XR801',jsonb_build_array(item)) x;
SELECT id INTO STRICT sku FROM public.skus WHERE brand='AR3F02';
SELECT id INTO STRICT lot FROM public.stock_lots WHERE sku_id=sku AND location_id=a AND uom='CASE';
c:=lot;
PERFORM public.complete_putaway_with_user_remarks('XR801',jsonb_build_array(item || jsonb_build_object('expiry_date','2099-01-01','container_no','AR3F02LATE')));
SELECT id INTO STRICT d FROM public.stock_lots WHERE sku_id=sku AND container_no='AR3F02LATE';
so := 'AR3F02SO';
SELECT x.lock_token INTO STRICT token FROM public.acquire_location_lock('XR801','PICK',so) x;
lot:=d;

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
SELECT x.transaction_id, x.fefo_overridden INTO tx, flag FROM public.complete_picking_with_approvals_and_container_audit('XR801',token,so,jsonb_build_array(jsonb_build_object('lot_id',lot,'qty',1,'barcode','AR3F02C') ||  '{}'::jsonb),false,NULL,'AR3F02 pick') x;

EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS err = MESSAGE_TEXT, err_code = RETURNED_SQLSTATE;
END;
IF (err IS NOT NULL) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: negative call must reject'; END IF;
IF (err_code='P0001') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected SQLSTATE P0001'; END IF;
IF (err='FEFO_CONFIRMATION_REQUIRED: Confirm the FEFO warning before adding this later-expiring item.') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected rejection: FEFO_CONFIRMATION_REQUIRED: Confirm the FEFO warning before adding this later-expiring item.'; END IF;

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
      INSERT INTO pg_temp.ar3_results VALUES (2,'F02','Later expiry needs line confirmation',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (2,'F02','Later expiry needs line confirmation',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

-- F03: Global FEFO allow required
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
item := '{"brand":"AR3F03","description":"AR3F03 regression","variant":"AR3F03","size":"AR3","case_barcode":"AR3F03C","pack_barcode":"AR3F03P","piece_barcode":"AR3F03E","container_no":"AR3F03EARLY","expiry_date":"2098-01-01","case_qty":5,"pack_qty":0,"piece_qty":0,"user_remark":"AR3F03 remark"}'::jsonb;
SELECT x.transaction_id INTO tx FROM public.complete_putaway_with_user_remarks('XR801',jsonb_build_array(item)) x;
SELECT id INTO STRICT sku FROM public.skus WHERE brand='AR3F03';
SELECT id INTO STRICT lot FROM public.stock_lots WHERE sku_id=sku AND location_id=a AND uom='CASE';
c:=lot;
PERFORM public.complete_putaway_with_user_remarks('XR801',jsonb_build_array(item || jsonb_build_object('expiry_date','2099-01-01','container_no','AR3F03LATE')));
SELECT id INTO STRICT d FROM public.stock_lots WHERE sku_id=sku AND container_no='AR3F03LATE';
so := 'AR3F03SO';
SELECT x.lock_token INTO STRICT token FROM public.acquire_location_lock('XR801','PICK',so) x;
lot:=d;

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
SELECT x.transaction_id, x.fefo_overridden INTO tx, flag FROM public.complete_picking_with_approvals_and_container_audit('XR801',token,so,jsonb_build_array(jsonb_build_object('lot_id',lot,'qty',1,'barcode','AR3F03C') || '{"fefo_override_confirmed":true}'::jsonb),false,NULL,'AR3F03 pick') x;

EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS err = MESSAGE_TEXT, err_code = RETURNED_SQLSTATE;
END;
IF (err IS NOT NULL) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: negative call must reject'; END IF;
IF (err_code='P0001') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected SQLSTATE P0001'; END IF;
IF (err='FEFO_OVERRIDE_REQUIRED: One or more selected lots are not the earliest-expiring available stock.') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected rejection: FEFO_OVERRIDE_REQUIRED: One or more selected lots are not the earliest-expiring available stock.'; END IF;

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
      INSERT INTO pg_temp.ar3_results VALUES (3,'F03','Global FEFO allow required',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (3,'F03','Global FEFO allow required',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

-- F04: FEFO reason required
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
item := '{"brand":"AR3F04","description":"AR3F04 regression","variant":"AR3F04","size":"AR3","case_barcode":"AR3F04C","pack_barcode":"AR3F04P","piece_barcode":"AR3F04E","container_no":"AR3F04EARLY","expiry_date":"2098-01-01","case_qty":5,"pack_qty":0,"piece_qty":0,"user_remark":"AR3F04 remark"}'::jsonb;
SELECT x.transaction_id INTO tx FROM public.complete_putaway_with_user_remarks('XR801',jsonb_build_array(item)) x;
SELECT id INTO STRICT sku FROM public.skus WHERE brand='AR3F04';
SELECT id INTO STRICT lot FROM public.stock_lots WHERE sku_id=sku AND location_id=a AND uom='CASE';
c:=lot;
PERFORM public.complete_putaway_with_user_remarks('XR801',jsonb_build_array(item || jsonb_build_object('expiry_date','2099-01-01','container_no','AR3F04LATE')));
SELECT id INTO STRICT d FROM public.stock_lots WHERE sku_id=sku AND container_no='AR3F04LATE';
so := 'AR3F04SO';
SELECT x.lock_token INTO STRICT token FROM public.acquire_location_lock('XR801','PICK',so) x;
lot:=d;

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
SELECT x.transaction_id, x.fefo_overridden INTO tx, flag FROM public.complete_picking_with_approvals_and_container_audit('XR801',token,so,jsonb_build_array(jsonb_build_object('lot_id',lot,'qty',1,'barcode','AR3F04C') || '{"fefo_override_confirmed":true}'::jsonb),true,'','AR3F04 pick') x;

EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS err = MESSAGE_TEXT, err_code = RETURNED_SQLSTATE;
END;
IF (err IS NOT NULL) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: negative call must reject'; END IF;
IF (err_code='P0001') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected SQLSTATE P0001'; END IF;
IF (err='A reason is required when FEFO is overridden.') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected rejection: A reason is required when FEFO is overridden.'; END IF;

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
      INSERT INTO pg_temp.ar3_results VALUES (4,'F04','FEFO reason required',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (4,'F04','FEFO reason required',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

-- F05: Confirmed FEFO override stores recommendation
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
item := '{"brand":"AR3F05","description":"AR3F05 regression","variant":"AR3F05","size":"AR3","case_barcode":"AR3F05C","pack_barcode":"AR3F05P","piece_barcode":"AR3F05E","container_no":"AR3F05EARLY","expiry_date":"2098-01-01","case_qty":5,"pack_qty":0,"piece_qty":0,"user_remark":"AR3F05 remark"}'::jsonb;
SELECT x.transaction_id INTO tx FROM public.complete_putaway_with_user_remarks('XR801',jsonb_build_array(item)) x;
SELECT id INTO STRICT sku FROM public.skus WHERE brand='AR3F05';
SELECT id INTO STRICT lot FROM public.stock_lots WHERE sku_id=sku AND location_id=a AND uom='CASE';
c:=lot;
PERFORM public.complete_putaway_with_user_remarks('XR801',jsonb_build_array(item || jsonb_build_object('expiry_date','2099-01-01','container_no','AR3F05LATE')));
SELECT id INTO STRICT d FROM public.stock_lots WHERE sku_id=sku AND container_no='AR3F05LATE';
so := 'AR3F05SO';
SELECT x.lock_token INTO STRICT token FROM public.acquire_location_lock('XR801','PICK',so) x;
lot:=d;
SELECT x.transaction_id, x.fefo_overridden INTO tx, flag FROM public.complete_picking_with_approvals_and_container_audit('XR801',token,so,jsonb_build_array(jsonb_build_object('lot_id',lot,'qty',1,'barcode','AR3F05C') || '{"fefo_override_confirmed":true}'::jsonb),true,'AR3 FEFO reason','AR3F05 pick') x;
IF (flag=true) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: FEFO override'; END IF;
IF (EXISTS(SELECT 1 FROM public.fefo_override_events WHERE transaction_id=tx AND lot_id=d AND recommended_lot_id=c AND recommended_location_code='XR801' AND recommended_expiry='2098-01-01' AND override_reason='AR3 FEFO reason')) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: FEFO evidence'; END IF;
IF (EXISTS (SELECT 1 FROM public.audit_log WHERE action='FEFO_OVERRIDE_CONFIRMED' AND after_data->>'transaction_no'=(SELECT tx_no FROM public.transactions WHERE id=tx))) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: audit FEFO_OVERRIDE_CONFIRMED'; END IF;

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
      INSERT INTO pg_temp.ar3_results VALUES (5,'F05','Confirmed FEFO override stores recommendation',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (5,'F05','Confirmed FEFO override stores recommendation',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

-- F06: Expired earlier stock ignored
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
item := '{"brand":"AR3F06","description":"AR3F06 regression","variant":"AR3F06","size":"AR3","case_barcode":"AR3F06C","pack_barcode":"AR3F06P","piece_barcode":"AR3F06E","container_no":"AR3F06EARLY","expiry_date":"2000-01-01","case_qty":5,"pack_qty":0,"piece_qty":0,"user_remark":"AR3F06 remark"}'::jsonb;
SELECT x.transaction_id INTO tx FROM public.complete_putaway_with_user_remarks('XR801',jsonb_build_array(item)) x;
SELECT id INTO STRICT sku FROM public.skus WHERE brand='AR3F06';
SELECT id INTO STRICT lot FROM public.stock_lots WHERE sku_id=sku AND location_id=a AND uom='CASE';
c:=lot;
PERFORM public.complete_putaway_with_user_remarks('XR801',jsonb_build_array(item || jsonb_build_object('expiry_date','2099-01-01','container_no','AR3F06LATE')));
SELECT id INTO STRICT d FROM public.stock_lots WHERE sku_id=sku AND container_no='AR3F06LATE';
so := 'AR3F06SO';
SELECT x.lock_token INTO STRICT token FROM public.acquire_location_lock('XR801','PICK',so) x;
lot:=d;
SELECT x.transaction_id, x.fefo_overridden INTO tx, flag FROM public.complete_picking_with_approvals_and_container_audit('XR801',token,so,jsonb_build_array(jsonb_build_object('lot_id',lot,'qty',1,'barcode','AR3F06C') ||  '{}'::jsonb),false,NULL,'AR3F06 pick') x;
IF (flag=false) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: no FEFO override'; END IF;
IF (NOT EXISTS(SELECT 1 FROM public.fefo_override_events WHERE transaction_id=tx)) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: no FEFO event'; END IF;
IF (NOT EXISTS(SELECT 1 FROM public.audit_log WHERE action='PICK_CONTAINER_PRIORITY_OVERRIDE' AND entity_id=tx::text)) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: no container override'; END IF;
IF ((SELECT s.qty FROM public.stock_lots s WHERE s.id=lot)=4) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: source quantity 4'; END IF;

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
      INSERT INTO pg_temp.ar3_results VALUES (6,'F06','Expired earlier stock ignored',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (6,'F06','Expired earlier stock ignored',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

-- C01: Later same-expiry container needs confirmation
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
item := '{"brand":"AR3C01","description":"AR3C01 regression","variant":"AR3C01","size":"AR3","case_barcode":"AR3C01C","pack_barcode":"AR3C01P","piece_barcode":"AR3C01E","container_no":"2099-001","expiry_date":"2099-01-01","case_qty":5,"pack_qty":0,"piece_qty":0,"user_remark":"AR3C01 remark"}'::jsonb;
SELECT x.transaction_id INTO tx FROM public.complete_putaway_with_user_remarks('XR801',jsonb_build_array(item)) x;
SELECT id INTO STRICT sku FROM public.skus WHERE brand='AR3C01';
SELECT id INTO STRICT lot FROM public.stock_lots WHERE sku_id=sku AND location_id=a AND uom='CASE';
c:=lot;
PERFORM public.complete_putaway_with_user_remarks('XR801',jsonb_build_array(item || jsonb_build_object('expiry_date','2099-01-01','container_no','2099-002')));
SELECT id INTO STRICT d FROM public.stock_lots WHERE sku_id=sku AND container_no='2099-002';
so := 'AR3C01SO';
SELECT x.lock_token INTO STRICT token FROM public.acquire_location_lock('XR801','PICK',so) x;
lot:=d;

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
SELECT x.transaction_id, x.fefo_overridden INTO tx, flag FROM public.complete_picking_with_approvals_and_container_audit('XR801',token,so,jsonb_build_array(jsonb_build_object('lot_id',lot,'qty',1,'barcode','AR3C01C') ||  '{}'::jsonb),false,NULL,'AR3C01 pick') x;

EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS err = MESSAGE_TEXT, err_code = RETURNED_SQLSTATE;
END;
IF (err IS NOT NULL) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: negative call must reject'; END IF;
IF (err_code='P0001') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected SQLSTATE P0001'; END IF;
IF (left(err,41)='CONTAINER_PRIORITY_CONFIRMATION_REQUIRED:') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected rejection: CONTAINER_PRIORITY_CONFIRMATION_REQUIRED:'; END IF;

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
      INSERT INTO pg_temp.ar3_results VALUES (7,'C01','Later same-expiry container needs confirmation',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (7,'C01','Later same-expiry container needs confirmation',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

-- C02: Container confirmation audited without FEFO
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
item := '{"brand":"AR3C02","description":"AR3C02 regression","variant":"AR3C02","size":"AR3","case_barcode":"AR3C02C","pack_barcode":"AR3C02P","piece_barcode":"AR3C02E","container_no":"2099-001","expiry_date":"2099-01-01","case_qty":5,"pack_qty":0,"piece_qty":0,"user_remark":"AR3C02 remark"}'::jsonb;
SELECT x.transaction_id INTO tx FROM public.complete_putaway_with_user_remarks('XR801',jsonb_build_array(item)) x;
SELECT id INTO STRICT sku FROM public.skus WHERE brand='AR3C02';
SELECT id INTO STRICT lot FROM public.stock_lots WHERE sku_id=sku AND location_id=a AND uom='CASE';
c:=lot;
PERFORM public.complete_putaway_with_user_remarks('XR801',jsonb_build_array(item || jsonb_build_object('expiry_date','2099-01-01','container_no','2099-002')));
SELECT id INTO STRICT d FROM public.stock_lots WHERE sku_id=sku AND container_no='2099-002';
so := 'AR3C02SO';
SELECT x.lock_token INTO STRICT token FROM public.acquire_location_lock('XR801','PICK',so) x;
lot:=d;
SELECT x.transaction_id, x.fefo_overridden INTO tx, flag FROM public.complete_picking_with_approvals_and_container_audit('XR801',token,so,jsonb_build_array(jsonb_build_object('lot_id',lot,'qty',1,'barcode','AR3C02C') || '{"container_priority_override_confirmed":true}'::jsonb),false,NULL,'AR3C02 pick') x;
IF (flag=false) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: no FEFO override'; END IF;
IF (NOT EXISTS(SELECT 1 FROM public.fefo_override_events WHERE transaction_id=tx)) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: no FEFO event'; END IF;
IF (EXISTS (SELECT 1 FROM public.audit_log WHERE action='PICK_CONTAINER_PRIORITY_OVERRIDE' AND entity_id=tx::text AND after_data @> '{"selected_container":"2099-002","recommended_container":"2099-001","selected_location":"XR801","recommended_location":"XR801","confirmation_received":true}'::jsonb)) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: audit PICK_CONTAINER_PRIORITY_OVERRIDE'; END IF;

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
      INSERT INTO pg_temp.ar3_results VALUES (8,'C02','Container confirmation audited without FEFO',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (8,'C02','Container confirmation audited without FEFO',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

-- C03: Expiry outranks container sequence
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
item := '{"brand":"AR3C03","description":"AR3C03 regression","variant":"AR3C03","size":"AR3","case_barcode":"AR3C03C","pack_barcode":"AR3C03P","piece_barcode":"AR3C03E","container_no":"2099-099","expiry_date":"2098-01-01","case_qty":5,"pack_qty":0,"piece_qty":0,"user_remark":"AR3C03 remark"}'::jsonb;
SELECT x.transaction_id INTO tx FROM public.complete_putaway_with_user_remarks('XR801',jsonb_build_array(item)) x;
SELECT id INTO STRICT sku FROM public.skus WHERE brand='AR3C03';
SELECT id INTO STRICT lot FROM public.stock_lots WHERE sku_id=sku AND location_id=a AND uom='CASE';
c:=lot;
PERFORM public.complete_putaway_with_user_remarks('XR801',jsonb_build_array(item || jsonb_build_object('expiry_date','2099-01-01','container_no','2099-001')));
SELECT id INTO STRICT d FROM public.stock_lots WHERE sku_id=sku AND container_no='2099-001';
so := 'AR3C03SO';
SELECT x.lock_token INTO STRICT token FROM public.acquire_location_lock('XR801','PICK',so) x;
SELECT x.transaction_id, x.fefo_overridden INTO tx, flag FROM public.complete_picking_with_approvals_and_container_audit('XR801',token,so,jsonb_build_array(jsonb_build_object('lot_id',lot,'qty',1,'barcode','AR3C03C') ||  '{}'::jsonb),false,NULL,'AR3C03 pick') x;
IF (flag=false) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: no FEFO override'; END IF;
IF (NOT EXISTS(SELECT 1 FROM public.fefo_override_events WHERE transaction_id=tx)) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: no FEFO event'; END IF;
IF (NOT EXISTS(SELECT 1 FROM public.audit_log WHERE action='PICK_CONTAINER_PRIORITY_OVERRIDE' AND entity_id=tx::text)) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: no container override'; END IF;

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
      INSERT INTO pg_temp.ar3_results VALUES (9,'C03','Expiry outranks container sequence',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (9,'C03','Expiry outranks container sequence',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

-- C04: Fully queued earlier container permits next
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
item := '{"brand":"AR3C04","description":"AR3C04 regression","variant":"AR3C04","size":"AR3","case_barcode":"AR3C04C","pack_barcode":"AR3C04P","piece_barcode":"AR3C04E","container_no":"2099-001","expiry_date":"2099-01-01","case_qty":5,"pack_qty":0,"piece_qty":0,"user_remark":"AR3C04 remark"}'::jsonb;
SELECT x.transaction_id INTO tx FROM public.complete_putaway_with_user_remarks('XR801',jsonb_build_array(item)) x;
SELECT id INTO STRICT sku FROM public.skus WHERE brand='AR3C04';
SELECT id INTO STRICT lot FROM public.stock_lots WHERE sku_id=sku AND location_id=a AND uom='CASE';
c:=lot;
PERFORM public.complete_putaway_with_user_remarks('XR801',jsonb_build_array(item || jsonb_build_object('expiry_date','2099-01-01','container_no','2099-002')));
SELECT id INTO STRICT d FROM public.stock_lots WHERE sku_id=sku AND container_no='2099-002';
so := 'AR3C04SO';
SELECT x.lock_token INTO STRICT token FROM public.acquire_location_lock('XR801','PICK',so) x;
SELECT x.transaction_id,x.fefo_overridden INTO tx,flag FROM public.complete_picking_with_approvals_and_container_audit('XR801',token,so,jsonb_build_array(jsonb_build_object('lot_id',c,'qty',5,'barcode','AR3C04C'),jsonb_build_object('lot_id',d,'qty',1,'barcode','AR3C04C')),false,NULL,'AR3 cart') x;
IF (flag=false) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: no FEFO override'; END IF;
IF (NOT EXISTS(SELECT 1 FROM public.fefo_override_events WHERE transaction_id=tx)) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: no FEFO event'; END IF;
IF (NOT EXISTS(SELECT 1 FROM public.audit_log WHERE action='PICK_CONTAINER_PRIORITY_OVERRIDE' AND entity_id=tx::text)) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: no container override'; END IF;
IF (coalesce((SELECT qty FROM public.stock_lots WHERE id=c),0)=0 AND (SELECT qty FROM public.stock_lots WHERE id=d)=4) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: cart balances'; END IF;

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
      INSERT INTO pg_temp.ar3_results VALUES (10,'C04','Fully queued earlier container permits next',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (10,'C04','Fully queued earlier container permits next',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

SELECT jsonb_build_object(
  'suite','AR-3.5 FEFO + Container Priority',
  'expected_total',10,
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

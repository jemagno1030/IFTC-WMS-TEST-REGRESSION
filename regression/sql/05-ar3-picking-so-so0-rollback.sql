-- AR-3.4 Picking / SO / SO-0: 9 scenarios.
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

-- S01: Empty SO cancellation releases order and lock
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
so := 'AR3S01SO';
SELECT x.lock_token INTO STRICT token FROM public.acquire_location_lock('XR801','PICK',so) x;
SELECT x.result_action INTO status_text FROM public.cancel_empty_pick_sales_order(so) x;
IF (status_text='CANCELLED_REUSABLE') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: reusable cancellation'; END IF;
IF (NOT EXISTS(SELECT 1 FROM public.pick_sales_orders WHERE sales_order=so)) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: SO removed'; END IF;
IF (NOT EXISTS(SELECT 1 FROM public.location_locks WHERE location_id IN(a,b))) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: fixture rack locks cleared'; END IF;
IF (EXISTS (SELECT 1 FROM public.audit_log WHERE action='CANCEL_EMPTY_PICK_SALES_ORDER' AND true)) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: audit CANCEL_EMPTY_PICK_SALES_ORDER'; END IF;

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
      INSERT INTO pg_temp.ar3_results VALUES (1,'S01','Empty SO cancellation releases order and lock',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (1,'S01','Empty SO cancellation releases order and lock',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

-- S02: Saved pick blocks cancel and permits Finish
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
item := '{"brand":"AR3S02","description":"AR3S02 regression","variant":"AR3S02","size":"AR3","case_barcode":"AR3S02C","pack_barcode":"AR3S02P","piece_barcode":"AR3S02E","container_no":"AR3S02BOX","expiry_date":"2099-12-31","case_qty":5,"pack_qty":0,"piece_qty":0,"user_remark":"AR3S02 remark"}'::jsonb;
SELECT x.transaction_id INTO tx FROM public.complete_putaway_with_user_remarks('XR801',jsonb_build_array(item)) x;
SELECT id INTO STRICT sku FROM public.skus WHERE brand='AR3S02';
SELECT id INTO STRICT lot FROM public.stock_lots WHERE sku_id=sku AND location_id=a AND uom='CASE';
so := 'AR3S02SO';
SELECT x.lock_token INTO STRICT token FROM public.acquire_location_lock('XR801','PICK',so) x;
SELECT x.transaction_id, x.fefo_overridden INTO tx, flag FROM public.complete_picking_with_approvals_and_container_audit('XR801',token,so,jsonb_build_array(jsonb_build_object('lot_id',lot,'qty',1,'barcode','AR3S02C') ||  '{}'::jsonb),false,NULL,'AR3S02 pick') x;
SELECT id INTO STRICT line FROM public.transaction_lines WHERE transaction_id=tx AND signed_qty<0;
IF ((SELECT s.qty FROM public.stock_lots s WHERE s.id=lot)=4) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: source quantity 4'; END IF;

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
PERFORM public.cancel_empty_pick_sales_order(so);
EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS err = MESSAGE_TEXT, err_code = RETURNED_SQLSTATE;
END;
IF (err IS NOT NULL) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: negative call must reject'; END IF;
IF (err_code='P0001') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected SQLSTATE P0001'; END IF;
IF (left(err,22)='CANNOT_CANCEL_PICKING:') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected rejection: CANNOT_CANCEL_PICKING:'; END IF;

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
SELECT x.result_status, x.pick_transaction_count INTO status_text,n FROM public.finish_pick_sales_order(so) x;
IF (status_text='COMPLETED' AND n=1) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: one-pick completion'; END IF;

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
      INSERT INTO pg_temp.ar3_results VALUES (2,'S02','Saved pick blocks cancel and permits Finish',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (2,'S02','Saved pick blocks cancel and permits Finish',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

-- S03: Completed SO reuse blocked
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
item := '{"brand":"AR3S03","description":"AR3S03 regression","variant":"AR3S03","size":"AR3","case_barcode":"AR3S03C","pack_barcode":"AR3S03P","piece_barcode":"AR3S03E","container_no":"AR3S03BOX","expiry_date":"2099-12-31","case_qty":5,"pack_qty":0,"piece_qty":0,"user_remark":"AR3S03 remark"}'::jsonb;
SELECT x.transaction_id INTO tx FROM public.complete_putaway_with_user_remarks('XR801',jsonb_build_array(item)) x;
SELECT id INTO STRICT sku FROM public.skus WHERE brand='AR3S03';
SELECT id INTO STRICT lot FROM public.stock_lots WHERE sku_id=sku AND location_id=a AND uom='CASE';
so := 'AR3S03SO';
SELECT x.lock_token INTO STRICT token FROM public.acquire_location_lock('XR801','PICK',so) x;
SELECT x.transaction_id, x.fefo_overridden INTO tx, flag FROM public.complete_picking_with_approvals_and_container_audit('XR801',token,so,jsonb_build_array(jsonb_build_object('lot_id',lot,'qty',1,'barcode','AR3S03C') ||  '{}'::jsonb),false,NULL,'AR3S03 pick') x;
SELECT id INTO STRICT line FROM public.transaction_lines WHERE transaction_id=tx AND signed_qty<0;
SELECT x.result_status, x.pick_transaction_count INTO status_text,n FROM public.finish_pick_sales_order(so) x;

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
SELECT x.lock_token INTO STRICT token FROM public.acquire_location_lock('XR801','PICK',so) x;

EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS err = MESSAGE_TEXT, err_code = RETURNED_SQLSTATE;
END;
IF (err IS NOT NULL) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: negative call must reject'; END IF;
IF (err_code='P0001') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected SQLSTATE P0001'; END IF;
IF (left(err,30)='SALES_ORDER_ALREADY_COMPLETED:') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected rejection: SALES_ORDER_ALREADY_COMPLETED:'; END IF;

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
      INSERT INTO pg_temp.ar3_results VALUES (3,'S03','Completed SO reuse blocked',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (3,'S03','Completed SO reuse blocked',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

-- S04: Completed SO cancel blocked
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
item := '{"brand":"AR3S04","description":"AR3S04 regression","variant":"AR3S04","size":"AR3","case_barcode":"AR3S04C","pack_barcode":"AR3S04P","piece_barcode":"AR3S04E","container_no":"AR3S04BOX","expiry_date":"2099-12-31","case_qty":5,"pack_qty":0,"piece_qty":0,"user_remark":"AR3S04 remark"}'::jsonb;
SELECT x.transaction_id INTO tx FROM public.complete_putaway_with_user_remarks('XR801',jsonb_build_array(item)) x;
SELECT id INTO STRICT sku FROM public.skus WHERE brand='AR3S04';
SELECT id INTO STRICT lot FROM public.stock_lots WHERE sku_id=sku AND location_id=a AND uom='CASE';
so := 'AR3S04SO';
SELECT x.lock_token INTO STRICT token FROM public.acquire_location_lock('XR801','PICK',so) x;
SELECT x.transaction_id, x.fefo_overridden INTO tx, flag FROM public.complete_picking_with_approvals_and_container_audit('XR801',token,so,jsonb_build_array(jsonb_build_object('lot_id',lot,'qty',1,'barcode','AR3S04C') ||  '{}'::jsonb),false,NULL,'AR3S04 pick') x;
SELECT id INTO STRICT line FROM public.transaction_lines WHERE transaction_id=tx AND signed_qty<0;
SELECT x.result_status, x.pick_transaction_count INTO status_text,n FROM public.finish_pick_sales_order(so) x;

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
PERFORM public.cancel_empty_pick_sales_order(so);
EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS err = MESSAGE_TEXT, err_code = RETURNED_SQLSTATE;
END;
IF (err IS NOT NULL) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: negative call must reject'; END IF;
IF (err_code='P0001') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected SQLSTATE P0001'; END IF;
IF (err='Only an OPEN picking Sales Order can be cancelled.') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected rejection: Only an OPEN picking Sales Order can be cancelled.'; END IF;

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
      INSERT INTO pg_temp.ar3_results VALUES (4,'S04','Completed SO cancel blocked',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (4,'S04','Completed SO cancel blocked',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

-- S05: Approved reopen, repick and complete
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
item := '{"brand":"AR3S05","description":"AR3S05 regression","variant":"AR3S05","size":"AR3","case_barcode":"AR3S05C","pack_barcode":"AR3S05P","piece_barcode":"AR3S05E","container_no":"AR3S05BOX","expiry_date":"2099-12-31","case_qty":5,"pack_qty":0,"piece_qty":0,"user_remark":"AR3S05 remark"}'::jsonb;
SELECT x.transaction_id INTO tx FROM public.complete_putaway_with_user_remarks('XR801',jsonb_build_array(item)) x;
SELECT id INTO STRICT sku FROM public.skus WHERE brand='AR3S05';
SELECT id INTO STRICT lot FROM public.stock_lots WHERE sku_id=sku AND location_id=a AND uom='CASE';
so := 'AR3S05SO';
SELECT x.lock_token INTO STRICT token FROM public.acquire_location_lock('XR801','PICK',so) x;
SELECT x.transaction_id, x.fefo_overridden INTO tx, flag FROM public.complete_picking_with_approvals_and_container_audit('XR801',token,so,jsonb_build_array(jsonb_build_object('lot_id',lot,'qty',1,'barcode','AR3S05C') ||  '{}'::jsonb),false,NULL,'AR3S05 pick') x;
SELECT id INTO STRICT line FROM public.transaction_lines WHERE transaction_id=tx AND signed_qty<0;
SELECT x.result_status, x.pick_transaction_count INTO status_text,n FROM public.finish_pick_sales_order(so) x;
SELECT x.approval_token INTO c FROM public.approve_sales_order_reopen_request(auth.uid(),so,'AR3 reopen reason') x;
PERFORM public.reopen_completed_sales_order_approved(so,'AR3 reopen reason',c);
IF (EXISTS(SELECT 1 FROM public.pick_sales_orders WHERE sales_order=so AND status='OPEN' AND override_count=1 AND last_override_by=auth.uid() AND last_override_reason='AR3 reopen reason' AND last_override_at IS NOT NULL)) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: reopened SO metadata'; END IF;
IF (EXISTS (SELECT 1 FROM public.audit_log WHERE action='SALES_ORDER_REOPEN_APPROVAL_GRANTED' AND true)) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: audit SALES_ORDER_REOPEN_APPROVAL_GRANTED'; END IF;
IF (EXISTS (SELECT 1 FROM public.audit_log WHERE action='SUPERVISOR_REOPEN_PICK_SALES_ORDER' AND true)) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: audit SUPERVISOR_REOPEN_PICK_SALES_ORDER'; END IF;
SELECT x.lock_token INTO STRICT token FROM public.acquire_location_lock('XR801','PICK',so) x;
SELECT x.transaction_id, x.fefo_overridden INTO tx, flag FROM public.complete_picking_with_approvals_and_container_audit('XR801',token,so,jsonb_build_array(jsonb_build_object('lot_id',lot,'qty',1,'barcode','AR3S05C') ||  '{}'::jsonb),false,NULL,'AR3S05 pick') x;
SELECT x.result_status, x.pick_transaction_count INTO status_text,n FROM public.finish_pick_sales_order(so) x;
IF (status_text='COMPLETED') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: second completion; stable now() cycle count deliberately not gated'; END IF;
IF ((SELECT s.qty FROM public.stock_lots s WHERE s.id=lot)=3) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: source quantity 3'; END IF;

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
      INSERT INTO pg_temp.ar3_results VALUES (5,'S05','Approved reopen, repick and complete',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (5,'S05','Approved reopen, repick and complete',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

-- S06: Finish blocked by active source session
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
so := 'AR3S06SO';
SELECT x.lock_token INTO STRICT token FROM public.acquire_location_lock('XR801','PICK',so) x;

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
PERFORM public.finish_pick_sales_order(so);
EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS err = MESSAGE_TEXT, err_code = RETURNED_SQLSTATE;
END;
IF (err IS NOT NULL) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: negative call must reject'; END IF;
IF (err_code='P0001') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected SQLSTATE P0001'; END IF;
IF (err='Complete or cancel the active source-rack session before finishing the sales order.') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected rejection: Complete or cancel the active source-rack session before finishing the sales order.'; END IF;

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
PERFORM public.cancel_empty_pick_sales_order(so);
IF (NOT EXISTS(SELECT 1 FROM public.location_locks WHERE location_id IN(a,b))) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: fixture rack locks cleared'; END IF;
IF (NOT EXISTS(SELECT 1 FROM public.pick_sales_orders WHERE sales_order=so)) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: empty SO cleaned'; END IF;

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
      INSERT INTO pg_temp.ar3_results VALUES (6,'S06','Finish blocked by active source session',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (6,'S06','Finish blocked by active source session',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

-- S07: SO-0 requires remarks then saves adjustment
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
item := '{"brand":"AR3S07","description":"AR3S07 regression","variant":"AR3S07","size":"AR3","case_barcode":"AR3S07C","pack_barcode":"AR3S07P","piece_barcode":"AR3S07E","container_no":"AR3S07BOX","expiry_date":"2099-12-31","case_qty":5,"pack_qty":0,"piece_qty":0,"user_remark":"AR3S07 remark"}'::jsonb;
SELECT x.transaction_id INTO tx FROM public.complete_putaway_with_user_remarks('XR801',jsonb_build_array(item)) x;
SELECT id INTO STRICT sku FROM public.skus WHERE brand='AR3S07';
SELECT id INTO STRICT lot FROM public.stock_lots WHERE sku_id=sku AND location_id=a AND uom='CASE';
SELECT x.lock_token,x.adjustment_session_key INTO token,session_key FROM public.acquire_stock_adjustment_pick_lock('XR801') x;

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
SELECT x.transaction_id INTO tx FROM public.complete_stock_adjustment_picking_with_remarks('XR801',token,session_key,jsonb_build_array(jsonb_build_object('lot_id',lot,'qty',1,'barcode','AR3S07C')),'',false,NULL) x;

EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS err = MESSAGE_TEXT, err_code = RETURNED_SQLSTATE;
END;
IF (err IS NOT NULL) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: negative call must reject'; END IF;
IF (err_code='P0001') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected SQLSTATE P0001'; END IF;
IF (err='STOCK_ADJUSTMENT_REMARKS_REQUIRED: Enter why the Warehouse Stock Adjustment is necessary.') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected rejection: STOCK_ADJUSTMENT_REMARKS_REQUIRED: Enter why the Warehouse Stock Adjustment is necessary.'; END IF;

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
SELECT x.transaction_id INTO tx FROM public.complete_stock_adjustment_picking_with_remarks('XR801',token,session_key,jsonb_build_array(jsonb_build_object('lot_id',lot,'qty',1,'barcode','AR3S07C')),'AR3 adjustment reason',false,NULL) x;
IF ((SELECT s.qty FROM public.stock_lots s WHERE s.id=lot)=4) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: source quantity 4'; END IF;
IF (EXISTS(SELECT 1 FROM public.transactions WHERE id=tx AND transaction_type='PICK' AND sales_order='0')) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: SO-0 PICK'; END IF;
IF (NOT EXISTS(SELECT 1 FROM public.pick_sales_orders WHERE order_key=session_key)) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: SO-0 control removed'; END IF;
IF (NOT EXISTS(SELECT 1 FROM public.location_locks WHERE location_id IN(a,b))) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: fixture rack locks cleared'; END IF;
IF (EXISTS (SELECT 1 FROM public.audit_log WHERE action='WAREHOUSE_STOCK_ADJUSTMENT_PICK' AND true)) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: audit WAREHOUSE_STOCK_ADJUSTMENT_PICK'; END IF;

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
      INSERT INTO pg_temp.ar3_results VALUES (7,'S07','SO-0 requires remarks then saves adjustment',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (7,'S07','SO-0 requires remarks then saves adjustment',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

-- S08: Two independent SO-0 sessions
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
item := '{"brand":"AR3S08","description":"AR3S08 regression","variant":"AR3S08","size":"AR3","case_barcode":"AR3S08C","pack_barcode":"AR3S08P","piece_barcode":"AR3S08E","container_no":"AR3S08BOX","expiry_date":"2099-12-31","case_qty":5,"pack_qty":0,"piece_qty":0,"user_remark":"AR3S08 remark"}'::jsonb;
SELECT x.transaction_id INTO tx FROM public.complete_putaway_with_user_remarks('XR801',jsonb_build_array(item)) x;
SELECT id INTO STRICT sku FROM public.skus WHERE brand='AR3S08';
SELECT id INTO STRICT lot FROM public.stock_lots WHERE sku_id=sku AND location_id=a AND uom='CASE';
SELECT x.lock_token,x.adjustment_session_key INTO token,session_key FROM public.acquire_stock_adjustment_pick_lock('XR801') x;
old_key:=session_key;
SELECT x.transaction_id INTO tx FROM public.complete_stock_adjustment_picking_with_remarks('XR801',token,session_key,jsonb_build_array(jsonb_build_object('lot_id',lot,'qty',1,'barcode','AR3S08C')),'AR3 adjustment reason',false,NULL) x;
IF (EXISTS(SELECT 1 FROM public.transactions WHERE id=tx AND transaction_type='PICK' AND sales_order='0')) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: SO-0 PICK'; END IF;
IF (NOT EXISTS(SELECT 1 FROM public.pick_sales_orders WHERE order_key=session_key)) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: SO-0 control removed'; END IF;
IF (NOT EXISTS(SELECT 1 FROM public.location_locks WHERE location_id IN(a,b))) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: fixture rack locks cleared'; END IF;
IF (EXISTS (SELECT 1 FROM public.audit_log WHERE action='WAREHOUSE_STOCK_ADJUSTMENT_PICK' AND true)) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: audit WAREHOUSE_STOCK_ADJUSTMENT_PICK'; END IF;
SELECT x.lock_token,x.adjustment_session_key INTO token,session_key FROM public.acquire_stock_adjustment_pick_lock('XR801') x;
IF (session_key<>old_key) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: fresh adjustment key'; END IF;
SELECT x.transaction_id INTO tx FROM public.complete_stock_adjustment_picking_with_remarks('XR801',token,session_key,jsonb_build_array(jsonb_build_object('lot_id',lot,'qty',1,'barcode','AR3S08C')),'AR3 adjustment reason',false,NULL) x;
IF (EXISTS(SELECT 1 FROM public.transactions WHERE id=tx AND transaction_type='PICK' AND sales_order='0')) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: SO-0 PICK'; END IF;
IF (NOT EXISTS(SELECT 1 FROM public.pick_sales_orders WHERE order_key=session_key)) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: SO-0 control removed'; END IF;
IF (NOT EXISTS(SELECT 1 FROM public.location_locks WHERE location_id IN(a,b))) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: fixture rack locks cleared'; END IF;
IF (EXISTS (SELECT 1 FROM public.audit_log WHERE action='WAREHOUSE_STOCK_ADJUSTMENT_PICK' AND true)) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: audit WAREHOUSE_STOCK_ADJUSTMENT_PICK'; END IF;
IF ((SELECT s.qty FROM public.stock_lots s WHERE s.id=lot)=3) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: source quantity 3'; END IF;
IF ((SELECT count(*) FROM public.transactions WHERE transaction_type='PICK' AND sales_order='0')=2) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: two independent SO-0 PICKs'; END IF;

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
      INSERT INTO pg_temp.ar3_results VALUES (8,'S08','Two independent SO-0 sessions',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (8,'S08','Two independent SO-0 sessions',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

-- S09: SO-0 cancel removes control and lock
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
item := '{"brand":"AR3S09","description":"AR3S09 regression","variant":"AR3S09","size":"AR3","case_barcode":"AR3S09C","pack_barcode":"AR3S09P","piece_barcode":"AR3S09E","container_no":"AR3S09BOX","expiry_date":"2099-12-31","case_qty":5,"pack_qty":0,"piece_qty":0,"user_remark":"AR3S09 remark"}'::jsonb;
SELECT x.transaction_id INTO tx FROM public.complete_putaway_with_user_remarks('XR801',jsonb_build_array(item)) x;
SELECT id INTO STRICT sku FROM public.skus WHERE brand='AR3S09';
SELECT id INTO STRICT lot FROM public.stock_lots WHERE sku_id=sku AND location_id=a AND uom='CASE';
SELECT x.lock_token,x.adjustment_session_key INTO token,session_key FROM public.acquire_stock_adjustment_pick_lock('XR801') x;
PERFORM public.cancel_stock_adjustment_pick(token,session_key,'AR3 cancel adjustment');
IF ((SELECT s.qty FROM public.stock_lots s WHERE s.id=lot)=5) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: source quantity 5'; END IF;
IF (NOT EXISTS(SELECT 1 FROM public.location_locks WHERE location_id IN(a,b))) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: fixture rack locks cleared'; END IF;
IF (NOT EXISTS(SELECT 1 FROM public.pick_sales_orders WHERE order_key=session_key)) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: control row removed'; END IF;
IF (EXISTS(SELECT 1 FROM public.transactions WHERE transaction_type='PICK_CANCEL' AND sales_order='0')) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: SO-0 PICK_CANCEL'; END IF;

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
      INSERT INTO pg_temp.ar3_results VALUES (9,'S09','SO-0 cancel removes control and lock',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (9,'S09','SO-0 cancel removes control and lock',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

SELECT jsonb_build_object(
  'suite','AR-3.4 Picking / SO / SO-0',
  'expected_total',9,
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

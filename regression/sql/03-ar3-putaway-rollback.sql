-- AR-3.2 Put-away: 12 scenarios.
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

-- P01: Barcoded multi-UOM put-away and per-line remarks
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
item := '{"brand":"AR3P01","description":"AR3P01 regression","variant":"AR3P01","size":"AR3","case_barcode":"AR3P01C","pack_barcode":"AR3P01P","piece_barcode":"AR3P01E","container_no":"AR3P01BOX","expiry_date":"2099-12-31","case_qty":4,"pack_qty":3,"piece_qty":2,"user_remark":"AR3P01 remark"}'::jsonb;
SELECT x.transaction_id INTO tx FROM public.complete_putaway_with_user_remarks('XR801',jsonb_build_array(item)) x;
SELECT id INTO STRICT sku FROM public.skus WHERE brand='AR3P01';
SELECT id INTO STRICT lot FROM public.stock_lots WHERE sku_id=sku AND location_id=a AND uom='CASE';
IF ((SELECT jsonb_object_agg(uom,signed_qty) FROM public.transaction_lines WHERE transaction_id=tx)='{"CASE":4,"PACK":3,"PIECE":2}'::jsonb) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: three UOM quantities'; END IF;
IF ((SELECT count(*) FROM public.transaction_lines WHERE transaction_id=tx)=3) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: three lines'; END IF;
IF ((SELECT count(*) FROM public.transaction_line_user_remarks WHERE transaction_id=tx AND remark='AR3P01 remark')=3) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: three mapped remarks'; END IF;
IF (EXISTS (SELECT 1 FROM public.audit_log WHERE action='COMPLETE_PUTAWAY' AND entity_id=tx::text)) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: audit COMPLETE_PUTAWAY'; END IF;
IF (EXISTS (SELECT 1 FROM public.audit_log WHERE action='PUTAWAY_LINE_USER_REMARKS_RECORDED' AND entity_id=tx::text)) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: audit PUTAWAY_LINE_USER_REMARKS_RECORDED'; END IF;

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
      INSERT INTO pg_temp.ar3_results VALUES (1,'P01','Barcoded multi-UOM put-away and per-line remarks',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (1,'P01','Barcoded multi-UOM put-away and per-line remarks',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

-- P02: Negative quantity
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
PERFORM public.complete_putaway_with_user_remarks('XR801',jsonb_build_array('{"brand":"AR3P02","description":"AR3P02 regression","variant":"AR3P02","size":"AR3","case_barcode":"AR3P02C","pack_barcode":"AR3P02P","piece_barcode":"AR3P02E","container_no":"AR3P02BOX","expiry_date":"2099-12-31","case_qty":-1,"pack_qty":0,"piece_qty":0,"user_remark":"AR3P02 remark"}'::jsonb));
EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS err = MESSAGE_TEXT, err_code = RETURNED_SQLSTATE;
END;
IF (err IS NOT NULL) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: negative call must reject'; END IF;
IF (err_code='P0001') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected SQLSTATE P0001'; END IF;
IF (err='PIECE, PACK, and CASE quantities cannot be negative.') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected rejection: PIECE, PACK, and CASE quantities cannot be negative.'; END IF;

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
      INSERT INTO pg_temp.ar3_results VALUES (2,'P02','Negative quantity',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (2,'P02','Negative quantity',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

-- P03: Decimal quantity
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
PERFORM public.complete_putaway_with_user_remarks('XR801',jsonb_build_array('{"brand":"AR3P03","description":"AR3P03 regression","variant":"AR3P03","size":"AR3","case_barcode":"AR3P03C","pack_barcode":"AR3P03P","piece_barcode":"AR3P03E","container_no":"AR3P03BOX","expiry_date":"2099-12-31","case_qty":1.5,"pack_qty":0,"piece_qty":0,"user_remark":"AR3P03 remark"}'::jsonb));
EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS err = MESSAGE_TEXT, err_code = RETURNED_SQLSTATE;
END;
IF (err IS NOT NULL) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: negative call must reject'; END IF;
IF (err_code='P0001') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected SQLSTATE P0001'; END IF;
IF (err='PIECE, PACK, and CASE quantities must be whole numbers only.') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected rejection: PIECE, PACK, and CASE quantities must be whole numbers only.'; END IF;

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
      INSERT INTO pg_temp.ar3_results VALUES (3,'P03','Decimal quantity',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (3,'P03','Decimal quantity',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

-- P04: All-zero quantities
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
PERFORM public.complete_putaway_with_user_remarks('XR801',jsonb_build_array('{"brand":"AR3P04","description":"AR3P04 regression","variant":"AR3P04","size":"AR3","case_barcode":"AR3P04C","pack_barcode":"AR3P04P","piece_barcode":"AR3P04E","container_no":"AR3P04BOX","expiry_date":"2099-12-31","case_qty":0,"pack_qty":0,"piece_qty":0,"user_remark":"AR3P04 remark"}'::jsonb));
EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS err = MESSAGE_TEXT, err_code = RETURNED_SQLSTATE;
END;
IF (err IS NOT NULL) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: negative call must reject'; END IF;
IF (err_code='P0001') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected SQLSTATE P0001'; END IF;
IF (err='Every SKU line requires a manually entered PIECE, PACK, or CASE quantity.') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected rejection: Every SKU line requires a manually entered PIECE, PACK, or CASE quantity.'; END IF;

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
      INSERT INTO pg_temp.ar3_results VALUES (4,'P04','All-zero quantities',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (4,'P04','All-zero quantities',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

-- P05: Missing expiry
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
PERFORM public.complete_putaway_with_user_remarks('XR801',jsonb_build_array('{"brand":"AR3P05","description":"AR3P05 regression","variant":"AR3P05","size":"AR3","case_barcode":"AR3P05C","pack_barcode":"AR3P05P","piece_barcode":"AR3P05E","container_no":"AR3P05BOX","expiry_date":"","case_qty":5,"pack_qty":0,"piece_qty":0,"user_remark":"AR3P05 remark"}'::jsonb));
EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS err = MESSAGE_TEXT, err_code = RETURNED_SQLSTATE;
END;
IF (err IS NOT NULL) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: negative call must reject'; END IF;
IF (err_code='P0001') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected SQLSTATE P0001'; END IF;
IF (err='Every SKU line requires a manually entered expiry date.') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected rejection: Every SKU line requires a manually entered expiry date.'; END IF;

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
      INSERT INTO pg_temp.ar3_results VALUES (5,'P05','Missing expiry',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (5,'P05','Missing expiry',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

-- P06: Missing container
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
PERFORM public.complete_putaway_with_user_remarks('XR801',jsonb_build_array('{"brand":"AR3P06","description":"AR3P06 regression","variant":"AR3P06","size":"AR3","case_barcode":"AR3P06C","pack_barcode":"AR3P06P","piece_barcode":"AR3P06E","container_no":"","expiry_date":"2099-12-31","case_qty":5,"pack_qty":0,"piece_qty":0,"user_remark":"AR3P06 remark"}'::jsonb));
EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS err = MESSAGE_TEXT, err_code = RETURNED_SQLSTATE;
END;
IF (err IS NOT NULL) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: negative call must reject'; END IF;
IF (err_code='P0001') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected SQLSTATE P0001'; END IF;
IF (err='Every SKU line requires a manually entered container number.') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected rejection: Every SKU line requires a manually entered container number.'; END IF;

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
      INSERT INTO pg_temp.ar3_results VALUES (6,'P06','Missing container',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (6,'P06','Missing container',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

-- P07: Duplicate exact row
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
item := '{"brand":"AR3P07","description":"AR3P07 regression","variant":"AR3P07","size":"AR3","case_barcode":"AR3P07C","pack_barcode":"AR3P07P","piece_barcode":"AR3P07E","container_no":"AR3P07BOX","expiry_date":"2099-12-31","case_qty":5,"pack_qty":0,"piece_qty":0,"user_remark":"AR3P07 remark"}'::jsonb;

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
PERFORM public.complete_putaway_with_user_remarks('XR801',jsonb_build_array(item,item));
EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS err = MESSAGE_TEXT, err_code = RETURNED_SQLSTATE;
END;
IF (err IS NOT NULL) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: negative call must reject'; END IF;
IF (err_code='P0001') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected SQLSTATE P0001'; END IF;
IF (left(err,33)='PUTAWAY_REMARK_MAPPING_AMBIGUOUS:') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected rejection: PUTAWAY_REMARK_MAPPING_AMBIGUOUS:'; END IF;

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
      INSERT INTO pg_temp.ar3_results VALUES (7,'P07','Duplicate exact row',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (7,'P07','Duplicate exact row',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

-- P08: All N/A without explicit selection
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
PERFORM public.complete_putaway_with_user_remarks('XR801',jsonb_build_array('{"brand":"AR3P08","description":"AR3P08 regression","variant":"AR3P08","size":"AR3","case_barcode":"N/A","pack_barcode":"N/A","piece_barcode":"N/A","container_no":"AR3P08BOX","expiry_date":"2099-12-31","case_qty":5,"pack_qty":0,"piece_qty":0,"user_remark":"AR3P08 remark"}'::jsonb));
EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS err = MESSAGE_TEXT, err_code = RETURNED_SQLSTATE;
END;
IF (err IS NOT NULL) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: negative call must reject'; END IF;
IF (err_code='P0001') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected SQLSTATE P0001'; END IF;
IF (left(err,35)='BARCODELESS_SKU_SELECTION_REQUIRED:') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected rejection: BARCODELESS_SKU_SELECTION_REQUIRED:'; END IF;

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
      INSERT INTO pg_temp.ar3_results VALUES (8,'P08','All N/A without explicit selection',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (8,'P08','All N/A without explicit selection',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

-- P09: Explicit barcode-less creation
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
item := '{"brand":"AR3P09","description":"AR3P09 regression","variant":"AR3P09","size":"AR3","case_barcode":"N/A","pack_barcode":"N/A","piece_barcode":"N/A","container_no":"AR3P09BOX","expiry_date":"2099-12-31","case_qty":5,"pack_qty":0,"piece_qty":0,"user_remark":"AR3P09 remark","create_barcode_less_sku":true}'::jsonb;
SELECT x.transaction_id INTO tx FROM public.complete_putaway_with_user_remarks('XR801',jsonb_build_array(item)) x;
SELECT id INTO STRICT sku FROM public.skus WHERE brand='AR3P09';
SELECT id INTO STRICT lot FROM public.stock_lots WHERE sku_id=sku AND location_id=a AND uom='CASE';
IF ((SELECT s.qty FROM public.stock_lots s WHERE s.id=lot)=5) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: source quantity 5'; END IF;
IF (EXISTS (SELECT 1 FROM public.audit_log WHERE action='ADD_BARCODELESS_SKU' AND entity_id=sku::text)) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: audit ADD_BARCODELESS_SKU'; END IF;
IF (EXISTS(SELECT 1 FROM public.transaction_line_user_remarks WHERE transaction_id=tx AND remark='AR3P09 remark')) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: barcode-less remark'; END IF;

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
      INSERT INTO pg_temp.ar3_results VALUES (9,'P09','Explicit barcode-less creation',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (9,'P09','Explicit barcode-less creation',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

-- P10: Partial N/A
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
item := '{"brand":"AR3P10","description":"AR3P10 regression","variant":"AR3P10","size":"AR3","case_barcode":"AR3P10C","pack_barcode":"N/A","piece_barcode":"N/A","container_no":"AR3P10BOX","expiry_date":"2099-12-31","case_qty":5,"pack_qty":0,"piece_qty":0,"user_remark":"AR3P10 remark"}'::jsonb;
SELECT x.transaction_id INTO tx FROM public.complete_putaway_with_user_remarks('XR801',jsonb_build_array(item)) x;
SELECT id INTO STRICT sku FROM public.skus WHERE brand='AR3P10';
SELECT id INTO STRICT lot FROM public.stock_lots WHERE sku_id=sku AND location_id=a AND uom='CASE';
IF ((SELECT s.qty FROM public.stock_lots s WHERE s.id=lot)=5) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: source quantity 5'; END IF;

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
      INSERT INTO pg_temp.ar3_results VALUES (10,'P10','Partial N/A',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (10,'P10','Partial N/A',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

-- P11: Inactive physical rack
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
SELECT code INTO STRICT rack_code FROM public.locations WHERE NOT is_active AND NOT is_pending ORDER BY code LIMIT 1;

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
PERFORM public.complete_putaway_with_user_remarks(rack_code,jsonb_build_array('{"brand":"AR3P11","description":"AR3P11 regression","variant":"AR3P11","size":"AR3","case_barcode":"AR3P11C","pack_barcode":"AR3P11P","piece_barcode":"AR3P11E","container_no":"AR3P11BOX","expiry_date":"2099-12-31","case_qty":5,"pack_qty":0,"piece_qty":0,"user_remark":"AR3P11 remark"}'::jsonb));
EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS err = MESSAGE_TEXT, err_code = RETURNED_SQLSTATE;
END;
IF (err IS NOT NULL) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: negative call must reject'; END IF;
IF (err_code='P0001') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected SQLSTATE P0001'; END IF;
IF (err='Rack location not found or inactive.') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected rejection: Rack location not found or inactive.'; END IF;

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
      INSERT INTO pg_temp.ar3_results VALUES (11,'P11','Inactive physical rack',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (11,'P11','Inactive physical rack',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

-- P12: Remark length boundary
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
PERFORM public.complete_putaway_with_user_remarks('XR801',jsonb_build_array('{"brand":"AR3P12","description":"AR3P12 regression","variant":"AR3P12","size":"AR3","case_barcode":"AR3P12C","pack_barcode":"AR3P12P","piece_barcode":"AR3P12E","container_no":"AR3P12BOX","expiry_date":"2099-12-31","case_qty":5,"pack_qty":0,"piece_qty":0,"user_remark":"AR3P12 remark"}'::jsonb || jsonb_build_object('user_remark',repeat('x',1001))));
EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS err = MESSAGE_TEXT, err_code = RETURNED_SQLSTATE;
END;
IF (err IS NOT NULL) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: negative call must reject'; END IF;
IF (err_code='P0001') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected SQLSTATE P0001'; END IF;
IF (err='Put-away line remarks are limited to 1,000 characters.') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected rejection: Put-away line remarks are limited to 1,000 characters.'; END IF;

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
      INSERT INTO pg_temp.ar3_results VALUES (12,'P12','Remark length boundary',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (12,'P12','Remark length boundary',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

SELECT jsonb_build_object(
  'suite','AR-3.2 Put-away',
  'expected_total',12,
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

-- AR-3.6 Saved Pick Correction: 12 scenarios.
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

-- SP01: Report physical return without stock restoration
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
item := '{"brand":"AR3SP01","description":"AR3SP01 regression","variant":"AR3SP01","size":"AR3","case_barcode":"AR3SP01C","pack_barcode":"AR3SP01P","piece_barcode":"AR3SP01E","container_no":"AR3SP01BOX","expiry_date":"2099-12-31","case_qty":5,"pack_qty":0,"piece_qty":0,"user_remark":"AR3SP01 remark"}'::jsonb;
SELECT x.transaction_id INTO tx FROM public.complete_putaway_with_user_remarks('XR801',jsonb_build_array(item)) x;
SELECT id INTO STRICT sku FROM public.skus WHERE brand='AR3SP01';
SELECT id INTO STRICT lot FROM public.stock_lots WHERE sku_id=sku AND location_id=a AND uom='CASE';
so := 'AR3SP01SO';
SELECT x.lock_token INTO STRICT token FROM public.acquire_location_lock('XR801','PICK',so) x;
SELECT x.transaction_id, x.fefo_overridden INTO tx, flag FROM public.complete_picking_with_approvals_and_container_audit('XR801',token,so,jsonb_build_array(jsonb_build_object('lot_id',lot,'qty',2,'barcode','AR3SP01C') ||  '{}'::jsonb),false,NULL,'AR3SP01 pick') x;
SELECT id INTO STRICT line FROM public.transaction_lines WHERE transaction_id=tx AND signed_qty<0;
SELECT x.correction_id INTO STRICT corr FROM public.report_saved_pick_mistake(line,1,'PHYSICAL_RETURN','AR3 mistake report') x;
IF ((SELECT s.qty FROM public.stock_lots s WHERE s.id=lot)=3) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: source quantity 3'; END IF;
IF (EXISTS(SELECT 1 FROM public.get_saved_pick_corrections(so) x WHERE x.correction_id=corr AND correction_status='REQUESTED' AND reported_qty=1)) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: correction report'; END IF;
IF (EXISTS (SELECT 1 FROM public.audit_log WHERE action='SAVED_PICK_MISTAKE_REPORTED' AND entity_id=corr::text)) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: audit SAVED_PICK_MISTAKE_REPORTED'; END IF;

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
      INSERT INTO pg_temp.ar3_results VALUES (1,'SP01','Report physical return without stock restoration',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (1,'SP01','Report physical return without stock restoration',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

-- SP02: Requested review blocks Finish
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
item := '{"brand":"AR3SP02","description":"AR3SP02 regression","variant":"AR3SP02","size":"AR3","case_barcode":"AR3SP02C","pack_barcode":"AR3SP02P","piece_barcode":"AR3SP02E","container_no":"AR3SP02BOX","expiry_date":"2099-12-31","case_qty":5,"pack_qty":0,"piece_qty":0,"user_remark":"AR3SP02 remark"}'::jsonb;
SELECT x.transaction_id INTO tx FROM public.complete_putaway_with_user_remarks('XR801',jsonb_build_array(item)) x;
SELECT id INTO STRICT sku FROM public.skus WHERE brand='AR3SP02';
SELECT id INTO STRICT lot FROM public.stock_lots WHERE sku_id=sku AND location_id=a AND uom='CASE';
so := 'AR3SP02SO';
SELECT x.lock_token INTO STRICT token FROM public.acquire_location_lock('XR801','PICK',so) x;
SELECT x.transaction_id, x.fefo_overridden INTO tx, flag FROM public.complete_picking_with_approvals_and_container_audit('XR801',token,so,jsonb_build_array(jsonb_build_object('lot_id',lot,'qty',2,'barcode','AR3SP02C') ||  '{}'::jsonb),false,NULL,'AR3SP02 pick') x;
SELECT id INTO STRICT line FROM public.transaction_lines WHERE transaction_id=tx AND signed_qty<0;
SELECT x.correction_id INTO STRICT corr FROM public.report_saved_pick_mistake(line,1,'PHYSICAL_RETURN','AR3 mistake report') x;

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
IF (err='SAVED_PICK_REVIEW_REQUIRED: A reported Saved Pick mistake is still awaiting Supervisor review. Review or reject the request before finishing this Sales Order.') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected rejection: SAVED_PICK_REVIEW_REQUIRED: A reported Saved Pick mistake is still awaiting Supervisor review. Review or reject the request before finishing this Sales Order.'; END IF;

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
      INSERT INTO pg_temp.ar3_results VALUES (2,'SP02','Requested review blocks Finish',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (2,'SP02','Requested review blocks Finish',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

-- SP03: Approve unchanged physical return
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
item := '{"brand":"AR3SP03","description":"AR3SP03 regression","variant":"AR3SP03","size":"AR3","case_barcode":"AR3SP03C","pack_barcode":"AR3SP03P","piece_barcode":"AR3SP03E","container_no":"AR3SP03BOX","expiry_date":"2099-12-31","case_qty":5,"pack_qty":0,"piece_qty":0,"user_remark":"AR3SP03 remark"}'::jsonb;
SELECT x.transaction_id INTO tx FROM public.complete_putaway_with_user_remarks('XR801',jsonb_build_array(item)) x;
SELECT id INTO STRICT sku FROM public.skus WHERE brand='AR3SP03';
SELECT id INTO STRICT lot FROM public.stock_lots WHERE sku_id=sku AND location_id=a AND uom='CASE';
so := 'AR3SP03SO';
SELECT x.lock_token INTO STRICT token FROM public.acquire_location_lock('XR801','PICK',so) x;
SELECT x.transaction_id, x.fefo_overridden INTO tx, flag FROM public.complete_picking_with_approvals_and_container_audit('XR801',token,so,jsonb_build_array(jsonb_build_object('lot_id',lot,'qty',2,'barcode','AR3SP03C') ||  '{}'::jsonb),false,NULL,'AR3SP03 pick') x;
SELECT id INTO STRICT line FROM public.transaction_lines WHERE transaction_id=tx AND signed_qty<0;
SELECT x.correction_id INTO STRICT corr FROM public.report_saved_pick_mistake(line,1,'PHYSICAL_RETURN','AR3 mistake report') x;
PERFORM public.review_saved_pick_correction(corr,'APPROVE',1,'PHYSICAL_RETURN',NULL);
IF ((SELECT s.qty FROM public.stock_lots s WHERE s.id=lot)=3) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: source quantity 3'; END IF;
IF (EXISTS(SELECT 1 FROM public.get_saved_pick_corrections(so) x WHERE x.correction_id=corr AND correction_status='PENDING_RETURN' AND correction_qty=1 AND assigned_to=auth.uid() AND reviewed_role='owner')) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: correction report'; END IF;
IF (EXISTS (SELECT 1 FROM public.audit_log WHERE action='SAVED_PICK_CORRECTION_APPROVED' AND entity_id=corr::text)) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: audit SAVED_PICK_CORRECTION_APPROVED'; END IF;
IF (EXISTS (SELECT 1 FROM public.audit_log WHERE action='SAVED_PICK_RETURN_PENDING' AND entity_id=corr::text)) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: audit SAVED_PICK_RETURN_PENDING'; END IF;

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
      INSERT INTO pg_temp.ar3_results VALUES (3,'SP03','Approve unchanged physical return',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (3,'SP03','Approve unchanged physical return',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

-- SP04: Pending return blocks Finish
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
item := '{"brand":"AR3SP04","description":"AR3SP04 regression","variant":"AR3SP04","size":"AR3","case_barcode":"AR3SP04C","pack_barcode":"AR3SP04P","piece_barcode":"AR3SP04E","container_no":"AR3SP04BOX","expiry_date":"2099-12-31","case_qty":5,"pack_qty":0,"piece_qty":0,"user_remark":"AR3SP04 remark"}'::jsonb;
SELECT x.transaction_id INTO tx FROM public.complete_putaway_with_user_remarks('XR801',jsonb_build_array(item)) x;
SELECT id INTO STRICT sku FROM public.skus WHERE brand='AR3SP04';
SELECT id INTO STRICT lot FROM public.stock_lots WHERE sku_id=sku AND location_id=a AND uom='CASE';
so := 'AR3SP04SO';
SELECT x.lock_token INTO STRICT token FROM public.acquire_location_lock('XR801','PICK',so) x;
SELECT x.transaction_id, x.fefo_overridden INTO tx, flag FROM public.complete_picking_with_approvals_and_container_audit('XR801',token,so,jsonb_build_array(jsonb_build_object('lot_id',lot,'qty',2,'barcode','AR3SP04C') ||  '{}'::jsonb),false,NULL,'AR3SP04 pick') x;
SELECT id INTO STRICT line FROM public.transaction_lines WHERE transaction_id=tx AND signed_qty<0;
SELECT x.correction_id INTO STRICT corr FROM public.report_saved_pick_mistake(line,1,'PHYSICAL_RETURN','AR3 mistake report') x;
PERFORM public.review_saved_pick_correction(corr,'APPROVE',1,'PHYSICAL_RETURN',NULL);

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
IF (err='PENDING_SAVED_PICK_RETURN: One or more approved Saved Pick physical returns are still unresolved. Complete the returns before finishing this Sales Order, or use the controlled Emergency Finish approval.') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected rejection: PENDING_SAVED_PICK_RETURN: One or more approved Saved Pick physical returns are still unresolved. Complete the returns before finishing this Sales Order, or use the controlled Emergency Finish approval.'; END IF;

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
      INSERT INTO pg_temp.ar3_results VALUES (4,'SP04','Pending return blocks Finish',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (4,'SP04','Pending return blocks Finish',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

-- SP05: Wrong return rack
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
item := '{"brand":"AR3SP05","description":"AR3SP05 regression","variant":"AR3SP05","size":"AR3","case_barcode":"AR3SP05C","pack_barcode":"AR3SP05P","piece_barcode":"AR3SP05E","container_no":"AR3SP05BOX","expiry_date":"2099-12-31","case_qty":5,"pack_qty":0,"piece_qty":0,"user_remark":"AR3SP05 remark"}'::jsonb;
SELECT x.transaction_id INTO tx FROM public.complete_putaway_with_user_remarks('XR801',jsonb_build_array(item)) x;
SELECT id INTO STRICT sku FROM public.skus WHERE brand='AR3SP05';
SELECT id INTO STRICT lot FROM public.stock_lots WHERE sku_id=sku AND location_id=a AND uom='CASE';
so := 'AR3SP05SO';
SELECT x.lock_token INTO STRICT token FROM public.acquire_location_lock('XR801','PICK',so) x;
SELECT x.transaction_id, x.fefo_overridden INTO tx, flag FROM public.complete_picking_with_approvals_and_container_audit('XR801',token,so,jsonb_build_array(jsonb_build_object('lot_id',lot,'qty',2,'barcode','AR3SP05C') ||  '{}'::jsonb),false,NULL,'AR3SP05 pick') x;
SELECT id INTO STRICT line FROM public.transaction_lines WHERE transaction_id=tx AND signed_qty<0;
SELECT x.correction_id INTO STRICT corr FROM public.report_saved_pick_mistake(line,1,'PHYSICAL_RETURN','AR3 mistake report') x;
PERFORM public.review_saved_pick_correction(corr,'APPROVE',1,'PHYSICAL_RETURN',NULL);

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
PERFORM public.complete_saved_pick_return(corr,'XR802','AR3SP05C');
EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS err = MESSAGE_TEXT, err_code = RETURNED_SQLSTATE;
END;
IF (err IS NOT NULL) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: negative call must reject'; END IF;
IF (err_code='P0001') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected SQLSTATE P0001'; END IF;
IF (left(err,21)='RETURN_RACK_MISMATCH:') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected rejection: RETURN_RACK_MISMATCH:'; END IF;

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
IF (position('XR801' in err)>0) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: original rack in rejection'; END IF;

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
      INSERT INTO pg_temp.ar3_results VALUES (5,'SP05','Wrong return rack',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (5,'SP05','Wrong return rack',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

-- SP06: Wrong return barcode
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
item := '{"brand":"AR3SP06","description":"AR3SP06 regression","variant":"AR3SP06","size":"AR3","case_barcode":"AR3SP06C","pack_barcode":"AR3SP06P","piece_barcode":"AR3SP06E","container_no":"AR3SP06BOX","expiry_date":"2099-12-31","case_qty":5,"pack_qty":0,"piece_qty":0,"user_remark":"AR3SP06 remark"}'::jsonb;
SELECT x.transaction_id INTO tx FROM public.complete_putaway_with_user_remarks('XR801',jsonb_build_array(item)) x;
SELECT id INTO STRICT sku FROM public.skus WHERE brand='AR3SP06';
SELECT id INTO STRICT lot FROM public.stock_lots WHERE sku_id=sku AND location_id=a AND uom='CASE';
so := 'AR3SP06SO';
SELECT x.lock_token INTO STRICT token FROM public.acquire_location_lock('XR801','PICK',so) x;
SELECT x.transaction_id, x.fefo_overridden INTO tx, flag FROM public.complete_picking_with_approvals_and_container_audit('XR801',token,so,jsonb_build_array(jsonb_build_object('lot_id',lot,'qty',2,'barcode','AR3SP06C') ||  '{}'::jsonb),false,NULL,'AR3SP06 pick') x;
SELECT id INTO STRICT line FROM public.transaction_lines WHERE transaction_id=tx AND signed_qty<0;
SELECT x.correction_id INTO STRICT corr FROM public.report_saved_pick_mistake(line,1,'PHYSICAL_RETURN','AR3 mistake report') x;
PERFORM public.review_saved_pick_correction(corr,'APPROVE',1,'PHYSICAL_RETURN',NULL);

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
PERFORM public.complete_saved_pick_return(corr,'XR801','AR3WRONG');
EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS err = MESSAGE_TEXT, err_code = RETURNED_SQLSTATE;
END;
IF (err IS NOT NULL) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: negative call must reject'; END IF;
IF (err_code='P0001') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected SQLSTATE P0001'; END IF;
IF (err='RETURN_BARCODE_MISMATCH: The barcode does not match the saved CASE SKU line being returned.') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected rejection: RETURN_BARCODE_MISMATCH: The barcode does not match the saved CASE SKU line being returned.'; END IF;

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
      INSERT INTO pg_temp.ar3_results VALUES (6,'SP06','Wrong return barcode',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (6,'SP06','Wrong return barcode',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

-- SP07: Return restores original lot and allows Finish
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
item := '{"brand":"AR3SP07","description":"AR3SP07 regression","variant":"AR3SP07","size":"AR3","case_barcode":"AR3SP07C","pack_barcode":"AR3SP07P","piece_barcode":"AR3SP07E","container_no":"AR3SP07BOX","expiry_date":"2099-12-31","case_qty":5,"pack_qty":0,"piece_qty":0,"user_remark":"AR3SP07 remark"}'::jsonb;
SELECT x.transaction_id INTO tx FROM public.complete_putaway_with_user_remarks('XR801',jsonb_build_array(item)) x;
SELECT id INTO STRICT sku FROM public.skus WHERE brand='AR3SP07';
SELECT id INTO STRICT lot FROM public.stock_lots WHERE sku_id=sku AND location_id=a AND uom='CASE';
so := 'AR3SP07SO';
SELECT x.lock_token INTO STRICT token FROM public.acquire_location_lock('XR801','PICK',so) x;
SELECT x.transaction_id, x.fefo_overridden INTO tx, flag FROM public.complete_picking_with_approvals_and_container_audit('XR801',token,so,jsonb_build_array(jsonb_build_object('lot_id',lot,'qty',2,'barcode','AR3SP07C') ||  '{}'::jsonb),false,NULL,'AR3SP07 pick') x;
SELECT id INTO STRICT line FROM public.transaction_lines WHERE transaction_id=tx AND signed_qty<0;
SELECT x.correction_id INTO STRICT corr FROM public.report_saved_pick_mistake(line,1,'PHYSICAL_RETURN','AR3 mistake report') x;
PERFORM public.review_saved_pick_correction(corr,'APPROVE',1,'PHYSICAL_RETURN',NULL);
SELECT x.restored_lot_id,x.restored_qty INTO c,n FROM public.complete_saved_pick_return(corr,'XR801','AR3SP07C') x;
IF (c=lot AND n=1) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: exact original lot restored'; END IF;
IF ((SELECT s.qty FROM public.stock_lots s WHERE s.id=lot)=4) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: source quantity 4'; END IF;
IF (EXISTS(SELECT 1 FROM public.stock_lots WHERE id=lot AND location_id=a)) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: original rack'; END IF;
IF (EXISTS(SELECT 1 FROM public.get_saved_pick_corrections(so) x WHERE x.correction_id=corr AND correction_status='COMPLETED' AND returned_location_code='XR801')) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: correction report'; END IF;
IF (EXISTS (SELECT 1 FROM public.audit_log WHERE action='SAVED_PICK_CORRECTION_COMPLETED' AND entity_id=corr::text)) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: audit SAVED_PICK_CORRECTION_COMPLETED'; END IF;
SELECT x.result_status, x.pick_transaction_count INTO status_text,n FROM public.finish_pick_sales_order(so) x;
IF (status_text='COMPLETED') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: Finish succeeds'; END IF;

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
      INSERT INTO pg_temp.ar3_results VALUES (7,'SP07','Return restores original lot and allows Finish',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (7,'SP07','Return restores original lot and allows Finish',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

-- SP08: Still in original rack automatically restores
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
item := '{"brand":"AR3SP08","description":"AR3SP08 regression","variant":"AR3SP08","size":"AR3","case_barcode":"AR3SP08C","pack_barcode":"AR3SP08P","piece_barcode":"AR3SP08E","container_no":"AR3SP08BOX","expiry_date":"2099-12-31","case_qty":5,"pack_qty":0,"piece_qty":0,"user_remark":"AR3SP08 remark"}'::jsonb;
SELECT x.transaction_id INTO tx FROM public.complete_putaway_with_user_remarks('XR801',jsonb_build_array(item)) x;
SELECT id INTO STRICT sku FROM public.skus WHERE brand='AR3SP08';
SELECT id INTO STRICT lot FROM public.stock_lots WHERE sku_id=sku AND location_id=a AND uom='CASE';
so := 'AR3SP08SO';
SELECT x.lock_token INTO STRICT token FROM public.acquire_location_lock('XR801','PICK',so) x;
SELECT x.transaction_id, x.fefo_overridden INTO tx, flag FROM public.complete_picking_with_approvals_and_container_audit('XR801',token,so,jsonb_build_array(jsonb_build_object('lot_id',lot,'qty',2,'barcode','AR3SP08C') ||  '{}'::jsonb),false,NULL,'AR3SP08 pick') x;
SELECT id INTO STRICT line FROM public.transaction_lines WHERE transaction_id=tx AND signed_qty<0;
SELECT x.correction_id INTO STRICT corr FROM public.report_saved_pick_mistake(line,1,'STILL_IN_ORIGINAL_RACK','AR3 mistake report') x;
PERFORM public.review_saved_pick_correction(corr,'APPROVE',1,'STILL_IN_ORIGINAL_RACK',NULL);
IF ((SELECT s.qty FROM public.stock_lots s WHERE s.id=lot)=4) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: source quantity 4'; END IF;
IF (EXISTS(SELECT 1 FROM public.get_saved_pick_corrections(so) x WHERE x.correction_id=corr AND correction_status='COMPLETED' AND correction_mode='STILL_IN_ORIGINAL_RACK')) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: correction report'; END IF;
IF (EXISTS (SELECT 1 FROM public.audit_log WHERE action='SAVED_PICK_CORRECTION_COMPLETED' AND entity_id=corr::text)) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: audit SAVED_PICK_CORRECTION_COMPLETED'; END IF;
SELECT x.result_status, x.pick_transaction_count INTO status_text,n FROM public.finish_pick_sales_order(so) x;
IF (status_text='COMPLETED') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: Finish without return scan'; END IF;

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
      INSERT INTO pg_temp.ar3_results VALUES (8,'SP08','Still in original rack automatically restores',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (8,'SP08','Still in original rack automatically restores',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

-- SP09: Quantity change requires note; return two of three
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
item := '{"brand":"AR3SP09","description":"AR3SP09 regression","variant":"AR3SP09","size":"AR3","case_barcode":"AR3SP09C","pack_barcode":"AR3SP09P","piece_barcode":"AR3SP09E","container_no":"AR3SP09BOX","expiry_date":"2099-12-31","case_qty":5,"pack_qty":0,"piece_qty":0,"user_remark":"AR3SP09 remark"}'::jsonb;
SELECT x.transaction_id INTO tx FROM public.complete_putaway_with_user_remarks('XR801',jsonb_build_array(item)) x;
SELECT id INTO STRICT sku FROM public.skus WHERE brand='AR3SP09';
SELECT id INTO STRICT lot FROM public.stock_lots WHERE sku_id=sku AND location_id=a AND uom='CASE';
so := 'AR3SP09SO';
SELECT x.lock_token INTO STRICT token FROM public.acquire_location_lock('XR801','PICK',so) x;
SELECT x.transaction_id, x.fefo_overridden INTO tx, flag FROM public.complete_picking_with_approvals_and_container_audit('XR801',token,so,jsonb_build_array(jsonb_build_object('lot_id',lot,'qty',3,'barcode','AR3SP09C') ||  '{}'::jsonb),false,NULL,'AR3SP09 pick') x;
SELECT id INTO STRICT line FROM public.transaction_lines WHERE transaction_id=tx AND signed_qty<0;
SELECT x.correction_id INTO STRICT corr FROM public.report_saved_pick_mistake(line,3,'PHYSICAL_RETURN','AR3 mistake report') x;

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
PERFORM public.review_saved_pick_correction(corr,'APPROVE',2,'PHYSICAL_RETURN',NULL);

EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS err = MESSAGE_TEXT, err_code = RETURNED_SQLSTATE;
END;
IF (err IS NOT NULL) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: negative call must reject'; END IF;
IF (err_code='P0001') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected SQLSTATE P0001'; END IF;
IF (err='A Supervisor review note is required when changing the picker-reported quantity or physical status.') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected rejection: A Supervisor review note is required when changing the picker-reported quantity or physical status.'; END IF;

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
PERFORM public.review_saved_pick_correction(corr,'APPROVE',2,'PHYSICAL_RETURN','AR3 corrected quantity');
SELECT x.restored_lot_id,x.restored_qty INTO c,n FROM public.complete_saved_pick_return(corr,'XR801','AR3SP09C') x;
IF (n=2 AND c=lot) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: two returned'; END IF;
IF (EXISTS(SELECT 1 FROM public.get_pick_sales_order_summary_with_corrections(so) WHERE transaction_line_id=line AND net_picked_qty=1)) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: net picked 1'; END IF;
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
      INSERT INTO pg_temp.ar3_results VALUES (9,'SP09','Quantity change requires note; return two of three',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (9,'SP09','Quantity change requires note; return two of three',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

-- SP10: Second correction changes physical status
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
item := '{"brand":"AR3SP10","description":"AR3SP10 regression","variant":"AR3SP10","size":"AR3","case_barcode":"AR3SP10C","pack_barcode":"AR3SP10P","piece_barcode":"AR3SP10E","container_no":"AR3SP10BOX","expiry_date":"2099-12-31","case_qty":5,"pack_qty":0,"piece_qty":0,"user_remark":"AR3SP10 remark"}'::jsonb;
SELECT x.transaction_id INTO tx FROM public.complete_putaway_with_user_remarks('XR801',jsonb_build_array(item)) x;
SELECT id INTO STRICT sku FROM public.skus WHERE brand='AR3SP10';
SELECT id INTO STRICT lot FROM public.stock_lots WHERE sku_id=sku AND location_id=a AND uom='CASE';
so := 'AR3SP10SO';
SELECT x.lock_token INTO STRICT token FROM public.acquire_location_lock('XR801','PICK',so) x;
SELECT x.transaction_id, x.fefo_overridden INTO tx, flag FROM public.complete_picking_with_approvals_and_container_audit('XR801',token,so,jsonb_build_array(jsonb_build_object('lot_id',lot,'qty',3,'barcode','AR3SP10C') ||  '{}'::jsonb),false,NULL,'AR3SP10 pick') x;
SELECT id INTO STRICT line FROM public.transaction_lines WHERE transaction_id=tx AND signed_qty<0;
SELECT x.correction_id INTO STRICT corr FROM public.report_saved_pick_mistake(line,3,'PHYSICAL_RETURN','AR3 mistake report') x;

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
PERFORM public.review_saved_pick_correction(corr,'APPROVE',2,'PHYSICAL_RETURN',NULL);

EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS err = MESSAGE_TEXT, err_code = RETURNED_SQLSTATE;
END;
IF (err IS NOT NULL) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: negative call must reject'; END IF;
IF (err_code='P0001') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected SQLSTATE P0001'; END IF;
IF (err='A Supervisor review note is required when changing the picker-reported quantity or physical status.') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected rejection: A Supervisor review note is required when changing the picker-reported quantity or physical status.'; END IF;

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
PERFORM public.review_saved_pick_correction(corr,'APPROVE',2,'PHYSICAL_RETURN','AR3 corrected quantity');
SELECT x.restored_lot_id,x.restored_qty INTO c,n FROM public.complete_saved_pick_return(corr,'XR801','AR3SP10C') x;
IF (n=2 AND c=lot) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: two returned'; END IF;
IF (EXISTS(SELECT 1 FROM public.get_pick_sales_order_summary_with_corrections(so) WHERE transaction_line_id=line AND net_picked_qty=1)) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: net picked 1'; END IF;
SELECT x.correction_id INTO STRICT corr FROM public.report_saved_pick_mistake(line,1,'PHYSICAL_RETURN','AR3 mistake report') x;

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
PERFORM public.review_saved_pick_correction(corr,'APPROVE',1,'STILL_IN_ORIGINAL_RACK',NULL);

EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS err = MESSAGE_TEXT, err_code = RETURNED_SQLSTATE;
END;
IF (err IS NOT NULL) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: negative call must reject'; END IF;
IF (err_code='P0001') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected SQLSTATE P0001'; END IF;
IF (err='A Supervisor review note is required when changing the picker-reported quantity or physical status.') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected rejection: A Supervisor review note is required when changing the picker-reported quantity or physical status.'; END IF;

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
PERFORM public.review_saved_pick_correction(corr,'APPROVE',1,'STILL_IN_ORIGINAL_RACK','AR3 changed physical status');
IF (EXISTS(SELECT 1 FROM public.get_pick_sales_order_summary_with_corrections(so) WHERE transaction_line_id=line AND net_picked_qty=0)) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: net picked 0'; END IF;
IF ((SELECT s.qty FROM public.stock_lots s WHERE s.id=lot)=5) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: source quantity 5'; END IF;
IF (EXISTS(SELECT 1 FROM public.get_saved_pick_corrections(so) x WHERE x.correction_id=corr AND correction_status='COMPLETED' AND correction_mode='STILL_IN_ORIGINAL_RACK')) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: correction report'; END IF;

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
      INSERT INTO pg_temp.ar3_results VALUES (10,'SP10','Second correction changes physical status',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (10,'SP10','Second correction changes physical status',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

-- SP11: Over-correction rejected after full restoration
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
item := '{"brand":"AR3SP11","description":"AR3SP11 regression","variant":"AR3SP11","size":"AR3","case_barcode":"AR3SP11C","pack_barcode":"AR3SP11P","piece_barcode":"AR3SP11E","container_no":"AR3SP11BOX","expiry_date":"2099-12-31","case_qty":5,"pack_qty":0,"piece_qty":0,"user_remark":"AR3SP11 remark"}'::jsonb;
SELECT x.transaction_id INTO tx FROM public.complete_putaway_with_user_remarks('XR801',jsonb_build_array(item)) x;
SELECT id INTO STRICT sku FROM public.skus WHERE brand='AR3SP11';
SELECT id INTO STRICT lot FROM public.stock_lots WHERE sku_id=sku AND location_id=a AND uom='CASE';
so := 'AR3SP11SO';
SELECT x.lock_token INTO STRICT token FROM public.acquire_location_lock('XR801','PICK',so) x;
SELECT x.transaction_id, x.fefo_overridden INTO tx, flag FROM public.complete_picking_with_approvals_and_container_audit('XR801',token,so,jsonb_build_array(jsonb_build_object('lot_id',lot,'qty',3,'barcode','AR3SP11C') ||  '{}'::jsonb),false,NULL,'AR3SP11 pick') x;
SELECT id INTO STRICT line FROM public.transaction_lines WHERE transaction_id=tx AND signed_qty<0;
SELECT x.correction_id INTO STRICT corr FROM public.report_saved_pick_mistake(line,3,'PHYSICAL_RETURN','AR3 mistake report') x;

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
PERFORM public.review_saved_pick_correction(corr,'APPROVE',2,'PHYSICAL_RETURN',NULL);

EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS err = MESSAGE_TEXT, err_code = RETURNED_SQLSTATE;
END;
IF (err IS NOT NULL) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: negative call must reject'; END IF;
IF (err_code='P0001') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected SQLSTATE P0001'; END IF;
IF (err='A Supervisor review note is required when changing the picker-reported quantity or physical status.') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected rejection: A Supervisor review note is required when changing the picker-reported quantity or physical status.'; END IF;

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
PERFORM public.review_saved_pick_correction(corr,'APPROVE',2,'PHYSICAL_RETURN','AR3 corrected quantity');
SELECT x.restored_lot_id,x.restored_qty INTO c,n FROM public.complete_saved_pick_return(corr,'XR801','AR3SP11C') x;
IF (n=2 AND c=lot) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: two returned'; END IF;
IF (EXISTS(SELECT 1 FROM public.get_pick_sales_order_summary_with_corrections(so) WHERE transaction_line_id=line AND net_picked_qty=1)) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: net picked 1'; END IF;
SELECT x.correction_id INTO STRICT corr FROM public.report_saved_pick_mistake(line,1,'PHYSICAL_RETURN','AR3 mistake report') x;

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
PERFORM public.review_saved_pick_correction(corr,'APPROVE',1,'STILL_IN_ORIGINAL_RACK',NULL);

EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS err = MESSAGE_TEXT, err_code = RETURNED_SQLSTATE;
END;
IF (err IS NOT NULL) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: negative call must reject'; END IF;
IF (err_code='P0001') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected SQLSTATE P0001'; END IF;
IF (err='A Supervisor review note is required when changing the picker-reported quantity or physical status.') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected rejection: A Supervisor review note is required when changing the picker-reported quantity or physical status.'; END IF;

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
PERFORM public.review_saved_pick_correction(corr,'APPROVE',1,'STILL_IN_ORIGINAL_RACK','AR3 changed physical status');
IF (EXISTS(SELECT 1 FROM public.get_pick_sales_order_summary_with_corrections(so) WHERE transaction_line_id=line AND net_picked_qty=0)) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: net picked 0'; END IF;
IF ((SELECT s.qty FROM public.stock_lots s WHERE s.id=lot)=5) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: source quantity 5'; END IF;

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
SELECT x.correction_id INTO STRICT corr FROM public.report_saved_pick_mistake(line,1,'PHYSICAL_RETURN','AR3 mistake report') x;

EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS err = MESSAGE_TEXT, err_code = RETURNED_SQLSTATE;
END;
IF (err IS NOT NULL) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: negative call must reject'; END IF;
IF (err_code='P0001') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected SQLSTATE P0001'; END IF;
IF (err ~ '^Reported quantity exceeds the remaining correctable amount\. Original Pick: 3(\.0+)?, already completed corrections: 3(\.0+)?, requested: 1(\.0+)?\.$') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: expected rejection: ^Reported quantity exceeds the remaining correctable amount\. Original Pick: 3(\.0+)?, already completed corrections: 3(\.0+)?, requested: 1(\.0+)?\.$'; END IF;

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
      INSERT INTO pg_temp.ar3_results VALUES (11,'SP11','Over-correction rejected after full restoration',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (11,'SP11','Over-correction rejected after full restoration',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

-- SP12: Rejection preserves stock and signed Pick
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
item := '{"brand":"AR3SP12","description":"AR3SP12 regression","variant":"AR3SP12","size":"AR3","case_barcode":"AR3SP12C","pack_barcode":"AR3SP12P","piece_barcode":"AR3SP12E","container_no":"AR3SP12BOX","expiry_date":"2099-12-31","case_qty":5,"pack_qty":0,"piece_qty":0,"user_remark":"AR3SP12 remark"}'::jsonb;
SELECT x.transaction_id INTO tx FROM public.complete_putaway_with_user_remarks('XR801',jsonb_build_array(item)) x;
SELECT id INTO STRICT sku FROM public.skus WHERE brand='AR3SP12';
SELECT id INTO STRICT lot FROM public.stock_lots WHERE sku_id=sku AND location_id=a AND uom='CASE';
so := 'AR3SP12SO';
SELECT x.lock_token INTO STRICT token FROM public.acquire_location_lock('XR801','PICK',so) x;
SELECT x.transaction_id, x.fefo_overridden INTO tx, flag FROM public.complete_picking_with_approvals_and_container_audit('XR801',token,so,jsonb_build_array(jsonb_build_object('lot_id',lot,'qty',1,'barcode','AR3SP12C') ||  '{}'::jsonb),false,NULL,'AR3SP12 pick') x;
SELECT id INTO STRICT line FROM public.transaction_lines WHERE transaction_id=tx AND signed_qty<0;
SELECT x.correction_id INTO STRICT corr FROM public.report_saved_pick_mistake(line,1,'PHYSICAL_RETURN','AR3 mistake report') x;
PERFORM public.review_saved_pick_correction(corr,'REJECT',NULL,NULL,'AR3 rejected mistake');
IF (EXISTS(SELECT 1 FROM public.get_saved_pick_corrections(so) x WHERE x.correction_id=corr AND correction_status='REJECTED')) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: correction report'; END IF;
IF ((SELECT s.qty FROM public.stock_lots s WHERE s.id=lot)=4) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: source quantity 4'; END IF;
IF ((SELECT signed_qty FROM public.transaction_lines WHERE id=line)=-1) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: original signed quantity'; END IF;
IF (EXISTS (SELECT 1 FROM public.audit_log WHERE action='SAVED_PICK_CORRECTION_REJECTED' AND entity_id=corr::text)) IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: audit SAVED_PICK_CORRECTION_REJECTED'; END IF;
SELECT x.result_status, x.pick_transaction_count INTO status_text,n FROM public.finish_pick_sales_order(so) x;
IF (status_text='COMPLETED') IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AR3 assertion: Finish after rejection'; END IF;

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
      INSERT INTO pg_temp.ar3_results VALUES (12,'SP12','Rejection preserves stock and signed Pick',scenario_ok,
        CASE WHEN scenario_ok THEN 'PASS: assertions satisfied; scenario fixtures rolled back'
        ELSE 'FAIL: unexpected private exception' END,counts_json);
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS err=MESSAGE_TEXT,err_code=RETURNED_SQLSTATE;
      INSERT INTO pg_temp.ar3_results VALUES (12,'SP12','Rejection preserves stock and signed Pick',false,
        err_code||': '||err,NULL);
  END;
END;
$scenario$;

SELECT jsonb_build_object(
  'suite','AR-3.6 Saved Pick Correction',
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

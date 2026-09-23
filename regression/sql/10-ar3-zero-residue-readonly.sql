-- AR-3 TEST-only zero-residue postcheck; one read-only statement.
-- Repository: jemagno1030/IFTC-WMS-TEST-REGRESSION
-- Project: gfswztynzocobxbtaitc
-- Use the privileged SQL-editor/connector runner so RLS cannot hide residue.
-- Owner-session correction assertions in suites 03..09 use reporting RPCs.
-- The sequence value is informational; gaps survive transaction rollback.
WITH checks AS (
SELECT 1 AS test_no, 'operational_mode' AS test_id, to_jsonb((SELECT operational_mode FROM public.app_settings WHERE id=1)) AS actual, '"ACTIVE"'::jsonb AS expected
UNION ALL
SELECT 2 AS test_no, 'profiles' AS test_id, to_jsonb((SELECT count(*) FROM public.profiles)) AS actual, '1'::jsonb AS expected
UNION ALL
SELECT 3 AS test_no, 'owners' AS test_id, to_jsonb((SELECT count(*) FROM public.profiles WHERE lower(role)='owner')) AS actual, '1'::jsonb AS expected
UNION ALL
SELECT 4 AS test_no, 'active_owners' AS test_id, to_jsonb((SELECT count(*) FROM public.profiles WHERE lower(role)='owner' AND is_active)) AS actual, '1'::jsonb AS expected
UNION ALL
SELECT 5 AS test_no, 'auth_users' AS test_id, to_jsonb((SELECT count(*) FROM auth.users)) AS actual, '1'::jsonb AS expected
UNION ALL
SELECT 6 AS test_no, 'locations' AS test_id, to_jsonb((SELECT count(*) FROM public.locations)) AS actual, '743'::jsonb AS expected
UNION ALL
SELECT 7 AS test_no, 'active_physical' AS test_id, to_jsonb((SELECT count(*) FROM public.locations WHERE NOT coalesce(is_pending,false) AND coalesce(is_active,true))) AS actual, '738'::jsonb AS expected
UNION ALL
SELECT 8 AS test_no, 'inactive_physical' AS test_id, to_jsonb((SELECT count(*) FROM public.locations WHERE NOT coalesce(is_pending,false) AND NOT coalesce(is_active,true))) AS actual, '1'::jsonb AS expected
UNION ALL
SELECT 9 AS test_no, 'active_pending' AS test_id, to_jsonb((SELECT count(*) FROM public.locations WHERE coalesce(is_pending,false) AND coalesce(is_active,true))) AS actual, '4'::jsonb AS expected
UNION ALL
SELECT 10 AS test_no, 'skus' AS test_id, to_jsonb((SELECT count(*) FROM public.skus)) AS actual, '0'::jsonb AS expected
UNION ALL
SELECT 11 AS test_no, 'uom_configs' AS test_id, to_jsonb((SELECT count(*) FROM public.sku_uom_conversion_config)) AS actual, '0'::jsonb AS expected
UNION ALL
SELECT 12 AS test_no, 'stock_lots' AS test_id, to_jsonb((SELECT count(*) FROM public.stock_lots)) AS actual, '0'::jsonb AS expected
UNION ALL
SELECT 13 AS test_no, 'transactions' AS test_id, to_jsonb((SELECT count(*) FROM public.transactions)) AS actual, '1'::jsonb AS expected
UNION ALL
SELECT 14 AS test_no, 'transaction_lines' AS test_id, to_jsonb((SELECT count(*) FROM public.transaction_lines)) AS actual, '0'::jsonb AS expected
UNION ALL
SELECT 15 AS test_no, 'sales_orders' AS test_id, to_jsonb((SELECT count(*) FROM public.pick_sales_orders)) AS actual, '0'::jsonb AS expected
UNION ALL
SELECT 16 AS test_no, 'shipper_boxes' AS test_id, to_jsonb((SELECT count(*) FROM public.shipper_boxes)) AS actual, '0'::jsonb AS expected
UNION ALL
SELECT 17 AS test_no, 'saved_pick_corrections' AS test_id, to_jsonb((SELECT count(*) FROM public.saved_pick_corrections)) AS actual, '0'::jsonb AS expected
UNION ALL
SELECT 18 AS test_no, 'saved_pick_finish_approvals' AS test_id, to_jsonb((SELECT count(*) FROM public.saved_pick_finish_approvals)) AS actual, '0'::jsonb AS expected
UNION ALL
SELECT 19 AS test_no, 'warehouse_action_approvals' AS test_id, to_jsonb((SELECT count(*) FROM public.warehouse_action_approvals)) AS actual, '0'::jsonb AS expected
UNION ALL
SELECT 20 AS test_no, 'fefo_override_events' AS test_id, to_jsonb((SELECT count(*) FROM public.fefo_override_events)) AS actual, '0'::jsonb AS expected
UNION ALL
SELECT 21 AS test_no, 'audit_log' AS test_id, to_jsonb((SELECT count(*) FROM public.audit_log)) AS actual, '1'::jsonb AS expected
UNION ALL
SELECT 22 AS test_no, 'positive_stock_lots' AS test_id, to_jsonb((SELECT count(*) FROM public.stock_lots WHERE qty>0)) AS actual, '0'::jsonb AS expected
UNION ALL
SELECT 23 AS test_no, 'active_locks' AS test_id, to_jsonb((SELECT count(*) FROM public.location_locks WHERE expires_at>now())) AS actual, '0'::jsonb AS expected
UNION ALL
SELECT 24 AS test_no, 'owner_identity_md5' AS test_id, to_jsonb((SELECT md5(coalesce(string_agg(id::text,E'\n' ORDER BY id::text),'')) FROM public.profiles WHERE lower(role)='owner')) AS actual, '"8efe2f577bc98e25a9837ef275c7ae1a"'::jsonb AS expected
UNION ALL
SELECT 25 AS test_no, 'location_identity_md5' AS test_id, to_jsonb((SELECT md5(coalesce(string_agg(
id::text||'|'||coalesce(code,'')||'|'||coalesce(display_name,'')||'|'||
coalesce(zone,'')||'|'||coalesce(row_label,'')||'|'||coalesce(bay_label,'')||'|'||
coalesce(level_label,'')||'|'||coalesce(sort_order::text,'')||'|'||
coalesce(is_pending::text,'')||'|'||coalesce(is_active::text,''),
E'\n' ORDER BY id::text),'')) FROM public.locations)) AS actual, '"13e82ec85bae291a5c61fd8fff41abf8"'::jsonb AS expected
UNION ALL
SELECT 26 AS test_no, 'function_body_md5' AS test_id, to_jsonb((SELECT md5(coalesce(string_agg(
p.proname||'('||pg_get_function_identity_arguments(p.oid)||')|'||pg_get_functiondef(p.oid),
E'\n' ORDER BY p.proname,pg_get_function_identity_arguments(p.oid)),'')) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public')) AS actual, '"8a82ab6596d917ce41b94cc10a1f60ab"'::jsonb AS expected
UNION ALL
SELECT 27 AS test_no, 'test_cluster_identity' AS test_id, to_jsonb((SELECT system_identifier::text FROM pg_control_system())) AS actual, '"7678069749886157684"'::jsonb AS expected
UNION ALL
SELECT 28 AS test_no, 'stock_lot_missing_sku' AS test_id, to_jsonb((SELECT count(*) FROM public.stock_lots sl LEFT JOIN public.skus s ON s.id=sl.sku_id WHERE s.id IS NULL)) AS actual, '0'::jsonb AS expected
UNION ALL
SELECT 29 AS test_no, 'stock_lot_missing_location' AS test_id, to_jsonb((SELECT count(*) FROM public.stock_lots sl LEFT JOIN public.locations l ON l.id=sl.location_id WHERE l.id IS NULL)) AS actual, '0'::jsonb AS expected
UNION ALL
SELECT 30 AS test_no, 'transaction_line_missing_transaction' AS test_id, to_jsonb((SELECT count(*) FROM public.transaction_lines tl LEFT JOIN public.transactions t ON t.id=tl.transaction_id WHERE t.id IS NULL)) AS actual, '0'::jsonb AS expected
UNION ALL
SELECT 31 AS test_no, 'transaction_line_missing_sku' AS test_id, to_jsonb((SELECT count(*) FROM public.transaction_lines tl LEFT JOIN public.skus s ON s.id=tl.sku_id WHERE tl.sku_id IS NOT NULL AND s.id IS NULL)) AS actual, '0'::jsonb AS expected
UNION ALL
SELECT 32 AS test_no, 'shipper_missing_location' AS test_id, to_jsonb((SELECT count(*) FROM public.shipper_boxes sb LEFT JOIN public.locations l ON l.id=sb.location_id WHERE sb.location_id IS NOT NULL AND l.id IS NULL)) AS actual, '0'::jsonb AS expected
UNION ALL
SELECT 33 AS test_no, 'ar3_sku_fields' AS test_id, to_jsonb((SELECT count(*) FROM public.skus t WHERE to_jsonb(t)::text ~* 'AR3')) AS actual, '0'::jsonb AS expected
UNION ALL
SELECT 34 AS test_no, 'xr8_locations' AS test_id, to_jsonb((SELECT count(*) FROM public.locations t WHERE code ILIKE 'XR8%')) AS actual, '0'::jsonb AS expected
UNION ALL
SELECT 35 AS test_no, 'ar3_sales_orders' AS test_id, to_jsonb((SELECT count(*) FROM public.pick_sales_orders t WHERE to_jsonb(t)::text ~* 'AR3')) AS actual, '0'::jsonb AS expected
UNION ALL
SELECT 36 AS test_no, 'adjustment_control_rows' AS test_id, to_jsonb((SELECT count(*) FROM public.pick_sales_orders t WHERE starts_with(order_key,'__WMS_ADJ0__:'))) AS actual, '0'::jsonb AS expected
UNION ALL
SELECT 37 AS test_no, 'ar3_transactions_notes' AS test_id, to_jsonb((SELECT count(*) FROM public.transactions t WHERE to_jsonb(t)::text ~* 'AR3')) AS actual, '0'::jsonb AS expected
UNION ALL
SELECT 38 AS test_no, 'ar3_transaction_lines' AS test_id, to_jsonb((SELECT count(*) FROM public.transaction_lines t WHERE to_jsonb(t)::text ~* 'AR3')) AS actual, '0'::jsonb AS expected
UNION ALL
SELECT 39 AS test_no, 'ar3_line_remarks' AS test_id, to_jsonb((SELECT count(*) FROM public.transaction_line_user_remarks t WHERE to_jsonb(t)::text ~* 'AR3')) AS actual, '0'::jsonb AS expected
UNION ALL
SELECT 40 AS test_no, 'ar3_transaction_remarks' AS test_id, to_jsonb((SELECT count(*) FROM public.transaction_user_remarks t WHERE to_jsonb(t)::text ~* 'AR3')) AS actual, '0'::jsonb AS expected
UNION ALL
SELECT 41 AS test_no, 'ar3_saved_pick_corrections' AS test_id, to_jsonb((SELECT count(*) FROM public.saved_pick_corrections t WHERE to_jsonb(t)::text ~* 'AR3')) AS actual, '0'::jsonb AS expected
UNION ALL
SELECT 42 AS test_no, 'ar3_audit_data_reasons' AS test_id, to_jsonb((SELECT count(*) FROM public.audit_log t WHERE to_jsonb(t)::text ~* '(AR3|XR8)')) AS actual, '0'::jsonb AS expected
UNION ALL
SELECT 43 AS test_no, 'ar3_stock_containers' AS test_id, to_jsonb((SELECT count(*) FROM public.stock_lots t WHERE container_no ILIKE 'AR3%')) AS actual, '0'::jsonb AS expected
UNION ALL
SELECT 44 AS test_no, 'regression_uom_active_locks' AS test_id, to_jsonb((SELECT count(*) FROM public.location_locks t WHERE expires_at>now() AND (operation='UOM_CONVERSION' OR sales_order ILIKE 'AR3%' OR starts_with(coalesce(sales_order,''),'__WMS_ADJ0__:') OR location_id IN (SELECT id FROM public.locations WHERE code ILIKE 'XR8%')))) AS actual, '0'::jsonb AS expected
UNION ALL
SELECT 45 AS test_no, 'ar3_fefo_events' AS test_id, to_jsonb((SELECT count(*) FROM public.fefo_override_events t WHERE to_jsonb(t)::text ~* 'AR3')) AS actual, '0'::jsonb AS expected
UNION ALL
SELECT 46 AS test_no, 'ar3_warehouse_approvals' AS test_id, to_jsonb((SELECT count(*) FROM public.warehouse_action_approvals t WHERE to_jsonb(t)::text ~* 'AR3')) AS actual, '0'::jsonb AS expected
UNION ALL
SELECT 47 AS test_no, 'ar3_finish_approvals' AS test_id, to_jsonb((SELECT count(*) FROM public.saved_pick_finish_approvals t WHERE to_jsonb(t)::text ~* 'AR3')) AS actual, '0'::jsonb AS expected
), results AS (
SELECT *, actual IS NOT DISTINCT FROM expected AS passed FROM checks
)
SELECT jsonb_build_object(
  'suite','AR-3 zero-residue read-only',
  'total',count(*),'pass',count(*) FILTER (WHERE passed),
  'fail',count(*) FILTER (WHERE NOT passed),
  'results',jsonb_agg(jsonb_build_object('test_no',test_no,'test_id',test_id,
    'actual',actual,'expected',expected,'pass',passed) ORDER BY test_no),
  'informational',jsonb_build_object(
    'wms_tx_seq_last',(SELECT last_value FROM pg_sequences
      WHERE schemaname='public' AND sequencename='wms_tx_seq'),
    'development_observed_sequence',77,
    'sequence_note','PostgreSQL sequences may advance despite rollback; never a PASS/FAIL gate')
) AS ar3_zero_residue FROM results;

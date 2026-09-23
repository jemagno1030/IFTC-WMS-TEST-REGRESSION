-- IFTC WMS Automated Regression V1
-- READ-ONLY ONLY. Safe for LIVE and TEST.
-- Returns one JSON object containing schema fingerprints, critical function hashes,
-- operational mode, important counts, identity fingerprints, orphan checks,
-- and EXECUTE privilege counts.

with
schema_columns as (
  select md5(coalesce(string_agg(
    table_name||'|'||column_name||'|'||data_type||'|'||coalesce(udt_name,'')||'|'||
    is_nullable||'|'||coalesce(column_default,''),
    E'\n' order by table_name, ordinal_position
  ),'')) as sig,
  count(*) as n
  from information_schema.columns
  where table_schema='public'
),
schema_constraints as (
  select md5(coalesce(string_agg(
    c.conrelid::regclass::text||'|'||c.conname||'|'||c.contype::text||'|'||pg_get_constraintdef(c.oid,true),
    E'\n' order by c.conrelid::regclass::text,c.conname
  ),'')) as sig,
  count(*) as n
  from pg_constraint c
  join pg_namespace nsp on nsp.oid=c.connamespace
  where nsp.nspname='public'
),
schema_functions as (
  select md5(coalesce(string_agg(
    p.proname||'('||pg_get_function_identity_arguments(p.oid)||')|'||pg_get_functiondef(p.oid),
    E'\n' order by p.proname,pg_get_function_identity_arguments(p.oid)
  ),'')) as body_sig,
  count(*) as n
  from pg_proc p
  join pg_namespace nsp on nsp.oid=p.pronamespace
  where nsp.nspname='public'
),
schema_triggers as (
  select md5(coalesce(string_agg(
    c.relname||'|'||t.tgname||'|'||pg_get_triggerdef(t.oid,true),
    E'\n' order by c.relname,t.tgname
  ),'')) as sig,
  count(*) as n
  from pg_trigger t
  join pg_class c on c.oid=t.tgrelid
  join pg_namespace nsp on nsp.oid=c.relnamespace
  where nsp.nspname='public' and not t.tgisinternal
),
schema_indexes as (
  select md5(coalesce(string_agg(
    tablename||'|'||indexname||'|'||indexdef,
    E'\n' order by tablename,indexname
  ),'')) as sig,
  count(*) as n
  from pg_indexes where schemaname='public'
),
schema_policies as (
  select md5(coalesce(string_agg(
    tablename||'|'||policyname||'|'||cmd||'|'||permissive||'|'||
    coalesce(array_to_string(roles,','),'')||'|'||coalesce(qual,'')||'|'||coalesce(with_check,''),
    E'\n' order by tablename,policyname
  ),'')) as sig,
  count(*) as n
  from pg_policies where schemaname='public'
),
rls_state as (
  select md5(coalesce(string_agg(
    c.relname||'|'||c.relrowsecurity::text||'|'||c.relforcerowsecurity::text,
    E'\n' order by c.relname
  ),'')) as sig,
  count(*) as table_n
  from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public' and c.relkind='r'
),
critical_functions as (
  select coalesce(jsonb_agg(jsonb_build_object(
    'name', p.proname,
    'args', pg_get_function_identity_arguments(p.oid),
    'md5', md5(pg_get_functiondef(p.oid))
  ) order by p.proname,pg_get_function_identity_arguments(p.oid)),'[]'::jsonb) as j
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname in (
    'complete_putaway_with_user_remarks',
    'complete_transfer_with_user_remarks',
    'complete_picking_with_approvals_and_container_audit',
    'complete_stock_adjustment_picking_with_remarks',
    'apply_stock_delta',
    'acquire_location_lock',
    'owner_full_reset_wms',
    'owner_full_reset_preview',
    'owner_full_reset_wms_vnext',
    'owner_full_reset_preview_vnext',
    'owner_edit_sku_master',
    'admin_create_sku_master_v1',
    'admin_set_sku_uom_conversion_config_v1',
    'get_sku_uom_conversion_config_v1',
    'get_uom_conversion_source_lots_v1',
    'complete_uom_conversion_v1',
    'complete_uom_conversion_v1_confirmed',
    'guard_uom_conversion_variance_confirmation_v1',
    'get_sku_balance_stock_card',
    'owner_delete_physical_location_v1',
    'owner_reactivate_physical_location_v1',
    'owner_rename_physical_location_v1',
    'add_location'
  )
),
critical_triggers as (
  select coalesce(jsonb_agg(jsonb_build_object(
    'table', c.relname,'name',t.tgname,'definition',pg_get_triggerdef(t.oid,true)
  ) order by c.relname,t.tgname),'[]'::jsonb) as j
  from pg_trigger t
  join pg_class c on c.oid=t.tgrelid
  join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public' and not t.tgisinternal
    and t.tgname in ('trg_uom_variance_confirmation_v1')
),
counts as (
  select jsonb_build_object(
    'profiles',(select count(*) from public.profiles),
    'owners',(select count(*) from public.profiles where lower(role)='owner'),
    'auth_users',(select count(*) from auth.users),
    'locations',(select count(*) from public.locations),
    'active_physical',(select count(*) from public.locations where coalesce(is_pending,false)=false and coalesce(is_active,true)=true),
    'inactive_physical',(select count(*) from public.locations where coalesce(is_pending,false)=false and coalesce(is_active,true)=false),
    'active_pending',(select count(*) from public.locations where coalesce(is_pending,false)=true and coalesce(is_active,true)=true),
    'skus',(select count(*) from public.skus),
    'uom_configs',(select count(*) from public.sku_uom_conversion_config),
    'stock_lots',(select count(*) from public.stock_lots),
    'positive_stock_lots',(select count(*) from public.stock_lots where qty > 0),
    'transactions',(select count(*) from public.transactions),
    'transaction_lines',(select count(*) from public.transaction_lines),
    'audit_log',(select count(*) from public.audit_log),
    'sales_orders',(select count(*) from public.pick_sales_orders),
    'shipper_boxes',(select count(*) from public.shipper_boxes),
    'saved_pick_corrections',(select count(*) from public.saved_pick_corrections),
    'active_location_locks',(select count(*) from public.location_locks where expires_at > now())
  ) as j
),
orphan_checks as (
  select jsonb_build_object(
    'stock_lot_missing_sku',(select count(*) from public.stock_lots sl left join public.skus s on s.id=sl.sku_id where s.id is null),
    'stock_lot_missing_location',(select count(*) from public.stock_lots sl left join public.locations l on l.id=sl.location_id where l.id is null),
    'transaction_line_missing_transaction',(select count(*) from public.transaction_lines tl left join public.transactions t on t.id=tl.transaction_id where t.id is null),
    'transaction_line_missing_sku',(select count(*) from public.transaction_lines tl left join public.skus s on s.id=tl.sku_id where tl.sku_id is not null and s.id is null),
    'shipper_missing_location',(select count(*) from public.shipper_boxes sb left join public.locations l on l.id=sb.location_id where sb.location_id is not null and l.id is null)
  ) as j
),
identity as (
  select jsonb_build_object(
    'location_identity_md5',(
      select md5(coalesce(string_agg(
        id::text||'|'||coalesce(code,'')||'|'||coalesce(display_name,'')||'|'||
        coalesce(zone,'')||'|'||coalesce(row_label,'')||'|'||coalesce(bay_label,'')||'|'||
        coalesce(level_label,'')||'|'||coalesce(sort_order::text,'')||'|'||
        coalesce(is_pending::text,'')||'|'||coalesce(is_active::text,''),
        E'\n' order by id::text
      ),'')) from public.locations
    ),
    'owner_identity_md5',(
      select md5(coalesce(string_agg(id::text,E'\n' order by id::text),''))
      from public.profiles where lower(role)='owner'
    )
  ) as j
),
function_privileges as (
  select jsonb_build_object(
    'public_function_count', count(*),
    'anon_execute_count', count(*) filter (where has_function_privilege('anon',p.oid,'EXECUTE')),
    'authenticated_execute_count', count(*) filter (where has_function_privilege('authenticated',p.oid,'EXECUTE')),
    'service_role_execute_count', count(*) filter (where has_function_privilege('service_role',p.oid,'EXECUTE')),
    'anon_security_definer_execute_count', count(*) filter (where has_function_privilege('anon',p.oid,'EXECUTE') and p.prosecdef),
    'authenticated_security_definer_execute_count', count(*) filter (where has_function_privilege('authenticated',p.oid,'EXECUTE') and p.prosecdef)
  ) as j
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public'
)
select jsonb_build_object(
  'operational_mode',(select operational_mode from public.app_settings where id=1),
  'counts',(select j from counts),
  'orphans',(select j from orphan_checks),
  'identity',(select j from identity),
  'schema',jsonb_build_object(
    'columns',jsonb_build_object('count',(select n from schema_columns),'md5',(select sig from schema_columns)),
    'constraints',jsonb_build_object('count',(select n from schema_constraints),'md5',(select sig from schema_constraints)),
    'functions',jsonb_build_object('count',(select n from schema_functions),'body_md5',(select body_sig from schema_functions)),
    'triggers',jsonb_build_object('count',(select n from schema_triggers),'md5',(select sig from schema_triggers)),
    'indexes',jsonb_build_object('count',(select n from schema_indexes),'md5',(select sig from schema_indexes)),
    'policies',jsonb_build_object('count',(select n from schema_policies),'md5',(select sig from schema_policies)),
    'rls',jsonb_build_object('tables',(select table_n from rls_state),'md5',(select sig from rls_state))
  ),
  'function_privileges',(select j from function_privileges),
  'critical_functions',(select j from critical_functions),
  'critical_triggers',(select j from critical_triggers)
) as regression_baseline;

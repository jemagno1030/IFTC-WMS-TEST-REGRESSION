-- READ-ONLY permission inventory. Safe for LIVE and TEST.
select p.proname as name,
       pg_get_function_identity_arguments(p.oid) as args,
       md5(pg_get_functiondef(p.oid)) as md5,
       has_function_privilege('anon',p.oid,'EXECUTE') as anon_exec,
       has_function_privilege('authenticated',p.oid,'EXECUTE') as authenticated_exec,
       has_function_privilege('service_role',p.oid,'EXECUTE') as service_role_exec,
       has_function_privilege('public',p.oid,'EXECUTE') as public_exec
from pg_proc p
join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public'
order by p.proname, pg_get_function_identity_arguments(p.oid);

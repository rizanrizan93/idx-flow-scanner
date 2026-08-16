-- Keep the automatic RLS helper internal to privileged maintenance only.
revoke execute on function public.rls_auto_enable() from public, anon, authenticated;

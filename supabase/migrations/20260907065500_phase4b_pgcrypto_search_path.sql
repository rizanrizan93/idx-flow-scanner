-- Phase 4B runtime compatibility: pgcrypto is installed in the `extensions`
-- schema on the canonical Supabase project. Keep the SECURITY DEFINER function
-- search path explicit while allowing the verified extension function to resolve.

alter function public.flow_capture_market_memory_manifest_v4(date,text)
  set search_path=pg_catalog,public,extensions;

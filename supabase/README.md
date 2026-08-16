# Supabase deployment

This directory is the source of truth for the dedicated `IDX Flow Scanner` Supabase project.

- Production branch: `main`
- Working directory: `.`
- Database migrations: `supabase/migrations/`
- Runtime tables: `public.flow_*`
- Browser roles (`anon`, `authenticated`) remain revoked from scanner tables; server-side persistence uses the backend secret/service-role only.

This file also serves as a harmless deployment trigger after connecting a fresh Supabase project to this repository.

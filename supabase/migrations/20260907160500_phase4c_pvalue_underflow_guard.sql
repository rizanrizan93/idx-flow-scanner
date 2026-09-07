-- Phase 4C numerical hardening.
-- PostgreSQL can raise floating-point underflow for exp(-0.5*z^2) at extreme z.
-- For |z| >= 37 the two-sided normal tail is below practical double-precision
-- discovery resolution, so returning 0.0 is both numerically safe and FDR-equivalent.

create or replace function public.flow_normal_two_sided_p_v4(p_z double precision)
returns double precision
language sql
immutable
parallel safe
strict
as $$
with x as (
  select abs(p_z) as z
), t as (
  select z,1.0/(1.0+0.2316419*z) as q
  from x
), cdf as (
  select z,
    1.0 -
    (exp(greatest(-700.0,-0.5*z*z))/sqrt(2.0*pi())) *
    (0.319381530*q + -0.356563782*power(q,2) + 1.781477937*power(q,3)
      + -1.821255978*power(q,4) + 1.330274429*power(q,5)) as v
  from t
)
select case when z>=37.0 then 0.0
  else greatest(0.0,least(1.0,2.0*(1.0-v))) end
from cdf;
$$;

revoke all on function public.flow_normal_two_sided_p_v4(double precision) from public,anon,authenticated;
grant execute on function public.flow_normal_two_sided_p_v4(double precision) to service_role;

comment on function public.flow_normal_two_sided_p_v4(double precision) is
'Numerically guarded two-sided normal p-value approximation. Extreme |z|>=37 returns 0.0 to avoid floating-point underflow; discovery/FDR semantics are unchanged.';

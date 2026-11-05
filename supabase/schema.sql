-- MyEGL portal backend. ERSY GLOBAL customer data with explicit RLS.
-- CRM remains the source of truth. Only the server-side Zoho sync may create/update jobs.
create table if not exists public.portal_customers (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null unique,
  approved boolean not null default false,
  created_at timestamptz not null default now()
);
-- New sign-ins are registered as PENDING, never auto-approved.
-- Keep the privileged trigger helper outside the exposed public API schema.
create schema if not exists private;
create or replace function private.register_portal_customer()
returns trigger language plpgsql security definer
set search_path = ''
as $$
begin
  if new.email is not null then
    insert into public.portal_customers(id,email,approved)
    values (new.id, lower(trim(new.email)), false)
    on conflict (id) do nothing;
  end if;
  return new;
end;
$$;
drop trigger if exists on_portal_auth_user_created on auth.users;
create trigger on_portal_auth_user_created
  after insert on auth.users for each row
  execute function private.register_portal_customer();

create table if not exists public.portal_jobs (
  id uuid primary key default gen_random_uuid(),
  zoho_record_id text unique not null,
  reference text unique not null,
  customer_id uuid references public.portal_customers(id) on delete set null,
  customer_email text not null,
  service_type text not null,
  origin text,
  destination text,
  request_details jsonb not null default '{}'::jsonb,
  included_services jsonb not null default '[]'::jsonb,
  currency text,
  quoted_total numeric(14,2),
  quote_status text not null default 'not_quoted'
    check (quote_status in ('not_quoted','pending','approved','declined','revision_requested','expired')),
  customer_decision text
    check (customer_decision in ('approved','declined') or customer_decision is null),
  decided_at timestamptz,
  payment_status text not null default 'not_requested'
    check (payment_status in ('not_requested','pending','paid','failed','refunded')),
  shipment_status text,
  tracking_number text,
  updated_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);
create index if not exists portal_jobs_customer_idx on public.portal_jobs(customer_id);
create index if not exists portal_jobs_email_idx on public.portal_jobs(lower(customer_email));

alter table public.portal_customers enable row level security;
alter table public.portal_jobs enable row level security;
revoke all on public.portal_customers from public, anon, authenticated;
revoke all on public.portal_jobs from public, anon, authenticated;
grant select on public.portal_customers to authenticated;
grant select on public.portal_jobs to authenticated;

drop policy if exists "Customers see their own profile" on public.portal_customers;
create policy "Customers see their own profile" on public.portal_customers
  for select to authenticated using (id = (select auth.uid()));

drop policy if exists "Approved customers see only their jobs" on public.portal_jobs;
create policy "Approved customers see only their jobs" on public.portal_jobs
  for select to authenticated using (
    customer_id = (select auth.uid())
    and exists (
      select 1 from public.portal_customers c
      where c.id = (select auth.uid()) and c.approved = true
    )
  );

-- A signed-in customer can accept or decline ONLY their own pending quote.
-- This records intent; it never marks a payment as paid.
create or replace function public.respond_to_quote(p_job_id uuid, p_decision text)
returns jsonb language plpgsql security definer
set search_path = ''
as $$
declare
  v_job public.portal_jobs%rowtype;
begin
  if auth.uid() is null then
    raise exception 'Sign in required';
  end if;
  if p_decision not in ('approved','declined') then
    raise exception 'Invalid decision';
  end if;
  update public.portal_jobs j
     set customer_decision = p_decision,
         quote_status = p_decision,
         decided_at = now(),
         updated_at = now()
   where j.id = p_job_id
     and j.customer_id = auth.uid()
     and j.quote_status = 'pending'
     and exists (select 1 from public.portal_customers c
                 where c.id = auth.uid() and c.approved = true)
   returning j.* into v_job;
  if not found then
    raise exception 'Quotation not available for approval';
  end if;
  return jsonb_build_object('reference',v_job.reference,'decision',v_job.customer_decision);
end;
$$;
revoke all on function public.respond_to_quote(uuid,text) from public, anon;
grant execute on function public.respond_to_quote(uuid,text) to authenticated;

-- Customer account approval and linking CRM records MUST be done server-side.
-- Do not create an unrestricted self-approval or automatic email-based access policy.

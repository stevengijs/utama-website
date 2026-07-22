-- UTAMA investor site - lead capture schema
-- Run this once in your Supabase project's SQL Editor (Database > SQL Editor > New query).
--
-- Design goals:
--   1. One contact per real person, even if they request 3 brochures across
--      2 projects and fill in the form with slightly different capitalisation
--      of their email. Dedup key = lowercased, trimmed email.
--   2. Every single form submission is still logged (as a "lead"), so you keep
--      full history of who asked for what, when - nothing is thrown away.
--   3. The public site only ever talks to Postgres through one function
--      (submit_lead). The anon key cannot read or write the tables directly,
--      so a visitor can never see or overwrite someone else's data.
--   4. A lead becoming a paying customer is tracked separately from the
--      inquiry itself (purchases, below), and once the investor portal has
--      real logins, a signed-in user can read - and only read - their own
--      contact/lead/purchase rows. contacts.user_id is the link between
--      "a person who filled in a form" and "a person who can log in".

create extension if not exists citext;
create extension if not exists pgcrypto; -- gen_random_uuid()

-- ---------------------------------------------------------------------------
-- contacts: one row per real person, deduplicated on email
-- ---------------------------------------------------------------------------
create table if not exists public.contacts (
  id               uuid primary key default gen_random_uuid(),
  email            citext not null unique,
  name             text,
  phone            text,
  locale           text,                          -- 'nl' | 'en' at last touch
  user_id          uuid references auth.users(id), -- filled in automatically once they create a portal login (see trigger below)
  first_seen_at    timestamptz not null default now(),
  last_activity_at timestamptz not null default now(),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

create index if not exists contacts_phone_idx on public.contacts (phone);
create index if not exists contacts_user_id_idx on public.contacts (user_id);

-- ---------------------------------------------------------------------------
-- leads: one row per submission (brochure request, early-access signup, ...)
-- Intentionally NOT deduplicated - a contact asking for the same brochure
-- twice is a real re-engagement signal you want to see (in Ashley's follow-up
-- queue, in reporting), not noise to collapse away. A contact can and will
-- have many leads across many projects - that's expected, not a bug.
-- ---------------------------------------------------------------------------
create table if not exists public.leads (
  id           uuid primary key default gen_random_uuid(),
  contact_id   uuid not null references public.contacts(id) on delete cascade,
  project      text not null,   -- 'The Maison' | 'MOKA' | 'Volgend project (early access)' | ...
  unit         text,            -- e.g. 'Signature Villa' (MOKA unit type), null where not applicable
  budget       text,
  timeline     text,            -- the "when do you want to buy" field
  source_page  text,            -- window.location.pathname at submit time
  lang         text,
  created_at   timestamptz not null default now()
);

create index if not exists leads_contact_id_idx on public.leads (contact_id);
create index if not exists leads_project_idx on public.leads (project);
create index if not exists leads_created_at_idx on public.leads (created_at desc);

-- ---------------------------------------------------------------------------
-- purchases: a lead becomes a customer. This is deliberately a separate
-- table from leads - a lead is "someone asked about a project", a purchase
-- is "someone actually committed money to a unit". One contact can have
-- purchases across multiple projects, and can have leads with no purchase
-- (still just interested) or a purchase with no matching lead row (e.g. you
-- add it manually after a call/WhatsApp deal that never went through the
-- website form).
--
-- This is what should eventually gate access to the investor portal - not
-- "did they ever submit a form" (that's leads), but "do they have a
-- confirmed purchase". You (or a future admin screen) create/update these
-- rows; the public site has no write access to this table at all.
-- ---------------------------------------------------------------------------
create table if not exists public.purchases (
  id                 uuid primary key default gen_random_uuid(),
  contact_id         uuid not null references public.contacts(id) on delete cascade,
  project            text not null,
  unit               text,
  status             text not null default 'reserved'
                       check (status in ('reserved', 'contracted', 'completed', 'cancelled')),
  price              numeric,
  deposit_amount     numeric,
  deposit_paid_at    timestamptz,
  contract_signed_at timestamptz,
  notes              text,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

create index if not exists purchases_contact_id_idx on public.purchases (contact_id);
create index if not exists purchases_project_idx on public.purchases (project);
create index if not exists purchases_status_idx on public.purchases (status);

-- ---------------------------------------------------------------------------
-- Row Level Security: locked down by default.
--
-- No INSERT/UPDATE/DELETE policies are added for anon/authenticated on any
-- of these three tables - that's deliberate. The only supported write path
-- for contacts/leads is submit_lead() below, which runs as SECURITY DEFINER
-- and validates its own inputs. purchases has no public write path at all:
-- you manage it yourself from the Supabase dashboard (or the SQL editor),
-- which uses your own account and bypasses RLS, or via the service_role key
-- from a future admin-only tool - never from the public anon key.
--
-- What IS added below: read-only policies so that once the investor portal
-- has real logins, a signed-in visitor can see their own data (and only
-- their own data) - not anyone else's.
-- ---------------------------------------------------------------------------
alter table public.contacts enable row level security;
alter table public.leads enable row level security;
alter table public.purchases enable row level security;

-- A logged-in portal user may read their own contact row.
create policy "self read contacts" on public.contacts
  for select to authenticated
  using (user_id = auth.uid());

-- A logged-in portal user may read their own leads (matched via contacts.user_id).
create policy "self read leads" on public.leads
  for select to authenticated
  using (
    contact_id in (select id from public.contacts where user_id = auth.uid())
  );

-- A logged-in portal user may read their own purchases - this is what a
-- future dashboard page ("your units") would query.
create policy "self read purchases" on public.purchases
  for select to authenticated
  using (
    contact_id in (select id from public.contacts where user_id = auth.uid())
  );

-- Optional, once you (Steven) log into Supabase with your own account and
-- want to browse everything in the dashboard beyond the table editor's
-- built-in bypass (e.g. from a future internal admin tool using your own
-- authenticated session rather than the service_role key): policies for an
-- admin. Left commented out - these grant blanket access to ALL rows, so
-- only uncomment if you have a way to tell "admin" apart from "customer"
-- (e.g. an is_admin flag or a fixed list of admin user ids); otherwise any
-- authenticated portal user would also match "true".
-- create policy "admin read contacts" on public.contacts for select to authenticated using (true);
-- create policy "admin read leads" on public.leads for select to authenticated using (true);
-- create policy "admin write purchases" on public.purchases for all to authenticated using (true) with check (true);

-- ---------------------------------------------------------------------------
-- submit_lead(): the only way the public site writes data.
-- Upserts the contact by email, then always inserts a new lead row.
-- Safe to call any number of times, for the same project or different
-- projects - each call adds one lead row and never overwrites a previous one.
-- ---------------------------------------------------------------------------
create or replace function public.submit_lead(
  p_email       text,
  p_name        text,
  p_phone       text,
  p_project     text,
  p_unit        text default null,
  p_budget      text default null,
  p_timeline    text default null,
  p_source_page text default null,
  p_lang        text default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_contact_id uuid;
  v_email citext;
begin
  v_email := lower(trim(p_email));

  if v_email is null or v_email = '' or position('@' in v_email) = 0 then
    raise exception 'submit_lead: invalid email';
  end if;
  if p_project is null or trim(p_project) = '' then
    raise exception 'submit_lead: project is required';
  end if;

  insert into public.contacts (email, name, phone, locale)
  values (v_email, nullif(trim(p_name), ''), nullif(trim(p_phone), ''), p_lang)
  on conflict (email) do update
    set name             = coalesce(nullif(trim(excluded.name), ''), contacts.name),
        phone            = coalesce(nullif(trim(excluded.phone), ''), contacts.phone),
        locale           = coalesce(excluded.locale, contacts.locale),
        last_activity_at = now(),
        updated_at       = now()
  returning id into v_contact_id;

  insert into public.leads (contact_id, project, unit, budget, timeline, source_page, lang)
  values (v_contact_id, trim(p_project), nullif(trim(p_unit), ''), p_budget, p_timeline, p_source_page, p_lang);

  return v_contact_id;
end;
$$;

-- Anyone (including anonymous website visitors) may call the function itself.
-- They still cannot query the tables - only insert through this one door.
grant execute on function public.submit_lead(
  text, text, text, text, text, text, text, text, text
) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- link_contact_on_signup(): the moment a lead becomes a portal user.
-- When someone creates a Supabase Auth account (portal login) with the same
-- email address they used on a brochure form, this automatically stamps
-- contacts.user_id so their existing contact/lead/purchase history is
-- attached to their new login - no manual matching needed. If no contact
-- row exists yet for that email (e.g. someone signs up who never submitted
-- a form), nothing happens and that's fine.
-- ---------------------------------------------------------------------------
create or replace function public.link_contact_on_signup()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.contacts
  set user_id       = new.id,
      last_activity_at = now(),
      updated_at    = now()
  where email = new.email
    and user_id is null;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created_link_contact on auth.users;
create trigger on_auth_user_created_link_contact
  after insert on auth.users
  for each row execute function public.link_contact_on_signup();

-- ---------------------------------------------------------------------------
-- Handy view for you to browse in the Supabase Table Editor / SQL Editor:
-- one row per contact with their most recent lead, a running lead count,
-- and whether they've actually become a paying customer.
-- ---------------------------------------------------------------------------
create or replace view public.contacts_overview as
select
  c.id,
  c.email,
  c.name,
  c.phone,
  c.locale,
  c.user_id,
  c.first_seen_at,
  c.last_activity_at,
  count(distinct l.id) as total_leads,
  array_agg(distinct l.project) filter (where l.project is not null) as projects_interested,
  (select l2.project from public.leads l2 where l2.contact_id = c.id order by l2.created_at desc limit 1) as last_project,
  count(distinct pu.id) filter (where pu.status <> 'cancelled') as total_purchases,
  array_agg(distinct pu.project) filter (where pu.status <> 'cancelled') as projects_purchased,
  bool_or(pu.status in ('contracted', 'completed')) as is_customer
from public.contacts c
left join public.leads l on l.contact_id = c.id
left join public.purchases pu on pu.contact_id = c.id
group by c.id
order by c.last_activity_at desc;

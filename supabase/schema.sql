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
--   4. contacts.user_id is left ready for when the private investor portal
--      (login-gated) ships - that's a separate follow-up, not built here.

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
  user_id          uuid references auth.users(id), -- filled in once the investor portal has logins
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
-- queue, in reporting), not noise to collapse away.
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
-- Row Level Security: locked down by default.
-- No policies are added for anon/authenticated on these tables directly - -- that's deliberate. The only supported write path is submit_lead() below,
-- which runs as SECURITY DEFINER and validates its own inputs.
-- ---------------------------------------------------------------------------
alter table public.contacts enable row level security;
alter table public.leads enable row level security;

-- Optional, once you (Steven) log into Supabase with your own account and
-- want to browse leads in the dashboard: a policy for authenticated admins.
-- Left commented out - uncomment once you've set up your own Supabase Auth
-- user and want dashboard access without using the table editor's bypass.
-- create policy "admin read contacts" on public.contacts for select to authenticated using (true);
-- create policy "admin read leads" on public.leads for select to authenticated using (true);

-- ---------------------------------------------------------------------------
-- submit_lead(): the only way the public site writes data.
-- Upserts the contact by email, then always inserts a new lead row.
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
-- Handy view for you to browse in the Supabase Table Editor / SQL Editor:
-- one row per contact with their most recent lead and a running count.
-- ---------------------------------------------------------------------------
create or replace view public.contacts_overview as
select
  c.id,
  c.email,
  c.name,
  c.phone,
  c.locale,
  c.first_seen_at,
  c.last_activity_at,
  count(l.id) as total_leads,
  array_agg(distinct l.project) as projects_interested,
  (select l2.project from public.leads l2 where l2.contact_id = c.id order by l2.created_at desc limit 1) as last_project
from public.contacts c
left join public.leads l on l.contact_id = c.id
group by c.id
order by c.last_activity_at desc;

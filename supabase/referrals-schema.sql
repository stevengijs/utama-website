-- UTAMA referral programme - additive migration
-- Run this once in your Supabase project's SQL Editor, AFTER schema.sql has
-- already been run. Safe to run again in full (everything below is
-- create-if-not-exists / drop-then-create), same as schema.sql.
--
-- What this adds, in plain terms:
--   1. Every contact (lead OR customer) can get a personal referral code,
--      e.g. MARK482, the moment they log in on /referral/ via a magic-link
--      email - no password, no separate signup step.
--   2. Anyone who visits the site with ?ref=CODE in the URL gets that code
--      remembered in their browser. If they later fill in ANY brochure/
--      early-access form, submit_lead() links them to that referrer -
--      first-touch, one credit per referred person, never to yourself.
--   3. When you mark a purchase as 'contracted' in the purchases table (same
--      manual process as today - nothing here writes to purchases), a
--      trigger automatically flags the matching referral as "eligible" so
--      you know a payout is due.
--   4. Payouts themselves stay 100% manual and outside the database: you
--      review referral_payouts_overview (below), wire the EUR 2500 yourself,
--      then flip that referral's status to 'paid' from the Table Editor.
--      Nothing in this schema can move money - it only tracks who is owed
--      what, so you can verify before you pay.
--
-- Required one-time setup you do by hand (can't be scripted from here):
--   Supabase dashboard -> Authentication -> URL Configuration -> add
--   https://invest.utamabali.com/referral/  to "Redirect URLs" (and your
--   Site URL if not set yet). Without that, the magic-link email will
--   refuse to redirect back into the referral page.

create extension if not exists citext;
create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- contacts: add a personal, unique referral code. Nullable until someone
-- actually logs into /referral/ for the first time (lazily generated).
-- ---------------------------------------------------------------------------
alter table public.contacts add column if not exists referral_code citext unique;
create index if not exists contacts_referral_code_idx on public.contacts (referral_code);

-- ---------------------------------------------------------------------------
-- referral_visits: one row per (roughly) unique browser session that landed
-- on the site via someone's ?ref=CODE link. No personal data - just a count
-- so a referrer can see "X mensen bezochten je link" before anyone converts.
-- Writable only through track_referral_visit() below; never readable via
-- the public anon/authenticated roles (you browse it yourself if curious).
-- ---------------------------------------------------------------------------
create table if not exists public.referral_visits (
  id           uuid primary key default gen_random_uuid(),
  code         text not null,
  source_page  text,
  created_at   timestamptz not null default now()
);
create index if not exists referral_visits_code_idx on public.referral_visits (code);
alter table public.referral_visits enable row level security;
revoke all on public.referral_visits from anon, authenticated;

create or replace function public.track_referral_visit(
  p_code        text,
  p_source_page text default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_code is null or trim(p_code) = '' then
    return;
  end if;
  insert into public.referral_visits (code, source_page)
  values (upper(trim(p_code)), p_source_page);
end;
$$;

grant execute on function public.track_referral_visit(text, text) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- referrals: one row per person who was referred in, created the first time
-- they submit a lead form while a valid ?ref=CODE is stored in their browser.
-- unique(referred_contact_id) enforces "first touch wins, one credit per
-- referred person, ever" - a stale later ?ref= link never bumps an existing
-- referral off, and the same person can't accidentally generate two credits.
-- ---------------------------------------------------------------------------
create table if not exists public.referrals (
  id                  uuid primary key default gen_random_uuid(),
  code                text not null,
  referrer_contact_id uuid not null references public.contacts(id) on delete cascade,
  referred_contact_id uuid not null references public.contacts(id) on delete cascade,
  purchase_id         uuid references public.purchases(id) on delete set null,
  reward_amount       numeric not null default 2500,
  status              text not null default 'pending'
                        check (status in ('pending', 'eligible', 'paid', 'void')),
  eligible_at         timestamptz,
  paid_at             timestamptz,
  created_at          timestamptz not null default now(),
  unique (referred_contact_id)
);
create index if not exists referrals_referrer_idx on public.referrals (referrer_contact_id);
create index if not exists referrals_status_idx on public.referrals (status);

alter table public.referrals enable row level security;

-- A logged-in referrer may read their own referral rows (status + amount +
-- dates only - the referred person's name/email/phone is NOT exposed here,
-- since contacts RLS only lets someone read their own contact row, not the
-- person they referred).
drop policy if exists "self read own referrals" on public.referrals;
create policy "self read own referrals" on public.referrals
  for select to authenticated
  using (
    referrer_contact_id in (select id from public.contacts where user_id = auth.uid())
  );

-- ---------------------------------------------------------------------------
-- generate_referral_code(): FIRSTNAME + 3 digits (e.g. MARK482), falling back
-- to the email's local part, then to "VRIEND", with a retry loop for the rare
-- collision. Called lazily the first time someone needs a code.
-- ---------------------------------------------------------------------------
create or replace function public.generate_referral_code(
  p_name  text,
  p_email text default null
) returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_base  text;
  v_code  text;
  v_tries int := 0;
begin
  v_base := upper(regexp_replace(coalesce(split_part(trim(p_name), ' ', 1), ''), '[^A-Za-z]', '', 'g'));
  if v_base = '' or v_base is null then
    v_base := upper(regexp_replace(split_part(coalesce(p_email, ''), '@', 1), '[^A-Za-z]', '', 'g'));
  end if;
  if v_base = '' or v_base is null then
    v_base := 'VRIEND';
  end if;
  v_base := left(v_base, 10);

  loop
    v_code := v_base || lpad(floor(random() * 1000)::text, 3, '0');
    exit when not exists (select 1 from public.contacts where referral_code = v_code);
    v_tries := v_tries + 1;
    exit when v_tries > 20;
  end loop;

  if v_tries > 20 then
    v_code := v_base || substr(md5(random()::text), 1, 6);
  end if;

  return v_code;
end;
$$;

-- ---------------------------------------------------------------------------
-- get_or_create_referral_code(): the only thing the referral page needs to
-- call once someone is signed in. Finds their contact row (linking it to
-- their new auth account if this is their very first login), creates one
-- from scratch if they'd never submitted a lead before, and returns their
-- code - generating it on first use.
-- ---------------------------------------------------------------------------
create or replace function public.get_or_create_referral_code()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_contact_id uuid;
  v_code       text;
  v_name       text;
  v_email      text;
begin
  if auth.uid() is null then
    raise exception 'get_or_create_referral_code: not authenticated';
  end if;

  select id, referral_code, name into v_contact_id, v_code, v_name
  from public.contacts where user_id = auth.uid();

  if v_contact_id is null then
    select email into v_email from auth.users where id = auth.uid();
    insert into public.contacts (email, user_id)
    values (v_email, auth.uid())
    on conflict (email) do update set user_id = excluded.user_id
    returning id, referral_code, name into v_contact_id, v_code, v_name;
  end if;

  if v_code is not null then
    return v_code;
  end if;

  select email into v_email from auth.users where id = auth.uid();
  v_code := public.generate_referral_code(v_name, v_email);

  update public.contacts set referral_code = v_code, updated_at = now() where id = v_contact_id;
  return v_code;
end;
$$;

grant execute on function public.get_or_create_referral_code() to authenticated;

-- ---------------------------------------------------------------------------
-- get_my_referral_stats(): single call the referral page uses after login -
-- ensures a code exists, and returns it plus visit count and every referral
-- credited to this person (status/amount/dates only, no PII of the referred
-- person - see the RLS comment above).
-- ---------------------------------------------------------------------------
create or replace function public.get_my_referral_stats()
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code       text;
  v_contact_id uuid;
  v_visits     int;
begin
  v_code := public.get_or_create_referral_code();
  select id into v_contact_id from public.contacts where referral_code = v_code;

  select count(*) into v_visits from public.referral_visits where code = v_code;

  return json_build_object(
    'code', v_code,
    'visits', coalesce(v_visits, 0),
    'referrals', coalesce((
      select json_agg(json_build_object(
        'status', status,
        'reward_amount', reward_amount,
        'created_at', created_at,
        'eligible_at', eligible_at,
        'paid_at', paid_at
      ) order by created_at desc)
      from public.referrals where referrer_contact_id = v_contact_id
    ), '[]'::json)
  );
end;
$$;

grant execute on function public.get_my_referral_stats() to authenticated;

-- ---------------------------------------------------------------------------
-- submit_lead(): extended with an optional p_ref_code. Existing callers that
-- don't pass it keep working unchanged (default null). Referral attribution
-- is best-effort and silent - an unknown/expired/self-referral code never
-- blocks or errors out someone's brochure request, it's just not credited.
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
  p_lang        text default null,
  p_ref_code    text default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_contact_id  uuid;
  v_email       citext;
  v_referrer_id uuid;
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

  if p_ref_code is not null and trim(p_ref_code) <> '' then
    select id into v_referrer_id
    from public.contacts
    where referral_code = upper(trim(p_ref_code));

    if v_referrer_id is not null and v_referrer_id <> v_contact_id then
      insert into public.referrals (code, referrer_contact_id, referred_contact_id)
      values (upper(trim(p_ref_code)), v_referrer_id, v_contact_id)
      on conflict (referred_contact_id) do nothing;
    end if;
  end if;

  return v_contact_id;
end;
$$;

grant execute on function public.submit_lead(
  text, text, text, text, text, text, text, text, text, text
) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- mark_referral_eligible(): the moment YOU flip a purchase's status to
-- 'contracted' (Table Editor / SQL Editor, exactly as today - nothing new to
-- do here), this stamps the matching referral as eligible for its EUR 2500
-- payout. Purely a status flag - it never moves money.
-- ---------------------------------------------------------------------------
create or replace function public.mark_referral_eligible()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = 'contracted' and (tg_op = 'INSERT' or old.status is distinct from 'contracted') then
    update public.referrals
    set purchase_id = new.id,
        status      = 'eligible',
        eligible_at = now()
    where referred_contact_id = new.contact_id
      and status = 'pending';
  end if;
  return new;
end;
$$;

drop trigger if exists on_purchase_contracted_mark_referral on public.purchases;
create trigger on_purchase_contracted_mark_referral
  after insert or update of status on public.purchases
  for each row execute function public.mark_referral_eligible();

-- ---------------------------------------------------------------------------
-- referral_payouts_overview: for YOU only (Table Editor / SQL Editor), never
-- for the public site - same pattern as contacts_overview in schema.sql.
-- This is where you check who's owed EUR 2500 before wiring it manually, then
-- come back and set that row's status to 'paid' (and paid_at = now()).
-- ---------------------------------------------------------------------------
drop view if exists public.referral_payouts_overview;
create view public.referral_payouts_overview
with (security_invoker = true)
as
select
  r.id as referral_id,
  r.code,
  r.status,
  r.reward_amount,
  r.created_at as referred_at,
  r.eligible_at,
  r.paid_at,
  refr.name  as referrer_name,
  refr.email as referrer_email,
  refr.phone as referrer_phone,
  refd.name  as referred_name,
  refd.email as referred_email,
  refd.phone as referred_phone,
  p.project  as purchase_project,
  p.status   as purchase_status
from public.referrals r
join public.contacts refr on refr.id = r.referrer_contact_id
join public.contacts refd on refd.id = r.referred_contact_id
left join public.purchases p on p.id = r.purchase_id
order by r.created_at desc;

revoke all on public.referral_payouts_overview from anon, authenticated;

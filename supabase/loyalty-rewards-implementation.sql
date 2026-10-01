-- Loyalty rewards implementation reference. This is intentionally outside supabase/migrations.
begin;

do $$
declare
  dependency text;
begin
  foreach dependency in array array[
    'auth.users', 'public.user_profiles', 'public.tasks', 'public.task_reports',
    'public.notifications', 'public.hotel_rooms', 'public.menu_orders',
    'public.menu_payment_attempts', 'public.hotel_bookings',
    'public.hotel_payment_attempts', 'public.special_event_bookings',
    'public.special_event_payments', 'public.books_organizations',
    'public.books_menu_sales_settings', 'public.books_accounts',
    'public.books_journal_transactions', 'public.books_fx_rates'
  ] loop
    if to_regclass(dependency) is null then
      raise exception 'Rewards setup stopped: required relation % is missing', dependency;
    end if;
  end loop;
  if to_regprocedure('public.user_books_organization_ids()') is null then
    raise exception 'Rewards setup stopped: Books membership helper is missing';
  end if;
  if not exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'post_books_journal_entry'
      and p.pronargs = 10
  ) then
    raise exception 'Rewards setup stopped: Books journal posting function is missing';
  end if;
end;
$$;

-- Run as one transaction in Supabase SQL Editor. Select the platform-owned UGX Books organization;
-- do not assume a seller's organization is the correct entity for platform-funded rewards.
-- Policy: 1 point per 1,000 UGX-equivalent eligible net spend; no points on tax, tips, or fees.
-- Guest referrals qualify on a first paid purchase of at least UGX 100,000; manager/provider
-- referrals qualify on a first approved task or first published hotel room. Both parties receive
-- 250 points. Approved work awards 50 points, capped at 500 per provider per calendar month.
-- Points do not expire, are not cash, and cannot be redeemed until seller settlement is available.
-- Do not backfill profiles.loyalty_points: existing values have no auditable earning source.

-- Step 1: program policy, accounts, immutable ledger, referral records, and private work queues.
create table if not exists public.loyalty_program_settings (
  id boolean primary key default true check (id),
  points_per_1000_ugx integer not null default 1 check (points_per_1000_ugx > 0),
  guest_referral_minimum_ugx numeric(20,4) not null default 100000 check (guest_referral_minimum_ugx > 0),
  referrer_bonus_points integer not null default 250 check (referrer_bonus_points > 0),
  invitee_bonus_points integer not null default 250 check (invitee_bonus_points > 0),
  task_approval_points integer not null default 50 check (task_approval_points > 0),
  monthly_task_points_cap integer not null default 500 check (monthly_task_points_cap > 0),
  ugx_value_per_point numeric(20,4) not null default 10 check (ugx_value_per_point > 0),
  books_expense_account_code text not null default '5105' check (length(trim(books_expense_account_code)) between 1 and 32),
  books_liability_account_code text not null default '2600' check (length(trim(books_liability_account_code)) between 1 and 32 and books_liability_account_code <> books_expense_account_code),
  books_organization_id uuid references public.books_organizations(id) on delete restrict,
  program_enabled boolean not null default false,
  redemption_enabled boolean not null default false,
  points_expire boolean not null default false,
  updated_at timestamptz not null default now()
);
alter table public.loyalty_program_settings add column if not exists points_per_1000_ugx integer not null default 1;
alter table public.loyalty_program_settings add column if not exists guest_referral_minimum_ugx numeric(20,4) not null default 100000;
alter table public.loyalty_program_settings add column if not exists referrer_bonus_points integer not null default 250;
alter table public.loyalty_program_settings add column if not exists invitee_bonus_points integer not null default 250;
alter table public.loyalty_program_settings add column if not exists task_approval_points integer not null default 50;
alter table public.loyalty_program_settings add column if not exists monthly_task_points_cap integer not null default 500;
alter table public.loyalty_program_settings add column if not exists ugx_value_per_point numeric(20,4) not null default 10;
alter table public.loyalty_program_settings add column if not exists books_expense_account_code text not null default '5105';
alter table public.loyalty_program_settings add column if not exists books_liability_account_code text not null default '2600';
alter table public.loyalty_program_settings add column if not exists books_organization_id uuid references public.books_organizations(id) on delete restrict;
alter table public.loyalty_program_settings add column if not exists program_enabled boolean not null default false;
alter table public.loyalty_program_settings add column if not exists redemption_enabled boolean not null default false;
alter table public.loyalty_program_settings add column if not exists points_expire boolean not null default false;
alter table public.loyalty_program_settings add column if not exists updated_at timestamptz not null default now();
insert into public.loyalty_program_settings (id) values (true) on conflict (id) do nothing;

create table if not exists public.loyalty_accounts (
  user_id uuid primary key references auth.users(id) on delete cascade,
  referral_code text not null unique,
  is_enrolled boolean not null default false,
  enrolled_at timestamptz,
  signup_referral_code text,
  available_points bigint not null default 0 check (available_points >= 0),
  debt_points bigint not null default 0 check (debt_points >= 0),
  lifetime_points_earned bigint not null default 0 check (lifetime_points_earned >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (referral_code = upper(referral_code))
);
alter table public.loyalty_accounts add column if not exists is_enrolled boolean not null default false;
alter table public.loyalty_accounts alter column is_enrolled set default false;
alter table public.loyalty_accounts add column if not exists enrolled_at timestamptz;
alter table public.loyalty_accounts add column if not exists signup_referral_code text;

create table if not exists public.loyalty_ledger_entries (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete restrict,
  entry_type text not null check (entry_type in (
    'purchase_earn', 'referral_earn', 'referral_welcome', 'task_earn',
    'purchase_reversal', 'referral_reversal'
  )),
  points_delta bigint not null check (points_delta <> 0),
  source_type text not null,
  source_id uuid not null,
  description text not null,
  created_at timestamptz not null default now(),
  unique (user_id, source_type, source_id, entry_type)
);

create table if not exists public.loyalty_referrals (
  id uuid primary key default gen_random_uuid(),
  referrer_user_id uuid not null references auth.users(id) on delete restrict,
  referred_user_id uuid not null unique references auth.users(id) on delete restrict,
  referral_code text not null,
  status text not null default 'pending' check (status in ('pending', 'qualified', 'cancelled')),
  qualification_type text,
  qualification_source_type text,
  qualification_source_id uuid,
  referrer_points integer not null default 0,
  invitee_points integer not null default 0,
  created_at timestamptz not null default now(),
  qualified_at timestamptz,
  check (referrer_user_id <> referred_user_id)
);

create table if not exists public.loyalty_award_queue (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete restrict,
  source_type text not null check (source_type in ('menu_order', 'hotel_booking', 'special_event_payment')),
  source_id uuid not null,
  eligible_amount numeric(20,4) not null check (eligible_amount >= 0),
  eligible_currency text not null check (char_length(trim(eligible_currency)) = 3),
  eligible_amount_ugx numeric(20,4),
  points_awarded bigint not null default 0,
  status text not null default 'pending_fx' check (status in ('pending_fx', 'posted', 'excluded', 'failed', 'refunded')),
  error_message text,
  created_at timestamptz not null default now(),
  processed_at timestamptz,
  unique (source_type, source_id)
);

create table if not exists public.loyalty_books_postings (
  ledger_entry_id uuid primary key references public.loyalty_ledger_entries(id) on delete restrict,
  organization_id uuid references public.books_organizations(id) on delete restrict,
  amount_ugx numeric(20,4) not null check (amount_ugx > 0),
  status text not null default 'pending' check (status in ('pending', 'posted', 'failed')),
  journal_transaction_id uuid references public.books_journal_transactions(id) on delete restrict,
  error_message text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists loyalty_ledger_user_recent_idx
  on public.loyalty_ledger_entries (user_id, created_at desc);
create index if not exists loyalty_referrals_referrer_recent_idx
  on public.loyalty_referrals (referrer_user_id, created_at desc);
create index if not exists loyalty_award_queue_pending_idx
  on public.loyalty_award_queue (eligible_currency, created_at)
  where status = 'pending_fx';

alter table public.loyalty_program_settings enable row level security;
alter table public.loyalty_accounts enable row level security;
alter table public.loyalty_ledger_entries enable row level security;
alter table public.loyalty_referrals enable row level security;
alter table public.loyalty_award_queue enable row level security;
alter table public.loyalty_books_postings enable row level security;

revoke all on public.loyalty_program_settings, public.loyalty_accounts,
  public.loyalty_ledger_entries, public.loyalty_referrals,
  public.loyalty_award_queue, public.loyalty_books_postings
  from public, anon, authenticated;
grant select on public.loyalty_accounts, public.loyalty_ledger_entries, public.loyalty_referrals,
  public.loyalty_books_postings to authenticated;

drop policy if exists loyalty_accounts_owner_read on public.loyalty_accounts;
create policy loyalty_accounts_owner_read on public.loyalty_accounts
  for select to authenticated using (user_id = auth.uid());
drop policy if exists loyalty_ledger_owner_read on public.loyalty_ledger_entries;
create policy loyalty_ledger_owner_read on public.loyalty_ledger_entries
  for select to authenticated using (user_id = auth.uid());
drop policy if exists loyalty_referrals_owner_read on public.loyalty_referrals;
create policy loyalty_referrals_owner_read on public.loyalty_referrals
  for select to authenticated using (referrer_user_id = auth.uid());
drop policy if exists loyalty_books_postings_books_member_read on public.loyalty_books_postings;
create policy loyalty_books_postings_books_member_read on public.loyalty_books_postings
  for select to authenticated
  using (organization_id in (select public.user_books_organization_ids()));

create or replace function public.prevent_loyalty_ledger_mutation()
returns trigger language plpgsql set search_path = pg_catalog, public
as $$ begin raise exception 'Loyalty ledger entries are immutable'; end; $$;
revoke all on function public.prevent_loyalty_ledger_mutation() from public, anon, authenticated;
drop trigger if exists loyalty_ledger_entries_immutable on public.loyalty_ledger_entries;
create trigger loyalty_ledger_entries_immutable
  before update or delete on public.loyalty_ledger_entries
  for each row execute function public.prevent_loyalty_ledger_mutation();

-- Step 2: private balance, Books, and summary functions.
create or replace function public.post_loyalty_ledger_entry_to_books(target_entry_id uuid)
returns void language plpgsql security definer set search_path = pg_catalog, public
as $$
declare
  entry_row public.loyalty_ledger_entries%rowtype;
  organization_uuid uuid;
  organization_owner uuid;
  expense_account uuid;
  liability_account uuid;
  journal_uuid uuid;
  posting_amount numeric(20,4);
  debit_code text;
  credit_code text;
  expense_code text;
  liability_code text;
begin
  select * into entry_row from public.loyalty_ledger_entries where id = target_entry_id;
  if not found then return; end if;

  select books_organization_id, books_expense_account_code, books_liability_account_code
    into organization_uuid, expense_code, liability_code
    from public.loyalty_program_settings where id = true;
  posting_amount := abs(entry_row.points_delta) * (select ugx_value_per_point from public.loyalty_program_settings where id = true);
  insert into public.loyalty_books_postings (ledger_entry_id, organization_id, amount_ugx, status)
  values (entry_row.id, organization_uuid, posting_amount, 'pending')
  on conflict (ledger_entry_id) do nothing;
  if organization_uuid is null then return; end if;

  begin
    select owner_id into organization_owner from public.books_organizations where id = organization_uuid;
    if organization_owner is null then raise exception 'The loyalty Books organization is unavailable'; end if;
    insert into public.books_accounts (organization_id, code, name, type, is_system)
    values
      (organization_uuid, expense_code, 'Loyalty rewards expense', 'expense', true),
      (organization_uuid, liability_code, 'Loyalty points liability', 'liability', true)
    on conflict (organization_id, code) do nothing;
    select id into expense_account from public.books_accounts
      where organization_id = organization_uuid and code = expense_code and type = 'expense';
    select id into liability_account from public.books_accounts
      where organization_id = organization_uuid and code = liability_code and type = 'liability';
    if expense_account is null or liability_account is null then
      raise exception 'The loyalty expense or liability account is configured with an incompatible account type';
    end if;

    if entry_row.points_delta > 0 then
      debit_code := expense_code;
      credit_code := liability_code;
    else
      debit_code := liability_code;
      credit_code := expense_code;
    end if;
    journal_uuid := public.post_books_journal_entry(
      organization_uuid, 'loyalty_points', entry_row.id, entry_row.created_at::date,
      entry_row.description, debit_code, credit_code, posting_amount, 'UGX', organization_owner
    );
    update public.loyalty_books_postings
       set organization_id = organization_uuid, status = 'posted',
           journal_transaction_id = journal_uuid, error_message = null, updated_at = now()
     where ledger_entry_id = entry_row.id;
  exception when others then
    update public.loyalty_books_postings
       set organization_id = organization_uuid, status = 'failed',
           error_message = left(sqlerrm, 1000), updated_at = now()
     where ledger_entry_id = target_entry_id;
  end;
end;
$$;
revoke all on function public.post_loyalty_ledger_entry_to_books(uuid) from public, anon, authenticated;

create or replace function public.apply_loyalty_points_delta(
  target_user_id uuid,
  target_entry_type text,
  target_points_delta bigint,
  target_source_type text,
  target_source_id uuid,
  target_description text
)
returns uuid language plpgsql security definer set search_path = pg_catalog, public
as $$
declare
  entry_uuid uuid;
  account_row public.loyalty_accounts%rowtype;
  remaining_delta bigint;
  available_delta bigint;
  debt_delta bigint;
begin
  if target_user_id is null or target_points_delta = 0 or target_source_id is null then
    raise exception 'A valid loyalty entry is required';
  end if;
  select * into account_row from public.loyalty_accounts where user_id = target_user_id for update;
  if not found then raise exception 'Loyalty account was not initialized'; end if;
  if target_points_delta > 0 and not account_row.is_enrolled then return null; end if;

  insert into public.loyalty_ledger_entries (user_id, entry_type, points_delta, source_type, source_id, description)
  values (target_user_id, target_entry_type, target_points_delta, target_source_type, target_source_id, target_description)
  on conflict (user_id, source_type, source_id, entry_type) do nothing
  returning id into entry_uuid;
  if entry_uuid is null then return null; end if;

  if target_points_delta > 0 then
    debt_delta := least(account_row.debt_points, target_points_delta);
    available_delta := target_points_delta - debt_delta;
    update public.loyalty_accounts
       set available_points = available_points + available_delta,
           debt_points = debt_points - debt_delta,
           lifetime_points_earned = lifetime_points_earned + target_points_delta,
           updated_at = now()
     where user_id = target_user_id;
  else
    remaining_delta := abs(target_points_delta);
    available_delta := least(account_row.available_points, remaining_delta);
    debt_delta := remaining_delta - available_delta;
    update public.loyalty_accounts
       set available_points = available_points - available_delta,
           debt_points = debt_points + debt_delta,
           updated_at = now()
     where user_id = target_user_id;
  end if;

  perform public.post_loyalty_ledger_entry_to_books(entry_uuid);
  return entry_uuid;
end;
$$;
revoke all on function public.apply_loyalty_points_delta(uuid, text, bigint, text, uuid, text) from public, anon, authenticated;

create or replace function public.get_my_loyalty_summary()
returns jsonb language plpgsql stable security definer set search_path = pg_catalog, public
as $$
declare result jsonb;
begin
  if auth.uid() is null then raise exception 'Sign in to view rewards'; end if;
  select jsonb_build_object(
    'availablePoints', account.available_points,
    'lifetimePoints', account.lifetime_points_earned,
    'debtPoints', account.debt_points,
    'referralCode', account.referral_code,
    'enrolled', account.is_enrolled,
    'referrals', jsonb_build_object(
      'total', (select count(*) from public.loyalty_referrals where referrer_user_id = auth.uid()),
      'qualified', (select count(*) from public.loyalty_referrals where referrer_user_id = auth.uid() and status = 'qualified'),
      'pending', (select count(*) from public.loyalty_referrals where referrer_user_id = auth.uid() and status = 'pending'),
      'pointsEarned', coalesce((select sum(points_delta) from public.loyalty_ledger_entries
        where user_id = auth.uid() and entry_type = 'referral_earn'), 0)
    ),
    'entries', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', recent.id, 'entryType', recent.entry_type, 'pointsDelta', recent.points_delta,
        'description', recent.description, 'createdAt', recent.created_at
      ) order by recent.created_at desc)
      from (
        select id, entry_type, points_delta, description, created_at
          from public.loyalty_ledger_entries
         where user_id = auth.uid()
         order by created_at desc
         limit 30
      ) recent
    ), '[]'::jsonb),
    'policy', jsonb_build_object(
      'pointsPer1000Ugx', settings.points_per_1000_ugx,
      'guestReferralMinimumUgx', settings.guest_referral_minimum_ugx,
      'referrerBonusPoints', settings.referrer_bonus_points,
      'inviteeBonusPoints', settings.invitee_bonus_points,
      'taskApprovalPoints', settings.task_approval_points,
      'monthlyTaskPointsCap', settings.monthly_task_points_cap,
      'ugxValuePerPoint', settings.ugx_value_per_point,
      'programEnabled', settings.program_enabled,
      'redemptionEnabled', settings.redemption_enabled,
      'pointsExpire', settings.points_expire
    )
  ) into result
  from public.loyalty_accounts account
  cross join public.loyalty_program_settings settings
  where account.user_id = auth.uid() and settings.id = true;
  if result is null then raise exception 'Loyalty account is not available'; end if;
  return result;
end;
$$;
revoke all on function public.get_my_loyalty_summary() from public, anon;
grant execute on function public.get_my_loyalty_summary() to authenticated;

-- Step 3: initialize accounts and claim a referral code from signup metadata.
create or replace function public.set_my_loyalty_enrollment(target_enrolled boolean)
returns boolean language plpgsql security definer set search_path = pg_catalog, public
as $$
declare supplied_code text; inviter_user_id uuid;
begin
  if auth.uid() is null then raise exception 'Sign in to manage rewards enrollment'; end if;
  update public.loyalty_accounts
     set is_enrolled = target_enrolled,
         enrolled_at = case
           when target_enrolled and is_enrolled then enrolled_at
           when target_enrolled then now()
           else null
         end,
         updated_at = now()
   where user_id = auth.uid();
  if not found then raise exception 'Loyalty account was not initialized'; end if;
  if target_enrolled then
    select signup_referral_code into supplied_code from public.loyalty_accounts where user_id = auth.uid();
    if supplied_code is not null then
      select user_id into inviter_user_id from public.loyalty_accounts where referral_code = supplied_code;
      if inviter_user_id is not null and inviter_user_id <> auth.uid() then
        insert into public.loyalty_referrals (referrer_user_id, referred_user_id, referral_code)
        values (inviter_user_id, auth.uid(), supplied_code)
        on conflict (referred_user_id) do nothing;
      end if;
    end if;
  end if;
  return target_enrolled;
end;
$$;
revoke all on function public.set_my_loyalty_enrollment(boolean) from public, anon;
grant execute on function public.set_my_loyalty_enrollment(boolean) to authenticated;

create or replace function public.initialize_loyalty_account_for_user()
returns trigger language plpgsql security definer set search_path = pg_catalog, public
as $$
declare
  generated_code text;
  inviter_user_id uuid;
  supplied_code text;
begin
  loop
    generated_code := 'SP-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12));
    insert into public.loyalty_accounts (user_id, referral_code, is_enrolled, enrolled_at, signup_referral_code)
    values (
      new.id, generated_code, coalesce(new.raw_user_meta_data->>'loyalty_program', 'false') = 'true',
      case when coalesce(new.raw_user_meta_data->>'loyalty_program', 'false') = 'true' then now() else null end,
      nullif(upper(trim(new.raw_user_meta_data->>'referral_code')), '')
    )
    on conflict (referral_code) do nothing;
    if found then exit; end if;
    if exists (select 1 from public.loyalty_accounts where user_id = new.id) then exit; end if;
  end loop;

  supplied_code := nullif(upper(trim(new.raw_user_meta_data->>'referral_code')), '');
  if supplied_code is not null and length(supplied_code) <= 32 then
    select user_id into inviter_user_id from public.loyalty_accounts where referral_code = supplied_code;
    if inviter_user_id is not null and inviter_user_id <> new.id then
      insert into public.loyalty_referrals (referrer_user_id, referred_user_id, referral_code)
      values (inviter_user_id, new.id, supplied_code)
      on conflict (referred_user_id) do nothing;
    end if;
  end if;
  return new;
end;
$$;
revoke all on function public.initialize_loyalty_account_for_user() from public, anon, authenticated;
drop trigger if exists initialize_loyalty_account_after_signup on auth.users;
create trigger initialize_loyalty_account_after_signup
  after insert on auth.users
  for each row execute function public.initialize_loyalty_account_for_user();

do $$
declare user_row record; generated_code text;
begin
  for user_row in select id from auth.users where not exists (
    select 1 from public.loyalty_accounts where user_id = auth.users.id
  ) loop
    loop
      generated_code := 'SP-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12));
      insert into public.loyalty_accounts (user_id, referral_code)
      values (user_row.id, generated_code)
      on conflict (referral_code) do nothing;
      exit when found;
    end loop;
  end loop;
end;
$$;

-- Step 4: award on verified, persisted paid purchases; queue awards until FX is available.
create or replace function public.process_loyalty_award_queue_entry(target_queue_id uuid)
returns void language plpgsql security definer set search_path = pg_catalog, public
as $$
declare
  queue_row public.loyalty_award_queue%rowtype;
  ugx_per_currency numeric;
  ugx_amount numeric(20,4);
  awarded_points bigint;
  entry_uuid uuid;
  account_row public.loyalty_accounts%rowtype;
begin
  select * into queue_row from public.loyalty_award_queue where id = target_queue_id for update;
  if not found or queue_row.status <> 'pending_fx' then return; end if;

  if not exists (select 1 from public.loyalty_program_settings where id = true and program_enabled) then
    update public.loyalty_award_queue set error_message = 'Rewards are awaiting Books configuration and activation' where id = target_queue_id;
    return;
  end if;
  select * into account_row from public.loyalty_accounts where user_id = queue_row.user_id for update;
  if not found then
    update public.loyalty_award_queue set status = 'failed', error_message = 'The member rewards account is not initialized', processed_at = now()
     where id = target_queue_id;
    return;
  end if;
  if not account_row.is_enrolled or account_row.enrolled_at is null
     or queue_row.created_at < account_row.enrolled_at then
    update public.loyalty_award_queue set status = 'excluded', error_message = 'Rewards enrollment was not active when the purchase was verified', processed_at = now()
     where id = target_queue_id;
    return;
  end if;

  if upper(queue_row.eligible_currency) = 'UGX' then
    ugx_per_currency := 1;
  else
    select rate into ugx_per_currency
      from public.books_fx_rates
     where base_currency = 'UGX' and quote_currency = upper(queue_row.eligible_currency)::char(3)
       and stored_at >= now() - interval '36 hours'
     order by stored_at desc limit 1;
  end if;
  if ugx_per_currency is null or ugx_per_currency <= 0 then
    update public.loyalty_award_queue set error_message = 'Awaiting a current UGX exchange-rate snapshot' where id = target_queue_id;
    return;
  end if;

  ugx_amount := round(queue_row.eligible_amount / ugx_per_currency, 4);
  awarded_points := floor(ugx_amount / 1000) * (select points_per_1000_ugx from public.loyalty_program_settings where id = true);
  update public.loyalty_award_queue
     set eligible_amount_ugx = ugx_amount, points_awarded = awarded_points,
         error_message = null
   where id = target_queue_id;
  if awarded_points < 1 then
    update public.loyalty_award_queue set status = 'excluded', processed_at = now() where id = target_queue_id;
    return;
  end if;

  entry_uuid := public.apply_loyalty_points_delta(
    queue_row.user_id, 'purchase_earn', awarded_points, queue_row.source_type,
    queue_row.source_id, 'Eligible verified purchase reward'
  );
  update public.loyalty_award_queue set status = 'posted', processed_at = now() where id = target_queue_id;
  if entry_uuid is not null then
    perform public.qualify_loyalty_referral(queue_row.user_id, 'purchase', queue_row.source_type, queue_row.source_id, ugx_amount);
  end if;
exception when others then
  update public.loyalty_award_queue
     set status = 'failed', error_message = left(sqlerrm, 1000), processed_at = now()
   where id = target_queue_id and status = 'pending_fx';
end;
$$;
revoke all on function public.process_loyalty_award_queue_entry(uuid) from public, anon, authenticated;

create or replace function public.process_pending_loyalty_awards()
returns integer language plpgsql security definer set search_path = pg_catalog, public
as $$
declare queue_row record; processed_count integer := 0;
begin
  for queue_row in
    select id from public.loyalty_award_queue where status = 'pending_fx'
    order by created_at for update skip locked
  loop
    perform public.process_loyalty_award_queue_entry(queue_row.id);
    processed_count := processed_count + 1;
  end loop;
  return processed_count;
end;
$$;
revoke all on function public.process_pending_loyalty_awards() from public, anon, authenticated;
grant execute on function public.process_pending_loyalty_awards() to service_role;

create or replace function public.retry_failed_loyalty_award(target_queue_id uuid)
returns text language plpgsql security definer set search_path = pg_catalog, public
as $$
declare current_status text;
begin
  if auth.role() <> 'service_role' then raise exception 'Only the service role may retry loyalty awards'; end if;
  update public.loyalty_award_queue
     set status = 'pending_fx', processed_at = null, error_message = null
   where id = target_queue_id and status = 'failed';
  if found then perform public.process_loyalty_award_queue_entry(target_queue_id); end if;
  select status into current_status from public.loyalty_award_queue where id = target_queue_id;
  return coalesce(current_status, 'not_found');
end;
$$;
revoke all on function public.retry_failed_loyalty_award(uuid) from public, anon, authenticated;
grant execute on function public.retry_failed_loyalty_award(uuid) to service_role;

create or replace function public.activate_loyalty_awards_after_configuration()
returns trigger language plpgsql security definer set search_path = pg_catalog, public
as $$
begin
  if new.program_enabled and (
    not old.program_enabled
    or new.books_organization_id is distinct from old.books_organization_id
    or new.books_expense_account_code is distinct from old.books_expense_account_code
    or new.books_liability_account_code is distinct from old.books_liability_account_code
  ) then
    if new.books_organization_id is null or not exists (
      select 1 from public.books_organizations
       where id = new.books_organization_id and upper(base_currency) = 'UGX'
    ) then
      raise exception 'Select the platform-owned UGX Books organization before activating rewards';
    end if;
    insert into public.books_accounts (organization_id, code, name, type, is_system)
    values
      (new.books_organization_id, new.books_expense_account_code, 'Loyalty rewards expense', 'expense', true),
      (new.books_organization_id, new.books_liability_account_code, 'Loyalty points liability', 'liability', true)
    on conflict (organization_id, code) do nothing;
    if not exists (
      select 1 from public.books_accounts where organization_id = new.books_organization_id
        and code = new.books_expense_account_code and type = 'expense'
    ) or not exists (
      select 1 from public.books_accounts where organization_id = new.books_organization_id
        and code = new.books_liability_account_code and type = 'liability'
    ) then
      raise exception 'Configured Books account codes must map to expense and liability accounts';
    end if;
    perform public.process_pending_loyalty_awards();
  end if;
  return new;
end;
$$;
revoke all on function public.activate_loyalty_awards_after_configuration() from public, anon, authenticated;
drop trigger if exists activate_loyalty_awards_after_configuration on public.loyalty_program_settings;
create trigger activate_loyalty_awards_after_configuration
  after update of program_enabled, books_organization_id, books_expense_account_code, books_liability_account_code
  on public.loyalty_program_settings
  for each row execute function public.activate_loyalty_awards_after_configuration();

create or replace function public.retry_loyalty_awards_after_fx_update()
returns trigger language plpgsql security definer set search_path = pg_catalog, public
as $$ begin perform public.process_pending_loyalty_awards(); return new; end; $$;
revoke all on function public.retry_loyalty_awards_after_fx_update() from public, anon, authenticated;
drop trigger if exists retry_loyalty_awards_after_fx_update on public.books_fx_rates;
create trigger retry_loyalty_awards_after_fx_update
  after insert or update on public.books_fx_rates
  for each row execute function public.retry_loyalty_awards_after_fx_update();

create or replace function public.retry_loyalty_books_posting(target_ledger_entry_id uuid)
returns text language plpgsql security definer set search_path = pg_catalog, public
as $$
declare current_status text;
begin
  if auth.role() <> 'service_role' then raise exception 'Only the service role may retry loyalty accounting'; end if;
  perform public.post_loyalty_ledger_entry_to_books(target_ledger_entry_id);
  select status into current_status from public.loyalty_books_postings where ledger_entry_id = target_ledger_entry_id;
  return coalesce(current_status, 'pending');
end;
$$;
revoke all on function public.retry_loyalty_books_posting(uuid) from public, anon, authenticated;
grant execute on function public.retry_loyalty_books_posting(uuid) to service_role;

create or replace function public.enqueue_verified_purchase_loyalty_award()
returns trigger language plpgsql security definer set search_path = pg_catalog, public
as $$
declare
  source_user_id uuid;
  source_uuid uuid;
  amount_value numeric;
  currency_value text;
  verified boolean := false;
  booking_row public.special_event_bookings%rowtype;
begin
  if tg_table_name = 'menu_orders' then
    if new.payment_status <> 'paid' or (tg_op = 'UPDATE' and old.payment_status = 'paid') then return new; end if;
    if new.payment_method not in ('card', 'mobile-money') or new.flutterwave_transaction_id is null then return new; end if;
    select exists (select 1 from public.menu_payment_attempts attempt
      where attempt.order_id = new.id and attempt.status = 'completed'
        and attempt.transaction_id = new.flutterwave_transaction_id) into verified;
    if not verified then return new; end if;
    source_user_id := new.user_id;
    source_uuid := new.id;
    amount_value := greatest(coalesce(new.subtotal, 0) - coalesce(new.points_discount, 0), 0);
    currency_value := new.currency;
    insert into public.loyalty_award_queue (user_id, source_type, source_id, eligible_amount, eligible_currency)
    values (source_user_id, 'menu_order', source_uuid, amount_value, currency_value)
    on conflict (source_type, source_id) do nothing;
    perform public.process_pending_loyalty_awards();
  elsif tg_table_name = 'hotel_bookings' then
    if new.payment_status <> 'paid' or (tg_op = 'UPDATE' and old.payment_status = 'paid') or new.user_id is null then return new; end if;
    select exists (select 1 from public.hotel_payment_attempts attempt
      where attempt.booking_id = new.id and attempt.status = 'completed' and attempt.transaction_id is not null) into verified;
    if not verified then return new; end if;
    insert into public.loyalty_award_queue (user_id, source_type, source_id, eligible_amount, eligible_currency)
    values (new.user_id, 'hotel_booking', new.id, greatest(new.taxable_subtotal, 0), trim(new.currency_code))
    on conflict (source_type, source_id) do nothing;
    perform public.process_pending_loyalty_awards();
  elsif tg_table_name = 'special_event_payments' then
    if new.status <> 'successful' or (tg_op = 'UPDATE' and old.status = 'successful') then return new; end if;
    select * into booking_row from public.special_event_bookings where id = new.booking_id;
    if not found or booking_row.user_id is null then return new; end if;
    insert into public.loyalty_award_queue (user_id, source_type, source_id, eligible_amount, eligible_currency)
    values (booking_row.user_id, 'special_event_payment', new.id,
      greatest(coalesce(booking_row.subtotal, 0) - coalesce(booking_row.discount_amount, 0), 0), upper(new.currency))
    on conflict (source_type, source_id) do nothing;
    perform public.process_pending_loyalty_awards();
  end if;
  return new;
end;
$$;
revoke all on function public.enqueue_verified_purchase_loyalty_award() from public, anon, authenticated;
drop trigger if exists menu_order_verified_loyalty_award on public.menu_orders;
create trigger menu_order_verified_loyalty_award
  after insert or update of payment_status on public.menu_orders
  for each row execute function public.enqueue_verified_purchase_loyalty_award();

create or replace function public.enqueue_menu_award_after_verified_attempt()
returns trigger language plpgsql security definer set search_path = pg_catalog, public
as $$
declare order_row public.menu_orders%rowtype;
begin
  if new.status <> 'completed' or new.transaction_id is null then return new; end if;
  select * into order_row from public.menu_orders where id = new.order_id;
  if not found or order_row.payment_status <> 'paid' or order_row.flutterwave_transaction_id <> new.transaction_id then return new; end if;
  insert into public.loyalty_award_queue (user_id, source_type, source_id, eligible_amount, eligible_currency)
  values (order_row.user_id, 'menu_order', order_row.id,
    greatest(coalesce(order_row.subtotal, 0) - coalesce(order_row.points_discount, 0), 0), order_row.currency)
  on conflict (source_type, source_id) do nothing;
  perform public.process_pending_loyalty_awards();
  return new;
end;
$$;
revoke all on function public.enqueue_menu_award_after_verified_attempt() from public, anon, authenticated;
drop trigger if exists menu_payment_attempt_verified_loyalty_award on public.menu_payment_attempts;
create trigger menu_payment_attempt_verified_loyalty_award
  after insert or update of status on public.menu_payment_attempts
  for each row execute function public.enqueue_menu_award_after_verified_attempt();

drop trigger if exists hotel_booking_verified_loyalty_award on public.hotel_bookings;
create trigger hotel_booking_verified_loyalty_award
  after insert or update of payment_status on public.hotel_bookings
  for each row execute function public.enqueue_verified_purchase_loyalty_award();
drop trigger if exists special_event_verified_loyalty_award on public.special_event_payments;
create trigger special_event_verified_loyalty_award
  after insert or update of status on public.special_event_payments
  for each row execute function public.enqueue_verified_purchase_loyalty_award();

-- Step 5: qualify referrals only from server-verified milestones, then credit both ledgers.
create or replace function public.qualify_loyalty_referral(
  target_user_id uuid,
  target_qualification_type text,
  target_source_type text,
  target_source_id uuid,
  target_purchase_ugx numeric default null
)
returns void language plpgsql security definer set search_path = pg_catalog, public
as $$
declare
  referral_row public.loyalty_referrals%rowtype;
  bonus_referrer integer;
  bonus_invitee integer;
  profile_role text;
  valid_milestone boolean := false;
  purchase_created_at timestamptz;
  referral_minimum numeric;
begin
  if target_qualification_type = 'purchase' then
    select created_at into purchase_created_at
      from public.loyalty_award_queue
     where user_id = target_user_id and source_type = target_source_type
       and source_id = target_source_id and status = 'posted';
    select guest_referral_minimum_ugx into referral_minimum
      from public.loyalty_program_settings where id = true;
    valid_milestone := coalesce(target_purchase_ugx >= referral_minimum, false)
      and purchase_created_at is not null
      and not exists (
        select 1 from public.loyalty_award_queue earlier_purchase
         where earlier_purchase.user_id = target_user_id
           and earlier_purchase.source_type in ('menu_order', 'hotel_booking', 'special_event_payment')
           and earlier_purchase.created_at < purchase_created_at
      );
  elsif target_qualification_type = 'task' then
    select exists (
      select 1 from public.task_reports report
      join public.tasks task on task.id = report.task_id
      join public.user_profiles provider on provider.id = report.provider_id
      where report.task_id = target_source_id and report.status = 'approved'
        and task.status = 'completed' and provider.user_id = target_user_id
        and provider.role = 'service_provider'
    ) into valid_milestone;
  elsif target_qualification_type = 'manager_listing' then
    select exists (
      select 1 from public.hotel_rooms room
      join public.user_profiles manager on manager.user_id = room.created_by
      where room.id = target_source_id and room.status = 'published'
        and room.created_by = target_user_id and manager.role = 'manager'
    ) into valid_milestone;
  end if;
  if not exists (select 1 from public.loyalty_program_settings where id = true and program_enabled) then return; end if;
  if not valid_milestone then return; end if;
  if not exists (
    select 1
      from public.loyalty_referrals referral
      join public.loyalty_accounts invitee on invitee.user_id = referral.referred_user_id and invitee.is_enrolled
      join public.loyalty_accounts referrer on referrer.user_id = referral.referrer_user_id and referrer.is_enrolled
     where referral.referred_user_id = target_user_id and referral.status = 'pending'
  ) then return; end if;

  select role into profile_role from public.user_profiles where user_id = target_user_id;
  if target_qualification_type = 'purchase' and profile_role is distinct from 'guest' then return; end if;
  if target_qualification_type in ('task', 'manager_listing') and profile_role not in ('manager', 'service_provider') then return; end if;

  perform 1 from public.loyalty_accounts where user_id = target_user_id for update;
  select * into referral_row from public.loyalty_referrals
   where referred_user_id = target_user_id and status = 'pending' for update;
  if not found then return; end if;
  select referrer_bonus_points, invitee_bonus_points into bonus_referrer, bonus_invitee
    from public.loyalty_program_settings where id = true;
  update public.loyalty_referrals
     set status = 'qualified', qualification_type = target_qualification_type,
         qualification_source_type = target_source_type, qualification_source_id = target_source_id,
         referrer_points = bonus_referrer, invitee_points = bonus_invitee, qualified_at = now()
   where id = referral_row.id;
  perform public.apply_loyalty_points_delta(
    referral_row.referrer_user_id, 'referral_earn', bonus_referrer, 'referral', referral_row.id,
    'Qualified referral reward'
  );
  perform public.apply_loyalty_points_delta(
    referral_row.referred_user_id, 'referral_welcome', bonus_invitee, 'referral', referral_row.id,
    'Referral welcome reward'
  );
end;
$$;
revoke all on function public.qualify_loyalty_referral(uuid, text, text, uuid, numeric) from public, anon, authenticated;

-- Step 6: use trusted approval for service-task rewards; clients cannot write approval status.
create or replace function public.submit_task_report_for_approval(target_report_id uuid)
returns void language plpgsql security definer set search_path = pg_catalog, public
as $$
declare report_row public.task_reports%rowtype; provider_profile_id uuid;
begin
  if auth.uid() is null then raise exception 'Sign in to submit work for approval'; end if;
  select id into provider_profile_id from public.user_profiles where user_id = auth.uid() and role = 'service_provider';
  if provider_profile_id is null then raise exception 'Only the assigned service provider can submit this report'; end if;
  select * into report_row from public.task_reports where id = target_report_id for update;
  if not found or report_row.provider_id <> provider_profile_id then raise exception 'Task report was not found'; end if;
  if report_row.status <> 'in_progress' or report_row.percentage_complete < 100 then
    raise exception 'Complete the report before requesting approval';
  end if;
  update public.task_reports set status = 'completed_pending_approval', last_updated_by = auth.uid(), updated_at = now()
   where id = target_report_id;
end;
$$;
revoke all on function public.submit_task_report_for_approval(uuid) from public, anon;
grant execute on function public.submit_task_report_for_approval(uuid) to authenticated;

create or replace function public.approve_task_report_and_award_points(target_report_id uuid)
returns integer language plpgsql security definer set search_path = pg_catalog, public
as $$
declare
  report_row public.task_reports%rowtype;
  task_row public.tasks%rowtype;
  provider_user_id uuid;
  actor_role text;
  points_this_month bigint;
  reward_points integer;
  task_cap integer;
begin
  if auth.uid() is null then raise exception 'Sign in to approve task work'; end if;
  select role into actor_role from public.user_profiles where user_id = auth.uid();
  select * into report_row from public.task_reports where id = target_report_id for update;
  if not found then raise exception 'Task report was not found'; end if;
  select * into task_row from public.tasks where id = report_row.task_id for update;
  if not found or task_row.created_by <> auth.uid() or actor_role <> 'manager' then
    raise exception 'Only the task manager can approve this report';
  end if;
  if task_row.assigned_to is distinct from report_row.provider_id
     or report_row.status <> 'completed_pending_approval' then
    raise exception 'This task report is not ready for approval';
  end if;
  select user_id into provider_user_id from public.user_profiles
    where id = report_row.provider_id and role = 'service_provider';
  if provider_user_id is null then raise exception 'Assigned service provider account was not found'; end if;
  perform 1 from public.loyalty_accounts where user_id = provider_user_id for update;

  update public.task_reports set status = 'approved', last_updated_by = auth.uid(), updated_at = now()
   where id = report_row.id;
  update public.tasks set status = 'completed', updated_at = now() where id = task_row.id;
  insert into public.notifications (user_id, task_id, type, message)
  values (provider_user_id, task_row.id, 'task_updated', 'Your task "' || task_row.title || '" has been approved and marked complete.');

  select coalesce(sum(points_delta), 0) into points_this_month
    from public.loyalty_ledger_entries
   where user_id = provider_user_id and entry_type = 'task_earn'
     and created_at >= date_trunc('month', now());
  select monthly_task_points_cap, task_approval_points into task_cap, reward_points
    from public.loyalty_program_settings where id = true;
  reward_points := least(reward_points, greatest(task_cap - points_this_month, 0)::integer);
  if reward_points > 0
     and exists (select 1 from public.loyalty_program_settings where id = true and program_enabled)
     and exists (select 1 from public.loyalty_accounts where user_id = provider_user_id and is_enrolled) then
    if public.apply_loyalty_points_delta(
      provider_user_id, 'task_earn', reward_points, 'approved_task', task_row.id,
      'Manager-approved service task reward'
    ) is null then
      reward_points := 0;
    end if;
  else
    reward_points := 0;
  end if;
  perform public.qualify_loyalty_referral(provider_user_id, 'task', 'approved_task', task_row.id, null);
  return reward_points;
end;
$$;
revoke all on function public.approve_task_report_and_award_points(uuid) from public, anon;
grant execute on function public.approve_task_report_and_award_points(uuid) to authenticated;

-- Keep direct client writes away from approval status. Existing forms write only these fields.
revoke insert, update, delete on public.task_reports from public, anon, authenticated;
grant select on public.task_reports to authenticated;
grant insert (task_id, provider_id, description, percentage_complete, last_updated_by)
  on public.task_reports to authenticated;
grant update (description, percentage_complete, last_updated_by, updated_at)
  on public.task_reports to authenticated;
drop policy if exists task_reports_insert on public.task_reports;
create policy task_reports_insert on public.task_reports for insert to authenticated
  with check (
    provider_id = (select id from public.user_profiles where user_id = auth.uid() and role = 'service_provider')
    and status = 'in_progress'
    and exists (select 1 from public.tasks task where task.id = task_reports.task_id and task.assigned_to = task_reports.provider_id)
  );
drop policy if exists task_reports_update on public.task_reports;
create policy task_reports_update on public.task_reports for update to authenticated
  using (
    status <> 'approved'
    and provider_id = (select id from public.user_profiles where user_id = auth.uid() and role = 'service_provider')
  )
  with check (
    provider_id = (select id from public.user_profiles where user_id = auth.uid() and role = 'service_provider')
  );

-- Award one referral milestone for a manager's first published room listing.
create or replace function public.qualify_manager_listing_referral()
returns trigger language plpgsql security definer set search_path = pg_catalog, public
as $$ begin
  if new.status = 'published' and (tg_op = 'INSERT' or old.status is distinct from 'published') then
    perform public.qualify_loyalty_referral(new.created_by, 'manager_listing', 'hotel_room', new.id, null);
  end if;
  return new;
end; $$;
revoke all on function public.qualify_manager_listing_referral() from public, anon, authenticated;
drop trigger if exists qualify_manager_listing_referral on public.hotel_rooms;
create trigger qualify_manager_listing_referral
  after insert or update of status on public.hotel_rooms
  for each row execute function public.qualify_manager_listing_referral();

-- Step 7: reverse full purchase awards and qualifying referral bonuses after full refunds or chargebacks.
-- Partial refunds are not prorated because menu and hotel flows do not persist a refund amount ledger.
alter table public.loyalty_award_queue drop constraint if exists loyalty_award_queue_status_check;
alter table public.loyalty_award_queue
  add constraint loyalty_award_queue_status_check
  check (status in ('pending_fx', 'posted', 'excluded', 'failed', 'refunded', 'reversed'));

create or replace function public.reverse_loyalty_purchase_effects(
  target_source_type text,
  target_source_id uuid,
  target_reversal_source_type text,
  target_queue_status text
)
returns void language plpgsql security definer set search_path = pg_catalog, public
as $$
declare
  queue_row public.loyalty_award_queue%rowtype;
  referral_row public.loyalty_referrals%rowtype;
begin
  if target_queue_status not in ('refunded', 'reversed') then
    raise exception 'Invalid loyalty reversal status';
  end if;

  select * into queue_row from public.loyalty_award_queue
   where source_type = target_source_type and source_id = target_source_id for update;
  if not found then return; end if;

  if queue_row.status = 'posted' and queue_row.points_awarded > 0 then
    perform public.apply_loyalty_points_delta(
      queue_row.user_id, 'purchase_reversal', -queue_row.points_awarded,
      target_reversal_source_type, target_source_id, 'Reversal of refunded or charged-back purchase reward'
    );
  end if;
  if queue_row.status in ('posted', 'pending_fx', 'failed') then
    update public.loyalty_award_queue
       set status = target_queue_status, processed_at = now(),
           error_message = case when target_queue_status = 'refunded' then 'Purchase refunded' else 'Purchase charged back' end
     where id = queue_row.id;
  end if;

  select * into referral_row from public.loyalty_referrals
   where status = 'qualified' and qualification_source_type = target_source_type
     and qualification_source_id = target_source_id for update;
  if found then
    perform public.apply_loyalty_points_delta(
      referral_row.referrer_user_id, 'referral_reversal', -referral_row.referrer_points,
      'referral_refund', referral_row.id, 'Reversal of referral reward after qualifying purchase reversal'
    );
    perform public.apply_loyalty_points_delta(
      referral_row.referred_user_id, 'referral_reversal', -referral_row.invitee_points,
      'referral_refund', referral_row.id, 'Reversal of referral welcome reward after qualifying purchase reversal'
    );
    update public.loyalty_referrals set status = 'cancelled' where id = referral_row.id;
  end if;
end;
$$;
revoke all on function public.reverse_loyalty_purchase_effects(text, uuid, text, text) from public, anon, authenticated;

create or replace function public.reverse_loyalty_after_order_refund()
returns trigger language plpgsql security definer set search_path = pg_catalog, public
as $$
declare
  source_type_value text;
  reversal_type_value text;
  queue_status_value text;
begin
  if new.payment_status not in ('refunded', 'chargeback')
     or old.payment_status is not distinct from new.payment_status then
    return new;
  end if;
  if tg_table_name = 'menu_orders' then
    source_type_value := 'menu_order';
  else
    source_type_value := 'hotel_booking';
  end if;
  reversal_type_value := source_type_value || '_reversal';
  queue_status_value := case when new.payment_status = 'refunded' then 'refunded' else 'reversed' end;
  perform public.reverse_loyalty_purchase_effects(source_type_value, new.id, reversal_type_value, queue_status_value);
  return new;
end;
$$;
revoke all on function public.reverse_loyalty_after_order_refund() from public, anon, authenticated;
drop trigger if exists reverse_menu_order_loyalty_refund on public.menu_orders;
create trigger reverse_menu_order_loyalty_refund
  after update of payment_status on public.menu_orders
  for each row execute function public.reverse_loyalty_after_order_refund();
drop trigger if exists reverse_hotel_booking_loyalty_refund on public.hotel_bookings;
create trigger reverse_hotel_booking_loyalty_refund
  after update of payment_status on public.hotel_bookings
  for each row execute function public.reverse_loyalty_after_order_refund();

create or replace function public.reverse_special_event_loyalty()
returns trigger language plpgsql security definer set search_path = pg_catalog, public
as $$
begin
  if new.status in ('refunded', 'chargeback') and old.status is distinct from new.status then
    perform public.reverse_loyalty_purchase_effects(
      'special_event_payment', new.id, 'special_event_payment_reversal',
      case when new.status = 'refunded' then 'refunded' else 'reversed' end
    );
  end if;
  return new;
end;
$$;
revoke all on function public.reverse_special_event_loyalty() from public, anon, authenticated;
drop trigger if exists reverse_refunded_event_loyalty on public.special_event_payments;
drop trigger if exists reverse_special_event_loyalty on public.special_event_payments;
create trigger reverse_special_event_loyalty
  after update of status on public.special_event_payments
  for each row execute function public.reverse_special_event_loyalty();

-- Step 8: propose the configured Books sales organization, but leave rewards disabled for Finance approval.
update public.loyalty_program_settings settings
   set books_organization_id = sales.organization_id, updated_at = now()
  from public.books_menu_sales_settings sales
  join public.books_organizations organization on organization.id = sales.organization_id
 where settings.id = true and sales.id = true
   and upper(organization.base_currency) = 'UGX'
   and settings.books_organization_id is null;

-- Verify the organization is platform-owned, uses UGX, and the expense/liability codes are appropriate:
-- select settings.program_enabled, organization.id, organization.name, organization.owner_id,
--        organization.base_currency, settings.books_expense_account_code, settings.books_liability_account_code
--   from public.loyalty_program_settings settings
--   left join public.books_organizations organization on organization.id = settings.books_organization_id
--  where settings.id = true;
-- Only after Finance approves that mapping, activate with:
-- update public.loyalty_program_settings set program_enabled = true, updated_at = now() where id = true;
-- Activation validates the UGX organization and account types before processing queued purchases.
-- Redemption remains disabled until merchant settlement and redemption accounting are implemented.

-- Step 9: useful indexes and schema refresh after reviewing the SQL and applying it.
create index if not exists loyalty_books_postings_status_idx
  on public.loyalty_books_postings (status, created_at) where status <> 'posted';
notify pgrst, 'reload schema';

-- Operational checks (read-only):
-- select status, count(*) from public.loyalty_award_queue group by status;
-- select status, count(*) from public.loyalty_books_postings group by status;
-- select count(*) from public.loyalty_ledger_entries where points_delta < 0;
-- Redemption is intentionally disabled; do not change redemption_enabled until seller-funded
-- vs platform-funded discount accounting and bank/processor settlement are implemented and tested.

commit;

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
    'public.books_memberships', 'public.books_menu_sales_settings',
    'public.books_accounts', 'public.books_journal_transactions',
    'public.books_journal_lines', 'public.books_fx_rates'
  ] loop
    if to_regclass(dependency) is null then
      raise exception 'Rewards setup stopped: required relation % is missing', dependency;
    end if;
  end loop;
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

create unique index if not exists books_journal_source_unique
  on public.books_journal_transactions (organization_id, source_type, source_id)
  where source_id is not null;
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
  using (exists (
    select 1 from public.books_memberships membership
     where membership.organization_id = loyalty_books_postings.organization_id
       and membership.user_id = auth.uid()
  ));

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
  debit_account_uuid uuid;
  credit_account_uuid uuid;
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
    select id into debit_account_uuid from public.books_accounts
     where organization_id = organization_uuid and code = debit_code;
    select id into credit_account_uuid from public.books_accounts
     where organization_id = organization_uuid and code = credit_code;
    insert into public.books_journal_transactions (
      organization_id, source_type, source_id, transaction_date, description, created_by
    ) values (
      organization_uuid, 'loyalty_points', entry_row.id, entry_row.created_at::date,
      entry_row.description, organization_owner
    ) on conflict do nothing returning id into journal_uuid;
    if journal_uuid is null then
      select id into journal_uuid from public.books_journal_transactions
       where organization_id = organization_uuid and source_type = 'loyalty_points'
         and source_id = entry_row.id;
    else
      insert into public.books_journal_lines (transaction_id, account_id, debit, currency_code)
      values (journal_uuid, debit_account_uuid, posting_amount, 'UGX');
      insert into public.books_journal_lines (transaction_id, account_id, credit, currency_code)
      values (journal_uuid, credit_account_uuid, posting_amount, 'UGX');
    end if;
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
-- Legacy rewards schema is retained but disabled; tenant-scoped setup follows in a second transaction.

commit;

begin;

do $$
declare dependency text;
begin
  foreach dependency in array array[
    'public.hotel_rooms','public.hotel_bookings','public.menu_items','public.menu_orders',
    'public.menu_order_items','public.menu_payment_attempts','public.hotel_payment_attempts',
    'public.special_events','public.special_event_bookings','public.special_event_payments',
    'public.tasks','public.task_reports','public.user_profiles','public.books_organizations',
    'public.books_memberships','public.books_accounts','public.books_journal_transactions',
    'public.books_journal_lines','public.books_fx_rates'
  ] loop
    if to_regclass(dependency) is null then
      raise exception 'Hotel rewards upgrade stopped: required relation % is missing', dependency;
    end if;
  end loop;
end;
$$;

-- Stop legacy global processing. Preserve its ledger and accounts; never infer their hotel owner.
drop trigger if exists initialize_loyalty_account_after_signup on auth.users;
drop trigger if exists menu_order_verified_loyalty_award on public.menu_orders;
drop trigger if exists menu_payment_attempt_verified_loyalty_award on public.menu_payment_attempts;
drop trigger if exists hotel_booking_verified_loyalty_award on public.hotel_bookings;
drop trigger if exists special_event_verified_loyalty_award on public.special_event_payments;
drop trigger if exists reverse_menu_order_loyalty_refund on public.menu_orders;
drop trigger if exists reverse_hotel_booking_loyalty_refund on public.hotel_bookings;
drop trigger if exists reverse_special_event_loyalty on public.special_event_payments;
drop trigger if exists reverse_refunded_event_loyalty on public.special_event_payments;
drop trigger if exists qualify_manager_listing_referral on public.hotel_rooms;
drop trigger if exists activate_loyalty_awards_after_configuration on public.loyalty_program_settings;
drop trigger if exists retry_loyalty_awards_after_fx_update on public.books_fx_rates;
update public.loyalty_program_settings set program_enabled=false, redemption_enabled=false where id=true;
revoke execute on function public.process_pending_loyalty_awards() from service_role;
revoke execute on function public.retry_failed_loyalty_award(uuid) from service_role;

create table if not exists public.hotel_loyalty_programs (
  organization_id uuid primary key references public.books_organizations(id) on delete restrict,
  points_per_1000_ugx integer not null default 1 check (points_per_1000_ugx > 0),
  guest_referral_minimum_ugx numeric(20,4) not null default 100000 check (guest_referral_minimum_ugx > 0),
  referrer_bonus_points integer not null default 250 check (referrer_bonus_points > 0),
  invitee_bonus_points integer not null default 250 check (invitee_bonus_points > 0),
  task_approval_points integer not null default 50 check (task_approval_points > 0),
  monthly_task_points_cap integer not null default 500 check (monthly_task_points_cap > 0),
  ugx_value_per_point numeric(20,4) not null default 10 check (ugx_value_per_point > 0),
  books_expense_account_code text not null default '5105',
  books_liability_account_code text not null default '2600',
  program_enabled boolean not null default false,
  redemption_enabled boolean not null default false,
  points_expire boolean not null default false,
  updated_at timestamptz not null default now(),
  check (books_expense_account_code <> books_liability_account_code)
);

alter table public.menu_items add column if not exists organization_id uuid references public.books_organizations(id) on delete restrict;
alter table public.menu_orders add column if not exists organization_id uuid references public.books_organizations(id) on delete restrict;
alter table public.menu_orders add column if not exists loyalty_points_redeemed bigint not null default 0;
alter table public.menu_orders add column if not exists gross_total_amount numeric(20,4);
alter table public.menu_orders add column if not exists amount_due numeric(20,4);
update public.menu_orders set gross_total_amount=coalesce(gross_total_amount,subtotal+tax_amount+service_fee+tip_amount),amount_due=coalesce(amount_due,total_amount) where gross_total_amount is null or amount_due is null;
alter table public.menu_orders alter column gross_total_amount set not null;
alter table public.menu_orders alter column amount_due set default 0;
alter table public.menu_orders alter column amount_due set not null;
alter table public.menu_orders drop constraint if exists menu_orders_secure_total_check;
alter table public.menu_orders add constraint menu_orders_secure_total_check check (
  pricing_version <> 1 or (
    public.checkout_currency_minor_units(currency) is not null and subtotal >= 0 and tax_amount >= 0
    and service_fee >= 0 and tip_amount >= 0 and points_discount >= 0
    and points_discount <= subtotal
    and gross_total_amount = round(subtotal + tax_amount + service_fee + tip_amount, public.checkout_currency_minor_units(currency))
    and total_amount = gross_total_amount
    and amount_due = round(total_amount-points_discount,public.checkout_currency_minor_units(currency))
  )
) not valid;

alter table public.hotel_bookings add column if not exists gross_total_amount numeric(20,4);
alter table public.hotel_bookings add column if not exists loyalty_points_discount numeric(20,4) not null default 0;
alter table public.hotel_bookings add column if not exists loyalty_points_redeemed bigint not null default 0;
update public.hotel_bookings set gross_total_amount=total_amount where gross_total_amount is null;
alter table public.hotel_bookings alter column gross_total_amount set not null;
alter table public.hotel_bookings drop constraint if exists hotel_bookings_secure_total_check;
alter table public.hotel_bookings add constraint hotel_bookings_secure_total_check check (
  public.checkout_currency_minor_units(currency_code) is not null and nightly_subtotal >= 0
  and discount_amount >= 0 and taxable_subtotal >= 0 and vat_amount >= 0 and lht_amount >= 0
  and loyalty_points_discount >= 0
  and gross_total_amount = round(taxable_subtotal + vat_amount + lht_amount,public.checkout_currency_minor_units(currency_code))
  and total_amount = gross_total_amount
  and amount_due = round(total_amount-loyalty_points_discount,public.checkout_currency_minor_units(currency_code))
) not valid;

alter table public.special_events add column if not exists organization_id uuid references public.books_organizations(id) on delete restrict;
alter table public.special_event_bookings add column if not exists organization_id uuid references public.books_organizations(id) on delete restrict;
alter table public.special_event_bookings add column if not exists gross_total_amount numeric(20,4);
alter table public.special_event_bookings add column if not exists loyalty_points_discount numeric(20,4) not null default 0;
alter table public.special_event_bookings add column if not exists loyalty_points_redeemed bigint not null default 0;
update public.special_event_bookings set gross_total_amount=total_amount where gross_total_amount is null;
alter table public.special_event_bookings alter column gross_total_amount set not null;
alter table public.special_event_bookings drop constraint if exists special_event_bookings_secure_total_check;
alter table public.special_event_bookings add constraint special_event_bookings_secure_total_check check (
  public.checkout_currency_minor_units(currency) is not null and subtotal >= 0 and service_fee >= 0
  and tax_amount >= 0 and discount_amount >= 0 and loyalty_points_discount >= 0
  and gross_total_amount = round(subtotal + service_fee + tax_amount - discount_amount,public.checkout_currency_minor_units(currency))
  and total_amount = gross_total_amount
  and amount_due = round(total_amount-loyalty_points_discount,public.checkout_currency_minor_units(currency))
) not valid;

alter table public.tasks add column if not exists organization_id uuid references public.books_organizations(id) on delete restrict;

-- Backfill only records with one unambiguous Books organization.
with unique_org as (
  select user_id,min(organization_id) organization_id from public.books_memberships
  group by user_id having count(distinct organization_id)=1
)
update public.menu_items i set organization_id=u.organization_id from unique_org u
where i.organization_id is null and i.managed_by=u.user_id;
with unique_org as (
  select user_id,min(organization_id) organization_id from public.books_memberships
  group by user_id having count(distinct organization_id)=1
)
update public.special_events e set organization_id=u.organization_id from unique_org u
where e.organization_id is null and e.organizer_id=u.user_id;
update public.special_event_bookings b set organization_id=e.organization_id from public.special_events e
where b.event_id=e.id and b.organization_id is null;
with unique_org as (
  select user_id,min(organization_id) organization_id from public.books_memberships
  group by user_id having count(distinct organization_id)=1
)
update public.tasks t set organization_id=u.organization_id from unique_org u
where t.organization_id is null and t.created_by=u.user_id;
update public.menu_orders o set organization_id=x.organization_id from (
  select moi.order_id,min(i.organization_id) organization_id from public.menu_order_items moi
  join public.menu_items i on i.id=moi.menu_item_id group by moi.order_id
  having count(distinct i.organization_id)=1 and min(i.organization_id) is not null
) x where o.id=x.order_id and o.organization_id is null;

create table if not exists public.hotel_loyalty_accounts (
  organization_id uuid not null references public.hotel_loyalty_programs(organization_id) on delete restrict,
  user_id uuid not null references auth.users(id) on delete cascade,
  referral_code text not null,
  is_enrolled boolean not null default false,
  enrolled_at timestamptz,
  signup_referral_code text,
  available_points bigint not null default 0 check (available_points >= 0),
  debt_points bigint not null default 0 check (debt_points >= 0),
  lifetime_points_earned bigint not null default 0 check (lifetime_points_earned >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (organization_id,user_id),
  unique (organization_id,referral_code),
  check (referral_code=upper(referral_code))
);
create table if not exists public.hotel_loyalty_ledger_entries (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.hotel_loyalty_programs(organization_id) on delete restrict,
  user_id uuid not null references auth.users(id) on delete restrict,
  entry_type text not null check (entry_type in ('purchase_earn','referral_earn','referral_welcome','task_earn','purchase_reversal','referral_reversal','redemption','redemption_refund')),
  points_delta bigint not null check (points_delta<>0),
  amount_ugx numeric(20,4) not null default 0 check (amount_ugx>=0),
  source_type text not null,
  source_id uuid not null,
  description text not null,
  created_at timestamptz not null default now(),
  unique (organization_id,user_id,source_type,source_id,entry_type)
);
create table if not exists public.hotel_loyalty_referrals (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.hotel_loyalty_programs(organization_id) on delete restrict,
  referrer_user_id uuid not null references auth.users(id) on delete restrict,
  referred_user_id uuid not null references auth.users(id) on delete restrict,
  referral_code text not null,
  status text not null default 'pending' check (status in ('pending','qualified','cancelled')),
  qualification_type text,
  qualification_source_type text,
  qualification_source_id uuid,
  referrer_points integer not null default 0,
  invitee_points integer not null default 0,
  created_at timestamptz not null default now(),
  qualified_at timestamptz,
  unique (organization_id,referred_user_id),
  check (referrer_user_id<>referred_user_id)
);
create table if not exists public.hotel_loyalty_award_queue (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.hotel_loyalty_programs(organization_id) on delete restrict,
  user_id uuid not null references auth.users(id) on delete restrict,
  source_type text not null check (source_type in ('menu_order','hotel_booking','special_event_payment')),
  source_id uuid not null,
  eligible_amount numeric(20,4) not null check (eligible_amount>=0),
  eligible_currency text not null check (char_length(trim(eligible_currency))=3),
  eligible_amount_ugx numeric(20,4),
  points_awarded bigint not null default 0,
  status text not null default 'pending_fx' check (status in ('pending_fx','posted','excluded','failed','refunded','reversed')),
  error_message text,
  created_at timestamptz not null default now(),
  processed_at timestamptz,
  unique (organization_id,source_type,source_id)
);
create table if not exists public.hotel_loyalty_redemptions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.hotel_loyalty_programs(organization_id) on delete restrict,
  user_id uuid not null references auth.users(id) on delete restrict,
  source_type text not null check (source_type in ('menu_order','hotel_booking','special_event_booking')),
  source_id uuid not null,
  points_redeemed bigint not null check (points_redeemed>0),
  discount_amount numeric(20,4) not null check (discount_amount>0),
  amount_ugx numeric(20,4) not null check (amount_ugx>0),
  currency_code text not null check (char_length(trim(currency_code))=3),
  status text not null default 'reserved' check (status in ('reserved','applied','released','refunded')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id,source_type,source_id)
);
create table if not exists public.hotel_loyalty_books_postings (
  ledger_entry_id uuid primary key references public.hotel_loyalty_ledger_entries(id) on delete restrict,
  organization_id uuid not null references public.hotel_loyalty_programs(organization_id) on delete restrict,
  amount_ugx numeric(20,4) not null check (amount_ugx>0),
  status text not null default 'pending' check (status in ('pending','posted','failed')),
  journal_transaction_id uuid references public.books_journal_transactions(id) on delete restrict,
  error_message text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.menu_orders add column if not exists amount_due numeric(20,4);
update public.menu_orders set amount_due=total_amount where amount_due is null;
alter table public.menu_orders alter column amount_due set default 0;
alter table public.menu_orders alter column amount_due set not null;
alter table public.menu_orders drop constraint if exists menu_orders_secure_total_check;
alter table public.menu_orders add constraint menu_orders_secure_total_check check (
  pricing_version<>1 or (
    public.checkout_currency_minor_units(currency) is not null and subtotal>=0 and tax_amount>=0 and service_fee>=0 and tip_amount>=0
    and points_discount>=0 and points_discount<=subtotal
    and total_amount=round(subtotal+tax_amount+service_fee+tip_amount,public.checkout_currency_minor_units(currency))
    and amount_due=round(total_amount-points_discount,public.checkout_currency_minor_units(currency))
  )
) not valid;

alter table public.hotel_bookings add column if not exists loyalty_points_discount numeric(20,4) not null default 0;
alter table public.hotel_bookings add column if not exists loyalty_points_redeemed bigint not null default 0;
alter table public.hotel_bookings add column if not exists amount_due numeric(20,4);
update public.hotel_bookings set gross_total_amount=total_amount,amount_due=total_amount where gross_total_amount is null or amount_due is null;
alter table public.hotel_bookings alter column gross_total_amount set not null;
alter table public.hotel_bookings alter column amount_due set default 0;
alter table public.hotel_bookings alter column amount_due set not null;
alter table public.hotel_bookings drop constraint if exists hotel_bookings_secure_total_check;
alter table public.hotel_bookings add constraint hotel_bookings_secure_total_check check (
  public.checkout_currency_minor_units(currency_code) is not null and nightly_subtotal>=0 and discount_amount>=0
  and taxable_subtotal>=0 and vat_amount>=0 and lht_amount>=0 and loyalty_points_discount>=0
  and total_amount=round(taxable_subtotal+vat_amount+lht_amount,public.checkout_currency_minor_units(currency_code))
  and amount_due=round(total_amount-loyalty_points_discount,public.checkout_currency_minor_units(currency_code))
) not valid;

alter table public.special_event_bookings add column if not exists loyalty_points_discount numeric(20,4) not null default 0;
alter table public.special_event_bookings add column if not exists loyalty_points_redeemed bigint not null default 0;
alter table public.special_event_bookings add column if not exists amount_due numeric(20,4);
update public.special_event_bookings set gross_total_amount=total_amount,amount_due=total_amount where gross_total_amount is null or amount_due is null;
alter table public.special_event_bookings alter column gross_total_amount set not null;
alter table public.special_event_bookings alter column amount_due set default 0;
alter table public.special_event_bookings alter column amount_due set not null;
alter table public.special_event_bookings drop constraint if exists special_event_bookings_secure_total_check;
alter table public.special_event_bookings add constraint special_event_bookings_secure_total_check check (
  public.checkout_currency_minor_units(currency) is not null and subtotal>=0 and service_fee>=0 and tax_amount>=0 and discount_amount>=0
  and loyalty_points_discount>=0
  and total_amount=round(subtotal+service_fee+tax_amount-discount_amount,public.checkout_currency_minor_units(currency))
  and amount_due=round(total_amount-loyalty_points_discount,public.checkout_currency_minor_units(currency))
) not valid;

create index if not exists hotel_loyalty_ledger_recent_idx on public.hotel_loyalty_ledger_entries (organization_id,user_id,created_at desc);
create index if not exists hotel_loyalty_referrals_referrer_idx on public.hotel_loyalty_referrals (organization_id,referrer_user_id,created_at desc);
create index if not exists hotel_loyalty_awards_pending_idx on public.hotel_loyalty_award_queue (organization_id,created_at) where status='pending_fx';
create index if not exists hotel_loyalty_redemptions_reserved_idx on public.hotel_loyalty_redemptions (organization_id,user_id) where status='reserved';
create index if not exists hotel_loyalty_books_status_idx on public.hotel_loyalty_books_postings (organization_id,status,created_at) where status<>'posted';

insert into public.hotel_loyalty_programs (organization_id)
select distinct organization_id from public.hotel_rooms on conflict do nothing;
insert into public.hotel_loyalty_programs (organization_id)
select distinct organization_id from public.menu_items where organization_id is not null on conflict do nothing;
insert into public.hotel_loyalty_programs (organization_id)
select distinct organization_id from public.special_events where organization_id is not null on conflict do nothing;

alter table public.hotel_loyalty_programs enable row level security;
alter table public.hotel_loyalty_accounts enable row level security;
alter table public.hotel_loyalty_ledger_entries enable row level security;
alter table public.hotel_loyalty_referrals enable row level security;
alter table public.hotel_loyalty_award_queue enable row level security;
alter table public.hotel_loyalty_redemptions enable row level security;
alter table public.hotel_loyalty_books_postings enable row level security;
revoke all on public.hotel_loyalty_programs,public.hotel_loyalty_accounts,public.hotel_loyalty_ledger_entries,public.hotel_loyalty_referrals,
  public.hotel_loyalty_award_queue,public.hotel_loyalty_redemptions,public.hotel_loyalty_books_postings from public,anon,authenticated;
grant select on public.hotel_loyalty_programs,public.hotel_loyalty_accounts,public.hotel_loyalty_ledger_entries,public.hotel_loyalty_referrals,
  public.hotel_loyalty_redemptions,public.hotel_loyalty_books_postings to authenticated;
drop policy if exists hotel_loyalty_program_member_read on public.hotel_loyalty_programs;
create policy hotel_loyalty_program_member_read on public.hotel_loyalty_programs for select to authenticated
using (program_enabled or exists(select 1 from public.books_memberships m where m.organization_id=hotel_loyalty_programs.organization_id and m.user_id=auth.uid()));
drop policy if exists hotel_loyalty_account_owner_read on public.hotel_loyalty_accounts;
create policy hotel_loyalty_account_owner_read on public.hotel_loyalty_accounts for select to authenticated using (user_id=auth.uid());
drop policy if exists hotel_loyalty_ledger_owner_read on public.hotel_loyalty_ledger_entries;
create policy hotel_loyalty_ledger_owner_read on public.hotel_loyalty_ledger_entries for select to authenticated using (user_id=auth.uid());
drop policy if exists hotel_loyalty_referral_participant_read on public.hotel_loyalty_referrals;
create policy hotel_loyalty_referral_participant_read on public.hotel_loyalty_referrals for select to authenticated
using (referrer_user_id=auth.uid() or referred_user_id=auth.uid());
drop policy if exists hotel_loyalty_redemption_owner_read on public.hotel_loyalty_redemptions;
create policy hotel_loyalty_redemption_owner_read on public.hotel_loyalty_redemptions for select to authenticated using (user_id=auth.uid());
drop policy if exists hotel_loyalty_books_member_read on public.hotel_loyalty_books_postings;
create policy hotel_loyalty_books_member_read on public.hotel_loyalty_books_postings for select to authenticated
using (exists(select 1 from public.books_memberships m where m.organization_id=hotel_loyalty_books_postings.organization_id and m.user_id=auth.uid()));

create or replace function public.ensure_hotel_loyalty_program()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if new.organization_id is not null then
    insert into public.hotel_loyalty_programs(organization_id) values(new.organization_id) on conflict do nothing;
  end if;
  return new;
end; $$;
revoke all on function public.ensure_hotel_loyalty_program() from public,anon,authenticated;
drop trigger if exists hotel_loyalty_program_room on public.hotel_rooms;
create trigger hotel_loyalty_program_room after insert or update of organization_id on public.hotel_rooms for each row execute function public.ensure_hotel_loyalty_program();

create or replace function public.attach_menu_order_hotel()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare item_org uuid; order_org uuid;
begin
  select organization_id into item_org from public.menu_items where id=new.menu_item_id;
  if item_org is null then raise exception 'Menu item must belong to a hotel before checkout'; end if;
  select organization_id into order_org from public.menu_orders where id=new.order_id for update;
  if order_org is not null and order_org<>item_org then raise exception 'A menu order can only contain items from one hotel'; end if;
  update public.menu_orders set organization_id=item_org where id=new.order_id;
  insert into public.hotel_loyalty_programs(organization_id) values(item_org) on conflict do nothing;
  return new;
end; $$;
revoke all on function public.attach_menu_order_hotel() from public,anon,authenticated;
drop trigger if exists menu_order_attach_hotel on public.menu_order_items;
create trigger menu_order_attach_hotel after insert or update of menu_item_id,order_id on public.menu_order_items for each row execute function public.attach_menu_order_hotel();

create or replace function public.attach_special_event_hotel()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare selected_org uuid;
begin
  if new.organization_id is null then
    select min(m.organization_id) into selected_org from public.books_memberships m where m.user_id=new.organizer_id
    group by m.user_id having count(distinct m.organization_id)=1;
    new.organization_id:=selected_org;
  end if;
  if new.organization_id is null then raise exception 'Choose the hotel organization for this event'; end if;
  insert into public.hotel_loyalty_programs(organization_id) values(new.organization_id) on conflict do nothing;
  return new;
end; $$;
revoke all on function public.attach_special_event_hotel() from public,anon,authenticated;
drop trigger if exists special_event_attach_hotel on public.special_events;
create trigger special_event_attach_hotel before insert or update of organization_id on public.special_events for each row execute function public.attach_special_event_hotel();

create or replace function public.attach_special_event_booking_hotel()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  select organization_id into new.organization_id from public.special_events where id=new.event_id;
  return new;
end; $$;
revoke all on function public.attach_special_event_booking_hotel() from public,anon,authenticated;
drop trigger if exists special_event_booking_attach_hotel on public.special_event_bookings;
create trigger special_event_booking_attach_hotel before insert or update of event_id on public.special_event_bookings for each row execute function public.attach_special_event_booking_hotel();

create or replace function public.configure_task_hotel_rewards()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare selected_org uuid;
begin
  if new.organization_id is null then
    select min(m.organization_id) into selected_org from public.books_memberships m where m.user_id=new.created_by
    group by m.user_id having count(distinct m.organization_id)=1;
    new.organization_id:=selected_org;
  end if;
  if new.organization_id is null then raise exception 'Select the hotel organization for this task'; end if;
  if not exists(select 1 from public.books_memberships m where m.organization_id=new.organization_id and m.user_id=new.created_by and m.role in ('owner','admin')) then
    raise exception 'Task manager must belong to the selected hotel';
  end if;
  insert into public.hotel_loyalty_programs(organization_id) values(new.organization_id) on conflict do nothing;
  return new;
end; $$;
revoke all on function public.configure_task_hotel_rewards() from public,anon,authenticated;
drop trigger if exists task_hotel_rewards_scope on public.tasks;
create trigger task_hotel_rewards_scope before insert or update of organization_id,created_by on public.tasks for each row execute function public.configure_task_hotel_rewards();

create or replace function public.ensure_hotel_loyalty_account(target_organization_id uuid,target_user_id uuid)
returns text language plpgsql security definer set search_path=pg_catalog,public as $$
declare code_value text;
begin
  if target_user_id is null or not exists(select 1 from public.hotel_loyalty_programs where organization_id=target_organization_id) then raise exception 'Hotel rewards program is unavailable'; end if;
  loop
    code_value:='HT-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,12));
    insert into public.hotel_loyalty_accounts(organization_id,user_id,referral_code) values(target_organization_id,target_user_id,code_value)
      on conflict(organization_id,referral_code) do nothing;
    if found then return code_value; end if;
    select referral_code into code_value from public.hotel_loyalty_accounts where organization_id=target_organization_id and user_id=target_user_id;
    if code_value is not null then return code_value; end if;
  end loop;
end; $$;
revoke all on function public.ensure_hotel_loyalty_account(uuid,uuid) from public,anon,authenticated;

create or replace function public.initialize_hotel_loyalty_account_for_user()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare org uuid; code_value text; wants_rewards boolean;
begin
  begin org:=nullif(new.raw_user_meta_data->>'loyalty_organization_id','')::uuid;
  exception when invalid_text_representation then org:=null; end;
  if org is null or not exists(select 1 from public.hotel_loyalty_programs where organization_id=org) then return new; end if;
  code_value:=public.ensure_hotel_loyalty_account(org,new.id);
  wants_rewards:=coalesce(new.raw_user_meta_data->>'loyalty_program','false')='true';
  update public.hotel_loyalty_accounts set signup_referral_code=nullif(upper(trim(new.raw_user_meta_data->>'referral_code')),''),
    is_enrolled=wants_rewards and exists(select 1 from public.hotel_loyalty_programs where organization_id=org and program_enabled),
    enrolled_at=case when wants_rewards then now() else null end
  where organization_id=org and user_id=new.id;
  return new;
end; $$;
revoke all on function public.initialize_hotel_loyalty_account_for_user() from public,anon,authenticated;
drop trigger if exists initialize_hotel_loyalty_account_after_signup on auth.users;
create trigger initialize_hotel_loyalty_account_after_signup after insert on auth.users for each row execute function public.initialize_hotel_loyalty_account_for_user();

create or replace function public.prevent_hotel_loyalty_ledger_mutation()
returns trigger language plpgsql set search_path=pg_catalog,public as $$ begin raise exception 'Hotel loyalty ledger entries are immutable'; end; $$;
revoke all on function public.prevent_hotel_loyalty_ledger_mutation() from public,anon,authenticated;
drop trigger if exists hotel_loyalty_ledger_immutable on public.hotel_loyalty_ledger_entries;
create trigger hotel_loyalty_ledger_immutable before update or delete on public.hotel_loyalty_ledger_entries for each row execute function public.prevent_hotel_loyalty_ledger_mutation();

create or replace function public.post_hotel_loyalty_ledger_entry(target_entry_id uuid)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare e public.hotel_loyalty_ledger_entries%rowtype; p public.hotel_loyalty_programs%rowtype; owner_user uuid;
  expense_id uuid; liability_id uuid; cash_id uuid; journal_id uuid; debit_id uuid; credit_id uuid; amount_value numeric(20,4);
begin
  select * into e from public.hotel_loyalty_ledger_entries where id=target_entry_id;
  if not found then return; end if;
  select * into p from public.hotel_loyalty_programs where organization_id=e.organization_id;
  amount_value:=case when e.amount_ugx>0 then e.amount_ugx else abs(e.points_delta)*p.ugx_value_per_point end;
  insert into public.hotel_loyalty_books_postings(ledger_entry_id,organization_id,amount_ugx,status)
  values(e.id,e.organization_id,amount_value,'pending') on conflict do nothing;
  select owner_id into owner_user from public.books_organizations where id=e.organization_id;
  insert into public.books_accounts(organization_id,code,name,type,is_system) values
   (e.organization_id,p.books_expense_account_code,'Hotel loyalty rewards expense','expense',true),
   (e.organization_id,p.books_liability_account_code,'Hotel loyalty points liability','liability',true),
   (e.organization_id,'1000','Cash and bank','asset',true) on conflict(organization_id,code) do nothing;
  select id into expense_id from public.books_accounts where organization_id=e.organization_id and code=p.books_expense_account_code and type='expense';
  select id into liability_id from public.books_accounts where organization_id=e.organization_id and code=p.books_liability_account_code and type='liability';
  select id into cash_id from public.books_accounts where organization_id=e.organization_id and code='1000' and type='asset';
  if expense_id is null or liability_id is null or cash_id is null then raise exception 'Hotel rewards Books account mapping is incompatible'; end if;
  if e.entry_type='redemption' then debit_id:=liability_id; credit_id:=cash_id;
  elsif e.entry_type='redemption_refund' then debit_id:=cash_id; credit_id:=liability_id;
  elsif e.points_delta>0 then debit_id:=expense_id; credit_id:=liability_id;
  else debit_id:=liability_id; credit_id:=expense_id; end if;
  insert into public.books_journal_transactions(organization_id,source_type,source_id,transaction_date,description,created_by)
  values(e.organization_id,'hotel_loyalty',e.id,e.created_at::date,e.description,owner_user) on conflict do nothing returning id into journal_id;
  if journal_id is null then
    select id into journal_id from public.books_journal_transactions where organization_id=e.organization_id and source_type='hotel_loyalty' and source_id=e.id;
  else
    insert into public.books_journal_lines(transaction_id,account_id,debit,currency_code) values(journal_id,debit_id,amount_value,'UGX');
    insert into public.books_journal_lines(transaction_id,account_id,credit,currency_code) values(journal_id,credit_id,amount_value,'UGX');
  end if;
  update public.hotel_loyalty_books_postings set status='posted',journal_transaction_id=journal_id,error_message=null,updated_at=now() where ledger_entry_id=e.id;
exception when others then
  update public.hotel_loyalty_books_postings set status='failed',error_message=left(sqlerrm,1000),updated_at=now() where ledger_entry_id=target_entry_id;
end; $$;
revoke all on function public.post_hotel_loyalty_ledger_entry(uuid) from public,anon,authenticated;

create or replace function public.apply_hotel_loyalty_delta(
  target_organization_id uuid,target_user_id uuid,target_entry_type text,target_points_delta bigint,
  target_source_type text,target_source_id uuid,target_description text,target_amount_ugx numeric default 0
)
returns uuid language plpgsql security definer set search_path=pg_catalog,public as $$
declare entry_id uuid; a public.hotel_loyalty_accounts%rowtype; applied bigint; remaining bigint;
begin
  if target_points_delta=0 then raise exception 'Points delta cannot be zero'; end if;
  select * into a from public.hotel_loyalty_accounts where organization_id=target_organization_id and user_id=target_user_id for update;
  if not found then raise exception 'Hotel rewards account is not initialized'; end if;
  if target_points_delta>0 and not a.is_enrolled and target_entry_type<>'redemption_refund' then return null; end if;
  insert into public.hotel_loyalty_ledger_entries(organization_id,user_id,entry_type,points_delta,amount_ugx,source_type,source_id,description)
  values(target_organization_id,target_user_id,target_entry_type,target_points_delta,greatest(target_amount_ugx,0),target_source_type,target_source_id,target_description)
  on conflict(organization_id,user_id,source_type,source_id,entry_type) do nothing returning id into entry_id;
  if entry_id is null then return null; end if;
  if target_points_delta>0 then
    applied:=least(a.debt_points,target_points_delta);
    update public.hotel_loyalty_accounts set available_points=available_points+target_points_delta-applied,
      debt_points=debt_points-applied,lifetime_points_earned=lifetime_points_earned+target_points_delta,updated_at=now()
    where organization_id=target_organization_id and user_id=target_user_id;
  else
    remaining:=abs(target_points_delta); applied:=least(a.available_points,remaining);
    update public.hotel_loyalty_accounts set available_points=available_points-applied,
      debt_points=debt_points+remaining-applied,updated_at=now()
    where organization_id=target_organization_id and user_id=target_user_id;
  end if;
  perform public.post_hotel_loyalty_ledger_entry(entry_id);
  return entry_id;
end; $$;
revoke all on function public.apply_hotel_loyalty_delta(uuid,uuid,text,bigint,text,uuid,text,numeric) from public,anon,authenticated;

create or replace function public.get_my_loyalty_summary()
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare result jsonb;
begin
  if auth.uid() is null then raise exception 'Sign in to view hotel rewards'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'organizationId',p.organization_id,'hotelName',o.name,'enrolled',coalesce(a.is_enrolled,false),'referralCode',a.referral_code,
    'availablePoints',greatest(coalesce(a.available_points,0)-coalesce((select sum(r.points_redeemed) from public.hotel_loyalty_redemptions r
      where r.organization_id=p.organization_id and r.user_id=auth.uid() and r.status='reserved'),0),0),
    'lifetimePoints',coalesce(a.lifetime_points_earned,0),'debtPoints',coalesce(a.debt_points,0),
    'referrals',jsonb_build_object(
      'total',(select count(*) from public.hotel_loyalty_referrals r where r.organization_id=p.organization_id and r.referrer_user_id=auth.uid()),
      'qualified',(select count(*) from public.hotel_loyalty_referrals r where r.organization_id=p.organization_id and r.referrer_user_id=auth.uid() and r.status='qualified'),
      'pending',(select count(*) from public.hotel_loyalty_referrals r where r.organization_id=p.organization_id and r.referrer_user_id=auth.uid() and r.status='pending'),
      'pointsEarned',coalesce((select sum(l.points_delta) from public.hotel_loyalty_ledger_entries l where l.organization_id=p.organization_id and l.user_id=auth.uid() and l.entry_type='referral_earn'),0)),
    'entries',coalesce((select jsonb_agg(jsonb_build_object('id',x.id,'entryType',x.entry_type,'pointsDelta',x.points_delta,'description',x.description,'createdAt',x.created_at) order by x.created_at desc)
      from (select id,entry_type,points_delta,description,created_at from public.hotel_loyalty_ledger_entries l where l.organization_id=p.organization_id and l.user_id=auth.uid() order by created_at desc limit 30) x),'[]'::jsonb),
    'policy',jsonb_build_object('pointsPer1000Ugx',p.points_per_1000_ugx,'guestReferralMinimumUgx',p.guest_referral_minimum_ugx,
      'referrerBonusPoints',p.referrer_bonus_points,'inviteeBonusPoints',p.invitee_bonus_points,'taskApprovalPoints',p.task_approval_points,
      'monthlyTaskPointsCap',p.monthly_task_points_cap,'ugxValuePerPoint',p.ugx_value_per_point,'programEnabled',p.program_enabled,
      'redemptionEnabled',p.redemption_enabled,'pointsExpire',p.points_expire,
      'canManage',exists(select 1 from public.books_memberships m where m.organization_id=p.organization_id and m.user_id=auth.uid() and m.role in ('owner','admin')))
  ) order by o.name),'[]'::jsonb) into result
  from public.hotel_loyalty_programs p join public.books_organizations o on o.id=p.organization_id
  left join public.hotel_loyalty_accounts a on a.organization_id=p.organization_id and a.user_id=auth.uid()
  where p.program_enabled or a.user_id is not null or exists(select 1 from public.books_memberships m where m.organization_id=p.organization_id and m.user_id=auth.uid());
  return jsonb_build_object('programs',result);
end; $$;
revoke all on function public.get_my_loyalty_summary() from public,anon;
grant execute on function public.get_my_loyalty_summary() to authenticated;

create or replace function public.set_my_loyalty_enrollment(target_organization_id uuid,target_enrolled boolean)
returns boolean language plpgsql security definer set search_path=pg_catalog,public as $$
declare supplied_code text; referrer_id uuid;
begin
  if auth.uid() is null then raise exception 'Sign in to manage hotel rewards enrollment'; end if;
  if target_enrolled and not exists(select 1 from public.hotel_loyalty_programs where organization_id=target_organization_id and program_enabled) then
    raise exception 'This hotel rewards program is not open for enrollment'; end if;
  perform public.ensure_hotel_loyalty_account(target_organization_id,auth.uid());
  update public.hotel_loyalty_accounts set is_enrolled=target_enrolled,
    enrolled_at=case when target_enrolled and is_enrolled then enrolled_at when target_enrolled then now() else null end,updated_at=now()
    where organization_id=target_organization_id and user_id=auth.uid();
  if target_enrolled then
    select signup_referral_code into supplied_code from public.hotel_loyalty_accounts where organization_id=target_organization_id and user_id=auth.uid();
    if supplied_code is not null then
      select user_id into referrer_id from public.hotel_loyalty_accounts where organization_id=target_organization_id and referral_code=supplied_code and is_enrolled;
      if referrer_id is not null and referrer_id<>auth.uid() then
        insert into public.hotel_loyalty_referrals(organization_id,referrer_user_id,referred_user_id,referral_code)
        values(target_organization_id,referrer_id,auth.uid(),supplied_code) on conflict(organization_id,referred_user_id) do nothing;
      end if;
    end if;
  end if;
  return target_enrolled;
end; $$;
revoke all on function public.set_my_loyalty_enrollment(uuid,boolean) from public,anon;
grant execute on function public.set_my_loyalty_enrollment(uuid,boolean) to authenticated;

create or replace function public.configure_hotel_loyalty_program(
  target_organization_id uuid,target_enabled boolean,target_redemption_enabled boolean,target_points_per_1000_ugx integer,
  target_guest_referral_minimum_ugx numeric,target_referrer_bonus_points integer,target_invitee_bonus_points integer,
  target_task_approval_points integer,target_monthly_task_points_cap integer,target_ugx_value_per_point numeric,
  target_expense_code text,target_liability_code text
)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if auth.uid() is null or not exists(select 1 from public.books_memberships m where m.organization_id=target_organization_id and m.user_id=auth.uid() and m.role in ('owner','admin')) then
    raise exception 'Only this hotel Books owner or admin may configure rewards'; end if;
  if target_redemption_enabled and not target_enabled then raise exception 'Enable hotel rewards before enabling redemption'; end if;
  if target_points_per_1000_ugx<=0 or target_guest_referral_minimum_ugx<=0 or target_referrer_bonus_points<=0 or target_invitee_bonus_points<=0
     or target_task_approval_points<=0 or target_monthly_task_points_cap<=0 or target_ugx_value_per_point<=0 then raise exception 'Rewards settings must be positive'; end if;
  if nullif(trim(target_expense_code),'') is null or nullif(trim(target_liability_code),'') is null or trim(target_expense_code)=trim(target_liability_code) then
    raise exception 'Choose distinct Books expense and liability codes'; end if;
  if target_enabled and not exists(select 1 from public.books_organizations where id=target_organization_id and upper(base_currency)='UGX') then
    raise exception 'Hotel rewards accounting requires a UGX Books organization'; end if;
  insert into public.hotel_loyalty_programs(organization_id,program_enabled,redemption_enabled,points_per_1000_ugx,guest_referral_minimum_ugx,
    referrer_bonus_points,invitee_bonus_points,task_approval_points,monthly_task_points_cap,ugx_value_per_point,books_expense_account_code,books_liability_account_code)
  values(target_organization_id,target_enabled,target_redemption_enabled,target_points_per_1000_ugx,target_guest_referral_minimum_ugx,
    target_referrer_bonus_points,target_invitee_bonus_points,target_task_approval_points,target_monthly_task_points_cap,target_ugx_value_per_point,
    trim(target_expense_code),trim(target_liability_code))
  on conflict(organization_id) do update set program_enabled=excluded.program_enabled,redemption_enabled=excluded.redemption_enabled,
    points_per_1000_ugx=excluded.points_per_1000_ugx,guest_referral_minimum_ugx=excluded.guest_referral_minimum_ugx,
    referrer_bonus_points=excluded.referrer_bonus_points,invitee_bonus_points=excluded.invitee_bonus_points,
    task_approval_points=excluded.task_approval_points,monthly_task_points_cap=excluded.monthly_task_points_cap,
    ugx_value_per_point=excluded.ugx_value_per_point,books_expense_account_code=excluded.books_expense_account_code,
    books_liability_account_code=excluded.books_liability_account_code,updated_at=now();
  if target_enabled then
    insert into public.books_accounts(organization_id,code,name,type,is_system) values
      (target_organization_id,trim(target_expense_code),'Hotel loyalty rewards expense','expense',true),
      (target_organization_id,trim(target_liability_code),'Hotel loyalty points liability','liability',true) on conflict(organization_id,code) do nothing;
    if not exists(select 1 from public.books_accounts where organization_id=target_organization_id and code=trim(target_expense_code) and type='expense')
       or not exists(select 1 from public.books_accounts where organization_id=target_organization_id and code=trim(target_liability_code) and type='liability') then
      raise exception 'The selected Books codes must be expense and liability accounts'; end if;
  end if;
end; $$;
revoke all on function public.configure_hotel_loyalty_program(uuid,boolean,boolean,integer,numeric,integer,integer,integer,integer,numeric,text,text) from public,anon;
grant execute on function public.configure_hotel_loyalty_program(uuid,boolean,boolean,integer,numeric,integer,integer,integer,integer,numeric,text,text) to authenticated;

create or replace function public.reserve_hotel_loyalty_redemption(target_user_id uuid,target_source_type text,target_source_id uuid,target_use_points boolean)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare uid uuid:=auth.uid(); org uuid; gross_value numeric; currency_value text; p public.hotel_loyalty_programs%rowtype;
  a public.hotel_loyalty_accounts%rowtype; r public.hotel_loyalty_redemptions%rowtype; reserved bigint; available bigint;
  fx_rate numeric; decimals integer; spend_points bigint; discount_value numeric; source_user uuid;
begin
  if target_user_id is null or (auth.role()<>'service_role' and uid is distinct from target_user_id) then raise exception 'Hotel loyalty user could not be verified'; end if;
  uid:=target_user_id;
  if target_source_type='menu_order' then
    select organization_id,total_amount,upper(currency),user_id into org,gross_value,currency_value,source_user
      from public.menu_orders where id=target_source_id and user_id=uid and payment_status in ('pending','failed','cancelled') for update;
  elsif target_source_type='hotel_booking' then
    select organization_id,total_amount,currency_code::text,user_id into org,gross_value,currency_value,source_user
      from public.hotel_bookings where id=target_source_id and user_id=uid and payment_status='pending' and booking_status='pending' for update;
  elsif target_source_type='special_event_booking' then
    select organization_id,total_amount,currency,user_id into org,gross_value,currency_value,source_user
      from public.special_event_bookings where id=target_source_id and user_id=uid and payment_status='pending' and status='pending' for update;
  else raise exception 'Unsupported hotel checkout'; end if;
  if org is null then raise exception 'Checkout is not associated with a hotel'; end if;
  select * into p from public.hotel_loyalty_programs where organization_id=org;
  if not found or not p.program_enabled or not p.redemption_enabled then
    if target_source_type='menu_order' then update public.menu_orders set points_discount=0,loyalty_points_redeemed=0,amount_due=total_amount where id=target_source_id;
    elsif target_source_type='hotel_booking' then update public.hotel_bookings set loyalty_points_discount=0,loyalty_points_redeemed=0,amount_due=total_amount where id=target_source_id;
    else update public.special_event_bookings set loyalty_points_discount=0,loyalty_points_redeemed=0,amount_due=total_amount where id=target_source_id; end if;
    return jsonb_build_object('organizationId',org,'discount',0,'points',0,'amountDue',gross_value,'currency',currency_value);
  end if;
  select * into r from public.hotel_loyalty_redemptions where organization_id=org and source_type=target_source_type and source_id=target_source_id for update;
  if not target_use_points then
    if found and r.status='reserved' then update public.hotel_loyalty_redemptions set status='released',updated_at=now() where id=r.id; end if;
    if target_source_type='menu_order' then update public.menu_orders set points_discount=0,loyalty_points_redeemed=0,amount_due=total_amount where id=target_source_id;
    elsif target_source_type='hotel_booking' then update public.hotel_bookings set loyalty_points_discount=0,loyalty_points_redeemed=0,amount_due=total_amount where id=target_source_id;
    else update public.special_event_bookings set loyalty_points_discount=0,loyalty_points_redeemed=0,amount_due=total_amount where id=target_source_id; end if;
    return jsonb_build_object('organizationId',org,'discount',0,'points',0,'amountDue',gross_value,'currency',currency_value);
  end if;
  if found and r.status='reserved' then
    return jsonb_build_object('organizationId',org,'discount',r.discount_amount,'points',r.points_redeemed,'amountDue',gross_value-r.discount_amount,'currency',currency_value);
  end if;
  perform public.ensure_hotel_loyalty_account(org,uid);
  select * into a from public.hotel_loyalty_accounts where organization_id=org and user_id=uid for update;
  if not a.is_enrolled then return jsonb_build_object('organizationId',org,'discount',0,'points',0,'amountDue',gross_value,'currency',currency_value); end if;
  select coalesce(sum(points_redeemed),0) into reserved from public.hotel_loyalty_redemptions where organization_id=org and user_id=uid and status='reserved';
  available:=greatest(a.available_points-reserved,0);
  decimals:=public.checkout_currency_minor_units(currency_value);
  if upper(currency_value)='UGX' then fx_rate:=1;
  else select rate into fx_rate from public.books_fx_rates where base_currency='UGX' and quote_currency=upper(currency_value)::char(3)
    and stored_at>=now()-interval '36 hours' order by stored_at desc limit 1; end if;
  if available<1 or decimals is null or fx_rate is null or fx_rate<=0 or gross_value<=0 then
    return jsonb_build_object('organizationId',org,'discount',0,'points',0,'amountDue',gross_value,'currency',currency_value);
  end if;
  spend_points:=least(available,floor(gross_value/(fx_rate*p.ugx_value_per_point))::bigint);
  discount_value:=round(spend_points*p.ugx_value_per_point*fx_rate,decimals);
  if target_source_type='menu_order' then
    select least(discount_value,subtotal) into discount_value from public.menu_orders where id=target_source_id;
    spend_points:=least(spend_points,floor(discount_value/(fx_rate*p.ugx_value_per_point))::bigint);
    discount_value:=round(spend_points*p.ugx_value_per_point*fx_rate,decimals);
  end if;
  if spend_points<1 or discount_value<=0 then return jsonb_build_object('organizationId',org,'discount',0,'points',0,'amountDue',gross_value,'currency',currency_value); end if;
  insert into public.hotel_loyalty_redemptions(organization_id,user_id,source_type,source_id,points_redeemed,discount_amount,amount_ugx,currency_code,status)
  values(org,uid,target_source_type,target_source_id,spend_points,discount_value,spend_points*p.ugx_value_per_point,upper(currency_value),'reserved')
  on conflict(organization_id,source_type,source_id) do update set user_id=excluded.user_id,points_redeemed=excluded.points_redeemed,
    discount_amount=excluded.discount_amount,amount_ugx=excluded.amount_ugx,currency_code=excluded.currency_code,status='reserved',updated_at=now()
  returning * into r;
  if target_source_type='menu_order' then update public.menu_orders set points_discount=discount_value,loyalty_points_redeemed=spend_points,amount_due=total_amount-discount_value where id=target_source_id;
  elsif target_source_type='hotel_booking' then update public.hotel_bookings set loyalty_points_discount=discount_value,loyalty_points_redeemed=spend_points,amount_due=total_amount-discount_value where id=target_source_id;
  else update public.special_event_bookings set loyalty_points_discount=discount_value,loyalty_points_redeemed=spend_points,amount_due=total_amount-discount_value where id=target_source_id; end if;
  return jsonb_build_object('organizationId',org,'discount',discount_value,'points',spend_points,'amountDue',gross_value-discount_value,'currency',currency_value);
end; $$;
revoke all on function public.reserve_hotel_loyalty_redemption(uuid,text,uuid,boolean) from public,anon;
grant execute on function public.reserve_hotel_loyalty_redemption(uuid,text,uuid,boolean) to authenticated,service_role;

create or replace function public.finalize_hotel_loyalty_redemption(target_organization_id uuid,target_source_type text,target_source_id uuid)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare r public.hotel_loyalty_redemptions%rowtype;
begin
  select * into r from public.hotel_loyalty_redemptions where organization_id=target_organization_id and source_type=target_source_type and source_id=target_source_id for update;
  if not found or r.status<>'reserved' then return; end if;
  if public.apply_hotel_loyalty_delta(target_organization_id,r.user_id,'redemption',-r.points_redeemed,'redemption',r.id,'Hotel points redeemed at checkout',r.amount_ugx) is not null then
    update public.hotel_loyalty_redemptions set status='applied',updated_at=now() where id=r.id;
  end if;
end; $$;
revoke all on function public.finalize_hotel_loyalty_redemption(uuid,text,uuid) from public,anon,authenticated;

create or replace function public.complete_full_points_checkout(target_source_type text,target_source_id uuid)
returns boolean language plpgsql security definer set search_path=pg_catalog,public as $$
declare uid uuid:=auth.uid(); org uuid; due numeric; redemption public.hotel_loyalty_redemptions%rowtype;
  room public.hotel_rooms%rowtype; booking public.hotel_bookings%rowtype; event_booking public.special_event_bookings%rowtype; event_row public.special_events%rowtype;
  reserved_units integer; remaining bigint; type_remaining bigint; confirmation text; ticket text;
begin
  if uid is null then raise exception 'Sign in to complete checkout'; end if;
  if target_source_type='menu_order' then
    select organization_id,amount_due,user_id into org,due,uid from public.menu_orders where id=target_source_id and user_id=auth.uid() for update;
  elsif target_source_type='hotel_booking' then
    select * into booking from public.hotel_bookings where id=target_source_id and user_id=auth.uid() for update;
    org:=booking.organization_id; due:=booking.amount_due;
  elsif target_source_type='special_event_booking' then
    select * into event_booking from public.special_event_bookings where id=target_source_id and user_id=auth.uid() for update;
    org:=event_booking.organization_id; due:=event_booking.amount_due;
  else raise exception 'Unsupported checkout source'; end if;
  if org is null or due<>0 then raise exception 'Points do not cover the amount due'; end if;
  select * into redemption from public.hotel_loyalty_redemptions where organization_id=org and source_type=target_source_type and source_id=target_source_id and status='reserved' and user_id=auth.uid() for update;
  if not found then raise exception 'A matching hotel points reservation was not found'; end if;
  if target_source_type='menu_order' then
    update public.menu_orders set payment_method='loyalty',payment_status='paid' where id=target_source_id and payment_status<>'paid';
  elsif target_source_type='hotel_booking' then
    if booking.expires_at is null or booking.expires_at<=now() then raise exception 'Reservation hold expired'; end if;
    select * into room from public.hotel_rooms where id=booking.room_id for update;
    select coalesce(sum(room_count),0) into reserved_units from public.hotel_bookings b where b.room_id=booking.room_id and b.id<>booking.id
      and ((b.booking_status in ('confirmed','manual_review') and b.payment_status in ('paid','manual_review')) or
        (b.booking_status='pending' and b.payment_status='pending' and b.expires_at>now()))
      and b.check_in<booking.check_out and b.check_out>booking.check_in;
    if reserved_units+booking.room_count>room.available_units then raise exception 'Room availability changed; release the points and select another room'; end if;
    update public.hotel_bookings set payment_method='loyalty',payment_status='paid',booking_status='confirmed',expires_at=null where id=booking.id;
  else
    perform pg_advisory_xact_lock(hashtextextended('special-event:'||event_booking.event_id::text,0));
    select * into event_row from public.special_events where id=event_booking.event_id for update;
    if event_booking.expires_at<=now() then raise exception 'Event ticket hold expired'; end if;
    select event_row.capacity-coalesce(sum(b.quantity),0) into remaining from public.special_event_bookings b where b.event_id=event_booking.event_id and b.id<>event_booking.id
      and (b.status='confirmed' or (b.status='manual_review' and b.payment_status='manual_review') or (b.status='pending' and b.payment_status='pending' and b.expires_at>now()));
    select t.capacity-coalesce(sum(b.quantity),0) into type_remaining from public.special_event_ticket_types t left join public.special_event_bookings b on b.ticket_type_id=t.id and b.id<>event_booking.id
      and (b.status='confirmed' or (b.status='manual_review' and b.payment_status='manual_review') or (b.status='pending' and b.payment_status='pending' and b.expires_at>now())) where t.id=event_booking.ticket_type_id group by t.capacity;
    if remaining<event_booking.quantity or (type_remaining is not null and type_remaining<event_booking.quantity) then raise exception 'Event capacity changed; release points and select another event'; end if;
    confirmation:='EVT-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,10));
    insert into public.special_event_tickets(event_id,booking_id,ticket_type_id,ticket_number,ticket_token,attendee_name,attendee_email)
    select event_booking.event_id,event_booking.id,event_booking.ticket_type_id,n,
      replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-',''),
      coalesce(nullif(trim(event_booking.attendee_names[n]),''),concat_ws(' ',event_booking.guest_first_name,event_booking.guest_last_name)),event_booking.guest_email
      from generate_series(1,event_booking.quantity) n on conflict(booking_id,ticket_number) do nothing;
    select ticket_token into ticket from public.special_event_tickets where booking_id=event_booking.id and ticket_number=1;
    update public.special_event_bookings set status='confirmed',payment_status='paid',payment_verified_at=now(),confirmation_number=confirmation,ticket_code=ticket,updated_at=now() where id=event_booking.id;
    update public.special_events set attendees_count=attendees_count+event_booking.quantity,updated_at=now() where id=event_booking.event_id;
    insert into public.special_event_payments(event_id,booking_id,provider,tx_ref,amount,currency,status,paid_at)
    values(event_booking.event_id,event_booking.id,'loyalty','loyalty-'||event_booking.order_number,0,event_booking.currency,'successful',now())
    on conflict(booking_id) do nothing;
  end if;
  return true;
end; $$;
revoke all on function public.complete_full_points_checkout(text,uuid) from public,anon;
grant execute on function public.complete_full_points_checkout(text,uuid) to authenticated;

create or replace function public.qualify_hotel_loyalty_referral(
  target_organization_id uuid,target_user_id uuid,target_type text,target_source_type text,target_source_id uuid,target_amount_ugx numeric default null
)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare r public.hotel_loyalty_referrals%rowtype; p public.hotel_loyalty_programs%rowtype; role_name text; qualifying boolean:=false;
begin
  select * into p from public.hotel_loyalty_programs where organization_id=target_organization_id and program_enabled;
  if not found then return; end if;
  if target_type='purchase' then
    select role into role_name from public.user_profiles where user_id=target_user_id;
    qualifying:=role_name='guest' and coalesce(target_amount_ugx,0)>=p.guest_referral_minimum_ugx
      and not exists(select 1 from public.hotel_loyalty_award_queue q
        where q.organization_id=target_organization_id and q.user_id=target_user_id and q.source_type in ('menu_order','hotel_booking','special_event_payment')
          and q.status='posted' and q.created_at < (select created_at from public.hotel_loyalty_award_queue where organization_id=target_organization_id and source_type=target_source_type and source_id=target_source_id));
  elsif target_type='task' then
    qualifying:=exists(select 1 from public.tasks t join public.task_reports tr on tr.task_id=t.id
      join public.user_profiles up on up.id=tr.provider_id where t.id=target_source_id and t.organization_id=target_organization_id
        and tr.status='approved' and up.user_id=target_user_id and up.role='service_provider');
  end if;
  if not qualifying then return; end if;
  select * into r from public.hotel_loyalty_referrals where organization_id=target_organization_id and referred_user_id=target_user_id and status='pending' for update;
  if not found or not exists(select 1 from public.hotel_loyalty_accounts where organization_id=target_organization_id and user_id=r.referrer_user_id and is_enrolled)
     or not exists(select 1 from public.hotel_loyalty_accounts where organization_id=target_organization_id and user_id=r.referred_user_id and is_enrolled) then return; end if;
  update public.hotel_loyalty_referrals set status='qualified',qualification_type=target_type,qualification_source_type=target_source_type,
    qualification_source_id=target_source_id,referrer_points=p.referrer_bonus_points,invitee_points=p.invitee_bonus_points,qualified_at=now() where id=r.id;
  perform public.apply_hotel_loyalty_delta(target_organization_id,r.referrer_user_id,'referral_earn',p.referrer_bonus_points,'referral',r.id,'Qualified hotel referral reward',p.referrer_bonus_points*p.ugx_value_per_point);
  perform public.apply_hotel_loyalty_delta(target_organization_id,r.referred_user_id,'referral_welcome',p.invitee_bonus_points,'referral',r.id,'Hotel referral welcome reward',p.invitee_bonus_points*p.ugx_value_per_point);
end; $$;
revoke all on function public.qualify_hotel_loyalty_referral(uuid,uuid,text,text,uuid,numeric) from public,anon,authenticated;

create or replace function public.process_hotel_loyalty_award(target_queue_id uuid)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare q public.hotel_loyalty_award_queue%rowtype; p public.hotel_loyalty_programs%rowtype;
  account_row public.hotel_loyalty_accounts%rowtype; fx_rate numeric; amount_ugx numeric(20,4); points bigint; entry_id uuid;
begin
  select * into q from public.hotel_loyalty_award_queue where id=target_queue_id for update;
  if not found or q.status<>'pending_fx' then return; end if;
  select * into p from public.hotel_loyalty_programs where organization_id=q.organization_id and program_enabled;
  if not found then update public.hotel_loyalty_award_queue set error_message='Hotel rewards are disabled' where id=q.id; return; end if;
  select * into account_row from public.hotel_loyalty_accounts where organization_id=q.organization_id and user_id=q.user_id for update;
  if not found or not account_row.is_enrolled or account_row.enrolled_at is null or q.created_at<account_row.enrolled_at then
    update public.hotel_loyalty_award_queue set status='excluded',processed_at=now(),error_message='Member was not enrolled when payment was verified' where id=q.id; return;
  end if;
  if upper(q.eligible_currency)='UGX' then fx_rate:=1;
  else select rate into fx_rate from public.books_fx_rates where base_currency='UGX' and quote_currency=upper(q.eligible_currency)::char(3)
    and stored_at>=now()-interval '36 hours' order by stored_at desc limit 1; end if;
  if fx_rate is null or fx_rate<=0 then update public.hotel_loyalty_award_queue set error_message='Awaiting a current UGX exchange rate' where id=q.id; return; end if;
  amount_ugx:=round(q.eligible_amount/fx_rate,4); points:=floor(amount_ugx/1000)*p.points_per_1000_ugx;
  if points<1 then update public.hotel_loyalty_award_queue set status='excluded',eligible_amount_ugx=amount_ugx,processed_at=now() where id=q.id; return; end if;
  entry_id:=public.apply_hotel_loyalty_delta(q.organization_id,q.user_id,'purchase_earn',points,q.source_type,q.source_id,
    'Eligible verified hotel purchase reward',points*p.ugx_value_per_point);
  update public.hotel_loyalty_award_queue set status=case when entry_id is null then 'excluded' else 'posted' end,
    points_awarded=case when entry_id is null then 0 else points end,eligible_amount_ugx=amount_ugx,processed_at=now() where id=q.id;
  if entry_id is not null then perform public.qualify_hotel_loyalty_referral(q.organization_id,q.user_id,'purchase',q.source_type,q.source_id,amount_ugx); end if;
exception when others then update public.hotel_loyalty_award_queue set status='failed',error_message=left(sqlerrm,1000),processed_at=now() where id=target_queue_id;
end; $$;
revoke all on function public.process_hotel_loyalty_award(uuid) from public,anon,authenticated;

create or replace function public.process_hotel_loyalty_awards(target_organization_id uuid)
returns integer language plpgsql security definer set search_path=pg_catalog,public as $$
declare q record; count_processed integer:=0;
begin
  for q in select id from public.hotel_loyalty_award_queue where organization_id=target_organization_id and status='pending_fx' order by created_at for update skip locked loop
    perform public.process_hotel_loyalty_award(q.id); count_processed:=count_processed+1;
  end loop;
  return count_processed;
end; $$;
revoke all on function public.process_hotel_loyalty_awards(uuid) from public,anon,authenticated;
grant execute on function public.process_hotel_loyalty_awards(uuid) to service_role;

create or replace function public.process_hotel_loyalty_purchase(
  target_organization_id uuid,target_user_id uuid,target_source_type text,target_source_id uuid,target_amount numeric,target_currency text
)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if target_organization_id is null or target_user_id is null then return; end if;
  if target_source_type='special_event_payment' then
    perform public.finalize_hotel_loyalty_redemption(target_organization_id,'special_event_booking',
      (select booking_id from public.special_event_payments where id=target_source_id));
  else perform public.finalize_hotel_loyalty_redemption(target_organization_id,target_source_type,target_source_id); end if;
  if not exists(select 1 from public.hotel_loyalty_programs where organization_id=target_organization_id and program_enabled) then return; end if;
  if not exists(select 1 from public.hotel_loyalty_accounts where organization_id=target_organization_id and user_id=target_user_id and is_enrolled) then return; end if;
  insert into public.hotel_loyalty_award_queue(organization_id,user_id,source_type,source_id,eligible_amount,eligible_currency)
  values(target_organization_id,target_user_id,target_source_type,target_source_id,greatest(target_amount,0),upper(target_currency))
  on conflict(organization_id,source_type,source_id) do nothing;
  perform public.process_hotel_loyalty_awards(target_organization_id);
end; $$;
revoke all on function public.process_hotel_loyalty_purchase(uuid,uuid,text,uuid,numeric,text) from public,anon,authenticated;

create or replace function public.enqueue_hotel_loyalty_purchase()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare verified boolean:=false; event_booking public.special_event_bookings%rowtype;
begin
  if tg_table_name='menu_orders' then
    if new.payment_status<>'paid' or (tg_op='UPDATE' and old.payment_status='paid') then return new; end if;
    select exists(select 1 from public.menu_payment_attempts a where a.order_id=new.id and a.status='completed' and a.transaction_id=new.flutterwave_transaction_id) into verified;
    if new.total_amount=0 and new.loyalty_points_redeemed>0 and exists(select 1 from public.hotel_loyalty_redemptions r where r.source_type='menu_order' and r.source_id=new.id and r.status='reserved') then verified:=true; end if;
    if verified then perform public.process_hotel_loyalty_purchase(new.organization_id,new.user_id,'menu_order',new.id,greatest(new.subtotal-coalesce(new.points_discount,0),0),new.currency); end if;
  elsif tg_table_name='hotel_bookings' then
    if new.payment_status<>'paid' or (tg_op='UPDATE' and old.payment_status='paid') or new.user_id is null then return new; end if;
    select exists(select 1 from public.hotel_payment_attempts a where a.booking_id=new.id and a.status='completed' and a.transaction_id is not null) into verified;
    if new.amount_due=0 and new.loyalty_points_redeemed>0 and exists(select 1 from public.hotel_loyalty_redemptions r where r.source_type='hotel_booking' and r.source_id=new.id and r.status='reserved') then verified:=true; end if;
    if verified then perform public.process_hotel_loyalty_purchase(new.organization_id,new.user_id,'hotel_booking',new.id,greatest(new.taxable_subtotal-new.loyalty_points_discount,0),trim(new.currency_code)); end if;
  else
    if new.status<>'successful' or (tg_op='UPDATE' and old.status='successful') then return new; end if;
    select * into event_booking from public.special_event_bookings where id=new.booking_id;
    if found then perform public.process_hotel_loyalty_purchase(event_booking.organization_id,event_booking.user_id,'special_event_payment',new.id,
      greatest(event_booking.subtotal-event_booking.discount_amount-event_booking.loyalty_points_discount,0),new.currency); end if;
  end if;
  return new;
end; $$;
revoke all on function public.enqueue_hotel_loyalty_purchase() from public,anon,authenticated;
drop trigger if exists hotel_menu_loyalty_award on public.menu_orders;
create trigger hotel_menu_loyalty_award after insert or update of payment_status on public.menu_orders for each row execute function public.enqueue_hotel_loyalty_purchase();
drop trigger if exists hotel_room_loyalty_award on public.hotel_bookings;
create trigger hotel_room_loyalty_award after insert or update of payment_status on public.hotel_bookings for each row execute function public.enqueue_hotel_loyalty_purchase();
drop trigger if exists hotel_event_loyalty_award on public.special_event_payments;
create trigger hotel_event_loyalty_award after insert or update of status on public.special_event_payments for each row execute function public.enqueue_hotel_loyalty_purchase();

create or replace function public.retry_hotel_loyalty_after_fx()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare p record;
begin for p in select organization_id from public.hotel_loyalty_programs where program_enabled loop perform public.process_hotel_loyalty_awards(p.organization_id); end loop; return new; end; $$;
revoke all on function public.retry_hotel_loyalty_after_fx() from public,anon,authenticated;
drop trigger if exists hotel_loyalty_fx_retry on public.books_fx_rates;
create trigger hotel_loyalty_fx_retry after insert or update on public.books_fx_rates for each row execute function public.retry_hotel_loyalty_after_fx();

create or replace function public.approve_task_report_and_award_points(target_report_id uuid)
returns integer language plpgsql security definer set search_path=pg_catalog,public as $$
declare report_row public.task_reports%rowtype; task_row public.tasks%rowtype; provider_user uuid; actor_role text;
  monthly_points bigint; reward_points integer; point_cap integer;
begin
  if auth.uid() is null then raise exception 'Sign in to approve task work'; end if;
  select role into actor_role from public.user_profiles where user_id=auth.uid();
  select * into report_row from public.task_reports where id=target_report_id for update;
  if not found then raise exception 'Task report was not found'; end if;
  select * into task_row from public.tasks where id=report_row.task_id for update;
  if not found or task_row.created_by<>auth.uid() or actor_role<>'manager' then raise exception 'Only the task manager can approve this report'; end if;
  if task_row.organization_id is null or not exists(select 1 from public.books_memberships m where m.organization_id=task_row.organization_id and m.user_id=auth.uid() and m.role in ('owner','admin')) then
    raise exception 'Task must be associated with the manager hotel organization'; end if;
  if task_row.assigned_to is distinct from report_row.provider_id or report_row.status<>'completed_pending_approval' then
    raise exception 'This task report is not ready for approval'; end if;
  select user_id into provider_user from public.user_profiles where id=report_row.provider_id and role='service_provider';
  if provider_user is null then raise exception 'Assigned service provider account was not found'; end if;
  update public.task_reports set status='approved',last_updated_by=auth.uid(),updated_at=now() where id=report_row.id;
  update public.tasks set status='completed',updated_at=now() where id=task_row.id;
  insert into public.notifications(user_id,task_id,type,message)
  values(provider_user,task_row.id,'task_updated','Your task "'||task_row.title||'" has been approved and marked complete.');
  select coalesce(sum(points_delta),0) into monthly_points from public.hotel_loyalty_ledger_entries
   where organization_id=task_row.organization_id and user_id=provider_user and entry_type='task_earn'
     and created_at>=date_trunc('month',now());
  select task_approval_points,monthly_task_points_cap into reward_points,point_cap from public.hotel_loyalty_programs where organization_id=task_row.organization_id;
  reward_points:=least(coalesce(reward_points,0),greatest(coalesce(point_cap,0)-monthly_points,0)::integer);
  if reward_points>0 and exists(select 1 from public.hotel_loyalty_programs where organization_id=task_row.organization_id and program_enabled)
     and exists(select 1 from public.hotel_loyalty_accounts where organization_id=task_row.organization_id and user_id=provider_user and is_enrolled) then
    if public.apply_hotel_loyalty_delta(task_row.organization_id,provider_user,'task_earn',reward_points,'approved_task',task_row.id,'Hotel manager-approved task reward',reward_points*(select ugx_value_per_point from public.hotel_loyalty_programs where organization_id=task_row.organization_id)) is null then reward_points:=0; end if;
  else reward_points:=0; end if;
  perform public.qualify_hotel_loyalty_referral(task_row.organization_id,provider_user,'task','approved_task',task_row.id,null);
  return reward_points;
end; $$;
revoke all on function public.approve_task_report_and_award_points(uuid) from public,anon;
grant execute on function public.approve_task_report_and_award_points(uuid) to authenticated;

create or replace function public.reverse_hotel_loyalty_purchase()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare org uuid; buyer uuid; source_type_value text; source_id_value uuid; state_value text; q public.hotel_loyalty_award_queue%rowtype;
  r public.hotel_loyalty_referrals%rowtype; redemption public.hotel_loyalty_redemptions%rowtype; reversal_type text;
begin
  if tg_table_name='menu_orders' then
    if new.payment_status not in ('refunded','chargeback') or old.payment_status is not distinct from new.payment_status then return new; end if;
    org:=new.organization_id; buyer:=new.user_id; source_type_value:='menu_order'; source_id_value:=new.id;
  elsif tg_table_name='hotel_bookings' then
    if new.payment_status not in ('refunded','chargeback') or old.payment_status is not distinct from new.payment_status then return new; end if;
    org:=new.organization_id; buyer:=new.user_id; source_type_value:='hotel_booking'; source_id_value:=new.id;
  else
    if new.status not in ('refunded','chargeback') or old.status is not distinct from new.status then return new; end if;
    select organization_id,user_id into org,buyer from public.special_event_bookings where id=new.booking_id;
    source_type_value:='special_event_payment'; source_id_value:=new.id;
  end if;
  state_value:=case when coalesce(new.payment_status,new.status)='refunded' then 'refunded' else 'reversed' end;
  select * into q from public.hotel_loyalty_award_queue where organization_id=org and source_type=source_type_value and source_id=source_id_value for update;
  if found and q.status='posted' and q.points_awarded>0 then
    reversal_type:=source_type_value||'_reversal';
    perform public.apply_hotel_loyalty_delta(org,q.user_id,'purchase_reversal',-q.points_awarded,reversal_type,source_id_value,'Reversal of refunded hotel purchase points',q.points_awarded*(select ugx_value_per_point from public.hotel_loyalty_programs where organization_id=org));
    update public.hotel_loyalty_award_queue set status=state_value,processed_at=now() where id=q.id;
  elsif found and q.status in ('pending_fx','failed') then update public.hotel_loyalty_award_queue set status=state_value,processed_at=now() where id=q.id; end if;
  select * into r from public.hotel_loyalty_referrals where organization_id=org and status='qualified' and qualification_source_type=source_type_value and qualification_source_id=source_id_value for update;
  if found then
    perform public.apply_hotel_loyalty_delta(org,r.referrer_user_id,'referral_reversal',-r.referrer_points,'referral_refund',r.id,'Hotel referral reversal after qualifying purchase refund',r.referrer_points*(select ugx_value_per_point from public.hotel_loyalty_programs where organization_id=org));
    perform public.apply_hotel_loyalty_delta(org,r.referred_user_id,'referral_reversal',-r.invitee_points,'referral_refund',r.id,'Hotel referral welcome reversal after purchase refund',r.invitee_points*(select ugx_value_per_point from public.hotel_loyalty_programs where organization_id=org));
    update public.hotel_loyalty_referrals set status='cancelled' where id=r.id;
  end if;
  select * into redemption from public.hotel_loyalty_redemptions where organization_id=org and source_type=case when source_type_value='special_event_payment' then 'special_event_booking' else source_type_value end and source_id=case when source_type_value='special_event_payment' then (select booking_id from public.special_event_payments where id=source_id_value) else source_id_value end for update;
  if found and redemption.status='reserved' then update public.hotel_loyalty_redemptions set status='released',updated_at=now() where id=redemption.id;
  elsif found and redemption.status='applied' then
    perform public.apply_hotel_loyalty_delta(org,redemption.user_id,'redemption_refund',redemption.points_redeemed,'redemption_refund',redemption.id,'Hotel points restored after refunded checkout',redemption.amount_ugx);
    update public.hotel_loyalty_redemptions set status='refunded',updated_at=now() where id=redemption.id;
  end if;
  return new;
end; $$;
revoke all on function public.reverse_hotel_loyalty_purchase() from public,anon,authenticated;
drop trigger if exists hotel_menu_loyalty_refund on public.menu_orders;
create trigger hotel_menu_loyalty_refund after update of payment_status on public.menu_orders for each row execute function public.reverse_hotel_loyalty_purchase();
drop trigger if exists hotel_room_loyalty_refund on public.hotel_bookings;
create trigger hotel_room_loyalty_refund after update of payment_status on public.hotel_bookings for each row execute function public.reverse_hotel_loyalty_purchase();
drop trigger if exists hotel_event_loyalty_refund on public.special_event_payments;
create trigger hotel_event_loyalty_refund after update of status on public.special_event_payments for each row execute function public.reverse_hotel_loyalty_purchase();

create or replace function public.reserve_hotel_loyalty_redemption(target_user_id uuid,target_source_type text,target_source_id uuid,target_use_points boolean)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare uid uuid:=auth.uid(); org uuid; gross numeric; currency_value text; p public.hotel_loyalty_programs%rowtype;
  a public.hotel_loyalty_accounts%rowtype; r public.hotel_loyalty_redemptions%rowtype; reserved bigint; available bigint; points bigint; discount numeric; source_owner uuid; fx_rate numeric; decimals integer;
begin
  if uid is null then raise exception 'Sign in to use hotel rewards'; end if;
  if target_source_type='menu_order' then
    select organization_id,gross_total_amount,upper(currency),user_id into org,gross,currency_value,source_owner from public.menu_orders
    where id=target_source_id and user_id=uid and payment_status in ('pending','failed','cancelled') for update;
  elsif target_source_type='hotel_booking' then
    select organization_id,total_amount,currency_code::text,user_id into org,gross,currency_value,source_owner from public.hotel_bookings
    where id=target_source_id and user_id=uid and booking_status='pending' and payment_status='pending' for update;
  elsif target_source_type='special_event_booking' then
    select organization_id,total_amount,currency,user_id into org,gross,currency_value,source_owner from public.special_event_bookings
    where id=target_source_id and user_id=uid and status='pending' and payment_status='pending' for update;
  else raise exception 'Unsupported hotel checkout'; end if;
  if org is null then raise exception 'Checkout has no hotel attribution'; end if;
  select * into p from public.hotel_loyalty_programs where organization_id=org;
  if not found or not p.program_enabled or not p.redemption_enabled then
    if target_source_type='menu_order' then update public.menu_orders set points_discount=0,loyalty_points_redeemed=0,amount_due=total_amount where id=target_source_id;
    elsif target_source_type='hotel_booking' then update public.hotel_bookings set loyalty_points_discount=0,loyalty_points_redeemed=0,amount_due=total_amount where id=target_source_id;
    else update public.special_event_bookings set loyalty_points_discount=0,loyalty_points_redeemed=0,amount_due=total_amount where id=target_source_id; end if;
    return jsonb_build_object('organizationId',org,'discount',0,'points',0,'amountDue',gross,'currency',currency_value);
  end if;
  select * into r from public.hotel_loyalty_redemptions where organization_id=org and source_type=target_source_type and source_id=target_source_id for update;
  if not target_use_points then
    if found and r.status='reserved' then update public.hotel_loyalty_redemptions set status='released',updated_at=now() where id=r.id; end if;
    if target_source_type='menu_order' then update public.menu_orders set points_discount=0,loyalty_points_redeemed=0,amount_due=total_amount where id=target_source_id;
    elsif target_source_type='hotel_booking' then update public.hotel_bookings set loyalty_points_discount=0,loyalty_points_redeemed=0,amount_due=total_amount where id=target_source_id;
    else update public.special_event_bookings set loyalty_points_discount=0,loyalty_points_redeemed=0,amount_due=total_amount where id=target_source_id; end if;
    return jsonb_build_object('organizationId',org,'discount',0,'points',0,'amountDue',gross,'currency',currency_value);
  end if;
  if found and r.status='reserved' then return jsonb_build_object('organizationId',org,'discount',r.discount_amount,'points',r.points_redeemed,'amountDue',gross-r.discount_amount,'currency',currency_value); end if;
  perform public.ensure_hotel_loyalty_account(org,uid);
  select * into a from public.hotel_loyalty_accounts where organization_id=org and user_id=uid for update;
  if not a.is_enrolled then return jsonb_build_object('organizationId',org,'discount',0,'points',0,'amountDue',gross,'currency',currency_value); end if;
  select coalesce(sum(points_redeemed),0) into reserved from public.hotel_loyalty_redemptions where organization_id=org and user_id=uid and status='reserved';
  available:=greatest(a.available_points-reserved,0);
  decimals:=public.checkout_currency_minor_units(currency_value);
  if upper(currency_value)='UGX' then fx_rate:=1;
  else select rate into fx_rate from public.books_fx_rates where base_currency='UGX' and quote_currency=upper(currency_value)::char(3)
    and stored_at>=now()-interval '36 hours' order by stored_at desc limit 1; end if;
  if decimals is null or fx_rate is null or fx_rate<=0 then return jsonb_build_object('organizationId',org,'discount',0,'points',0,'amountDue',gross,'currency',currency_value); end if;
  points:=least(available,floor(gross/(fx_rate*p.ugx_value_per_point))::bigint);
  discount:=round(points*p.ugx_value_per_point*fx_rate,decimals);
  if target_source_type='menu_order' then
    select least(discount,subtotal) into discount from public.menu_orders where id=target_source_id;
    points:=least(points,floor(discount/(fx_rate*p.ugx_value_per_point))::bigint);
    discount:=round(points*p.ugx_value_per_point*fx_rate,decimals);
  end if;
  if points<1 or discount<=0 then return jsonb_build_object('organizationId',org,'discount',0,'points',0,'amountDue',gross,'currency',currency_value); end if;
  insert into public.hotel_loyalty_redemptions(organization_id,user_id,source_type,source_id,points_redeemed,discount_amount,amount_ugx,currency_code,status)
  values(org,uid,target_source_type,target_source_id,points,discount,points*p.ugx_value_per_point,upper(currency_value),'reserved')
  on conflict(organization_id,source_type,source_id) do update set user_id=excluded.user_id,points_redeemed=excluded.points_redeemed,
    discount_amount=excluded.discount_amount,amount_ugx=excluded.amount_ugx,status='reserved',updated_at=now();
  if target_source_type='menu_order' then update public.menu_orders set points_discount=discount,loyalty_points_redeemed=points,amount_due=total_amount-discount where id=target_source_id;
  elsif target_source_type='hotel_booking' then update public.hotel_bookings set loyalty_points_discount=discount,loyalty_points_redeemed=points,amount_due=total_amount-discount where id=target_source_id;
  else update public.special_event_bookings set loyalty_points_discount=discount,loyalty_points_redeemed=points,amount_due=total_amount-discount where id=target_source_id; end if;
  return jsonb_build_object('organizationId',org,'discount',discount,'points',points,'amountDue',gross-discount,'currency',currency_value);
end; $$;
revoke all on function public.reserve_hotel_loyalty_redemption(uuid,text,uuid,boolean) from public,anon;
grant execute on function public.reserve_hotel_loyalty_redemption(uuid,text,uuid,boolean) to authenticated,service_role;

create or replace function public.complete_full_points_checkout(target_source_type text,target_source_id uuid)
returns boolean language plpgsql security definer set search_path=pg_catalog,public as $$
declare uid uuid:=auth.uid(); org uuid; due numeric; b public.hotel_bookings%rowtype; room public.hotel_rooms%rowtype;
  eb public.special_event_bookings%rowtype; event_row public.special_events%rowtype; reserved integer; rem bigint; type_rem bigint;
  r public.hotel_loyalty_redemptions%rowtype; confirmation text; ticket text;
begin
  if uid is null then raise exception 'Sign in to complete this checkout'; end if;
  if target_source_type='menu_order' then select organization_id,amount_due into org,due from public.menu_orders where id=target_source_id and user_id=uid for update;
  elsif target_source_type='hotel_booking' then select * into b from public.hotel_bookings where id=target_source_id and user_id=uid for update; org:=b.organization_id; due:=b.amount_due;
  elsif target_source_type='special_event_booking' then select * into eb from public.special_event_bookings where id=target_source_id and user_id=uid for update; org:=eb.organization_id; due:=eb.amount_due;
  else raise exception 'Unsupported hotel checkout'; end if;
  if org is null or due<>0 then raise exception 'Points do not cover the amount due'; end if;
  select * into r from public.hotel_loyalty_redemptions where organization_id=org and source_type=target_source_type and source_id=target_source_id and user_id=uid and status='reserved' for update;
  if not found then raise exception 'Matching hotel points reservation was not found'; end if;
  if target_source_type='menu_order' then
    update public.menu_orders set payment_method='loyalty',payment_status='paid' where id=target_source_id and payment_status<>'paid';
  elsif target_source_type='hotel_booking' then
    if b.expires_at is null or b.expires_at<=now() then raise exception 'Room hold expired'; end if;
    select * into room from public.hotel_rooms where id=b.room_id for update;
    select coalesce(sum(x.room_count),0) into reserved from public.hotel_bookings x where x.room_id=b.room_id and x.id<>b.id
      and ((x.booking_status in ('confirmed','manual_review') and x.payment_status in ('paid','manual_review')) or (x.booking_status='pending' and x.payment_status='pending' and x.expires_at>now()))
      and x.check_in<b.check_out and x.check_out>b.check_in;
    if reserved+b.room_count>room.available_units then raise exception 'Room availability changed; release points and select a new room'; end if;
    update public.hotel_bookings set payment_method='loyalty',payment_status='paid',booking_status='confirmed',expires_at=null where id=b.id;
  else
    perform pg_advisory_xact_lock(hashtextextended('special-event:'||eb.event_id::text,0));
    select * into event_row from public.special_events where id=eb.event_id for update;
    if eb.expires_at<=now() then raise exception 'Ticket hold expired'; end if;
    select event_row.capacity-coalesce(sum(x.quantity),0) into rem from public.special_event_bookings x where x.event_id=eb.event_id and x.id<>eb.id
      and (x.status='confirmed' or (x.status='manual_review' and x.payment_status='manual_review') or (x.status='pending' and x.payment_status='pending' and x.expires_at>now()));
    select t.capacity-coalesce(sum(x.quantity),0) into type_rem from public.special_event_ticket_types t left join public.special_event_bookings x on x.ticket_type_id=t.id and x.id<>eb.id
      and (x.status='confirmed' or (x.status='manual_review' and x.payment_status='manual_review') or (x.status='pending' and x.payment_status='pending' and x.expires_at>now())) where t.id=eb.ticket_type_id group by t.capacity;
    if rem<eb.quantity or (type_rem is not null and type_rem<eb.quantity) then raise exception 'Event capacity changed; release points and select another event'; end if;
    confirmation:='EVT-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,10));
    insert into public.special_event_tickets(event_id,booking_id,ticket_type_id,ticket_number,ticket_token,attendee_name,attendee_email)
    select eb.event_id,eb.id,eb.ticket_type_id,n,replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-',''),
      coalesce(nullif(trim(eb.attendee_names[n]),''),concat_ws(' ',eb.guest_first_name,eb.guest_last_name)),eb.guest_email from generate_series(1,eb.quantity) n
      on conflict(booking_id,ticket_number) do nothing;
    select ticket_token into ticket from public.special_event_tickets where booking_id=eb.id and ticket_number=1;
    update public.special_event_bookings set status='confirmed',payment_status='paid',payment_verified_at=now(),confirmation_number=confirmation,ticket_code=ticket,updated_at=now() where id=eb.id;
    update public.special_events set attendees_count=attendees_count+eb.quantity,updated_at=now() where id=eb.event_id;
    insert into public.special_event_payments(event_id,booking_id,provider,tx_ref,amount,currency,status,paid_at)
    values(eb.event_id,eb.id,'loyalty','loyalty-'||eb.order_number,0,eb.currency,'successful',now()) on conflict(booking_id) do nothing;
  end if;
  return true;
end; $$;
revoke all on function public.complete_full_points_checkout(text,uuid) from public,anon;
grant execute on function public.complete_full_points_checkout(text,uuid) to authenticated;

create or replace function public.assign_menu_item_hotel()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare selected_org uuid;
begin
  if new.organization_id is null then
    select min(organization_id) into selected_org from public.books_memberships where user_id=new.managed_by
    group by user_id having count(distinct organization_id)=1;
    new.organization_id:=selected_org;
  end if;
  if new.organization_id is null or not exists(select 1 from public.books_memberships where organization_id=new.organization_id and user_id=new.managed_by) then
    raise exception 'Choose a hotel organization for this menu item';
  end if;
  insert into public.hotel_loyalty_programs(organization_id) values(new.organization_id) on conflict do nothing;
  return new;
end; $$;
revoke all on function public.assign_menu_item_hotel() from public,anon,authenticated;
drop trigger if exists menu_item_hotel_scope on public.menu_items;
create trigger menu_item_hotel_scope before insert or update of organization_id,managed_by on public.menu_items for each row execute function public.assign_menu_item_hotel();

create or replace function public.initialize_hotel_checkout_totals()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if tg_table_name='menu_orders' then
    new.gross_total_amount:=new.subtotal+new.tax_amount+new.service_fee+new.tip_amount;
    if new.amount_due is null or new.amount_due=0 then new.amount_due:=new.gross_total_amount; end if;
  elsif tg_table_name='hotel_bookings' then
    new.gross_total_amount:=new.taxable_subtotal+new.vat_amount+new.lht_amount;
    if new.amount_due is null or new.amount_due=0 then new.amount_due:=new.gross_total_amount; end if;
  else
    new.gross_total_amount:=new.subtotal+new.service_fee+new.tax_amount-new.discount_amount;
    if new.amount_due is null or new.amount_due=0 then new.amount_due:=new.gross_total_amount; end if;
  end if;
  return new;
end; $$;
revoke all on function public.initialize_hotel_checkout_totals() from public,anon,authenticated;
drop trigger if exists menu_order_gross_total on public.menu_orders;
create trigger menu_order_gross_total before insert or update of subtotal,tax_amount,service_fee,tip_amount,total_amount on public.menu_orders for each row execute function public.initialize_hotel_checkout_totals();
drop trigger if exists hotel_booking_gross_total on public.hotel_bookings;
create trigger hotel_booking_gross_total before insert or update of taxable_subtotal,vat_amount,lht_amount,total_amount on public.hotel_bookings for each row execute function public.initialize_hotel_checkout_totals();
drop trigger if exists event_booking_gross_total on public.special_event_bookings;
create trigger event_booking_gross_total before insert or update of subtotal,service_fee,tax_amount,discount_amount,total_amount on public.special_event_bookings for each row execute function public.initialize_hotel_checkout_totals();

create or replace function public.validate_menu_payment_attempt_total()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare o public.menu_orders%rowtype;
begin
  select * into o from public.menu_orders where id=new.order_id;
  if not found or o.pricing_version<>1 or new.amount::text in ('NaN','Infinity','-Infinity') or new.amount<>o.amount_due
    or upper(new.currency)<>upper(o.currency) or public.checkout_currency_minor_units(new.currency) is null
    or new.amount<>round(new.amount,public.checkout_currency_minor_units(new.currency)) or new.amount<=0 then
    raise exception 'Menu payment attempt does not match the amount due'; end if;
  return new;
end; $$;
revoke all on function public.validate_menu_payment_attempt_total() from public,anon,authenticated;
drop trigger if exists menu_payment_attempt_total_validation on public.menu_payment_attempts;
create trigger menu_payment_attempt_total_validation before insert or update of order_id,amount,currency on public.menu_payment_attempts
for each row execute function public.validate_menu_payment_attempt_total();

create or replace function public.create_menu_payment_attempt(target_order_id uuid,target_user_id uuid,target_tx_ref text)
returns table(attempt_id uuid,attempt_tx_ref text,attempt_status text,attempt_payment_url text)
language plpgsql security definer set search_path=pg_catalog,public as $$
declare o public.menu_orders%rowtype; a public.menu_payment_attempts%rowtype; created public.menu_payment_attempts%rowtype;
begin
  select * into o from public.menu_orders where id=target_order_id for update;
  if not found or o.user_id<>target_user_id or o.pricing_version<>1 then raise exception 'Payment order could not be verified'; end if;
  if o.status<>'pending' or o.payment_status not in ('pending','cancelled','failed') then raise exception 'This order is no longer awaiting payment'; end if;
  if o.amount_due<=0 then raise exception 'This order does not require online payment'; end if;
  select * into a from public.menu_payment_attempts where order_id=o.id and status in ('initiated','redirected') order by created_at desc limit 1 for update;
  if found then
    if a.status='redirected' and a.payment_url is not null then return query select a.id,a.tx_ref,a.status,a.payment_url; return; end if;
    if a.created_at>now()-interval '2 minutes' then return query select a.id,a.tx_ref,'preparing'::text,a.payment_url; return; end if;
    update public.menu_payment_attempts set status='failed',failure_reason='Checkout preparation timed out',updated_at=now() where id=a.id;
  end if;
  insert into public.menu_payment_attempts(order_id,tx_ref,amount,currency,status) values(o.id,target_tx_ref,o.amount_due,o.currency,'initiated') returning * into created;
  update public.menu_orders set payment_reference=created.tx_ref,payment_status='pending' where id=o.id;
  return query select created.id,created.tx_ref,created.status,created.payment_url;
end; $$;
revoke all on function public.create_menu_payment_attempt(uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.create_menu_payment_attempt(uuid,uuid,text) to service_role;

create or replace function public.apply_menu_invoice_totals()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare o public.menu_orders%rowtype;
begin
  select * into o from public.menu_orders where books_invoice_id=new.id and pricing_version=1;
  if not found and left(new.invoice_number,5)='MENU-' then select * into o from public.menu_orders where order_number=substring(new.invoice_number from 6) and pricing_version=1; end if;
  if not found then return new; end if;
  if new.organization_id<>o.organization_id then raise exception 'Menu invoice organization does not match the order hotel'; end if;
  new.currency_code:=upper(o.currency)::char(3); new.subtotal:=o.subtotal; new.tax_amount:=o.tax_amount;
  new.other_charges:=o.service_fee+o.tip_amount; new.total:=o.gross_total_amount;
  if new.total<>o.total_amount then raise exception 'Menu invoice total does not match the gross order'; end if;
  return new;
end; $$;
revoke all on function public.apply_menu_invoice_totals() from public,anon,authenticated;
drop trigger if exists menu_invoice_totals_before_insert on public.books_invoices;
drop trigger if exists zzz_menu_invoice_totals_before_insert on public.books_invoices;
drop trigger if exists zzz_menu_invoice_totals_before_write on public.books_invoices;
create trigger zzz_menu_invoice_totals_before_write before insert or update on public.books_invoices for each row execute function public.apply_menu_invoice_totals();

create or replace function public.post_paid_menu_order_to_books_v2()
returns trigger language plpgsql security definer set search_path=public as $$
declare org uuid; contact_id uuid; invoice_id uuid; tax_id uuid; contact_name text; contact_email text; contact_phone text;
  tax_rate numeric; order_day date:=coalesce(new.created_at::date,current_date);
begin
  if new.payment_status<>'paid' or not (tg_op='INSERT' or old.payment_status is distinct from 'paid') or new.books_invoice_id is not null then return new; end if;
  org:=new.organization_id;
  if org is null then update public.menu_orders set books_accounting_status='failed',books_accounting_error='Menu order has no hotel organization' where id=new.id; return new; end if;
  contact_name:=nullif(trim(concat_ws(' ',new.first_name,new.last_name)),''); contact_email:=nullif(trim(new.email),''); contact_phone:=nullif(trim(new.phone),'');
  if new.user_id is not null then
    select first_name,last_name,email,phone into contact_name,contact_email,contact_phone from public.user_profiles where user_id=new.user_id;
    contact_name:=coalesce(contact_name,nullif(trim(concat_ws(' ',new.first_name,new.last_name)),''));
    contact_email:=coalesce(contact_email,nullif(trim(new.email),'')); contact_phone:=coalesce(contact_phone,nullif(trim(new.phone),''));
  end if;
  if contact_email is null then update public.menu_orders set books_accounting_status='failed',books_accounting_error='Customer email is required for the hotel Books invoice' where id=new.id; return new; end if;
  select id into contact_id from public.books_contacts where organization_id=org and lower(email)=lower(contact_email) and type in ('customer','both') order by created_at limit 1;
  if contact_id is null then insert into public.books_contacts(organization_id,name,type,email,phone) values(org,coalesce(contact_name,contact_email),'customer',contact_email,contact_phone) returning id into contact_id; end if;
  if new.tax_amount>0 and new.subtotal>0 then
    tax_rate:=round(new.tax_amount/new.subtotal*100,4);
    insert into public.books_tax_rates(organization_id,country_code,name,rate_percentage) values(org,'UG','Menu sale tax '||tax_rate||'%',tax_rate) on conflict(organization_id,name,effective_from) do nothing;
    select id into tax_id from public.books_tax_rates where organization_id=org and rate_percentage=tax_rate and is_active and order_day>=effective_from and (effective_to is null or order_day<=effective_to) order by created_at desc limit 1;
  end if;
  select id into invoice_id from public.books_invoices where organization_id=org and invoice_number='MENU-'||new.order_number;
  if invoice_id is null then
    insert into public.books_invoices(organization_id,contact_id,invoice_number,issue_date,due_date,currency_code,subtotal,tax_amount,tax_rate_id,status,notes)
    values(org,contact_id,'MENU-'||new.order_number,order_day,order_day,upper(new.currency)::char(3),new.subtotal,new.tax_amount,tax_id,'paid','Hotel menu order '||new.order_number||' ('||new.id||')') returning id into invoice_id;
  end if;
  if not exists(select 1 from public.books_invoice_lines where invoice_id=invoice_id) then
    insert into public.books_invoice_lines(invoice_id,organization_id,description,quantity,unit_price)
    select invoice_id,org,item_name,quantity,unit_price from public.menu_order_items where order_id=new.id;
    if new.service_fee>0 then insert into public.books_invoice_lines(invoice_id,organization_id,description,quantity,unit_price) values(invoice_id,org,'Service fee',1,new.service_fee); end if;
    if new.tip_amount>0 then insert into public.books_invoice_lines(invoice_id,organization_id,description,quantity,unit_price) values(invoice_id,org,'Tip',1,new.tip_amount); end if;
  end if;
  update public.menu_orders set books_invoice_id=invoice_id,books_accounting_status='posted',books_accounting_error=null where id=new.id;
  return new;
exception when others then update public.menu_orders set books_accounting_status='failed',books_accounting_error=left(sqlerrm,2000) where id=new.id; return new;
end; $$;
drop trigger if exists menu_order_paid_books on public.menu_orders;
drop trigger if exists menu_order_paid_books_v2 on public.menu_orders;
create trigger menu_order_paid_books_v2 after insert or update of payment_status on public.menu_orders for each row execute function public.post_paid_menu_order_to_books_v2();
revoke all on function public.post_paid_menu_order_to_books_v2() from public;

-- Hotel/event payment, invoice settlement and FX-safe redemption functions continue below.

commit;

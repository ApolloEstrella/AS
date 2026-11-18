begin;

alter table public.accounts
  add column if not exists cash_flow_category text;

update public.accounts
set cash_flow_category = case
  when code like '15%' or code like '16%' then 'investing'
  when type = 'equity' or code like '23%' or code like '24%' or code like '25%' then 'financing'
  else 'operating'
end
where cash_flow_category is null;

alter table public.accounts
  alter column cash_flow_category set default 'operating',
  alter column cash_flow_category set not null;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.accounts'::regclass
      and conname = 'accounts_cash_flow_category_valid'
  ) then
    alter table public.accounts
      add constraint accounts_cash_flow_category_valid
      check (cash_flow_category in ('operating', 'investing', 'financing'));
  end if;
end;
$$;

alter table public.expenses
  add column if not exists due_date date,
  add column if not exists payment_date date;

create table if not exists public.account_budgets (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  account_id uuid not null,
  budget_month date not null check (extract(day from budget_month) = 1),
  amount numeric(14, 2) not null check (amount >= 0),
  notes text check (notes is null or length(notes) <= 500),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, account_id, budget_month),
  unique (id, organization_id),
  foreign key (account_id, organization_id)
    references public.accounts(id, organization_id) on delete cascade
);

create table if not exists public.bank_reconciliations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  account_id uuid not null,
  statement_date date not null,
  beginning_balance numeric(14, 2) not null,
  ending_balance numeric(14, 2) not null,
  status text not null default 'draft' check (status in ('draft', 'reconciled')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, account_id, statement_date),
  unique (id, organization_id),
  foreign key (account_id, organization_id)
    references public.accounts(id, organization_id) on delete cascade
);

create unique index if not exists journal_lines_id_organization_uidx
  on public.journal_lines (id, organization_id);

create table if not exists public.bank_reconciliation_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  reconciliation_id uuid not null,
  journal_line_id uuid not null,
  is_cleared boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (reconciliation_id, journal_line_id),
  unique (id, organization_id),
  foreign key (reconciliation_id, organization_id)
    references public.bank_reconciliations(id, organization_id) on delete cascade,
  foreign key (journal_line_id, organization_id)
    references public.journal_lines(id, organization_id) on delete cascade
);

create or replace function public.validate_account_budget_account()
returns trigger
language plpgsql
as $$
begin
  if not exists (
    select 1 from public.accounts
    where id = new.account_id and organization_id = new.organization_id
      and type in ('revenue', 'expense')
  ) then
    raise exception 'Budgets can only be assigned to revenue or expense accounts.';
  end if;
  return new;
end;
$$;

drop trigger if exists validate_account_budget_account on public.account_budgets;
create trigger validate_account_budget_account
before insert or update on public.account_budgets
for each row execute function public.validate_account_budget_account();

create or replace function public.validate_bank_reconciliation_item()
returns trigger
language plpgsql
as $$
declare
  reconciliation_account uuid;
  reconciliation_date date;
  line_account uuid;
  entry_status text;
  entry_date date;
begin
  select account_id, statement_date
    into reconciliation_account, reconciliation_date
    from public.bank_reconciliations
    where id = new.reconciliation_id and organization_id = new.organization_id;
  if not found then
    raise exception 'Choose a reconciliation in this organization.';
  end if;

  select line.account_id, entry.status, entry.entry_date
    into line_account, entry_status, entry_date
    from public.journal_lines line
    join public.journal_entries entry
      on entry.id = line.journal_entry_id and entry.organization_id = line.organization_id
    where line.id = new.journal_line_id and line.organization_id = new.organization_id;
  if not found or line_account <> reconciliation_account or entry_status <> 'posted' or entry_date > reconciliation_date then
    raise exception 'Reconciliation items must be posted transactions for the selected cash account on or before the statement date.';
  end if;
  return new;
end;
$$;

drop trigger if exists validate_bank_reconciliation_item on public.bank_reconciliation_items;
create trigger validate_bank_reconciliation_item
before insert or update on public.bank_reconciliation_items
for each row execute function public.validate_bank_reconciliation_item();

do $$
declare
  table_name text;
begin
  foreach table_name in array array['account_budgets', 'bank_reconciliations', 'bank_reconciliation_items']
  loop
    execute format(
      'drop trigger if exists set_%I_updated_at on public.%I',
      table_name, table_name
    );
    execute format(
      'create trigger set_%I_updated_at before update on public.%I for each row execute function public.set_updated_at()',
      table_name, table_name
    );
  end loop;
end;
$$;

alter table public.account_budgets enable row level security;
alter table public.bank_reconciliations enable row level security;
alter table public.bank_reconciliation_items enable row level security;

drop policy if exists "Organization owners manage account budgets" on public.account_budgets;
create policy "Organization owners manage account budgets"
  on public.account_budgets for all
  using (exists (
    select 1 from public.organizations o
    where o.id = organization_id and o.owner_id = auth.uid()
  ))
  with check (exists (
    select 1 from public.organizations o
    where o.id = organization_id and o.owner_id = auth.uid()
  ));

drop policy if exists "Organization owners manage bank reconciliations" on public.bank_reconciliations;
create policy "Organization owners manage bank reconciliations"
  on public.bank_reconciliations for all
  using (exists (
    select 1 from public.organizations o
    where o.id = organization_id and o.owner_id = auth.uid()
  ))
  with check (exists (
    select 1 from public.organizations o
    where o.id = organization_id and o.owner_id = auth.uid()
  ));

drop policy if exists "Organization owners manage bank reconciliation items" on public.bank_reconciliation_items;
create policy "Organization owners manage bank reconciliation items"
  on public.bank_reconciliation_items for all
  using (exists (
    select 1 from public.organizations o
    where o.id = organization_id and o.owner_id = auth.uid()
  ))
  with check (exists (
    select 1 from public.organizations o
    where o.id = organization_id and o.owner_id = auth.uid()
  ));

grant select, insert, update, delete on public.account_budgets to authenticated;
grant select, insert, update, delete on public.bank_reconciliations to authenticated;
grant select, insert, update, delete on public.bank_reconciliation_items to authenticated;

create index if not exists account_budgets_month_idx
  on public.account_budgets (organization_id, budget_month);
create index if not exists bank_reconciliations_account_date_idx
  on public.bank_reconciliations (organization_id, account_id, statement_date desc);
create index if not exists bank_reconciliation_items_reconciliation_idx
  on public.bank_reconciliation_items (organization_id, reconciliation_id, is_cleared);

revoke all on function public.validate_account_budget_account() from public, anon, authenticated;
revoke all on function public.validate_bank_reconciliation_item() from public, anon, authenticated;

notify pgrst, 'reload schema';
commit;

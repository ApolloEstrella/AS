begin;

alter table public.expenses
  add column if not exists payment_account_id uuid;

do $$
begin
  if not exists (
    select 1
      from pg_constraint
      where conrelid = 'public.expenses'::regclass
        and conname = 'expenses_payment_account_id_organization_id_fkey'
  ) then
    alter table public.expenses
      add constraint expenses_payment_account_id_organization_id_fkey
      foreign key (payment_account_id, organization_id)
      references public.accounts(id, organization_id) on delete restrict;
  end if;
end;
$$;

create or replace function public.validate_expense_payment_account()
returns trigger
language plpgsql
as $$
begin
  if new.status = 'paid' and not exists (
    select 1
      from public.accounts
      where id = new.payment_account_id
        and organization_id = new.organization_id
        and type = 'asset'
        and is_active
        and code like '10%'
  ) then
    raise exception 'Paid expenses must use an active cash or bank account.';
  end if;
  return new;
end;
$$;

drop trigger if exists validate_expense_payment_account on public.expenses;
create trigger validate_expense_payment_account
before insert or update on public.expenses
for each row execute function public.validate_expense_payment_account();

create or replace function public.sync_paid_expense_payment_account()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  credit_account_id uuid;
begin
  if new.status = 'paid' then
    credit_account_id := new.payment_account_id;
  elsif tg_op = 'UPDATE' and old.status = 'paid' and new.status <> 'void' then
    select id into credit_account_id
      from public.accounts
      where organization_id = new.organization_id
        and code = '2000'
        and type = 'liability'
        and is_active;
    if not found then
      raise exception 'An active Accounts Payable account (2000) is required for unpaid expenses.';
    end if;
  else
    return new;
  end if;

  update public.journal_lines as line
    set account_id = credit_account_id
    from public.journal_entries as entry
    where entry.id = line.journal_entry_id
      and entry.organization_id = line.organization_id
      and entry.organization_id = new.organization_id
      and entry.source_type = 'expense'
      and entry.source_id = new.id
      and entry.status = 'posted'
      and entry.reversal_of is null
      and entry.id = (
        select candidate.id
          from public.journal_entries as candidate
          where candidate.organization_id = new.organization_id
            and candidate.source_type = 'expense'
            and candidate.source_id = new.id
            and candidate.reversal_of is null
            and not exists (
              select 1
                from public.journal_entries as reversal
                where reversal.reversal_of = candidate.id
                  and reversal.status = 'posted'
            )
          order by candidate.created_at desc, candidate.id desc
          limit 1
      )
      and line.amount_code = 'C'
      and line.account_id is distinct from credit_account_id;

  return new;
end;
$$;

revoke all on function public.sync_paid_expense_payment_account() from public, anon, authenticated;

drop trigger if exists sync_paid_expense_payment_account on public.expenses;
create trigger sync_paid_expense_payment_account
after insert or update on public.expenses
for each row execute function public.sync_paid_expense_payment_account();

notify pgrst, 'reload schema';
commit;

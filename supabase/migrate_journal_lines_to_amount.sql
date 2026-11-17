begin;

alter table public.journal_lines
  add column amount numeric(14, 2),
  add column amount_code text;

do $$
begin
  if exists (
    select 1
    from public.journal_lines
    where not ((debit > 0 and credit = 0) or (credit > 0 and debit = 0))
  ) then
    raise exception 'Cannot migrate journal lines with both or neither debit and credit amounts.';
  end if;
end;
$$;

update public.journal_lines
set amount = case when debit > 0 then debit else credit end,
    amount_code = case when debit > 0 then 'D' else 'C' end;

alter table public.journal_lines
  alter column amount set not null,
  alter column amount_code set not null,
  add constraint journal_lines_amount_positive check (amount > 0),
  add constraint journal_lines_amount_code_valid check (amount_code in ('D', 'C'));

create or replace function public.validate_journal_entry_posting()
returns trigger
language plpgsql
as $$
declare
  debit_total numeric(14, 2);
  credit_total numeric(14, 2);
begin
  if new.status = 'posted' and tg_op = 'INSERT' then
    select coalesce(sum(case when amount_code = 'D' then amount else 0 end), 0),
           coalesce(sum(case when amount_code = 'C' then amount else 0 end), 0)
      into debit_total, credit_total
      from public.journal_lines
      where journal_entry_id = new.id and organization_id = new.organization_id;
    if debit_total = 0 or debit_total <> credit_total then
      raise exception 'Journal entry must have equal, non-zero debit and credit totals before posting.';
    end if;
  elsif new.status = 'posted' and tg_op = 'UPDATE' and old.status is distinct from 'posted' then
    select coalesce(sum(case when amount_code = 'D' then amount else 0 end), 0),
           coalesce(sum(case when amount_code = 'C' then amount else 0 end), 0)
      into debit_total, credit_total
      from public.journal_lines
      where journal_entry_id = new.id and organization_id = new.organization_id;
    if debit_total = 0 or debit_total <> credit_total then
      raise exception 'Journal entry must have equal, non-zero debit and credit totals before posting.';
    end if;
  end if;
  return new;
end;
$$;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.journal_lines'::regclass
      and conname = 'journal_lines_organization_id_fkey'
  ) then
    alter table public.journal_lines
      add constraint journal_lines_organization_id_fkey
      foreign key (organization_id) references public.organizations(id) on delete cascade;
  end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.journal_lines'::regclass
      and conname = 'journal_lines_journal_entry_id_organization_id_fkey'
  ) then
    alter table public.journal_lines
      add constraint journal_lines_journal_entry_id_organization_id_fkey
      foreign key (journal_entry_id, organization_id)
      references public.journal_entries(id, organization_id) on delete cascade;
  end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.journal_lines'::regclass
      and conname = 'journal_lines_account_id_organization_id_fkey'
  ) then
    alter table public.journal_lines
      add constraint journal_lines_account_id_organization_id_fkey
      foreign key (account_id, organization_id)
      references public.accounts(id, organization_id) on delete restrict;
  end if;
end;
$$;

alter table public.journal_lines
  drop column debit,
  drop column credit;

notify pgrst, 'reload schema';

commit;

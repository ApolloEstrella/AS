begin;

create or replace function public.prevent_posted_journal_entry_changes()
returns trigger
language plpgsql
as $$
begin
  if old.status = 'posted' and
    current_setting('app.allow_posted_journal_entry_changes', true) is distinct from 'on' and (
    old.source_type is null
    or pg_trigger_depth() <= 1
  ) then
    raise exception 'Posted journal entries cannot be changed or deleted.';
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

create or replace function public.prevent_posted_journal_line_changes()
returns trigger
language plpgsql
as $$
declare
  entry_id uuid;
  org_id uuid;
begin
  if tg_op = 'DELETE' then
    entry_id := old.journal_entry_id;
    org_id := old.organization_id;
  else
    entry_id := new.journal_entry_id;
    org_id := new.organization_id;
  end if;

  if exists (
    select 1 from public.journal_entries
    where id = entry_id and organization_id = org_id and status = 'posted'
      and current_setting('app.allow_posted_journal_entry_changes', true) is distinct from 'on'
      and (
        source_type is null
        or pg_trigger_depth() <= 1
      )
  ) then
    raise exception 'Posted journal entries are immutable.';
  end if;

  if tg_op = 'UPDATE' and exists (
    select 1 from public.journal_entries
    where id = old.journal_entry_id and organization_id = old.organization_id and status = 'posted'
      and current_setting('app.allow_posted_journal_entry_changes', true) is distinct from 'on'
      and (
        source_type is null
        or pg_trigger_depth() <= 1
      )
  ) then
    raise exception 'Posted journal entries are immutable.';
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

alter table public.invoices
  add column if not exists is_tax_exempt boolean not null default true,
  add column if not exists tax_rate numeric(5, 2) not null default 0,
  add column if not exists tax_amount numeric(14, 2) not null default 0;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.invoices'::regclass
      and conname = 'invoices_tax_rate_valid'
  ) then
    alter table public.invoices
      add constraint invoices_tax_rate_valid
      check (tax_rate between 0 and 100);
  end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.invoices'::regclass
      and conname = 'invoices_tax_amount_valid'
  ) then
    alter table public.invoices
      add constraint invoices_tax_amount_valid
      check (tax_amount >= 0 and tax_amount <= total);
  end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.invoices'::regclass
      and conname = 'invoices_tax_snapshot_valid'
  ) then
    alter table public.invoices
      add constraint invoices_tax_snapshot_valid
      check (
        (is_tax_exempt and tax_rate = 0 and tax_amount = 0)
        or (not is_tax_exempt and tax_amount = round((total - tax_amount) * tax_rate / 100, 2))
      );
  end if;
end;
$$;

alter table public.journal_entries
  add column if not exists source_type text,
  add column if not exists source_id uuid,
  add column if not exists reversal_of uuid;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.journal_entries'::regclass
      and conname = 'journal_entries_source_type_valid'
  ) then
    alter table public.journal_entries
      add constraint journal_entries_source_type_valid
      check (source_type is null or source_type in ('invoice', 'expense'));
  end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.journal_entries'::regclass
      and conname = 'journal_entries_source_fields_match'
  ) then
    alter table public.journal_entries
      add constraint journal_entries_source_fields_match
      check ((source_type is null) = (source_id is null));
  end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.journal_entries'::regclass
      and conname = 'journal_entries_reversal_source_required'
  ) then
    alter table public.journal_entries
      add constraint journal_entries_reversal_source_required
      check (reversal_of is null or source_type is not null);
  end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.journal_entries'::regclass
      and conname = 'journal_entries_reversal_same_organization_fkey'
  ) then
    alter table public.journal_entries
      add constraint journal_entries_reversal_same_organization_fkey
      foreign key (reversal_of, organization_id)
      references public.journal_entries(id, organization_id)
      on delete cascade;
  end if;
end;
$$;

create index if not exists journal_entries_source_idx
  on public.journal_entries (organization_id, source_type, source_id);

create unique index if not exists journal_entries_reversal_of_uidx
  on public.journal_entries (reversal_of)
  where reversal_of is not null;

create or replace function public.sync_source_transaction_ledger(
  p_source_type text,
  p_source_id uuid,
  p_organization_id uuid,
  p_deleted boolean default false,
  p_backfill boolean default false
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  source_status text;
  source_date date;
  source_amount numeric(14, 2);
  source_tax_amount numeric(14, 2) := 0;
  source_description text;
  source_reference text;
  should_post boolean := false;
  debit_account_id uuid;
  credit_account_id uuid;
  tax_credit_account_id uuid;
  original_entry public.journal_entries%rowtype;
  new_entry_id uuid;
begin
  if p_source_type is null or p_source_type not in ('invoice', 'expense') then
    raise exception 'Unsupported ledger source type.';
  end if;

  if p_deleted then
    delete from public.journal_entries
      where organization_id = p_organization_id
        and source_type = p_source_type
        and source_id = p_source_id;
    return;
  end if;

  if p_backfill and exists (
    select 1
    from public.journal_entries
    where organization_id = p_organization_id
      and source_type = p_source_type
      and source_id = p_source_id
  ) then
    return;
  end if;

  if not p_deleted and p_source_type = 'invoice' then
    select status, issue_date, total, invoice_number, tax_amount
      into source_status, source_date, source_amount, source_reference, source_tax_amount
      from public.invoices
      where id = p_source_id and organization_id = p_organization_id;
    if not found then return; end if;

    should_post := source_status in ('sent', 'paid', 'overdue') and source_amount > 0;
    source_description := left('Invoice ' || source_reference, 500);
    source_reference := 'AUTO-INV:' || p_source_id::text;

    if should_post then
      select id into debit_account_id
        from public.accounts
        where organization_id = p_organization_id
          and code = '1100' and type = 'asset' and is_active;
      if not found then
        raise exception 'An active Accounts Receivable account (1100) is required to post invoices.';
      end if;
      select id into credit_account_id
        from public.accounts
        where organization_id = p_organization_id
          and code = '4010' and type = 'revenue' and is_active;
      if not found then
        raise exception 'An active Service Revenue account (4010) is required to post invoices.';
      end if;
      if source_tax_amount > 0 then
        select id into tax_credit_account_id
          from public.accounts
          where organization_id = p_organization_id
            and code = '2130' and type = 'liability' and is_active;
        if not found then
          raise exception 'An active Sales Tax Payable account (2130) is required to post taxed invoices.';
        end if;
      end if;
    end if;
  elsif not p_deleted and p_source_type = 'expense' then
    select status, expense_date, amount, description, account_id
      into source_status, source_date, source_amount, source_description, debit_account_id
      from public.expenses
      where id = p_source_id and organization_id = p_organization_id;
    if not found then return; end if;

    should_post := source_status <> 'void' and source_amount > 0;
    source_description := left('Expense: ' || source_description, 500);
    source_reference := 'AUTO-EXP:' || p_source_id::text;

    if should_post then
      if not exists (
        select 1 from public.accounts
        where id = debit_account_id
          and organization_id = p_organization_id
          and type = 'expense' and is_active
      ) then
        raise exception 'Expenses must use an active expense account.';
      end if;
      select id into credit_account_id
        from public.accounts
        where organization_id = p_organization_id
          and code = '2000' and type = 'liability' and is_active;
      if not found then
        raise exception 'An active Accounts Payable account (2000) is required to post expenses.';
      end if;
    end if;
  end if;

  select entry.*
    into original_entry
    from public.journal_entries as entry
    where entry.organization_id = p_organization_id
      and entry.source_type = p_source_type
      and entry.source_id = p_source_id
      and entry.reversal_of is null
      and not exists (
        select 1 from public.journal_entries as reversal
        where reversal.reversal_of = entry.id and reversal.status = 'posted'
      )
    order by entry.created_at desc, entry.id desc
    limit 1
    for update of entry;

  if found then
    if should_post then
      update public.journal_entries
        set status = 'draft',
            entry_date = source_date,
            description = source_description,
            reference = source_reference
        where id = original_entry.id and organization_id = p_organization_id;

      delete from public.journal_lines
        where journal_entry_id = original_entry.id
          and organization_id = p_organization_id;
    else
      update public.journal_entries
        set status = 'void',
            entry_date = source_date,
            description = source_description,
            reference = source_reference
        where id = original_entry.id and organization_id = p_organization_id;
    end if;

    if should_post then
      insert into public.journal_lines (
        organization_id, journal_entry_id, account_id, amount, amount_code, description
      )
      values (p_organization_id, original_entry.id, debit_account_id, source_amount, 'D', source_description);

      if p_source_type = 'invoice' then
        if source_amount > source_tax_amount then
          insert into public.journal_lines (
            organization_id, journal_entry_id, account_id, amount, amount_code, description
          )
          values (
            p_organization_id, original_entry.id, credit_account_id,
            source_amount - source_tax_amount, 'C', source_description
          );
        end if;
        if source_tax_amount > 0 then
          insert into public.journal_lines (
            organization_id, journal_entry_id, account_id, amount, amount_code, description
          )
          values (
            p_organization_id, original_entry.id, tax_credit_account_id,
            source_tax_amount, 'C', 'Sales tax for ' || source_reference
          );
        end if;
      else
        insert into public.journal_lines (
          organization_id, journal_entry_id, account_id, amount, amount_code, description
        )
        values (p_organization_id, original_entry.id, credit_account_id, source_amount, 'C', source_description);
      end if;

      update public.journal_entries
        set status = 'posted'
        where id = original_entry.id and organization_id = p_organization_id;
    end if;

  elsif should_post then
    insert into public.journal_entries (
      organization_id, entry_date, description, reference, status, source_type, source_id
    )
    values (
      p_organization_id, source_date, source_description, source_reference,
      'draft', p_source_type, p_source_id
    )
    returning id into new_entry_id;

    insert into public.journal_lines (
      organization_id, journal_entry_id, account_id, amount, amount_code, description
    )
    values (p_organization_id, new_entry_id, debit_account_id, source_amount, 'D', source_description);

    if p_source_type = 'invoice' then
      if source_amount > source_tax_amount then
        insert into public.journal_lines (
          organization_id, journal_entry_id, account_id, amount, amount_code, description
        )
        values (
          p_organization_id, new_entry_id, credit_account_id,
          source_amount - source_tax_amount, 'C', source_description
        );
      end if;
      if source_tax_amount > 0 then
        insert into public.journal_lines (
          organization_id, journal_entry_id, account_id, amount, amount_code, description
        )
        values (
          p_organization_id, new_entry_id, tax_credit_account_id,
          source_tax_amount, 'C', 'Sales tax for ' || source_reference
        );
      end if;
    else
      insert into public.journal_lines (
        organization_id, journal_entry_id, account_id, amount, amount_code, description
      )
      values (p_organization_id, new_entry_id, credit_account_id, source_amount, 'C', source_description);
    end if;

    update public.journal_entries
      set status = 'posted'
      where id = new_entry_id;
  end if;
end;
$$;

create or replace function public.sync_source_transaction_ledger_trigger()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  old_record jsonb;
  new_record jsonb;
begin
  if pg_trigger_depth() > 1 then
    if tg_op = 'DELETE' then return old; end if;
    return new;
  end if;

  if tg_op = 'UPDATE' then
    old_record := to_jsonb(old);
    new_record := to_jsonb(new);

    if tg_table_name = 'invoices'
      and old_record ->> 'organization_id' is not distinct from new_record ->> 'organization_id'
      and old_record ->> 'total' is not distinct from new_record ->> 'total'
      and old_record ->> 'tax_amount' is not distinct from new_record ->> 'tax_amount'
      and old_record ->> 'issue_date' is not distinct from new_record ->> 'issue_date'
      and old_record ->> 'invoice_number' is not distinct from new_record ->> 'invoice_number'
      and (old_record ->> 'status' in ('sent', 'paid', 'overdue')) is not distinct from
          (new_record ->> 'status' in ('sent', 'paid', 'overdue')) then
      return new;
    end if;

    if tg_table_name = 'expenses'
      and old_record ->> 'organization_id' is not distinct from new_record ->> 'organization_id'
      and old_record ->> 'amount' is not distinct from new_record ->> 'amount'
      and old_record ->> 'expense_date' is not distinct from new_record ->> 'expense_date'
      and old_record ->> 'account_id' is not distinct from new_record ->> 'account_id'
      and old_record ->> 'description' is not distinct from new_record ->> 'description'
      and (old_record ->> 'status' <> 'void') is not distinct from
          (new_record ->> 'status' <> 'void') then
      return new;
    end if;
  end if;

  if tg_op = 'DELETE' then
    if tg_table_name = 'invoices' then
      perform public.sync_source_transaction_ledger('invoice', old.id, old.organization_id, true);
    else
      perform public.sync_source_transaction_ledger('expense', old.id, old.organization_id, true);
    end if;
    return old;
  end if;

  if tg_table_name = 'invoices' then
    perform public.sync_source_transaction_ledger('invoice', new.id, new.organization_id);
  else
    perform public.sync_source_transaction_ledger('expense', new.id, new.organization_id);
  end if;
  return new;
end;
$$;

revoke all on function public.sync_source_transaction_ledger(text, uuid, uuid, boolean, boolean)
  from public, anon, authenticated;
revoke all on function public.sync_source_transaction_ledger_trigger()
  from public, anon, authenticated;

do $$
declare
  backfill_invoices boolean := false;
  backfill_expenses boolean := false;
  source_row record;
begin
  if not exists (
    select 1 from pg_trigger
    where tgrelid = 'public.invoices'::regclass
      and tgname = 'sync_invoice_to_ledger'
      and not tgisinternal
  ) then
    execute 'create trigger sync_invoice_to_ledger after insert or update or delete on public.invoices for each row execute function public.sync_source_transaction_ledger_trigger()';
    backfill_invoices := true;
  end if;

  if not exists (
    select 1 from pg_trigger
    where tgrelid = 'public.expenses'::regclass
      and tgname = 'sync_expense_to_ledger'
      and not tgisinternal
  ) then
    execute 'create trigger sync_expense_to_ledger after insert or update or delete on public.expenses for each row execute function public.sync_source_transaction_ledger_trigger()';
    backfill_expenses := true;
  end if;

  if backfill_invoices then
    for source_row in
      select id, organization_id from public.invoices
      where status in ('sent', 'paid', 'overdue') and total > 0
    loop
      perform public.sync_source_transaction_ledger(
        'invoice', source_row.id, source_row.organization_id, false, true
      );
    end loop;
  end if;

  if backfill_expenses then
    for source_row in
      select id, organization_id from public.expenses
      where status <> 'void' and amount > 0
    loop
      perform public.sync_source_transaction_ledger(
        'expense', source_row.id, source_row.organization_id, false, true
      );
    end loop;
  end if;
end;
$$;

notify pgrst, 'reload schema';

commit;

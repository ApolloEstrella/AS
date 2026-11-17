-- Apply sync_source_transactions_to_ledger.sql first so invoice balances are posted before receipts.
begin;

alter table public.journal_entries
  add column if not exists source_type text,
  add column if not exists source_id uuid,
  add column if not exists reversal_of uuid;

alter table public.journal_entries
  drop constraint if exists journal_entries_source_type_valid;
alter table public.journal_entries
  add constraint journal_entries_source_type_valid
  check (source_type is null or source_type in ('invoice', 'expense', 'invoice_payment'));

do $$
begin
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

create table if not exists public.invoice_payments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  invoice_id uuid not null,
  account_id uuid not null,
  payment_date date not null default current_date,
  amount numeric(14, 2) not null check (amount > 0),
  payment_method text not null check (payment_method in ('cash', 'check', 'card', 'bank_transfer', 'other')),
  reference text check (reference is null or length(reference) <= 100),
  notes text check (notes is null or length(notes) <= 500),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, organization_id),
  foreign key (invoice_id, organization_id)
    references public.invoices(id, organization_id) on delete restrict,
  foreign key (account_id, organization_id)
    references public.accounts(id, organization_id) on delete restrict
);

create or replace function public.validate_invoice_payment()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  invoice_status text;
  invoice_total numeric(14, 2);
  paid_elsewhere numeric(14, 2);
  account_type text;
  account_active boolean;
  account_code text;
begin
  select status, total
    into invoice_status, invoice_total
    from public.invoices
    where id = new.invoice_id
      and organization_id = new.organization_id
    for update;
  if not found then
    raise exception 'Choose an invoice in this organization.';
  end if;
  if invoice_status in ('draft', 'void') then
    raise exception 'Payments can only be recorded for sent, overdue, or paid invoices.';
  end if;

  select type, is_active, code
    into account_type, account_active, account_code
    from public.accounts
    where id = new.account_id
      and organization_id = new.organization_id;
  if not found or account_type <> 'asset' or not account_active or account_code not like '10%' then
    raise exception 'Choose an active cash or bank asset account with an account code beginning with 10.';
  end if;

  select coalesce(sum(amount), 0)
    into paid_elsewhere
    from public.invoice_payments
    where invoice_id = new.invoice_id
      and organization_id = new.organization_id
      and id is distinct from new.id;
  if paid_elsewhere + new.amount > invoice_total then
    raise exception 'Payment exceeds the invoice balance due.';
  end if;

  return new;
end;
$$;

drop trigger if exists validate_invoice_payment_before_write on public.invoice_payments;
create trigger validate_invoice_payment_before_write
before insert or update on public.invoice_payments
for each row execute function public.validate_invoice_payment();

create or replace function public.prevent_invoice_payment_conflicts()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  paid_total numeric(14, 2);
begin
  if tg_op = 'INSERT' then
    if new.status = 'paid' then
      raise exception 'Record a payment before marking an invoice as paid.';
    end if;
    return new;
  end if;

  if new.total is distinct from old.total or new.status is distinct from old.status then
    select coalesce(sum(amount), 0) into paid_total
      from public.invoice_payments
      where invoice_id = old.id and organization_id = old.organization_id;
    if paid_total > new.total then
      raise exception 'Invoice total cannot be less than payments already received.';
    end if;
    if paid_total > 0 and new.status in ('draft', 'void') then
      raise exception 'An invoice with payments cannot be changed to draft or void. Delete or reduce its recorded payments first.';
    end if;
    if new.status <> 'paid' and new.status not in ('draft', 'void') and
      new.total > 0 and paid_total >= new.total then
      raise exception 'This invoice is fully paid. Delete or reduce its recorded payments first; payment changes update the invoice status and ledger entry.';
    end if;
    if new.status = 'paid' and old.status is distinct from 'paid' and
      (new.total <= 0 or paid_total < new.total) then
      raise exception 'Record payments covering the invoice total before marking it paid.';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists invoices_prevent_paid_without_payment_insert on public.invoices;
create trigger invoices_prevent_paid_without_payment_insert
before insert on public.invoices
for each row execute function public.prevent_invoice_payment_conflicts();

drop trigger if exists invoices_prevent_payment_conflicts on public.invoices;
create trigger invoices_prevent_payment_conflicts
before update of total, status on public.invoices
for each row execute function public.prevent_invoice_payment_conflicts();

create or replace function public.recalculate_invoice_payment_status(p_invoice_id uuid, p_organization_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  invoice_row public.invoices%rowtype;
  paid_total numeric(14, 2);
  next_status text;
begin
  select * into invoice_row
    from public.invoices
    where id = p_invoice_id and organization_id = p_organization_id
    for update;
  if not found or invoice_row.status in ('draft', 'void') then
    return;
  end if;

  select coalesce(sum(amount), 0) into paid_total
    from public.invoice_payments
    where invoice_id = p_invoice_id and organization_id = p_organization_id;

  next_status := invoice_row.status;
  if invoice_row.total > 0 and paid_total >= invoice_row.total then
    next_status := 'paid';
  elsif invoice_row.status = 'paid' then
    next_status := case when invoice_row.due_date < current_date then 'overdue' else 'sent' end;
  end if;

  if next_status is distinct from invoice_row.status then
    update public.invoices
      set status = next_status
      where id = p_invoice_id and organization_id = p_organization_id;
  end if;
end;
$$;

create or replace function public.sync_invoice_payment_ledger(
  p_payment_id uuid,
  p_organization_id uuid,
  p_deleted boolean default false
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  payment_row public.invoice_payments%rowtype;
  original_entry public.journal_entries%rowtype;
  receivable_account_id uuid;
  new_entry_id uuid;
  payment_description text;
begin
  if p_deleted then
    delete from public.journal_entries
      where organization_id = p_organization_id
        and source_type = 'invoice_payment'
        and source_id = p_payment_id;
    return;
  end if;

  select * into payment_row
    from public.invoice_payments
    where id = p_payment_id and organization_id = p_organization_id;
  if not found then return; end if;

  select id into receivable_account_id
    from public.accounts
    where organization_id = p_organization_id
      and code = '1100'
      and type = 'asset'
      and is_active;
  if not found then
    raise exception 'An active Accounts Receivable account (1100) is required to post invoice payments.';
  end if;

  payment_description := left(
    'Payment for invoice ' || (select invoice_number from public.invoices where id = payment_row.invoice_id and organization_id = p_organization_id)
      || case when payment_row.reference is null or payment_row.reference = '' then '' else ' / ' || payment_row.reference end,
    500
  );

  select entry.* into original_entry
    from public.journal_entries as entry
    where entry.organization_id = p_organization_id
      and entry.source_type = 'invoice_payment'
      and entry.source_id = p_payment_id
      and entry.reversal_of is null
      and not exists (
        select 1 from public.journal_entries as reversal
        where reversal.reversal_of = entry.id and reversal.status = 'posted'
      )
    order by entry.created_at desc, entry.id desc
    limit 1
    for update of entry;

  if found then
    update public.journal_entries
      set status = 'draft',
          entry_date = payment_row.payment_date,
          description = payment_description,
          reference = 'AUTO-PAY:' || p_payment_id::text
      where id = original_entry.id and organization_id = p_organization_id;

    delete from public.journal_lines
      where journal_entry_id = original_entry.id
        and organization_id = p_organization_id;

    insert into public.journal_lines (
      organization_id, journal_entry_id, account_id, amount, amount_code, description
    )
    values
      (p_organization_id, original_entry.id, payment_row.account_id, payment_row.amount, 'D', payment_description),
      (p_organization_id, original_entry.id, receivable_account_id, payment_row.amount, 'C', payment_description);

    update public.journal_entries
      set status = 'posted'
      where id = original_entry.id and organization_id = p_organization_id;

  else
    insert into public.journal_entries (
      organization_id, entry_date, description, reference, status, source_type, source_id
    )
    values (
      p_organization_id, payment_row.payment_date, payment_description,
      'AUTO-PAY:' || p_payment_id::text, 'draft', 'invoice_payment', p_payment_id
    )
    returning id into new_entry_id;

    insert into public.journal_lines (
      organization_id, journal_entry_id, account_id, amount, amount_code, description
    )
    values
      (p_organization_id, new_entry_id, payment_row.account_id, payment_row.amount, 'D', payment_description),
      (p_organization_id, new_entry_id, receivable_account_id, payment_row.amount, 'C', payment_description);

    update public.journal_entries set status = 'posted' where id = new_entry_id;
  end if;
end;
$$;

create or replace function public.invoice_payment_after_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'DELETE' then
    perform public.sync_invoice_payment_ledger(old.id, old.organization_id, true);
    perform public.recalculate_invoice_payment_status(old.invoice_id, old.organization_id);
    return old;
  end if;

  perform public.sync_invoice_payment_ledger(new.id, new.organization_id);
  if tg_op = 'UPDATE' then
    if old.invoice_id is distinct from new.invoice_id then
      perform public.recalculate_invoice_payment_status(old.invoice_id, old.organization_id);
    end if;
  end if;
  perform public.recalculate_invoice_payment_status(new.invoice_id, new.organization_id);
  return new;
end;
$$;

drop trigger if exists invoice_payments_after_change on public.invoice_payments;
create trigger invoice_payments_after_change
after insert or update or delete on public.invoice_payments
for each row execute function public.invoice_payment_after_change();

create or replace function public.recalculate_invoice_status_after_total_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.recalculate_invoice_payment_status(new.id, new.organization_id);
  return new;
end;
$$;

drop trigger if exists invoices_recalculate_payment_status on public.invoices;
create trigger invoices_recalculate_payment_status
after update of total on public.invoices
for each row
when (old.total is distinct from new.total)
execute function public.recalculate_invoice_status_after_total_change();

grant select, insert, update, delete on public.invoice_payments to authenticated;
alter table public.invoice_payments enable row level security;

drop policy if exists "Organization owners manage invoice_payments" on public.invoice_payments;
create policy "Organization owners manage invoice_payments"
on public.invoice_payments for all
using (
  exists (
    select 1 from public.organizations o
    where o.id = organization_id and o.owner_id = auth.uid()
  )
)
with check (
  exists (
    select 1 from public.organizations o
    where o.id = organization_id and o.owner_id = auth.uid()
  )
);

drop trigger if exists set_invoice_payments_updated_at on public.invoice_payments;
create trigger set_invoice_payments_updated_at
before update on public.invoice_payments
for each row execute function public.set_updated_at();

create index if not exists invoice_payments_invoice_date_idx
  on public.invoice_payments (organization_id, invoice_id, payment_date desc);
create index if not exists journal_entries_source_idx
  on public.journal_entries (organization_id, source_type, source_id);
create unique index if not exists journal_entries_reversal_of_uidx
  on public.journal_entries (reversal_of) where reversal_of is not null;

revoke all on function public.validate_invoice_payment() from public, anon, authenticated;
revoke all on function public.prevent_invoice_payment_conflicts() from public, anon, authenticated;
revoke all on function public.recalculate_invoice_payment_status(uuid, uuid) from public, anon, authenticated;
revoke all on function public.sync_invoice_payment_ledger(uuid, uuid, boolean) from public, anon, authenticated;
revoke all on function public.invoice_payment_after_change() from public, anon, authenticated;
revoke all on function public.recalculate_invoice_status_after_total_change() from public, anon, authenticated;

notify pgrst, 'reload schema';

commit;

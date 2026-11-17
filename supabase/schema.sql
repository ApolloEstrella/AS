create extension if not exists pgcrypto;

create table public.organizations (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  name text not null check (length(trim(name)) between 1 and 120),
  currency text not null default 'USD' check (currency ~ '^[A-Z]{3}$'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (owner_id)
);

create table public.accounts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  code text not null,
  name text not null,
  type text not null check (type in ('asset', 'liability', 'equity', 'revenue', 'expense')),
  description text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, code),
  unique (id, organization_id)
);

create table public.inventory (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  sku text not null check (length(trim(sku)) between 1 and 64),
  name text not null check (length(trim(name)) between 1 and 160),
  description text,
  unit text not null default 'each',
  quantity_on_hand numeric(12, 3) not null default 0 check (quantity_on_hand >= 0),
  unit_cost numeric(14, 2) not null default 0 check (unit_cost >= 0),
  unit_price numeric(14, 2) not null default 0 check (unit_price >= 0),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, sku),
  unique (id, organization_id)
);

create table public.contacts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null,
  type text not null check (type in ('customer', 'vendor', 'both')),
  email text,
  phone text,
  company text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, organization_id)
);

create table public.invoices (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  contact_id uuid not null,
  invoice_number text not null,
  status text not null default 'draft' check (status in ('draft', 'sent', 'paid', 'overdue', 'void')),
  issue_date date not null default current_date,
  due_date date not null,
  currency text not null default 'USD' check (currency ~ '^[A-Z]{3}$'),
  total numeric(14, 2) not null default 0 check (total >= 0),
  is_tax_exempt boolean not null default true,
  tax_rate numeric(5, 2) not null default 0 check (tax_rate between 0 and 100),
  tax_amount numeric(14, 2) not null default 0 check (tax_amount >= 0 and tax_amount <= total),
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (
    (is_tax_exempt and tax_rate = 0 and tax_amount = 0)
    or (not is_tax_exempt and tax_amount = round((total - tax_amount) * tax_rate / 100, 2))
  ),
  unique (organization_id, invoice_number),
  unique (id, organization_id),
  foreign key (contact_id, organization_id)
    references public.contacts(id, organization_id) on delete restrict
);

create table public.invoice_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  invoice_id uuid not null,
  inventory_id uuid,
  account_id uuid,
  description text not null,
  quantity numeric(12, 3) not null default 1 check (quantity > 0),
  unit_price numeric(14, 2) not null default 0 check (unit_price >= 0),
  line_total numeric(14, 2) generated always as (round(quantity * unit_price, 2)) stored,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (invoice_id, organization_id)
    references public.invoices(id, organization_id) on delete cascade,
  foreign key (inventory_id, organization_id)
    references public.inventory(id, organization_id) on delete set null (inventory_id),
  foreign key (account_id, organization_id)
    references public.accounts(id, organization_id) on delete set null (account_id)
);

create table public.invoice_payments (
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

create table public.expenses (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  contact_id uuid,
  account_id uuid not null,
  payment_account_id uuid,
  description text not null,
  amount numeric(14, 2) not null check (amount > 0),
  expense_date date not null default current_date,
  status text not null default 'unpaid' check (status in ('unpaid', 'paid', 'void')),
  receipt_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (contact_id, organization_id)
    references public.contacts(id, organization_id) on delete set null (contact_id),
  foreign key (account_id, organization_id)
    references public.accounts(id, organization_id) on delete restrict,
  foreign key (payment_account_id, organization_id)
    references public.accounts(id, organization_id) on delete restrict,
  unique (id, organization_id)
);

create table public.journal_entries (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  entry_date date not null default current_date,
  description text not null,
  reference text,
  status text not null default 'draft' check (status in ('draft', 'posted', 'void')),
  source_type text,
  source_id uuid,
  reversal_of uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, organization_id),
  constraint journal_entries_source_type_valid
    check (source_type is null or source_type in ('invoice', 'expense', 'invoice_payment')),
  constraint journal_entries_source_fields_match
    check ((source_type is null) = (source_id is null)),
  constraint journal_entries_reversal_source_required
    check (reversal_of is null or source_type is not null),
  constraint journal_entries_reversal_same_organization_fkey
    foreign key (reversal_of, organization_id)
    references public.journal_entries(id, organization_id) on delete cascade
);

create table public.journal_lines (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  journal_entry_id uuid not null,
  account_id uuid not null,
  amount numeric(14, 2) not null check (amount > 0),
  amount_code text not null check (amount_code in ('D', 'C')),
  description text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (journal_entry_id, organization_id)
    references public.journal_entries(id, organization_id) on delete cascade,
  foreign key (account_id, organization_id)
    references public.accounts(id, organization_id) on delete restrict
);

create function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

do $$
declare
  table_name text;
begin
  foreach table_name in array array[
    'organizations', 'accounts', 'inventory', 'contacts', 'invoices', 'invoice_items', 'invoice_payments',
    'expenses', 'journal_entries', 'journal_lines'
  ]
  loop
    execute format(
      'create trigger set_%I_updated_at before update on public.%I for each row execute function public.set_updated_at()',
      table_name, table_name
    );
  end loop;
end;
$$;

create function public.create_default_accounts()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.accounts (organization_id, code, name, type, description) values
    (new.id, '1000', 'Cash', 'asset', 'Cash and cash equivalents.'),
    (new.id, '1010', 'Checking account', 'asset', 'Operating bank checking account.'),
    (new.id, '1020', 'Savings account', 'asset', 'Business savings and reserve accounts.'),
    (new.id, '1030', 'Petty cash', 'asset', 'Small cash fund for minor purchases.'),
    (new.id, '1100', 'Accounts receivable', 'asset', 'Amounts customers owe for invoiced work or sales.'),
    (new.id, '1110', 'Allowance for doubtful accounts', 'asset', 'Contra-asset allowance for estimated uncollectible receivables.'),
    (new.id, '1200', 'Inventory - merchandise', 'asset', 'Finished goods held for resale.'),
    (new.id, '1210', 'Inventory - raw materials', 'asset', 'Materials held for production.'),
    (new.id, '1220', 'Inventory - work in process', 'asset', 'Partially completed goods and production costs.'),
    (new.id, '1230', 'Inventory - finished goods', 'asset', 'Completed goods held for sale.'),
    (new.id, '1300', 'Prepaid expenses', 'asset', 'Operating costs paid before they are incurred.'),
    (new.id, '1310', 'Prepaid insurance', 'asset', 'Insurance premiums paid for future coverage periods.'),
    (new.id, '1400', 'Employee advances', 'asset', 'Recoverable advances paid to employees.'),
    (new.id, '1500', 'Furniture and fixtures', 'asset', 'Furniture and fixtures used in operations.'),
    (new.id, '1510', 'Equipment and computers', 'asset', 'Equipment and computer hardware used in operations.'),
    (new.id, '1520', 'Vehicles', 'asset', 'Vehicles owned and used by the business.'),
    (new.id, '1590', 'Accumulated depreciation', 'asset', 'Contra-asset account for depreciation of fixed assets.'),
    (new.id, '1600', 'Leasehold improvements', 'asset', 'Improvements made to leased business premises.'),
    (new.id, '1700', 'Security deposits', 'asset', 'Refundable deposits held by landlords and vendors.'),
    (new.id, '2000', 'Accounts payable', 'liability', 'Amounts owed to vendors and suppliers.'),
    (new.id, '2010', 'Credit card payable', 'liability', 'Outstanding balances on business credit cards.'),
    (new.id, '2100', 'Accrued expenses', 'liability', 'Expenses incurred but not yet paid or invoiced.'),
    (new.id, '2110', 'Wages payable', 'liability', 'Earned employee wages not yet paid.'),
    (new.id, '2120', 'Payroll taxes payable', 'liability', 'Employee and employer payroll taxes due.'),
    (new.id, '2130', 'Sales tax payable', 'liability', 'Sales taxes collected and due to tax authorities.'),
    (new.id, '2200', 'Customer deposits and deferred revenue', 'liability', 'Customer prepayments for goods or services not yet delivered.'),
    (new.id, '2300', 'Current portion of debt', 'liability', 'Principal on debt due within the next year.'),
    (new.id, '2400', 'Notes payable', 'liability', 'Long-term borrowing evidenced by notes.'),
    (new.id, '2500', 'Lease liabilities', 'liability', 'Amounts due under business lease agreements.'),
    (new.id, '2600', 'Income taxes payable', 'liability', 'Business income taxes accrued and unpaid.'),
    (new.id, '3000', 'Owner equity', 'equity', 'Owner capital and accumulated business equity.'),
    (new.id, '3010', 'Owner contributions', 'equity', 'Additional capital contributed by owners.'),
    (new.id, '3020', 'Owner draws', 'equity', 'Withdrawals of business equity by owners.'),
    (new.id, '3100', 'Retained earnings', 'equity', 'Accumulated earnings retained in the business.'),
    (new.id, '3200', 'Opening balance equity', 'equity', 'Temporary account for initial account balances.'),
    (new.id, '4000', 'Sales revenue', 'revenue', 'General operating revenue not assigned to a specialized revenue account.'),
    (new.id, '4010', 'Product sales', 'revenue', 'Revenue from sales of inventory and products.'),
    (new.id, '4020', 'Service revenue', 'revenue', 'Revenue from services performed.'),
    (new.id, '4030', 'Contract and recurring service revenue', 'revenue', 'Revenue from retainers, subscriptions, and service contracts.'),
    (new.id, '4040', 'Shipping and handling revenue', 'revenue', 'Amounts charged to customers for shipping and handling.'),
    (new.id, '4090', 'Sales returns and allowances', 'revenue', 'Contra-revenue for refunds, returns, and sales allowances.'),
    (new.id, '4100', 'Sales discounts', 'revenue', 'Contra-revenue for discounts granted to customers.'),
    (new.id, '4200', 'Other operating income', 'revenue', 'Other income from normal business operations.'),
    (new.id, '4300', 'Interest income', 'revenue', 'Interest earned on cash and investments.'),
    (new.id, '5000', 'Operating expenses', 'expense', 'General operating expenses not assigned to a specialized account.'),
    (new.id, '5100', 'Cost of goods sold', 'expense', 'Cost assigned to inventory sold to customers.'),
    (new.id, '5110', 'Cost of services', 'expense', 'Direct costs of delivering services to customers.'),
    (new.id, '5120', 'Direct labor', 'expense', 'Labor directly attributable to products or customer services.'),
    (new.id, '5130', 'Subcontractor costs', 'expense', 'Third-party labor and services used to fulfill customer work.'),
    (new.id, '5140', 'Freight-in and landed costs', 'expense', 'Inbound freight and other costs of acquiring inventory.'),
    (new.id, '5150', 'Inventory shrinkage and adjustments', 'expense', 'Inventory losses, spoilage, and count adjustments.'),
    (new.id, '6000', 'Wages and salaries', 'expense', 'Employee compensation not classified as direct labor.'),
    (new.id, '6010', 'Employer payroll taxes', 'expense', 'Employer-paid payroll taxes and contributions.'),
    (new.id, '6020', 'Advertising and marketing', 'expense', 'Advertising, promotion, and marketing costs.'),
    (new.id, '6030', 'Automobile and delivery', 'expense', 'Vehicle operating costs and customer delivery expenses.'),
    (new.id, '6040', 'Bank and merchant fees', 'expense', 'Bank service charges and payment processing fees.'),
    (new.id, '6050', 'Depreciation expense', 'expense', 'Periodic depreciation of fixed assets.'),
    (new.id, '6060', 'Insurance expense', 'expense', 'Business insurance premiums for the current period.'),
    (new.id, '6070', 'Licenses and permits', 'expense', 'Business licenses, permits, and regulatory fees.'),
    (new.id, '6080', 'Meals', 'expense', 'Business meals, subject to applicable tax rules.'),
    (new.id, '6090', 'Office supplies', 'expense', 'Consumable office and administrative supplies.'),
    (new.id, '6100', 'Rent', 'expense', 'Rent for offices, shops, and other business premises.'),
    (new.id, '6110', 'Repairs and maintenance', 'expense', 'Repairs and routine maintenance of business property.'),
    (new.id, '6120', 'Software and subscriptions', 'expense', 'Software, hosting, and recurring technology services.'),
    (new.id, '6130', 'Telephone and internet', 'expense', 'Business telephone, mobile, and internet services.'),
    (new.id, '6140', 'Travel', 'expense', 'Business travel and lodging costs.'),
    (new.id, '6150', 'Utilities', 'expense', 'Electricity, water, gas, and other utility services.'),
    (new.id, '6160', 'Professional services', 'expense', 'Legal, accounting, and other professional fees.'),
    (new.id, '6170', 'Training', 'expense', 'Employee training and professional development.'),
    (new.id, '6180', 'Bad debt expense', 'expense', 'Write-offs and provisions for uncollectible customer balances.'),
    (new.id, '6190', 'Small tools and equipment', 'expense', 'Low-cost tools and equipment expensed when purchased.'),
    (new.id, '6200', 'Interest expense', 'expense', 'Interest and financing charges on business debt.'),
    (new.id, '6210', 'Income tax expense', 'expense', 'Business income tax expense for the period.'),
    (new.id, '6220', 'Miscellaneous expense', 'expense', 'Infrequent expenses not classified elsewhere.')
  on conflict (organization_id, code) do nothing;
  return new;
end;
$$;

create trigger create_default_accounts_after_organization
after insert on public.organizations
for each row execute function public.create_default_accounts();

create function public.validate_journal_entry_posting()
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

create trigger validate_journal_entry_before_post
before insert or update of status on public.journal_entries
for each row execute function public.validate_journal_entry_posting();

create function public.prevent_posted_journal_entry_changes()
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

create trigger prevent_posted_journal_entry_changes
before update or delete on public.journal_entries
for each row execute function public.prevent_posted_journal_entry_changes();

create function public.prevent_posted_journal_line_changes()
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

create trigger prevent_posted_journal_line_changes
before insert or update or delete on public.journal_lines
for each row execute function public.prevent_posted_journal_line_changes();

create function public.sync_source_transaction_ledger(
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
        raise exception 'An active Product Sales account (4010) is required to post invoices.';
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

create function public.sync_source_transaction_ledger_trigger()
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

create trigger sync_invoice_to_ledger
after insert or update or delete on public.invoices
for each row execute function public.sync_source_transaction_ledger_trigger();

create trigger sync_expense_to_ledger
after insert or update or delete on public.expenses
for each row execute function public.sync_source_transaction_ledger_trigger();

create function public.validate_expense_payment_account()
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

create trigger validate_expense_payment_account
before insert or update on public.expenses
for each row execute function public.validate_expense_payment_account();

create function public.sync_paid_expense_payment_account()
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

create trigger sync_paid_expense_payment_account
after insert or update on public.expenses
for each row execute function public.sync_paid_expense_payment_account();

create function public.validate_invoice_payment()
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
  select status, total into invoice_status, invoice_total
    from public.invoices
    where id = new.invoice_id and organization_id = new.organization_id
    for update;
  if not found then
    raise exception 'Choose an invoice in this organization.';
  end if;
  if invoice_status in ('draft', 'void') then
    raise exception 'Payments can only be recorded for sent, overdue, or paid invoices.';
  end if;

  select type, is_active, code into account_type, account_active, account_code
    from public.accounts
    where id = new.account_id and organization_id = new.organization_id;
  if not found or account_type <> 'asset' or not account_active or account_code not like '10%' then
    raise exception 'Choose an active cash or bank asset account with an account code beginning with 10.';
  end if;

  select coalesce(sum(amount), 0) into paid_elsewhere
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

create trigger validate_invoice_payment_before_write
before insert or update on public.invoice_payments
for each row execute function public.validate_invoice_payment();

create function public.prevent_invoice_payment_conflicts()
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

create trigger invoices_prevent_paid_without_payment_insert
before insert on public.invoices
for each row execute function public.prevent_invoice_payment_conflicts();

create trigger invoices_prevent_payment_conflicts
before update of total, status on public.invoices
for each row execute function public.prevent_invoice_payment_conflicts();

create function public.recalculate_invoice_payment_status(p_invoice_id uuid, p_organization_id uuid)
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

create function public.sync_invoice_payment_ledger(
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
      and code = '1100' and type = 'asset' and is_active;
  if not found then
    raise exception 'An active Accounts Receivable account (1100) is required to post invoice payments.';
  end if;

  payment_description := left(
    'Payment for invoice ' || (
      select invoice_number from public.invoices
      where id = payment_row.invoice_id and organization_id = p_organization_id
    ) || case when payment_row.reference is null or payment_row.reference = '' then '' else ' / ' || payment_row.reference end,
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

create function public.invoice_payment_after_change()
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

create trigger invoice_payments_after_change
after insert or update or delete on public.invoice_payments
for each row execute function public.invoice_payment_after_change();

create function public.save_journal_entry_with_lines(
  p_organization_id uuid,
  p_entry_id uuid,
  p_entry jsonb,
  p_lines jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_entry_date date;
  v_description text;
  v_reference text;
  v_status text;
  v_line jsonb;
  v_account_id uuid;
  v_amount numeric;
  v_amount_code text;
  v_line_description text;
  v_debit_total numeric := 0;
  v_credit_total numeric := 0;
  v_entry public.journal_entries%rowtype;
  v_result_lines jsonb;
begin
  if auth.uid() is null or not exists (
    select 1
      from public.organizations
      where id = p_organization_id and owner_id = auth.uid()
  ) then
    raise exception 'You do not have access to this organization.';
  end if;
  perform set_config('app.allow_posted_journal_entry_changes', 'on', true);

  if jsonb_typeof(p_entry) is distinct from 'object' then
    raise exception 'Journal entry details are required.';
  end if;
  if jsonb_typeof(p_lines) is distinct from 'array' then
    raise exception 'Journal lines must be an array.';
  end if;
  if jsonb_array_length(p_lines) < 2 then
    raise exception 'Add at least two journal lines.';
  end if;

  if coalesce(p_entry->>'entry_date', '') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
    raise exception 'Enter a valid journal entry date.';
  end if;
  v_entry_date := (p_entry->>'entry_date')::date;
  v_description := btrim(coalesce(p_entry->>'description', ''));
  v_reference := nullif(btrim(coalesce(p_entry->>'reference', '')), '');
  v_status := coalesce(nullif(p_entry->>'status', ''), 'draft');

  if v_description = '' or length(v_description) > 500 then
    raise exception 'Description is required and must be 500 characters or fewer.';
  end if;
  if v_reference is not null and length(v_reference) > 100 then
    raise exception 'Reference must be 100 characters or fewer.';
  end if;
  if v_status not in ('draft', 'posted', 'void') then
    raise exception 'Choose a valid journal entry status.';
  end if;

  for v_line in select value from jsonb_array_elements(p_lines)
  loop
    if jsonb_typeof(v_line) is distinct from 'object' or
      coalesce(v_line->>'account_id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      raise exception 'Each journal line must have a valid account.';
    end if;
    v_account_id := (v_line->>'account_id')::uuid;
    if not exists (
      select 1 from public.accounts
      where id = v_account_id
        and organization_id = p_organization_id
        and is_active
    ) then
      raise exception 'Journal lines must use active accounts in this organization.';
    end if;

    if jsonb_typeof(v_line->'amount') is distinct from 'number' or
      coalesce(v_line->>'amount_code', '') not in ('D', 'C') then
      raise exception 'Each journal line needs a debit or credit amount.';
    end if;
    v_amount := (v_line->>'amount')::numeric;
    if v_amount <= 0 or v_amount > 999999999999.99 or v_amount <> round(v_amount, 2) then
      raise exception 'Journal line amounts must be positive with at most two decimal places.';
    end if;

    if v_line ? 'description' and jsonb_typeof(v_line->'description') not in ('string', 'null') then
      raise exception 'Journal line descriptions must be text.';
    end if;
    v_line_description := nullif(btrim(coalesce(v_line->>'description', '')), '');
    if v_line_description is not null and length(v_line_description) > 500 then
      raise exception 'Journal line descriptions must be 500 characters or fewer.';
    end if;

    v_amount_code := v_line->>'amount_code';
    if v_amount_code = 'D' then
      v_debit_total := v_debit_total + v_amount;
    else
      v_credit_total := v_credit_total + v_amount;
    end if;
  end loop;

  if v_debit_total <= 0 or v_debit_total <> v_credit_total then
    raise exception 'Total debits and credits must be equal and greater than zero.';
  end if;

  if p_entry_id is null then
    insert into public.journal_entries (
      organization_id, entry_date, description, reference, status
    )
    values (
      p_organization_id, v_entry_date, v_description, v_reference, 'draft'
    )
    returning * into v_entry;
  else
    select * into v_entry
      from public.journal_entries
      where id = p_entry_id and organization_id = p_organization_id
      for update;
    if not found then
      raise exception 'Journal entry not found.';
    end if;
    update public.journal_entries
      set entry_date = v_entry_date,
          description = v_description,
          reference = v_reference,
          status = 'draft'
      where id = p_entry_id and organization_id = p_organization_id
      returning * into v_entry;
    delete from public.journal_lines
      where journal_entry_id = p_entry_id and organization_id = p_organization_id;
  end if;

  for v_line in select value from jsonb_array_elements(p_lines)
  loop
    insert into public.journal_lines (
      organization_id, journal_entry_id, account_id, amount, amount_code, description
    )
    values (
      p_organization_id,
      v_entry.id,
      (v_line->>'account_id')::uuid,
      (v_line->>'amount')::numeric,
      v_line->>'amount_code',
      nullif(btrim(coalesce(v_line->>'description', '')), '')
    );
  end loop;

  update public.journal_entries
    set status = v_status
    where id = v_entry.id and organization_id = p_organization_id
    returning * into v_entry;

  select coalesce(jsonb_agg(to_jsonb(line) order by line.created_at, line.id), '[]'::jsonb)
    into v_result_lines
    from public.journal_lines as line
    where line.journal_entry_id = v_entry.id and line.organization_id = p_organization_id;

  return jsonb_build_object('entry', to_jsonb(v_entry), 'lines', v_result_lines);
end;
$$;

create function public.delete_journal_entry(
  p_organization_id uuid,
  p_entry_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_deleted_id uuid;
begin
  if auth.uid() is null or not exists (
    select 1
      from public.organizations
      where id = p_organization_id and owner_id = auth.uid()
  ) then
    raise exception 'You do not have access to this organization.';
  end if;
  perform set_config('app.allow_posted_journal_entry_changes', 'on', true);

  delete from public.journal_entries
    where id = p_entry_id and organization_id = p_organization_id
    returning id into v_deleted_id;
  if not found then
    raise exception 'Journal entry not found.';
  end if;

  return jsonb_build_object('id', v_deleted_id);
end;
$$;

revoke all on function public.delete_journal_entry(uuid, uuid) from public, anon, authenticated;
grant execute on function public.delete_journal_entry(uuid, uuid) to authenticated;

create function public.create_paid_invoice_with_payment(
  p_organization_id uuid,
  p_invoice jsonb,
  p_items jsonb,
  p_payment jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_organization_currency text;
  v_contact_id uuid;
  v_invoice_number text;
  v_issue_date date;
  v_due_date date;
  v_currency text;
  v_is_tax_exempt boolean;
  v_tax_rate numeric;
  v_subtotal numeric := 0;
  v_tax_amount numeric := 0;
  v_total numeric := 0;
  v_payment_date date;
  v_payment_account_id uuid;
  v_payment_method text;
  v_payment_reference text;
  v_item record;
  v_invoice public.invoices%rowtype;
  v_payment public.invoice_payments%rowtype;
begin
  if auth.uid() is null or not exists (
    select 1
      from public.organizations
      where id = p_organization_id and owner_id = auth.uid()
  ) then
    raise exception 'The organization is not available to the current user.';
  end if;

  if jsonb_typeof(p_invoice) is distinct from 'object' or
    jsonb_typeof(p_payment) is distinct from 'object' or
    jsonb_typeof(p_items) is distinct from 'array' then
    raise exception 'Invoice, invoice items, and payment details are required.';
  end if;
  if jsonb_array_length(p_items) = 0 then
    raise exception 'Add at least one invoice line.';
  end if;

  select currency into v_organization_currency
    from public.organizations
    where id = p_organization_id;

  v_contact_id := nullif(btrim(p_invoice ->> 'contact_id'), '')::uuid;
  v_invoice_number := nullif(btrim(p_invoice ->> 'invoice_number'), '');
  v_issue_date := nullif(p_invoice ->> 'issue_date', '')::date;
  v_due_date := nullif(p_invoice ->> 'due_date', '')::date;
  v_currency := upper(coalesce(nullif(btrim(p_invoice ->> 'currency'), ''), v_organization_currency));
  v_is_tax_exempt := coalesce((p_invoice ->> 'is_tax_exempt')::boolean, true);
  v_tax_rate := coalesce((p_invoice ->> 'tax_rate')::numeric, 0);

  if v_contact_id is null or not exists (
    select 1 from public.contacts
    where id = v_contact_id
      and organization_id = p_organization_id
      and type in ('customer', 'both')
  ) then
    raise exception 'Choose a customer in this organization.';
  end if;
  if v_invoice_number is null or length(v_invoice_number) > 50 then
    raise exception 'Invoice number is required and must be 50 characters or fewer.';
  end if;
  if v_issue_date is null or v_due_date is null or v_due_date < v_issue_date then
    raise exception 'Enter valid invoice dates; the due date cannot be before the issue date.';
  end if;
  if v_currency !~ '^[A-Z]{3}$' then
    raise exception 'Currency must be a three-letter uppercase code.';
  end if;
  if v_tax_rate < 0 or v_tax_rate > 100 or v_tax_rate <> round(v_tax_rate, 2) then
    raise exception 'Tax rate must be between 0 and 100 with at most two decimal places.';
  end if;
  if v_is_tax_exempt and v_tax_rate <> 0 then
    raise exception 'Tax-exempt invoices must have a zero tax rate.';
  end if;

  for v_item in
    select *
      from jsonb_to_recordset(p_items) as item(
        inventory_id uuid,
        description text,
        quantity numeric,
        unit_price numeric,
        account_id uuid
      )
  loop
    if v_item.description is null or length(btrim(v_item.description)) not between 1 and 500 then
      raise exception 'Each invoice line needs a description of 1 to 500 characters.';
    end if;
    if v_item.quantity is null or v_item.quantity <= 0 or
      v_item.quantity > 999999999.999 or v_item.quantity <> round(v_item.quantity, 3) then
      raise exception 'Invoice line quantity must be greater than zero with at most three decimal places.';
    end if;
    if v_item.unit_price is null or v_item.unit_price < 0 or
      v_item.unit_price > 999999999999.99 or v_item.unit_price <> round(v_item.unit_price, 2) then
      raise exception 'Invoice line unit price must be non-negative with at most two decimal places.';
    end if;
    if v_item.inventory_id is not null and not exists (
      select 1 from public.inventory
      where id = v_item.inventory_id and organization_id = p_organization_id and is_active
    ) then
      raise exception 'Choose an active inventory item for each invoice line.';
    end if;
    if v_item.account_id is not null and not exists (
      select 1 from public.accounts
      where id = v_item.account_id
        and organization_id = p_organization_id
        and type = 'revenue'
        and is_active
    ) then
      raise exception 'Choose an active revenue account for each invoice line.';
    end if;
    v_subtotal := v_subtotal + round(v_item.quantity * v_item.unit_price, 2);
  end loop;

  if v_is_tax_exempt then
    v_tax_rate := 0;
  else
    v_tax_amount := round(v_subtotal * v_tax_rate / 100, 2);
  end if;
  v_total := v_subtotal + v_tax_amount;
  if v_total <= 0 then
    raise exception 'A zero-total invoice cannot have a payment recorded.';
  end if;
  if v_total > 999999999999.99 then
    raise exception 'Invoice total exceeds the supported maximum.';
  end if;

  v_payment_date := nullif(p_payment ->> 'payment_date', '')::date;
  v_payment_account_id := nullif(btrim(p_payment ->> 'account_id'), '')::uuid;
  v_payment_method := p_payment ->> 'payment_method';
  v_payment_reference := nullif(btrim(p_payment ->> 'reference'), '');
  if v_payment_date is null then
    raise exception 'Enter a valid payment date.';
  end if;
  if v_payment_account_id is null or not exists (
    select 1 from public.accounts
    where id = v_payment_account_id
      and organization_id = p_organization_id
      and type = 'asset'
      and is_active
      and code like '10%'
  ) then
    raise exception 'Choose an active cash or bank deposit account.';
  end if;
  if v_payment_method is null or v_payment_method not in ('cash', 'check', 'card', 'bank_transfer', 'other') then
    raise exception 'Choose a valid payment method.';
  end if;
  if v_payment_reference is not null and length(v_payment_reference) > 100 then
    raise exception 'Payment reference must be 100 characters or fewer.';
  end if;

  insert into public.invoices (
    organization_id, contact_id, invoice_number, status, issue_date, due_date,
    currency, total, is_tax_exempt, tax_rate, tax_amount
  )
  values (
    p_organization_id, v_contact_id, v_invoice_number, 'sent', v_issue_date, v_due_date,
    v_currency, v_total, v_is_tax_exempt, v_tax_rate, v_tax_amount
  )
  returning * into v_invoice;

  for v_item in
    select *
      from jsonb_to_recordset(p_items) as item(
        inventory_id uuid,
        description text,
        quantity numeric,
        unit_price numeric,
        account_id uuid
      )
  loop
    insert into public.invoice_items (
      organization_id, invoice_id, inventory_id, description, quantity, unit_price, account_id
    )
    values (
      p_organization_id,
      v_invoice.id,
      v_item.inventory_id,
      btrim(v_item.description),
      v_item.quantity,
      v_item.unit_price,
      v_item.account_id
    );
  end loop;

  insert into public.invoice_payments (
    organization_id, invoice_id, account_id, payment_date, amount, payment_method, reference
  )
  values (
    p_organization_id, v_invoice.id, v_payment_account_id, v_payment_date,
    v_total, v_payment_method, v_payment_reference
  )
  returning * into v_payment;

  select * into v_invoice
    from public.invoices
    where id = v_invoice.id and organization_id = p_organization_id;

  return jsonb_build_object(
    'invoice', to_jsonb(v_invoice),
    'payment', to_jsonb(v_payment)
  );
end;
$$;

create function public.recalculate_invoice_status_after_total_change()
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

create trigger invoices_recalculate_payment_status
after update of total on public.invoices
for each row
when (old.total is distinct from new.total)
execute function public.recalculate_invoice_status_after_total_change();

revoke all on function public.validate_invoice_payment() from public, anon, authenticated;
revoke all on function public.prevent_invoice_payment_conflicts() from public, anon, authenticated;
revoke all on function public.recalculate_invoice_payment_status(uuid, uuid) from public, anon, authenticated;
revoke all on function public.sync_invoice_payment_ledger(uuid, uuid, boolean) from public, anon, authenticated;
revoke all on function public.invoice_payment_after_change() from public, anon, authenticated;
revoke all on function public.recalculate_invoice_status_after_total_change() from public, anon, authenticated;
revoke all on function public.save_journal_entry_with_lines(uuid, uuid, jsonb, jsonb) from public, anon, authenticated;
grant execute on function public.save_journal_entry_with_lines(uuid, uuid, jsonb, jsonb) to authenticated;
revoke all on function public.create_paid_invoice_with_payment(uuid, jsonb, jsonb, jsonb) from public, anon, authenticated;
grant execute on function public.create_paid_invoice_with_payment(uuid, jsonb, jsonb, jsonb) to authenticated;

grant usage on schema public to authenticated;
grant select, insert, update, delete on table
  public.organizations,
  public.accounts,
  public.inventory,
  public.contacts,
  public.invoices,
  public.invoice_items,
  public.invoice_payments,
  public.expenses,
  public.journal_entries,
  public.journal_lines
to authenticated;

create index invoices_organization_date_idx on public.invoices (organization_id, issue_date desc);
create index expenses_organization_date_idx on public.expenses (organization_id, expense_date desc);
create index journal_entries_organization_date_idx on public.journal_entries (organization_id, entry_date desc);
create index journal_lines_entry_idx on public.journal_lines (journal_entry_id, organization_id);
create index invoice_items_inventory_idx on public.invoice_items (inventory_id, organization_id);
create index invoice_payments_invoice_date_idx on public.invoice_payments (organization_id, invoice_id, payment_date desc);
create index journal_entries_source_idx on public.journal_entries (organization_id, source_type, source_id);
create unique index journal_entries_reversal_of_uidx on public.journal_entries (reversal_of) where reversal_of is not null;
create index contacts_organization_name_idx on public.contacts (organization_id, name);

alter table public.organizations enable row level security;
alter table public.accounts enable row level security;
alter table public.inventory enable row level security;
alter table public.contacts enable row level security;
alter table public.invoices enable row level security;
alter table public.invoice_items enable row level security;
alter table public.invoice_payments enable row level security;
alter table public.expenses enable row level security;
alter table public.journal_entries enable row level security;
alter table public.journal_lines enable row level security;

create policy "Owners manage their organizations"
on public.organizations for all
using (owner_id = auth.uid())
with check (owner_id = auth.uid());

do $$
declare
  table_name text;
begin
  foreach table_name in array array[
    'accounts', 'inventory', 'contacts', 'invoices', 'invoice_items', 'invoice_payments',
    'expenses', 'journal_entries', 'journal_lines'
  ]
  loop
    execute format(
      'create policy "Organization owners manage %1$s" on public.%1$I for all using (exists (select 1 from public.organizations o where o.id = organization_id and o.owner_id = auth.uid())) with check (exists (select 1 from public.organizations o where o.id = organization_id and o.owner_id = auth.uid()))',
      table_name
    );
  end loop;
end;
$$;

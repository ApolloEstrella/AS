-- Apply sync_source_transactions_to_ledger.sql and add_invoice_payments.sql first.
begin;

create or replace function public.create_paid_invoice_with_payment(
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

revoke all on function public.create_paid_invoice_with_payment(uuid, jsonb, jsonb, jsonb)
  from public, anon, authenticated;
grant execute on function public.create_paid_invoice_with_payment(uuid, jsonb, jsonb, jsonb)
  to authenticated;

notify pgrst, 'reload schema';
commit;

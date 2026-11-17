-- Apply after add_invoice_payments.sql.
begin;

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
      raise exception 'This invoice is fully paid. Delete or reduce its recorded payments first; payment changes update the invoice status and reverse the ledger entry.';
    end if;
    if new.status = 'paid' and old.status is distinct from 'paid' and
      (new.total <= 0 or paid_total < new.total) then
      raise exception 'Record payments covering the invoice total before marking it paid.';
    end if;
  end if;
  return new;
end;
$$;

update public.invoices as invoice
set status = 'paid'
where invoice.status in ('sent', 'overdue')
  and invoice.total > 0
  and (
    select coalesce(sum(payment.amount), 0)
    from public.invoice_payments as payment
    where payment.invoice_id = invoice.id
      and payment.organization_id = invoice.organization_id
  ) >= invoice.total;

notify pgrst, 'reload schema';
commit;

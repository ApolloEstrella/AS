import type { SupabaseClient } from "@supabase/supabase-js";

const paymentMethods = new Set(["cash", "check", "card", "bank_transfer", "other"]);
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function isValidDate(value: string) {
  const parsed = new Date(`${value}T00:00:00.000Z`);
  return /^\d{4}-\d{2}-\d{2}$/.test(value) && !Number.isNaN(parsed.getTime()) &&
    parsed.toISOString().slice(0, 10) === value;
}

type ValidationResult =
  | { payload: Record<string, unknown> }
  | { error: string; status: number };

export async function validateInvoicePaymentPayload(
  client: SupabaseClient,
  payload: Record<string, unknown>,
  organizationId: string,
  paymentId?: string,
): Promise<ValidationResult> {
  let existing: Record<string, unknown> = {};
  if (paymentId) {
    const { data, error } = await client
      .from("invoice_payments")
      .select("id, invoice_id, account_id, payment_date, amount, payment_method, reference, notes")
      .eq("id", paymentId)
      .eq("organization_id", organizationId)
      .maybeSingle();
    if (error) return { error: error.message, status: 400 };
    if (!data) return { error: "Payment not found.", status: 404 };
    existing = data;
  }

  const values = { ...existing, ...payload };
  const invoiceId = values.invoice_id;
  const accountId = values.account_id;
  const paymentDate = values.payment_date;
  const method = values.payment_method;
  const amount = values.amount;
  if (typeof invoiceId !== "string" || !uuidPattern.test(invoiceId)) {
    return { error: "Choose a valid invoice.", status: 400 };
  }
  if (typeof accountId !== "string" || !uuidPattern.test(accountId)) {
    return { error: "Choose a valid deposit account.", status: 400 };
  }
  if (typeof paymentDate !== "string" || !isValidDate(paymentDate)) {
    return { error: "Enter a valid payment date.", status: 400 };
  }
  if (typeof method !== "string" || !paymentMethods.has(method)) {
    return { error: "Choose a valid payment method.", status: 400 };
  }
  if (typeof amount !== "number" || !Number.isFinite(amount) || amount <= 0 ||
    amount > 999999999999.99 || Math.abs(amount * 100 - Math.round(amount * 100)) > 0.000001) {
    return { error: "Payment amount must be greater than zero with at most two decimal places.", status: 400 };
  }
  const amountCents = Math.round(amount * 100);

  for (const field of ["reference", "notes"]) {
    const value = values[field];
    if (value !== undefined && value !== null &&
      (typeof value !== "string" || value.trim().length > (field === "reference" ? 100 : 500))) {
      return { error: `${field === "reference" ? "Reference" : "Notes"} must be within the allowed length.`, status: 400 };
    }
  }

  const { data: invoice, error: invoiceError } = await client
    .from("invoices")
    .select("id, status, total")
    .eq("id", invoiceId)
    .eq("organization_id", organizationId)
    .maybeSingle();
  if (invoiceError) return { error: invoiceError.message, status: 400 };
  if (!invoice) return { error: "Choose an invoice in this organization.", status: 400 };
  if (invoice.status === "draft" || invoice.status === "void") {
    return { error: "Payments can only be recorded for sent, overdue, or paid invoices.", status: 400 };
  }

  const { data: account, error: accountError } = await client
    .from("accounts")
    .select("type, is_active, code")
    .eq("id", accountId)
    .eq("organization_id", organizationId)
    .maybeSingle();
  if (accountError) return { error: accountError.message, status: 400 };
  if (!account || account.type !== "asset" || !account.is_active ||
    typeof account.code !== "string" || !account.code.startsWith("10")) {
    return { error: "Choose an active cash or bank account with an account code beginning with 10.", status: 400 };
  }

  let existingPaidCents = 0;
  let offset = 0;
  while (true) {
    const { data: payments, error: paymentsError } = await client
      .from("invoice_payments")
      .select("id, amount")
      .eq("invoice_id", invoiceId)
      .eq("organization_id", organizationId)
      .order("id", { ascending: true })
      .range(offset, offset + 499);
    if (paymentsError) return { error: paymentsError.message, status: 400 };
    for (const payment of payments ?? []) {
      if (payment.id !== paymentId) existingPaidCents += Math.round(Number(payment.amount) * 100);
    }
    if (!payments || payments.length < 500) break;
    offset += payments.length;
  }

  const invoiceTotalCents = Math.round(Number(invoice.total) * 100);
  if (existingPaidCents + amountCents > invoiceTotalCents) {
    return { error: "Payment exceeds the invoice balance due.", status: 400 };
  }

  const normalizedPayload = { ...payload };
  if (Object.hasOwn(payload, "amount")) normalizedPayload.amount = amountCents / 100;
  for (const field of ["reference", "notes"]) {
    if (Object.hasOwn(payload, field)) {
      const value = payload[field];
      normalizedPayload[field] = typeof value === "string" ? value.trim() || null : value;
    }
  }
  return { payload: normalizedPayload };
}

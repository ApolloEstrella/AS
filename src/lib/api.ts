import { createClient, type SupabaseClient, type User } from "@supabase/supabase-js";

export const resources = {
  organizations: {
    table: "organizations",
    fields: ["name", "currency"],
  },
  accounts: {
    table: "accounts",
    fields: ["code", "name", "type", "description", "is_active"],
  },
  inventory: {
    table: "inventory",
    fields: ["sku", "name", "description", "unit", "quantity_on_hand", "unit_cost", "unit_price", "is_active"],
  },
  contacts: {
    table: "contacts",
    fields: ["name", "email", "phone", "company", "type"],
  },
  invoices: {
    table: "invoices",
    fields: [
      "contact_id",
      "invoice_number",
      "status",
      "issue_date",
      "due_date",
      "currency",
      "total",
      "is_tax_exempt",
      "tax_rate",
      "tax_amount",
      "notes",
    ],
  },
  "invoice-items": {
    table: "invoice_items",
    fields: ["invoice_id", "inventory_id", "description", "quantity", "unit_price", "account_id"],
  },
  "invoice-payments": {
    table: "invoice_payments",
    fields: ["invoice_id", "account_id", "payment_date", "amount", "payment_method", "reference", "notes"],
  },
  expenses: {
    table: "expenses",
    fields: [
      "contact_id",
      "account_id",
      "payment_account_id",
      "description",
      "amount",
      "expense_date",
      "status",
      "receipt_url",
    ],
  },
  "journal-entries": {
    table: "journal_entries",
    fields: ["entry_date", "description", "reference", "status"],
  },
  "journal-lines": {
    table: "journal_lines",
    fields: ["journal_entry_id", "account_id", "amount", "amount_code", "description"],
  },
} as const;

export type Resource = keyof typeof resources;

export async function getRequestClient(
  request: Request,
): Promise<{ client: SupabaseClient; user: User } | Response> {
  const authorization = request.headers.get("authorization");
  if (!authorization?.startsWith("Bearer ")) {
    return Response.json({ error: "A Supabase access token is required." }, { status: 401 });
  }

  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  if (!url || !key) {
    return Response.json({ error: "Supabase environment variables are not configured." }, { status: 503 });
  }

  const client = createClient(url, key, {
    global: { headers: { Authorization: authorization } },
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const { data, error } = await client.auth.getUser();
  if (error || !data.user) {
    return Response.json({ error: "The Supabase access token is invalid or expired." }, { status: 401 });
  }

  return { client, user: data.user };
}

export function isResource(value: string): value is Resource {
  return Object.hasOwn(resources, value);
}

export function filterFields(resource: Resource, value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  const fields: readonly string[] = resources[resource].fields;
  return Object.fromEntries(
    Object.entries(value).filter(([key, item]) => fields.includes(key) && item !== undefined),
  );
}

export function apiError(message: string, status = 400) {
  return Response.json({ error: message }, { status });
}

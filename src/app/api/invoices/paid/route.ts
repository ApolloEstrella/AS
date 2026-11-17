import { apiError, getRequestClient } from "@/lib/api";

type JsonRecord = Record<string, unknown>;

function isJsonRecord(value: unknown): value is JsonRecord {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

export async function POST(request: Request) {
  const auth = await getRequestClient(request);
  if (auth instanceof Response) return auth;

  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return apiError("Request body must be valid JSON.");
  }
  if (!isJsonRecord(body) ||
    typeof body.organization_id !== "string" ||
    !isJsonRecord(body.invoice) ||
    !Array.isArray(body.items) ||
    !isJsonRecord(body.payment)) {
    return apiError("Invoice, invoice items, payment details, and organization_id are required.");
  }
  if (body.items.length === 0) return apiError("Add at least one invoice line.");

  const { data, error } = await auth.client.rpc("create_paid_invoice_with_payment", {
    p_organization_id: body.organization_id,
    p_invoice: body.invoice,
    p_items: body.items,
    p_payment: body.payment,
  });
  if (error) return apiError(error.message, 400);
  return Response.json({ data }, { status: 201 });
}

import type { NextRequest } from "next/server";
import { apiError, filterFields, getRequestClient, isResource, resources } from "@/lib/api";
import { validateInvoicePaymentPayload } from "@/lib/invoice-payment-validation";
import { validateInvoiceTaxPayload } from "@/lib/invoice-tax-validation";
import { normalizeInventoryPayload } from "@/lib/inventory-validation";

type RouteContext = { params: Promise<{ resource: string }> };

export async function GET(request: NextRequest, { params }: RouteContext) {
  const { resource } = await params;
  if (!isResource(resource)) return apiError("Unknown resource.", 404);
  const auth = await getRequestClient(request);
  if (auth instanceof Response) return auth;

  const limitValue = request.nextUrl.searchParams.get("limit") ?? "500";
  const offsetValue = request.nextUrl.searchParams.get("offset") ?? "0";
  if (!/^\d+$/.test(limitValue) || !/^\d+$/.test(offsetValue)) {
    return apiError("limit and offset must be non-negative integers.");
  }
  const limit = Number(limitValue);
  const offset = Number(offsetValue);
  if (!Number.isSafeInteger(limit) || limit < 1 || limit > 500 ||
    !Number.isSafeInteger(offset) || offset + limit > 2_147_483_647) {
    return apiError("Pagination values are outside the allowed range.");
  }

  let query = auth.client.from(resources[resource].table).select("*");
  if (resource === "organizations") {
    query = query.eq("owner_id", auth.user.id);
  } else {
    const organizationId = request.nextUrl.searchParams.get("organizationId");
    if (!organizationId) return apiError("organizationId is required.");
    query = query.eq("organization_id", organizationId);
  }
  if (resource === "invoice-items") {
    if (request.nextUrl.searchParams.has("invoiceId")) {
      const invoiceId = request.nextUrl.searchParams.get("invoiceId");
      if (!invoiceId) return apiError("invoiceId must not be empty.");
      query = query.eq("invoice_id", invoiceId);
    }
  } else if (resource === "invoice-payments" && request.nextUrl.searchParams.has("invoiceId")) {
    const invoiceId = request.nextUrl.searchParams.get("invoiceId");
    if (!invoiceId) return apiError("invoiceId must not be empty.");
    query = query.eq("invoice_id", invoiceId);
  } else if (resource !== "invoice-payments" && request.nextUrl.searchParams.has("invoiceId")) {
    return apiError("invoiceId is only supported for invoice items and payments.");
  }

  const { data, error } = await query
    .order("created_at", { ascending: false })
    .order("id", { ascending: true })
    .range(offset, offset + limit - 1);
  if (error) return apiError(error.message, 400);
  return Response.json({ data });
}

export async function POST(request: NextRequest, { params }: RouteContext) {
  const { resource } = await params;
  if (!isResource(resource)) return apiError("Unknown resource.", 404);
  const auth = await getRequestClient(request);
  if (auth instanceof Response) return auth;

  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return apiError("Request body must be valid JSON.");
  }

  let payload = filterFields(resource, body);
  let organizationId: string | null = null;
  if (resource === "organizations") {
    payload.owner_id = auth.user.id;
  } else if (body && typeof body === "object" && !Array.isArray(body)) {
    const requestedOrganizationId = (body as Record<string, unknown>).organization_id;
    if (typeof requestedOrganizationId !== "string") return apiError("organization_id is required.");
    organizationId = requestedOrganizationId;
    payload.organization_id = organizationId;
  }

  if (resource === "invoice-payments") {
    if (!organizationId) return apiError("organization_id is required.");
    const validation = await validateInvoicePaymentPayload(auth.client, payload, organizationId);
    if ("error" in validation) return apiError(validation.error, validation.status);
    payload = validation.payload;
  }

  if (resource === "invoices") {
    payload.is_tax_exempt ??= true;
    payload.tax_rate ??= 0;
    payload.tax_amount ??= 0;
    const error = validateInvoiceTaxPayload(payload);
    if (error) return apiError(error);
  }

  if (resource === "inventory") {
    const normalized = normalizeInventoryPayload(payload, true);
    if (normalized.error) return apiError(normalized.error);
    payload = normalized.payload;
    const sku = String(payload.sku);
    const escapedSku = sku.replace(/([%_\\])/g, "\\$1");
    const { data: existing, error: lookupError } = await auth.client
      .from("inventory")
      .select("id")
      .eq("organization_id", payload.organization_id)
      .ilike("sku", escapedSku)
      .limit(1)
      .maybeSingle();
    if (lookupError) return apiError(lookupError.message, 400);
    if (existing) return apiError("This SKU is already in use.", 409);
  }

  const { data, error } = await auth.client
    .from(resources[resource].table)
    .insert(payload)
    .select("*")
    .single();
  if (error) return apiError(error.message, 400);
  return Response.json({ data }, { status: 201 });
}

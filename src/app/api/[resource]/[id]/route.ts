import type { NextRequest } from "next/server";
import { apiError, filterFields, getRequestClient, isResource, resources } from "@/lib/api";
import { validateInvoicePaymentPayload } from "@/lib/invoice-payment-validation";
import { validateInvoiceTaxPayload } from "@/lib/invoice-tax-validation";
import { normalizeInventoryPayload } from "@/lib/inventory-validation";

type RouteContext = { params: Promise<{ resource: string; id: string }> };

async function getTarget(request: NextRequest, context: RouteContext) {
  const { resource, id } = await context.params;
  if (!isResource(resource)) return { response: apiError("Unknown resource.", 404) } as const;
  const auth = await getRequestClient(request);
  if (auth instanceof Response) return { response: auth } as const;
  return { resource, id, ...auth } as const;
}

export async function GET(request: NextRequest, context: RouteContext) {
  const target = await getTarget(request, context);
  if ("response" in target) return target.response;
  const { data, error } = await target.client
    .from(resources[target.resource].table)
    .select("*")
    .eq("id", target.id)
    .maybeSingle();
  if (error) return apiError(error.message, 400);
  if (!data) return apiError("Record not found.", 404);
  return Response.json({ data });
}

export async function PATCH(request: NextRequest, context: RouteContext) {
  const target = await getTarget(request, context);
  if ("response" in target) return target.response;
  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return apiError("Request body must be valid JSON.");
  }

  let payload = filterFields(target.resource, body);
  if (Object.keys(payload).length === 0) return apiError("No editable fields were provided.");
  if (target.resource === "invoices") {
    const error = validateInvoiceTaxPayload(payload);
    if (error) return apiError(error);
  }
  if (target.resource === "invoice-payments") {
    const organizationId = request.nextUrl.searchParams.get("organizationId");
    if (!organizationId) return apiError("organizationId is required.");
    const validation = await validateInvoicePaymentPayload(target.client, payload, organizationId, target.id);
    if ("error" in validation) return apiError(validation.error, validation.status);
    payload = validation.payload;
  }
  if (target.resource === "inventory") {
    const normalized = normalizeInventoryPayload(payload, false);
    if (normalized.error) return apiError(normalized.error);
    payload = normalized.payload;
    if (typeof payload.sku === "string") {
      const organizationId = request.nextUrl.searchParams.get("organizationId");
      if (!organizationId) return apiError("organizationId is required.");
      const escapedSku = payload.sku.replace(/([%_\\])/g, "\\$1");
      const { data: existing, error: lookupError } = await target.client
        .from("inventory")
        .select("id")
        .eq("organization_id", organizationId)
        .neq("id", target.id)
        .ilike("sku", escapedSku)
        .limit(1)
        .maybeSingle();
      if (lookupError) return apiError(lookupError.message, 400);
      if (existing) return apiError("This SKU is already in use.", 409);
    }
  }
  const { data, error } = await target.client
    .from(resources[target.resource].table)
    .update(payload)
    .eq("id", target.id)
    .select("*")
    .maybeSingle();
  if (error) return apiError(error.message, 400);
  if (!data) return apiError("Record not found.", 404);
  return Response.json({ data });
}

export async function DELETE(request: NextRequest, context: RouteContext) {
  const target = await getTarget(request, context);
  if ("response" in target) return target.response;
  if (target.resource === "journal-entries") {
    const organizationId = request.nextUrl.searchParams.get("organizationId");
    if (!organizationId) return apiError("organizationId is required.");
    const { data, error } = await target.client.rpc("delete_journal_entry", {
      p_organization_id: organizationId,
      p_entry_id: target.id,
    });
    if (error) return apiError(error.message, 400);
    return Response.json({ data });
  }
  const { data, error } = await target.client
    .from(resources[target.resource].table)
    .delete()
    .eq("id", target.id)
    .select("id")
    .maybeSingle();
  if (error) return apiError(error.message, 400);
  if (!data) return apiError("Record not found.", 404);
  return Response.json({ data });
}

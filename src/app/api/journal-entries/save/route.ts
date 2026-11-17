import { apiError, getRequestClient } from "@/lib/api";

type JsonRecord = Record<string, unknown>;

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

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
  if (!isJsonRecord(body) || typeof body.organization_id !== "string" ||
    !uuidPattern.test(body.organization_id) ||
    (body.entry_id !== null && body.entry_id !== undefined &&
      (typeof body.entry_id !== "string" || !uuidPattern.test(body.entry_id))) ||
    !isJsonRecord(body.entry) || !Array.isArray(body.lines) ||
    !body.lines.every(isJsonRecord)) {
    return apiError("Organization, journal entry details, and journal lines are required.");
  }
  if (body.lines.length < 2) return apiError("Add at least two journal lines.");

  const entryId = typeof body.entry_id === "string" ? body.entry_id : null;
  const { data, error } = await auth.client.rpc("save_journal_entry_with_lines", {
    p_organization_id: body.organization_id,
    p_entry_id: entryId,
    p_entry: body.entry,
    p_lines: body.lines,
  });
  if (error) return apiError(error.message, 400);
  return Response.json({ data }, { status: entryId ? 200 : 201 });
}

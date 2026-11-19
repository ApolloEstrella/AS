const inventoryLimits = {
  quantity_on_hand: { max: 999_999_999.999, decimalPlaces: 3 },
  unit_cost: { max: 999_999_999_999.99, decimalPlaces: 2 },
  unit_price: { max: 999_999_999_999.99, decimalPlaces: 2 },
  reorder_level: { max: 999_999_999.999, decimalPlaces: 3 },
} as const;

function decimalPlaces(value: number) {
  const [coefficient, exponentText] = value.toString().toLowerCase().split("e");
  const fractionDigits = coefficient.split(".")[1]?.length ?? 0;
  return Math.max(0, fractionDigits - Number(exponentText ?? 0));
}

export function normalizeInventoryPayload(
  payload: Record<string, unknown>,
  isCreate: boolean,
): { payload: Record<string, unknown>; error?: string } {
  const normalized = { ...payload };

  for (const field of ["sku", "name", "unit"] as const) {
    const value = normalized[field];
    if (value === undefined) {
      if (isCreate && field !== "unit") return { payload: normalized, error: `${field} is required.` };
      continue;
    }
    if (typeof value !== "string") return { payload: normalized, error: `${field} must be text.` };
    normalized[field] = value.trim();
  }

  if (typeof normalized.sku === "string") {
    if (normalized.sku.length < 1 || normalized.sku.length > 64) {
      return { payload: normalized, error: "SKU must be between 1 and 64 characters." };
    }
    if (!/^[A-Za-z0-9][A-Za-z0-9._/-]*$/.test(normalized.sku)) {
      return { payload: normalized, error: "SKU must start with a letter or number and contain only letters, numbers, periods, hyphens, underscores, or slashes." };
    }
  }

  if (typeof normalized.name === "string" &&
    (normalized.name.length < 1 || normalized.name.length > 160)) {
    return { payload: normalized, error: "Name must be between 1 and 160 characters." };
  }

  if (typeof normalized.unit === "string" &&
    (normalized.unit.length < 1 || normalized.unit.length > 32)) {
    return { payload: normalized, error: "Unit must be between 1 and 32 characters." };
  }

  if ("description" in normalized) {
    const description = normalized.description;
    if (description !== null && typeof description !== "string") {
      return { payload: normalized, error: "Description must be text." };
    }
    if (typeof description === "string") {
      const trimmedDescription = description.trim();
      normalized.description = trimmedDescription;
      if (trimmedDescription.length > 500) {
        return { payload: normalized, error: "Description must be 500 characters or fewer." };
      }
    }
  }

  for (const [field, limits] of Object.entries(inventoryLimits)) {
    if (!(field in normalized)) continue;
    const value = normalized[field];
    if (typeof value !== "number" || !Number.isFinite(value)) {
      return { payload: normalized, error: `${field} must be a valid number.` };
    }
    if (value < 0 || value > limits.max) {
      return { payload: normalized, error: `${field} must be between 0 and ${limits.max}.` };
    }
    if (decimalPlaces(value) > limits.decimalPlaces) {
      return { payload: normalized, error: `${field} can have at most ${limits.decimalPlaces} decimal places.` };
    }
  }

  if ("is_active" in normalized && typeof normalized.is_active !== "boolean") {
    return { payload: normalized, error: "is_active must be a boolean." };
  }

  return { payload: normalized };
}

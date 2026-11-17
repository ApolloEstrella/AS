const MAX_AMOUNT = 999999999999.99;

function isMoney(value: unknown): value is number {
  return typeof value === "number" &&
    Number.isFinite(value) &&
    value >= 0 &&
    value <= MAX_AMOUNT &&
    Math.abs(Math.round(value * 100) - value * 100) < 1e-7;
}

export function validateInvoiceTaxPayload(payload: Record<string, unknown>): string | null {
  const { is_tax_exempt: isTaxExempt, tax_rate: taxRate, tax_amount: taxAmount, total } = payload;

  if (isTaxExempt !== undefined && typeof isTaxExempt !== "boolean") {
    return "is_tax_exempt must be a boolean.";
  }
  if (taxRate !== undefined &&
    (typeof taxRate !== "number" || !Number.isFinite(taxRate) || taxRate < 0 || taxRate > 100 ||
      Math.abs(Math.round(taxRate * 100) - taxRate * 100) >= 1e-7)) {
    return "Tax rate must be between 0 and 100 with at most 2 decimal places.";
  }
  if (taxAmount !== undefined && !isMoney(taxAmount)) {
    return "Tax amount must be a non-negative amount with at most 2 decimal places.";
  }
  if (total !== undefined && !isMoney(total)) {
    return "Invoice total must be a non-negative amount with at most 2 decimal places.";
  }
  if (isTaxExempt === true &&
    ((taxRate !== undefined && taxRate !== 0) || (taxAmount !== undefined && taxAmount !== 0))) {
    return "Tax-exempt invoices must have a zero tax rate and tax amount.";
  }
  if (typeof taxAmount === "number" && typeof total === "number" && taxAmount > total) {
    return "Tax amount cannot exceed the invoice total.";
  }
  if (isTaxExempt === false &&
    typeof taxRate === "number" &&
    typeof taxAmount === "number" &&
    typeof total === "number") {
    const expectedTax = Math.round((total - taxAmount) * taxRate) / 100;
    if (Math.round(expectedTax * 100) !== Math.round(taxAmount * 100)) {
      return "Tax amount must match the invoice subtotal and tax rate.";
    }
  }
  return null;
}

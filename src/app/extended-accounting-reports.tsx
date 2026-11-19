"use client";

import { useMemo, useState } from "react";
import type { FormEvent } from "react";
import type { ReportRequest, ReportRow } from "./accounting-reports";

type Period = { fromDate: string; throughDate: string };

function todayInput() {
  const date = new Date();
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
}

function yearPeriod(): Period {
  const today = todayInput();
  return { fromDate: `${today.slice(0, 4)}-01-01`, throughDate: today };
}

function validDate(value: string) {
  const date = new Date(`${value}T00:00:00.000Z`);
  return /^\d{4}-\d{2}-\d{2}$/.test(value) && Number.isFinite(date.getTime()) &&
    date.toISOString().slice(0, 10) === value;
}

function cents(value: unknown) {
  const amount = Number(value ?? 0);
  return Number.isFinite(amount) ? Math.round(amount * 100) : 0;
}

function money(value: number, currency: string) {
  return new Intl.NumberFormat("en-US", { style: "currency", currency }).format(value / 100);
}

function displayDate(value: unknown) {
  const date = String(value ?? "");
  return validDate(date) ? new Date(`${date}T00:00:00`).toLocaleDateString() : "—";
}

function ReportHeading({ title, description, eyebrow = "ACCOUNTING REPORTS" }: {
  title: string;
  description: string;
  eyebrow?: string;
}) {
  return (
    <div className="page-heading list-heading">
      <div><p className="eyebrow">{eyebrow}</p><h1>{title}</h1><p className="muted">{description}</p></div>
    </div>
  );
}

function SummaryCard({ label, value }: { label: string; value: string }) {
  return <div className="panel" style={{ padding: 16 }}><p className="eyebrow">{label}</p><strong className="table-amount">{value}</strong></div>;
}

function PeriodFilters({ period, onChange }: { period: Period; onChange: (period: Period) => void }) {
  const invalid = !validDate(period.fromDate) || !validDate(period.throughDate) || period.fromDate > period.throughDate;
  return (
    <div className="ledger-filters income-statement-filters">
      <label>From<input type="date" value={period.fromDate} aria-invalid={invalid} onChange={(event) => onChange({ ...period, fromDate: event.target.value })} /></label>
      <label>Through<input type="date" value={period.throughDate} aria-invalid={invalid} onChange={(event) => onChange({ ...period, throughDate: event.target.value })} /></label>
      {invalid && <p className="field-error" role="alert">Enter a valid date range.</p>}
    </div>
  );
}

function EmptyReport({ message }: { message: string }) {
  return <div className="empty-state"><p>{message}</p></div>;
}

function isPostedEntry(entry: ReportRow | undefined, date: string) {
  return entry?.status === "posted" && validDate(date);
}

export function EquityChangesReport({
  accounts, journalEntries, journalLines, currency,
}: {
  accounts: ReportRow[];
  journalEntries: ReportRow[];
  journalLines: ReportRow[];
  currency: string;
}) {
  const [period, setPeriod] = useState(yearPeriod);
  const report = useMemo(() => {
    const accountById = new Map(accounts.map((account) => [String(account.id), account]));
    const entryById = new Map(journalEntries.map((entry) => [String(entry.id), entry]));
    const equityAccounts = accounts.filter((account) => account.type === "equity");
    const balances = new Map<string, { opening: number; movement: number }>(
      equityAccounts.map((account) => [String(account.id), { opening: 0, movement: 0 }]),
    );
    let netIncome = 0;
    for (const line of journalLines) {
      const entry = entryById.get(String(line.journal_entry_id));
      const date = String(entry?.entry_date ?? "");
      if (!isPostedEntry(entry, date) || date > period.throughDate) continue;
      const account = accountById.get(String(line.account_id));
      if (!account) continue;
      const amount = cents(line.amount);
      const signed = line.amount_code === "C" ? amount : -amount;
      if (account.type === "equity") {
        const balance = balances.get(String(account.id));
        if (balance) {
          if (date < period.fromDate) balance.opening += signed;
          else balance.movement += signed;
        }
      } else if (date >= period.fromDate) {
        if (account.type === "revenue") netIncome += signed;
        if (account.type === "expense") netIncome -= signed;
      }
    }
    const rows = equityAccounts.map((account) => {
      const balance = balances.get(String(account.id)) ?? { opening: 0, movement: 0 };
      return { account, ...balance, ending: balance.opening + balance.movement };
    }).sort((a, b) => String(a.account.code ?? "").localeCompare(String(b.account.code ?? ""), undefined, { numeric: true }));
    const opening = rows.reduce((sum, row) => sum + row.opening, 0);
    const directChange = rows.reduce((sum, row) => sum + row.movement, 0);
    return { rows, opening, directChange, netIncome, ending: opening + directChange + netIncome };
  }, [accounts, journalEntries, journalLines, period.fromDate, period.throughDate]);
  const invalid = !validDate(period.fromDate) || !validDate(period.throughDate) || period.fromDate > period.throughDate;

  return (
    <>
      <ReportHeading title="Statement of changes in equity" description="Opening and ending equity account balances plus posted equity activity and net income for the period." />
      <div className="panel table-panel">
        <PeriodFilters period={period} onChange={setPeriod} />
        {!invalid && (
          <>
            <div className="dashboard-grid" style={{ padding: 16 }}>
              <SummaryCard label="Opening equity" value={money(report.opening, currency)} />
              <SummaryCard label="Equity account activity" value={money(report.directChange, currency)} />
              <SummaryCard label="Period net income" value={money(report.netIncome, currency)} />
              <SummaryCard label="Estimated ending equity" value={money(report.ending, currency)} />
            </div>
            {report.rows.length ? <div className="table-scroll"><table>
              <thead><tr><th>Account</th><th>Opening balance</th><th>Period change</th><th>Ending balance</th></tr></thead>
              <tbody>
                {report.rows.map((row) => <tr key={String(row.account.id)}>
                  <td>{String(row.account.code ?? "")} · {String(row.account.name ?? "")}</td>
                  <td>{money(row.opening, currency)}</td><td>{money(row.movement, currency)}</td><td className="table-amount">{money(row.ending, currency)}</td>
                </tr>)}
              </tbody>
            </table></div> : <EmptyReport message="No equity accounts are available." />}
            <p className="muted" style={{ padding: "0 16px 16px" }}>Ending equity includes current-period net income; this estimate can differ if income-closing entries are posted during the period.</p>
          </>
        )}
      </div>
    </>
  );
}

type ForecastRow = { week: string; receivables: number; payables: number; net: number; ending: number };

function dateOffset(date: string, days: number) {
  const result = new Date(`${date}T00:00:00.000Z`);
  result.setUTCDate(result.getUTCDate() + days);
  return result.toISOString().slice(0, 10);
}

export function CashForecastReport({
  accounts, journalEntries, journalLines, invoices, invoicePayments, expenses, currency,
}: {
  accounts: ReportRow[];
  journalEntries: ReportRow[];
  journalLines: ReportRow[];
  invoices: ReportRow[];
  invoicePayments: ReportRow[];
  expenses: ReportRow[];
  currency: string;
}) {
  const [asOfDate, setAsOfDate] = useState(todayInput);
  const report = useMemo(() => {
    if (!validDate(asOfDate)) return { cash: 0, rows: [] };
    const accountIds = new Set(accounts
      .filter((account) => account.type === "asset" && String(account.code ?? "").startsWith("10"))
      .map((account) => String(account.id)));
    const entryById = new Map(journalEntries.map((entry) => [String(entry.id), entry]));
    let cash = 0;
    for (const line of journalLines) {
      const entry = entryById.get(String(line.journal_entry_id));
      const date = String(entry?.entry_date ?? "");
      if (!accountIds.has(String(line.account_id)) || !isPostedEntry(entry, date) || date > asOfDate) continue;
      cash += line.amount_code === "D" ? cents(line.amount) : -cents(line.amount);
    }
    const paymentsByInvoice = new Map<string, number>();
    for (const payment of invoicePayments) {
      const date = String(payment.payment_date ?? "");
      if (validDate(date) && date <= asOfDate) {
        const id = String(payment.invoice_id);
        paymentsByInvoice.set(id, (paymentsByInvoice.get(id) ?? 0) + cents(payment.amount));
      }
    }
    const weeks = new Map<string, { receivables: number; payables: number }>();
    const add = (date: string, key: "receivables" | "payables", amount: number) => {
      if (!validDate(date) || amount <= 0) return;
      const due = date < asOfDate ? asOfDate : date;
      const day = new Date(`${due}T00:00:00.000Z`);
      const weekday = (day.getUTCDay() + 6) % 7;
      day.setUTCDate(day.getUTCDate() - weekday);
      const week = day.toISOString().slice(0, 10);
      const current = weeks.get(week) ?? { receivables: 0, payables: 0 };
      current[key] += amount;
      weeks.set(week, current);
    };
    const horizon = dateOffset(asOfDate, 90);
    for (const invoice of invoices) {
      const status = String(invoice.status);
      const issue = String(invoice.issue_date ?? "");
      const due = String(invoice.due_date ?? "");
      if (!["sent", "overdue", "paid"].includes(status) || !validDate(issue) || issue > asOfDate || !validDate(due) || due > horizon) continue;
      const outstanding = Math.max(0, cents(invoice.total) - (paymentsByInvoice.get(String(invoice.id)) ?? 0));
      add(due, "receivables", outstanding);
    }
    for (const expense of expenses) {
      if (expense.status !== "unpaid") continue;
      const expenseDate = String(expense.expense_date ?? "");
      const due = validDate(String(expense.due_date ?? ""))
        ? String(expense.due_date)
        : validDate(expenseDate) ? dateOffset(expenseDate, 30) : "";
      if (due && due <= horizon && validDate(expenseDate) && expenseDate <= asOfDate) add(due, "payables", cents(expense.amount));
    }
    const first = new Date(`${asOfDate}T00:00:00.000Z`);
    const mondayOffset = (first.getUTCDay() + 6) % 7;
    first.setUTCDate(first.getUTCDate() - mondayOffset);
    let running = cash;
    const rows: ForecastRow[] = [];
    for (let weekIndex = 0; weekIndex < 13; weekIndex++) {
      const date = new Date(first);
      date.setUTCDate(date.getUTCDate() + weekIndex * 7);
      const week = date.toISOString().slice(0, 10);
      const flows = weeks.get(week) ?? { receivables: 0, payables: 0 };
      const net = flows.receivables - flows.payables;
      running += net;
      rows.push({ week, ...flows, net, ending: running });
    }
    return { cash, rows };
  }, [accounts, asOfDate, expenses, invoicePayments, invoices, journalEntries, journalLines]);
  const invalid = !validDate(asOfDate);

  return (
    <>
      <ReportHeading title="Cash position & forecast" description="Posted cash-account balances projected with open customer invoices and unpaid expenses due over the next 13 weeks." />
      <div className="panel table-panel">
        <div className="ledger-filters trial-balance-filters"><label>Cash as of<input type="date" value={asOfDate} aria-invalid={invalid} onChange={(event) => setAsOfDate(event.target.value)} /></label>{invalid && <p className="field-error" role="alert">Enter a valid date.</p>}</div>
        {!invalid && <>
          <div className="dashboard-grid" style={{ padding: 16 }}><SummaryCard label="Current cash position" value={money(report.cash, currency)} /><SummaryCard label="Projected ending cash" value={money(report.rows[report.rows.length - 1]?.ending ?? report.cash, currency)} /></div>
          <div className="table-scroll"><table>
            <thead><tr><th>Week of</th><th>Expected receipts</th><th>Expected payments</th><th>Net cash flow</th><th>Projected cash</th></tr></thead>
            <tbody>{report.rows.map((row) => <tr key={row.week}>
              <td>{displayDate(row.week)}</td><td>{money(row.receivables, currency)}</td><td>{money(row.payables, currency)}</td>
              <td>{money(row.net, currency)}</td><td className="table-amount">{money(row.ending, currency)}</td>
            </tr>)}</tbody>
          </table></div>
          <p className="muted" style={{ padding: "0 16px 16px" }}>Forecast assumes invoices and bills are paid on their due dates. Bills without a due date are estimated 30 days after the expense date.</p>
        </>}
      </div>
    </>
  );
}

export function SalesAnalysisReport({
  invoices, invoiceItems, contacts, inventory, currency,
}: {
  invoices: ReportRow[];
  invoiceItems: ReportRow[];
  contacts: ReportRow[];
  inventory: ReportRow[];
  currency: string;
}) {
  const [period, setPeriod] = useState(yearPeriod);
  const [groupBy, setGroupBy] = useState("item");
  const invalid = !validDate(period.fromDate) || !validDate(period.throughDate) || period.fromDate > period.throughDate;
  const result = useMemo(() => {
    const contactById = new Map(contacts.map((contact) => [String(contact.id), String(contact.name ?? "Customer")]));
    const itemById = new Map(inventory.map((item) => [String(item.id), String(item.name ?? "Item")]));
    const itemsByInvoice = new Map<string, ReportRow[]>();
    for (const item of invoiceItems) {
      const id = String(item.invoice_id);
      itemsByInvoice.set(id, [...(itemsByInvoice.get(id) ?? []), item]);
    }
    const grouped = new Map<string, { label: string; amount: number; invoiceIds: Set<string> }>();
    let total = 0;
    for (const invoice of invoices) {
      const date = String(invoice.issue_date ?? "");
      if (!["sent", "overdue", "paid"].includes(String(invoice.status)) ||
        !validDate(date) || date < period.fromDate || date > period.throughDate) continue;
      const invoiceId = String(invoice.id);
      const customer = contactById.get(String(invoice.contact_id)) ?? "Customer";
      const invoiceItemRows = itemsByInvoice.get(invoiceId) ?? [];
      const parts = invoiceItemRows.length
        ? invoiceItemRows.map((item) => ({
          item: itemById.get(String(item.inventory_id)) ?? String(item.description ?? "Sale"),
          amount: Math.round(Number(item.quantity ?? 0) * cents(item.unit_price)),
        }))
        : [{ item: "Unitemized sales", amount: Math.max(0, cents(invoice.total) - cents(invoice.tax_amount)) }];
      const reportParts = groupBy === "month"
        ? [{ item: date.slice(0, 7), amount: Math.max(0, cents(invoice.total) - cents(invoice.tax_amount)) }]
        : parts;
      for (const part of reportParts) {
        const key = groupBy === "customer" ? customer : groupBy === "month" ? date.slice(0, 7) : part.item;
        const bucket = grouped.get(key) ?? { label: key, amount: 0, invoiceIds: new Set<string>() };
        bucket.amount += part.amount;
        bucket.invoiceIds.add(invoiceId);
        grouped.set(key, bucket);
      }
      total += Math.max(0, cents(invoice.total) - cents(invoice.tax_amount));
    }
    return { total, rows: [...grouped.values()].sort((a, b) => b.amount - a.amount) };
  }, [contacts, groupBy, inventory, invoiceItems, invoices, period.fromDate, period.throughDate]);

  return (
    <>
      <ReportHeading title="Sales analysis" description="Net sales by customer, inventory item, or invoice month. Voided and draft invoices are excluded." />
      <div className="panel table-panel">
        <PeriodFilters period={period} onChange={setPeriod} />
        <div className="ledger-filters trial-balance-filters"><label>Group by<select value={groupBy} onChange={(event) => setGroupBy(event.target.value)}><option value="item">Item</option><option value="customer">Customer</option><option value="month">Month</option></select></label></div>
        {!invalid && <>
          <div className="dashboard-grid" style={{ padding: 16 }}><SummaryCard label="Net sales" value={money(result.total, currency)} /><SummaryCard label="Groups" value={String(result.rows.length)} /></div>
          {result.rows.length ? <div className="table-scroll"><table>
            <thead><tr><th>{groupBy === "customer" ? "Customer" : groupBy === "month" ? "Month" : "Item"}</th><th>Invoices</th><th>Net sales</th></tr></thead>
            <tbody>{result.rows.map((row) => <tr key={row.label}><td>{row.label}</td><td>{row.invoiceIds.size}</td><td className="table-amount">{money(row.amount, currency)}</td></tr>)}</tbody>
          </table></div> : <EmptyReport message="No sales in this period." />}
        </>}
      </div>
    </>
  );
}

export function ExpenseAnalysisReport({
  expenses, accounts, contacts, currency,
}: {
  expenses: ReportRow[];
  accounts: ReportRow[];
  contacts: ReportRow[];
  currency: string;
}) {
  const [period, setPeriod] = useState(yearPeriod);
  const [groupBy, setGroupBy] = useState("account");
  const invalid = !validDate(period.fromDate) || !validDate(period.throughDate) || period.fromDate > period.throughDate;
  const result = useMemo(() => {
    const accountById = new Map(accounts.map((account) => [String(account.id), `${String(account.code ?? "")} · ${String(account.name ?? "Expense")}`]));
    const contactById = new Map(contacts.map((contact) => [String(contact.id), String(contact.name ?? "Payee")]));
    const grouped = new Map<string, { amount: number; count: number }>();
    for (const expense of expenses) {
      const date = String(expense.expense_date ?? "");
      if (expense.status === "void" || !validDate(date) || date < period.fromDate || date > period.throughDate) continue;
      const label = groupBy === "vendor" ? contactById.get(String(expense.contact_id)) ?? "Unassigned vendor"
        : groupBy === "month" ? date.slice(0, 7)
          : accountById.get(String(expense.account_id)) ?? "Unassigned account";
      const bucket = grouped.get(label) ?? { amount: 0, count: 0 };
      bucket.amount += cents(expense.amount);
      bucket.count += 1;
      grouped.set(label, bucket);
    }
    return [...grouped.entries()].map(([label, row]) => ({ label, ...row }))
      .sort((a, b) => b.amount - a.amount);
  }, [accounts, contacts, expenses, groupBy, period.fromDate, period.throughDate]);
  const total = result.reduce((sum, row) => sum + row.amount, 0);

  return (
    <>
      <ReportHeading title="Expense analysis" description="Non-void expense records grouped by expense account, vendor, or month." />
      <div className="panel table-panel">
        <PeriodFilters period={period} onChange={setPeriod} />
        <div className="ledger-filters trial-balance-filters"><label>Group by<select value={groupBy} onChange={(event) => setGroupBy(event.target.value)}><option value="account">Expense account</option><option value="vendor">Vendor</option><option value="month">Month</option></select></label></div>
        {!invalid && <>
          <div className="dashboard-grid" style={{ padding: 16 }}><SummaryCard label="Total expenses" value={money(total, currency)} /><SummaryCard label="Transactions" value={String(result.reduce((sum, row) => sum + row.count, 0))} /></div>
          {result.length ? <div className="table-scroll"><table>
            <thead><tr><th>{groupBy === "vendor" ? "Vendor" : groupBy === "month" ? "Month" : "Expense account"}</th><th>Transactions</th><th>Amount</th></tr></thead>
            <tbody>{result.map((row) => <tr key={row.label}><td>{row.label}</td><td>{row.count}</td><td className="table-amount">{money(row.amount, currency)}</td></tr>)}</tbody>
          </table></div> : <EmptyReport message="No expenses in this period." />}
        </>}
      </div>
    </>
  );
}

export function InventoryMovementReport({
  inventory, movements, currency, organizationId, request, refreshData,
}: {
  inventory: ReportRow[];
  movements: ReportRow[];
  currency: string;
  organizationId: string;
  request: ReportRequest;
  refreshData: () => Promise<void>;
}) {
  const [inventoryId, setInventoryId] = useState("");
  const [type, setType] = useState("receipt");
  const [quantity, setQuantity] = useState("");
  const [unitCost, setUnitCost] = useState("");
  const [movementDate, setMovementDate] = useState(todayInput);
  const [reference, setReference] = useState("");
  const [notes, setNotes] = useState("");
  const [error, setError] = useState("");
  const [saving, setSaving] = useState(false);
  const itemById = useMemo(() => new Map(inventory.map((item) => [String(item.id), item])), [inventory]);
  const lowStock = inventory.filter((item) => item.is_active !== false &&
    Number(item.reorder_level ?? 0) > 0 && Number(item.quantity_on_hand ?? 0) <= Number(item.reorder_level));
  const sortedMovements = [...movements].sort((a, b) => String(b.movement_date).localeCompare(String(a.movement_date)));

  async function addMovement(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const amount = Number(quantity);
    if (!inventoryId || !validDate(movementDate) || !Number.isFinite(amount) ||
      (type === "adjustment" ? amount === 0 : amount <= 0)) {
      setError("Choose an item and date, then enter a non-zero quantity. Adjustments may be positive or negative.");
      return;
    }
    setSaving(true);
    setError("");
    try {
      const selectedItem = itemById.get(inventoryId);
      const quantityChange = type === "issue" ? -Math.abs(amount) : amount;
      await request("inventory-movements", "POST", {
        organization_id: organizationId,
        inventory_id: inventoryId,
        movement_type: type,
        quantity_change: quantityChange,
        unit_cost: Number(unitCost || selectedItem?.unit_cost || 0),
        movement_date: movementDate,
        reference: reference.trim() || null,
        notes: notes.trim() || null,
      });
      setQuantity("");
      setReference("");
      setNotes("");
      await refreshData();
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : String(reason));
    } finally {
      setSaving(false);
    }
  }

  return (
    <>
      <ReportHeading eyebrow="INVENTORY REPORTS" title="Inventory movement & reorder" description="Record stock receipts, issues, and adjustments; review movement history and items at or below their reorder level." />
      <div className="panel table-panel">
        <form className="ledger-filters report-entry-form" onSubmit={addMovement}>
          <label>Item<select required value={inventoryId} onChange={(event) => setInventoryId(event.target.value)}><option value="">Select an inventory item</option>{inventory.map((item) => <option key={String(item.id)} value={String(item.id)}>{String(item.sku)} · {String(item.name)}</option>)}</select></label>
          <label>Movement<select value={type} onChange={(event) => setType(event.target.value)}><option value="receipt">Receipt</option><option value="issue">Issue</option><option value="adjustment">Adjustment</option></select></label>
          <label>Quantity{type === "adjustment" ? " (+/-)" : ""}<input type="number" step="0.001" value={quantity} onChange={(event) => setQuantity(event.target.value)} required /></label>
          <label>Unit cost<input type="number" min="0" step="0.01" value={unitCost} onChange={(event) => setUnitCost(event.target.value)} /></label>
          <label>Date<input type="date" value={movementDate} onChange={(event) => setMovementDate(event.target.value)} required /></label>
          <label>Reference<input value={reference} maxLength={100} onChange={(event) => setReference(event.target.value)} /></label>
          <label>Notes<input value={notes} maxLength={500} onChange={(event) => setNotes(event.target.value)} /></label>
          <button className="primary-button" disabled={saving || inventory.length === 0}>{saving ? "Saving…" : "Record movement"}</button>
          {error && <p className="field-error" role="alert">{error}</p>}
        </form>
        <div className="dashboard-grid" style={{ padding: 16 }}><SummaryCard label="Items to reorder" value={String(lowStock.length)} /><SummaryCard label="Tracked movements" value={String(movements.length)} /></div>
        <h2 style={{ padding: "0 16px" }}>Reorder list</h2>
        {lowStock.length ? <div className="table-scroll"><table>
          <thead><tr><th>SKU</th><th>Item</th><th>On hand</th><th>Reorder at</th><th>Value on hand</th></tr></thead>
          <tbody>{lowStock.map((item) => <tr key={String(item.id)}><td>{String(item.sku)}</td><td>{String(item.name)}</td><td>{Number(item.quantity_on_hand).toLocaleString()}</td><td>{Number(item.reorder_level).toLocaleString()}</td><td>{money(Math.round(Number(item.quantity_on_hand) * cents(item.unit_cost)), currency)}</td></tr>)}</tbody>
        </table></div> : <EmptyReport message="No active inventory items are below their reorder level." />}
        <h2 style={{ padding: "16px 16px 0" }}>Movement history</h2>
        {sortedMovements.length ? <div className="table-scroll"><table>
          <thead><tr><th>Date</th><th>SKU / item</th><th>Type</th><th>Quantity change</th><th>Unit cost</th><th>Reference</th><th>Notes</th></tr></thead>
          <tbody>{sortedMovements.map((movement) => {
            const item = itemById.get(String(movement.inventory_id));
            return <tr key={String(movement.id)}><td>{displayDate(movement.movement_date)}</td><td>{item ? `${String(item.sku)} · ${String(item.name)}` : "Deleted item"}</td><td>{String(movement.movement_type)}</td><td>{Number(movement.quantity_change).toLocaleString()}</td><td>{money(cents(movement.unit_cost), currency)}</td><td>{String(movement.reference ?? "—")}</td><td>{String(movement.notes ?? "—")}</td></tr>;
          })}</tbody>
        </table></div> : <EmptyReport message="No inventory movements are recorded." />}
      </div>
    </>
  );
}

function accumulatedDepreciation(asset: ReportRow, throughDate: string) {
  const acquired = String(asset.acquisition_date ?? "");
  if (!validDate(acquired) || throughDate < acquired) return 0;
  const endDate = validDate(String(asset.disposed_date ?? "")) && String(asset.disposed_date) < throughDate
    ? String(asset.disposed_date) : throughDate;
  if (endDate < acquired) return 0;
  const months = Math.max(0,
    (Number(endDate.slice(0, 4)) - Number(acquired.slice(0, 4))) * 12 +
    Number(endDate.slice(5, 7)) - Number(acquired.slice(5, 7)) + 1);
  const base = Math.max(0, cents(asset.cost) - cents(asset.salvage_value));
  const life = Math.max(1, Number(asset.useful_life_months));
  return Math.min(base, Math.round(base * Math.min(months, life) / life));
}

export function FixedAssetReport({
  assets, currency, organizationId, request, refreshData,
}: {
  assets: ReportRow[];
  currency: string;
  organizationId: string;
  request: ReportRequest;
  refreshData: () => Promise<void>;
}) {
  const [throughDate, setThroughDate] = useState(todayInput);
  const [draft, setDraft] = useState({ name: "", asset_number: "", category: "", acquisition_date: todayInput(), cost: "", salvage_value: "0", useful_life_months: "60", disposed_date: "", notes: "" });
  const [error, setError] = useState("");
  const [saving, setSaving] = useState(false);
  const rows = assets.map((asset) => {
    const accumulated = accumulatedDepreciation(asset, throughDate);
    const depreciableBase = Math.max(0, cents(asset.cost) - cents(asset.salvage_value));
    return {
      asset,
      accumulated,
      netBookValue: Math.max(cents(asset.salvage_value), cents(asset.cost) - accumulated),
      monthly: Math.round(depreciableBase / Math.max(1, Number(asset.useful_life_months))),
    };
  }).sort((a, b) => String(a.asset.acquisition_date).localeCompare(String(b.asset.acquisition_date)));

  async function addAsset(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!validDate(draft.acquisition_date) || (draft.disposed_date && !validDate(draft.disposed_date)) ||
      Number(draft.cost) <= 0 || Number(draft.salvage_value) < 0 ||
      Number(draft.salvage_value) > Number(draft.cost) || !Number.isInteger(Number(draft.useful_life_months)) ||
      Number(draft.useful_life_months) <= 0) {
      setError("Enter valid dates, cost, salvage value, and a positive whole-number useful life.");
      return;
    }
    setSaving(true);
    setError("");
    try {
      await request("fixed-assets", "POST", {
        organization_id: organizationId,
        ...draft,
        category: draft.category.trim() || "Other",
        cost: Number(draft.cost),
        salvage_value: Number(draft.salvage_value),
        useful_life_months: Number(draft.useful_life_months),
        disposed_date: draft.disposed_date || null,
        notes: draft.notes.trim() || null,
      });
      setDraft({ name: "", asset_number: "", category: "", acquisition_date: todayInput(), cost: "", salvage_value: "0", useful_life_months: "60", disposed_date: "", notes: "" });
      await refreshData();
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : String(reason));
    } finally {
      setSaving(false);
    }
  }

  async function deleteAsset(id: string) {
    if (!window.confirm("Delete this fixed asset record?")) return;
    try {
      await request("fixed-assets", "DELETE", undefined, id);
      await refreshData();
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : String(reason));
    }
  }

  const invalidDate = !validDate(throughDate);
  return (
    <>
      <ReportHeading eyebrow="FIXED ASSETS" title="Fixed asset & depreciation schedule" description="Straight-line depreciation, calculated monthly with the acquisition month treated as a full month. This schedule is informational and does not post journal entries." />
      <div className="panel table-panel">
        <form className="ledger-filters report-entry-form" onSubmit={addAsset}>
          <label>Asset name<input value={draft.name} maxLength={160} onChange={(event) => setDraft({ ...draft, name: event.target.value })} required /></label>
          <label>Asset number<input value={draft.asset_number} maxLength={64} onChange={(event) => setDraft({ ...draft, asset_number: event.target.value })} required /></label>
          <label>Category<input value={draft.category} maxLength={80} onChange={(event) => setDraft({ ...draft, category: event.target.value })} /></label>
          <label>Acquisition date<input type="date" value={draft.acquisition_date} onChange={(event) => setDraft({ ...draft, acquisition_date: event.target.value })} required /></label>
          <label>Cost<input type="number" min="0.01" step="0.01" value={draft.cost} onChange={(event) => setDraft({ ...draft, cost: event.target.value })} required /></label>
          <label>Salvage value<input type="number" min="0" step="0.01" value={draft.salvage_value} onChange={(event) => setDraft({ ...draft, salvage_value: event.target.value })} required /></label>
          <label>Useful life (months)<input type="number" min="1" step="1" value={draft.useful_life_months} onChange={(event) => setDraft({ ...draft, useful_life_months: event.target.value })} required /></label>
          <label>Disposed date<input type="date" value={draft.disposed_date} onChange={(event) => setDraft({ ...draft, disposed_date: event.target.value })} /></label>
          <label>Notes<input value={draft.notes} maxLength={500} onChange={(event) => setDraft({ ...draft, notes: event.target.value })} /></label>
          <button className="primary-button" disabled={saving}>{saving ? "Saving…" : "Add fixed asset"}</button>
          {error && <p className="field-error" role="alert">{error}</p>}
        </form>
        <div className="ledger-filters trial-balance-filters"><label>Schedule as of<input type="date" value={throughDate} aria-invalid={invalidDate} onChange={(event) => setThroughDate(event.target.value)} /></label></div>
        {!invalidDate && <>
          <div className="dashboard-grid" style={{ padding: 16 }}>
            <SummaryCard label="Asset cost" value={money(rows.reduce((sum, row) => sum + cents(row.asset.cost), 0), currency)} />
            <SummaryCard label="Accumulated depreciation" value={money(rows.reduce((sum, row) => sum + row.accumulated, 0), currency)} />
            <SummaryCard label="Net book value" value={money(rows.reduce((sum, row) => sum + row.netBookValue, 0), currency)} />
          </div>
          {rows.length ? <div className="table-scroll"><table>
            <thead><tr><th>Asset</th><th>Category</th><th>Acquired</th><th>Cost</th><th>Monthly depreciation</th><th>Accumulated depreciation</th><th>Net book value</th><th></th></tr></thead>
            <tbody>{rows.map((row) => <tr key={String(row.asset.id)}>
              <td>{String(row.asset.asset_number)} · {String(row.asset.name)}</td><td>{String(row.asset.category)}</td><td>{displayDate(row.asset.acquisition_date)}</td>
              <td>{money(cents(row.asset.cost), currency)}</td><td>{money(row.monthly, currency)}</td><td>{money(row.accumulated, currency)}</td>
              <td className="table-amount">{money(row.netBookValue, currency)}</td><td><button type="button" className="secondary-button" onClick={() => deleteAsset(String(row.asset.id))}>Delete</button></td>
            </tr>)}</tbody>
          </table></div> : <EmptyReport message="No fixed assets have been added." />}
        </>}
      </div>
    </>
  );
}

export function PayrollTaxReport({
  payments, currency, organizationId, request, refreshData,
}: {
  payments: ReportRow[];
  currency: string;
  organizationId: string;
  request: ReportRequest;
  refreshData: () => Promise<void>;
}) {
  const currentYear = String(new Date().getFullYear());
  const [year, setYear] = useState(currentYear);
  const [draft, setDraft] = useState({ payee_name: "", payee_type: "employee", payment_date: todayInput(), gross_amount: "", income_tax_withheld: "0", other_tax_withheld: "0", reference: "", notes: "" });
  const [error, setError] = useState("");
  const [saving, setSaving] = useState(false);
  const rows = useMemo(() => {
    const grouped = new Map<string, { name: string; type: string; gross: number; incomeTax: number; otherTax: number; payments: number }>();
    for (const payment of payments) {
      const date = String(payment.payment_date ?? "");
      if (!validDate(date) || date.slice(0, 4) !== year) continue;
      const name = String(payment.payee_name ?? "Payee");
      const type = String(payment.payee_type ?? "employee");
      const key = `${type}:${name}`;
      const row = grouped.get(key) ?? { name, type, gross: 0, incomeTax: 0, otherTax: 0, payments: 0 };
      row.gross += cents(payment.gross_amount);
      row.incomeTax += cents(payment.income_tax_withheld);
      row.otherTax += cents(payment.other_tax_withheld);
      row.payments += 1;
      grouped.set(key, row);
    }
    return [...grouped.values()].sort((a, b) => a.type.localeCompare(b.type) || a.name.localeCompare(b.name));
  }, [payments, year]);
  const yearPayments = payments.filter((payment) =>
    validDate(String(payment.payment_date ?? "")) && String(payment.payment_date).slice(0, 4) === year)
    .sort((a, b) => String(b.payment_date).localeCompare(String(a.payment_date)));
  const totals = rows.reduce((sum, row) => ({
    gross: sum.gross + row.gross,
    incomeTax: sum.incomeTax + row.incomeTax,
    otherTax: sum.otherTax + row.otherTax,
    net: sum.net + row.gross - row.incomeTax - row.otherTax,
  }), { gross: 0, incomeTax: 0, otherTax: 0, net: 0 });

  async function addPayment(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const gross = Number(draft.gross_amount);
    const incomeTax = Number(draft.income_tax_withheld);
    const otherTax = Number(draft.other_tax_withheld);
    if (!validDate(draft.payment_date) || !Number.isFinite(gross) || gross <= 0 ||
      !Number.isFinite(incomeTax) || !Number.isFinite(otherTax) || incomeTax < 0 || otherTax < 0 ||
      incomeTax + otherTax > gross) {
      setError("Enter a valid payment date and gross amount; withholding cannot exceed gross pay.");
      return;
    }
    setSaving(true);
    setError("");
    try {
      await request("payroll-payments", "POST", {
        organization_id: organizationId,
        ...draft,
        payee_name: draft.payee_name.trim(),
        gross_amount: gross,
        income_tax_withheld: incomeTax,
        other_tax_withheld: otherTax,
        reference: draft.reference.trim() || null,
        notes: draft.notes.trim() || null,
      });
      setDraft({ payee_name: "", payee_type: "employee", payment_date: todayInput(), gross_amount: "", income_tax_withheld: "0", other_tax_withheld: "0", reference: "", notes: "" });
      await refreshData();
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : String(reason));
    } finally {
      setSaving(false);
    }
  }

  async function deletePayment(payment: ReportRow) {
    if (!window.confirm(`Delete the payment recorded for ${String(payment.payee_name)}?`)) return;
    setError("");
    try {
      await request("payroll-payments", "DELETE", undefined, String(payment.id));
      await refreshData();
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : String(reason));
    }
  }

  return (
    <>
      <ReportHeading eyebrow="PAYROLL REPORTS" title="Payroll & contractor tax summary" description="Annual gross payments and recorded withholding by employee or contractor. This is a bookkeeping summary, not a tax filing or compliance determination." />
      <div className="panel table-panel">
        <form className="ledger-filters report-entry-form" onSubmit={addPayment}>
          <label>Payee<input value={draft.payee_name} maxLength={160} onChange={(event) => setDraft({ ...draft, payee_name: event.target.value })} required /></label>
          <label>Type<select value={draft.payee_type} onChange={(event) => setDraft({ ...draft, payee_type: event.target.value })}><option value="employee">Employee</option><option value="contractor">Contractor</option></select></label>
          <label>Pay date<input type="date" value={draft.payment_date} onChange={(event) => setDraft({ ...draft, payment_date: event.target.value })} required /></label>
          <label>Gross pay<input type="number" min="0.01" step="0.01" value={draft.gross_amount} onChange={(event) => setDraft({ ...draft, gross_amount: event.target.value })} required /></label>
          <label>Income tax withheld<input type="number" min="0" step="0.01" value={draft.income_tax_withheld} onChange={(event) => setDraft({ ...draft, income_tax_withheld: event.target.value })} required /></label>
          <label>Other tax withheld<input type="number" min="0" step="0.01" value={draft.other_tax_withheld} onChange={(event) => setDraft({ ...draft, other_tax_withheld: event.target.value })} required /></label>
          <label>Reference<input value={draft.reference} maxLength={100} onChange={(event) => setDraft({ ...draft, reference: event.target.value })} /></label>
          <label>Notes<input value={draft.notes} maxLength={500} onChange={(event) => setDraft({ ...draft, notes: event.target.value })} /></label>
          <button className="primary-button" disabled={saving}>{saving ? "Saving…" : "Record payment"}</button>
          {error && <p className="field-error" role="alert">{error}</p>}
        </form>
        <div className="ledger-filters trial-balance-filters"><label>Tax year<input type="number" min="1900" max="9999" step="1" value={year} onChange={(event) => setYear(event.target.value)} /></label></div>
        <div className="dashboard-grid" style={{ padding: 16 }}>
          <SummaryCard label="Gross paid" value={money(totals.gross, currency)} /><SummaryCard label="Income tax withheld" value={money(totals.incomeTax, currency)} />
          <SummaryCard label="Other tax withheld" value={money(totals.otherTax, currency)} /><SummaryCard label="Net paid" value={money(totals.net, currency)} />
        </div>
        {rows.length ? <div className="table-scroll"><table>
          <thead><tr><th>Payee</th><th>Type</th><th>Payments</th><th>Gross paid</th><th>Income tax withheld</th><th>Other tax withheld</th><th>Net paid</th></tr></thead>
          <tbody>{rows.map((row) => <tr key={`${row.type}:${row.name}`}>
            <td>{row.name}</td><td>{row.type === "contractor" ? "Contractor" : "Employee"}</td><td>{row.payments}</td>
            <td>{money(row.gross, currency)}</td><td>{money(row.incomeTax, currency)}</td><td>{money(row.otherTax, currency)}</td>
            <td className="table-amount">{money(row.gross - row.incomeTax - row.otherTax, currency)}</td>
          </tr>)}</tbody>
        </table></div> : <EmptyReport message={`No payroll or contractor payments recorded for ${year}.`} />}
        {yearPayments.length > 0 && <div className="table-scroll">
          <table>
            <thead><tr><th>Payment date</th><th>Payee</th><th>Type</th><th>Gross</th><th>Income tax</th><th>Other tax</th><th>Reference</th><th>Action</th></tr></thead>
            <tbody>{yearPayments.map((payment) => <tr key={String(payment.id)}>
              <td>{displayDate(payment.payment_date)}</td><td>{String(payment.payee_name)}</td><td>{String(payment.payee_type)}</td>
              <td>{money(cents(payment.gross_amount), currency)}</td><td>{money(cents(payment.income_tax_withheld), currency)}</td>
              <td>{money(cents(payment.other_tax_withheld), currency)}</td><td>{String(payment.reference ?? "—")}</td>
              <td><button type="button" className="secondary-button" onClick={() => deletePayment(payment)}>Delete</button></td>
            </tr>)}</tbody>
          </table>
        </div>}
      </div>
    </>
  );
}

"use client";

import { useMemo, useState } from "react";
import type { FormEvent } from "react";

export type ReportRow = Record<string, string | number | boolean | null>;
export type ReportRequest = (
  resource: string,
  method: string,
  body?: Record<string, unknown>,
  id?: string,
) => Promise<unknown>;

const agingBuckets = ["Current", "1–30 days", "31–60 days", "61–90 days", "Over 90 days", "No due date"] as const;
type AgingBucket = (typeof agingBuckets)[number];
type Period = { fromDate: string; throughDate: string };

function todayInput() {
  const date = new Date();
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
}

function currentYearPeriod(): Period {
  const today = todayInput();
  return { fromDate: `${today.slice(0, 4)}-01-01`, throughDate: today };
}

function isValidDate(value: string) {
  const date = new Date(`${value}T00:00:00.000Z`);
  return /^\d{4}-\d{2}-\d{2}$/.test(value) && Number.isFinite(date.getTime()) &&
    date.toISOString().slice(0, 10) === value;
}

function cents(value: unknown) {
  const amount = Number(value ?? 0);
  return Number.isFinite(amount) ? Math.round(amount * 100) : 0;
}

function money(valueInCents: number, currency: string) {
  return new Intl.NumberFormat("en-US", { style: "currency", currency }).format(valueInCents / 100);
}

function displayDate(value: unknown) {
  const date = String(value ?? "");
  if (!isValidDate(date)) return "—";
  return new Date(`${date}T00:00:00`).toLocaleDateString();
}

function text(value: unknown, fallback = "—") {
  const result = String(value ?? "").trim();
  return result || fallback;
}

function dateRangeIsValid(period: Period) {
  return isValidDate(period.fromDate) && isValidDate(period.throughDate) &&
    period.fromDate <= period.throughDate;
}

function ReportHeading({ eyebrow, title, description }: { eyebrow: string; title: string; description: string }) {
  return (
    <div className="page-heading list-heading">
      <div>
        <p className="eyebrow">{eyebrow}</p>
        <h1>{title}</h1>
        <p className="muted">{description}</p>
      </div>
    </div>
  );
}

function PeriodFilters({
  period,
  onChange,
  error,
}: {
  period: Period;
  onChange: (next: Period) => void;
  error: boolean;
}) {
  return (
    <div className="ledger-filters income-statement-filters">
      <label>
        From
        <input
          type="date"
          value={period.fromDate}
          aria-invalid={error && !isValidDate(period.fromDate)}
          onChange={(event) => onChange({ ...period, fromDate: event.target.value })}
        />
      </label>
      <label>
        Through
        <input
          type="date"
          value={period.throughDate}
          aria-invalid={error && !isValidDate(period.throughDate)}
          onChange={(event) => onChange({ ...period, throughDate: event.target.value })}
        />
      </label>
      {error && <p className="field-error">Enter a valid date range.</p>}
    </div>
  );
}

function SummaryCard({ label, value }: { label: string; value: string }) {
  return (
    <div className="panel" style={{ padding: 16 }}>
      <p className="eyebrow">{label}</p>
      <strong className="table-amount">{value}</strong>
    </div>
  );
}

function EmptyReport({ message }: { message: string }) {
  return <div className="empty-state"><p>{message}</p></div>;
}

type CashActivity = { inflows: number; outflows: number };
const cashFlowCategories = ["operating", "investing", "financing", "unclassified"] as const;

export function CashFlowReport({
  accounts,
  journalEntries,
  journalLines,
  currency,
}: {
  accounts: ReportRow[];
  journalEntries: ReportRow[];
  journalLines: ReportRow[];
  currency: string;
}) {
  const [period, setPeriod] = useState(currentYearPeriod);
  const invalid = !dateRangeIsValid(period);
  const report = useMemo(() => {
    const accountById = new Map(accounts.map((account) => [String(account.id), account]));
    const cashAccountIds = new Set(accounts
      .filter((account) => account.type === "asset" && String(account.code ?? "").startsWith("10"))
      .map((account) => String(account.id)));
    const linesByEntry = new Map<string, ReportRow[]>();
    for (const line of journalLines) {
      const entryId = String(line.journal_entry_id ?? "");
      linesByEntry.set(entryId, [...(linesByEntry.get(entryId) ?? []), line]);
    }

    const activity = new Map<string, CashActivity>(
      cashFlowCategories.map((category) => [category, { inflows: 0, outflows: 0 }]),
    );
    let openingBalance = 0;
    for (const entry of journalEntries) {
      const entryDate = String(entry.entry_date ?? "");
      if (entry.status !== "posted" || !isValidDate(entryDate) || entryDate > period.throughDate) continue;
      const lines = linesByEntry.get(String(entry.id)) ?? [];
      const cashLines = lines.filter((line) => cashAccountIds.has(String(line.account_id)));
      if (!cashLines.length) continue;
      if (entryDate < period.fromDate) {
        openingBalance += cashLines.reduce((sum, line) =>
          sum + (line.amount_code === "D" ? cents(line.amount) : -cents(line.amount)), 0);
        continue;
      }

      const counterpartLines = lines.filter((line) => !cashAccountIds.has(String(line.account_id)));
      if (!counterpartLines.length) continue;
      for (const cashLine of cashLines) {
        const cashAmount = cents(cashLine.amount);
        const totalWeight = counterpartLines.reduce((sum, line) => sum + cents(line.amount), 0);
        if (cashAmount <= 0 || totalWeight <= 0) continue;
        let allocated = 0;
        counterpartLines.forEach((counterpart, index) => {
          const share = index === counterpartLines.length - 1
            ? cashAmount - allocated
            : Math.round(cashAmount * cents(counterpart.amount) / totalWeight);
          allocated += share;
          const categoryValue = accountById.get(String(counterpart.account_id))?.cash_flow_category;
          const category = cashFlowCategories.find((value) => value === categoryValue) ?? "unclassified";
          const item = activity.get(category) ?? { inflows: 0, outflows: 0 };
          if (cashLine.amount_code === "D") item.inflows += share;
          else item.outflows += share;
          activity.set(category, item);
        });
      }
    }
    const rows = cashFlowCategories.map((category) => ({
      category,
      ...activity.get(category)!,
      net: activity.get(category)!.inflows - activity.get(category)!.outflows,
    }));
    const netChange = rows.reduce((sum, row) => sum + row.net, 0);
    return { rows, openingBalance, netChange, endingBalance: openingBalance + netChange };
  }, [accounts, journalEntries, journalLines, period.fromDate, period.throughDate]);

  return (
    <>
      <ReportHeading eyebrow="FINANCIAL REPORTS" title="Cash flow statement"
        description="Cash movement from posted journal entries, grouped by the category assigned to each account." />
      <div className="panel table-panel">
        <PeriodFilters period={period} onChange={setPeriod} error={invalid} />
        {!invalid && (
          <>
            <div className="dashboard-grid" style={{ padding: 16 }}>
              <SummaryCard label="Beginning cash" value={money(report.openingBalance, currency)} />
              <SummaryCard label="Net cash change" value={money(report.netChange, currency)} />
              <SummaryCard label="Ending cash" value={money(report.endingBalance, currency)} />
            </div>
            <div className="table-scroll">
              <table>
                <thead><tr><th>Activity</th><th>Cash inflows</th><th>Cash outflows</th><th>Net cash flow</th></tr></thead>
                <tbody>
                  {report.rows.map((row) => (
                    <tr key={row.category}>
                      <td className="table-amount">{row.category === "unclassified" ? "Unclassified" : `${row.category[0].toUpperCase()}${row.category.slice(1)}`}</td>
                      <td>{money(row.inflows, currency)}</td><td>{money(row.outflows, currency)}</td>
                      <td className="table-amount">{money(row.net, currency)}</td>
                    </tr>
                  ))}
                  <tr><td className="table-amount">Net change in cash</td><td>—</td><td>—</td><td className="table-amount">{money(report.netChange, currency)}</td></tr>
                </tbody>
              </table>
            </div>
          </>
        )}
      </div>
    </>
  );
}

type AgingRow = { id: string; counterparty: string; reference: string; dueDate: string; amount: number; bucket: AgingBucket };

function agingBucket(dueDate: string, asOfDate: string): AgingBucket {
  if (!isValidDate(dueDate)) return "No due date";
  const overdueDays = Math.floor((Date.parse(`${asOfDate}T00:00:00Z`) - Date.parse(`${dueDate}T00:00:00Z`)) / 86400000);
  if (overdueDays <= 0) return "Current";
  if (overdueDays <= 30) return "1–30 days";
  if (overdueDays <= 60) return "31–60 days";
  if (overdueDays <= 90) return "61–90 days";
  return "Over 90 days";
}

function AgingReportTable({ rows, currency, emptyMessage }: { rows: AgingRow[]; currency: string; emptyMessage: string }) {
  const totals = new Map<AgingBucket, number>(agingBuckets.map((bucket) => [bucket, 0]));
  for (const row of rows) totals.set(row.bucket, (totals.get(row.bucket) ?? 0) + row.amount);
  const total = rows.reduce((sum, row) => sum + row.amount, 0);
  return (
    <div className="panel table-panel">
      <div className="dashboard-grid" style={{ padding: 16 }}>
        {agingBuckets.map((bucket) => <SummaryCard key={bucket} label={bucket} value={money(totals.get(bucket) ?? 0, currency)} />)}
      </div>
      {rows.length ? (
        <div className="table-scroll"><table>
          <thead><tr><th>Customer / vendor</th><th>Reference</th><th>Due date</th><th>Aging</th><th>Outstanding</th></tr></thead>
          <tbody>
            {rows.map((row) => <tr key={row.id}><td>{row.counterparty}</td><td>{row.reference}</td><td>{displayDate(row.dueDate)}</td><td>{row.bucket}</td><td className="table-amount">{money(row.amount, currency)}</td></tr>)}
            <tr><td colSpan={4} className="table-amount">Total outstanding</td><td className="table-amount">{money(total, currency)}</td></tr>
          </tbody>
        </table></div>
      ) : <EmptyReport message={emptyMessage} />}
    </div>
  );
}

export function ReceivablesAgingReport({
  contacts,
  invoices,
  invoicePayments,
  currency,
}: {
  contacts: ReportRow[];
  invoices: ReportRow[];
  invoicePayments: ReportRow[];
  currency: string;
}) {
  const [asOfDate, setAsOfDate] = useState(todayInput);
  const invalid = !isValidDate(asOfDate);
  const rows = useMemo(() => {
    if (invalid) return [];
    const contactById = new Map(contacts.map((contact) => [String(contact.id), contact]));
    const paymentsByInvoice = new Map<string, number>();
    for (const payment of invoicePayments) {
      const date = String(payment.payment_date ?? "");
      if (isValidDate(date) && date <= asOfDate) {
        const invoiceId = String(payment.invoice_id ?? "");
        paymentsByInvoice.set(invoiceId, (paymentsByInvoice.get(invoiceId) ?? 0) + cents(payment.amount));
      }
    }
    return invoices.flatMap((invoice) => {
      const issueDate = String(invoice.issue_date ?? "");
      if (!["sent", "overdue", "paid"].includes(String(invoice.status)) ||
        !isValidDate(issueDate) || issueDate > asOfDate) return [];
      const outstanding = Math.max(0, cents(invoice.total) - (paymentsByInvoice.get(String(invoice.id)) ?? 0));
      if (!outstanding) return [];
      const dueDate = String(invoice.due_date ?? "");
      const contact = contactById.get(String(invoice.contact_id));
      return [{
        id: String(invoice.id),
        counterparty: text(contact?.name, "Customer"),
        reference: text(invoice.invoice_number, "Invoice"),
        dueDate,
        amount: outstanding,
        bucket: agingBucket(dueDate, asOfDate),
      }];
    }).sort((a, b) => agingBuckets.indexOf(a.bucket) - agingBuckets.indexOf(b.bucket) ||
      a.dueDate.localeCompare(b.dueDate) || a.reference.localeCompare(b.reference, undefined, { numeric: true }));
  }, [asOfDate, contacts, invalid, invoices, invoicePayments]);

  return (
    <>
      <ReportHeading eyebrow="RECEIVABLES" title="Accounts receivable aging"
        description="Outstanding sent and overdue invoices, net of payments recorded through the selected date." />
      <div className="panel table-panel">
        <div className="ledger-filters trial-balance-filters">
          <label>As of<input type="date" value={asOfDate} aria-invalid={invalid} onChange={(event) => setAsOfDate(event.target.value)} /></label>
          {invalid && <p className="field-error">Enter a valid date.</p>}
        </div>
      </div>
      {!invalid && <AgingReportTable rows={rows} currency={currency} emptyMessage="No outstanding invoices as of this date." />}
    </>
  );
}

export function PayablesAgingReport({
  contacts,
  expenses,
  currency,
}: {
  contacts: ReportRow[];
  expenses: ReportRow[];
  currency: string;
}) {
  const [asOfDate, setAsOfDate] = useState(todayInput);
  const invalid = !isValidDate(asOfDate);
  const rows = useMemo(() => {
    if (invalid) return [];
    const contactById = new Map(contacts.map((contact) => [String(contact.id), contact]));
    return expenses.flatMap((expense) => {
      const paymentDate = String(expense.payment_date ?? "");
      const outstandingAsOfDate = expense.status === "unpaid" ||
        (expense.status === "paid" && isValidDate(paymentDate) && paymentDate > asOfDate);
      if (!outstandingAsOfDate || !isValidDate(String(expense.expense_date ?? "")) ||
        String(expense.expense_date) > asOfDate) return [];
      const dueDate = String(expense.due_date ?? "");
      return [{
        id: String(expense.id),
        counterparty: text(contactById.get(String(expense.contact_id))?.name, "Unassigned vendor"),
        reference: text(expense.description, `Expense ${String(expense.id ?? "").slice(0, 8)}`),
        dueDate,
        amount: cents(expense.amount),
        bucket: agingBucket(dueDate, asOfDate),
      }];
    }).sort((a, b) => agingBuckets.indexOf(a.bucket) - agingBuckets.indexOf(b.bucket) ||
      a.dueDate.localeCompare(b.dueDate) || a.reference.localeCompare(b.reference));
  }, [asOfDate, contacts, expenses, invalid]);

  return (
    <>
      <ReportHeading eyebrow="PAYABLES" title="Accounts payable aging"
        description="Unpaid expenses by due date. Vendor expenses are tracked as fully paid or unpaid; partial payments are not currently recorded." />
      <div className="panel table-panel">
        <div className="ledger-filters trial-balance-filters">
          <label>As of<input type="date" value={asOfDate} aria-invalid={invalid} onChange={(event) => setAsOfDate(event.target.value)} /></label>
          {invalid && <p className="field-error">Enter a valid date.</p>}
        </div>
      </div>
      {!invalid && <AgingReportTable rows={rows} currency={currency} emptyMessage="No unpaid expenses as of this date." />}
    </>
  );
}

export function SalesTaxReport({ invoices, currency }: { invoices: ReportRow[]; currency: string }) {
  const [period, setPeriod] = useState(currentYearPeriod);
  const invalid = !dateRangeIsValid(period);
  const groups = useMemo(() => {
    if (invalid) return [];
    const byRate = new Map<string, { rate: number; taxableSales: number; tax: number; count: number }>();
    for (const invoice of invoices) {
      const issueDate = String(invoice.issue_date ?? "");
      if (!["sent", "overdue", "paid"].includes(String(invoice.status)) ||
        !isValidDate(issueDate) || issueDate < period.fromDate || issueDate > period.throughDate) continue;
      if (invoice.is_tax_exempt === true) {
        continue;
      }
      const rate = Number(invoice.tax_rate ?? 0);
      const key = String(rate);
      const group = byRate.get(key) ?? { rate, taxableSales: 0, tax: 0, count: 0 };
      group.taxableSales += Math.max(0, cents(invoice.total) - cents(invoice.tax_amount));
      group.tax += cents(invoice.tax_amount);
      group.count += 1;
      byRate.set(key, group);
    }
    return [...byRate.values()].sort((a, b) => a.rate - b.rate).map((group) => ({ ...group, key: String(group.rate) }));
  }, [invalid, invoices, period.fromDate, period.throughDate]);
  const taxTotal = groups.reduce((sum, group) => sum + group.tax, 0);

  return (
    <>
      <ReportHeading eyebrow="TAX REPORTS" title="Sales tax report"
        description="Sales tax collected on sent, overdue, and paid invoices issued in the selected period." />
      <div className="panel table-panel">
        <PeriodFilters period={period} onChange={setPeriod} error={invalid} />
        {!invalid && (
          <>
            <div className="dashboard-grid" style={{ padding: 16 }}>
              <SummaryCard label="Tax collected" value={money(taxTotal, currency)} />
              <SummaryCard label="Tax-exempt sales" value={money(exemptSalesTotal(invoices, period), currency)} />
            </div>
            {groups.length ? <div className="table-scroll"><table>
              <thead><tr><th>Tax rate</th><th>Invoices</th><th>Taxable sales</th><th>Tax collected</th></tr></thead>
              <tbody>
                {groups.map((group) => <tr key={group.key}><td>{group.rate}%</td><td>{group.count}</td><td>{money(group.taxableSales, currency)}</td><td className="table-amount">{money(group.tax, currency)}</td></tr>)}
                <tr><td colSpan={3} className="table-amount">Total tax collected</td><td className="table-amount">{money(taxTotal, currency)}</td></tr>
              </tbody>
            </table></div> : <EmptyReport message="No taxable invoices in this period." />}
          </>
        )}
      </div>
    </>
  );
}

function exemptSalesTotal(invoices: ReportRow[], period: Period) {
  return invoices.reduce((sum, invoice) => {
    const date = String(invoice.issue_date ?? "");
    if (invoice.is_tax_exempt !== true || !["sent", "overdue", "paid"].includes(String(invoice.status)) ||
      !isValidDate(date) || date < period.fromDate || date > period.throughDate) return sum;
    return sum + Math.max(0, cents(invoice.total) - cents(invoice.tax_amount));
  }, 0);
}

export function JournalEntriesReport({
  accounts,
  journalEntries,
  journalLines,
  currency,
}: {
  accounts: ReportRow[];
  journalEntries: ReportRow[];
  journalLines: ReportRow[];
  currency: string;
}) {
  const [period, setPeriod] = useState(currentYearPeriod);
  const [status, setStatus] = useState("all");
  const invalid = !dateRangeIsValid(period);
  const accountById = useMemo(() => new Map(accounts.map((account) => [String(account.id), account])), [accounts]);
  const entries = useMemo(() => journalEntries
    .filter((entry) => {
      const date = String(entry.entry_date ?? "");
      return !invalid && isValidDate(date) && date >= period.fromDate && date <= period.throughDate &&
        (status === "all" || entry.status === status);
    })
    .sort((a, b) => String(b.entry_date).localeCompare(String(a.entry_date))), [invalid, journalEntries, period.fromDate, period.throughDate, status]);
  const linesByEntry = useMemo(() => {
    const map = new Map<string, ReportRow[]>();
    for (const line of journalLines) {
      const id = String(line.journal_entry_id ?? "");
      map.set(id, [...(map.get(id) ?? []), line]);
    }
    return map;
  }, [journalLines]);
  const totalDebits = entries.reduce((sum, entry) => sum + (linesByEntry.get(String(entry.id)) ?? [])
    .reduce((lineSum, line) => lineSum + (line.amount_code === "D" ? cents(line.amount) : 0), 0), 0);
  const totalCredits = entries.reduce((sum, entry) => sum + (linesByEntry.get(String(entry.id)) ?? [])
    .reduce((lineSum, line) => lineSum + (line.amount_code === "C" ? cents(line.amount) : 0), 0), 0);

  return (
    <>
      <ReportHeading eyebrow="ACCOUNTING REPORTS" title="Journal entries report"
        description="Browse journal entries and their debit and credit lines by date and posting status." />
      <div className="panel table-panel">
        <PeriodFilters period={period} onChange={setPeriod} error={invalid} />
        <div className="ledger-filters trial-balance-filters">
          <label>Status<select value={status} onChange={(event) => setStatus(event.target.value)}>
            <option value="all">All statuses</option><option value="posted">Posted</option><option value="draft">Draft</option><option value="void">Void</option>
          </select></label>
        </div>
        {!invalid && (entries.length ? (
          <>
            <div className="table-scroll"><table>
              <thead><tr><th>Date</th><th>Status</th><th>Description / reference</th><th>Account</th><th>Line description</th><th>Debit</th><th>Credit</th></tr></thead>
              <tbody>{entries.map((entry) => {
                const lines = linesByEntry.get(String(entry.id)) ?? [];
                return lines.length ? lines.map((line, index) => {
                  const account = accountById.get(String(line.account_id));
                  return <tr key={`${entry.id}-${line.id ?? index}`}>
                    <td>{displayDate(entry.entry_date)}</td><td><span className={`status-pill status-${String(entry.status)}`}>{text(entry.status)}</span></td>
                    <td>{text(entry.description)}{entry.reference ? ` · ${String(entry.reference)}` : ""}</td>
                    <td>{account ? `${text(account.code)} · ${text(account.name)}` : "Unknown account"}</td>
                    <td>{text(line.description)}</td><td>{line.amount_code === "D" ? money(cents(line.amount), currency) : "—"}</td>
                    <td>{line.amount_code === "C" ? money(cents(line.amount), currency) : "—"}</td>
                  </tr>;
                }) : <tr key={String(entry.id)}><td>{displayDate(entry.entry_date)}</td><td>{text(entry.status)}</td><td>{text(entry.description)}</td><td colSpan={4}>No journal lines</td></tr>;
              })}</tbody>
              <tfoot><tr><th colSpan={5}>Period totals</th><th>{money(totalDebits, currency)}</th><th>{money(totalCredits, currency)}</th></tr></tfoot>
            </table></div>
          </>
        ) : <EmptyReport message="No journal entries match the selected filters." />)}
      </div>
    </>
  );
}

export function InventoryValuationReport({ inventory, currency }: { inventory: ReportRow[]; currency: string }) {
  const rows = useMemo((): (ReportRow & { quantityValue: number; unitCostCents: number; value: number })[] => inventory.map((item) => ({
    ...item,
    quantityValue: Number(item.quantity_on_hand ?? 0),
    unitCostCents: cents(item.unit_cost),
  })).map((item) => ({ ...item, value: Math.round(item.quantityValue * item.unitCostCents) }))
    .sort((a, b) => b.value - a.value), [inventory]);
  const total = rows.reduce((sum, row) => sum + row.value, 0);

  return (
    <>
      <ReportHeading eyebrow="INVENTORY REPORTS" title="Inventory valuation"
        description="Current inventory quantity multiplied by current unit cost; this is a snapshot, not historical FIFO or LIFO costing." />
      <div className="panel table-panel">
        <div className="dashboard-grid" style={{ padding: 16 }}><SummaryCard label="Total inventory value" value={money(total, currency)} /><SummaryCard label="Items on hand" value={String(rows.filter((row) => row.quantityValue > 0).length)} /></div>
        {rows.length ? <div className="table-scroll"><table>
          <thead><tr><th>SKU</th><th>Item</th><th>Unit</th><th>Quantity on hand</th><th>Unit cost</th><th>Inventory value</th></tr></thead>
          <tbody>
            {rows.map((row) => <tr key={String(row.id)}><td>{text(row.sku)}</td><td>{text(row.name)}</td><td>{text(row.unit)}</td><td>{row.quantityValue.toLocaleString()}</td><td>{money(row.unitCostCents, currency)}</td><td className="table-amount">{money(row.value, currency)}</td></tr>)}
            <tr><td colSpan={5} className="table-amount">Total inventory value</td><td className="table-amount">{money(total, currency)}</td></tr>
          </tbody>
        </table></div> : <EmptyReport message="No inventory items to value." />}
      </div>
    </>
  );
}

function monthInputValue(date = new Date()) {
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}`;
}

function monthStart(value: string) {
  return `${value}-01`;
}

export function BudgetVsActualReport({
  budgets,
  accounts,
  journalEntries,
  journalLines,
  currency,
  organizationId,
  request,
  refreshData,
}: {
  budgets: ReportRow[];
  accounts: ReportRow[];
  journalEntries: ReportRow[];
  journalLines: ReportRow[];
  currency: string;
  organizationId: string;
  request: ReportRequest;
  refreshData: () => Promise<void>;
}) {
  const [month, setMonth] = useState(monthInputValue);
  const [accountId, setAccountId] = useState("");
  const [budgetDraft, setBudgetDraft] = useState<{ key: string; value: string } | null>(null);
  const [error, setError] = useState("");
  const [saving, setSaving] = useState(false);
  const chosenMonth = month ? monthStart(month) : "";
  const reportRows = useMemo(() => {
    const eligibleAccounts = accounts.filter((account) =>
      ["revenue", "expense"].includes(String(account.type)) && account.is_active !== false);
    const entryById = new Map(journalEntries.map((entry) => [String(entry.id), entry]));
    const actualByAccount = new Map<string, number>();
    for (const line of journalLines) {
      const entry = entryById.get(String(line.journal_entry_id));
      const date = String(entry?.entry_date ?? "");
      if (!month || entry?.status !== "posted" || !date.startsWith(month) || !isValidDate(date)) continue;
      const account = accounts.find((item) => String(item.id) === String(line.account_id));
      if (!account || !["revenue", "expense"].includes(String(account.type))) continue;
      const signedAmount = account.type === "revenue"
        ? (line.amount_code === "C" ? cents(line.amount) : -cents(line.amount))
        : (line.amount_code === "D" ? cents(line.amount) : -cents(line.amount));
      const id = String(line.account_id);
      actualByAccount.set(id, (actualByAccount.get(id) ?? 0) + signedAmount);
    }
    const budgetByAccount = new Map(budgets.filter((budget) => String(budget.budget_month) === chosenMonth)
      .map((budget) => [String(budget.account_id), budget]));
    return eligibleAccounts.map((account) => {
      const budget = budgetByAccount.get(String(account.id));
      const budgetCents = cents(budget?.amount);
      const actualCents = actualByAccount.get(String(account.id)) ?? 0;
      return { account, budget, budgetCents, actualCents, varianceCents: actualCents - budgetCents };
    }).sort((a, b) => String(a.account.code ?? "").localeCompare(String(b.account.code ?? ""), undefined, { numeric: true }));
  }, [accounts, budgets, chosenMonth, journalEntries, journalLines, month]);
  const totalBudget = reportRows.reduce((sum, row) => sum + row.budgetCents, 0);
  const totalActual = reportRows.reduce((sum, row) => sum + row.actualCents, 0);
  const accountOptions = accounts.filter((account) => ["revenue", "expense"].includes(String(account.type)) && account.is_active !== false);
  const existingBudget = budgets.find((budget) => String(budget.account_id) === accountId && String(budget.budget_month) === chosenMonth);
  const budgetDraftKey = `${chosenMonth}:${accountId}`;
  const amount = budgetDraft?.key === budgetDraftKey ? budgetDraft.value : String(existingBudget?.amount ?? "");

  async function saveBudget(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const numericAmount = Number(amount);
    if (!accountId || !chosenMonth || !Number.isFinite(numericAmount) || numericAmount < 0 || !/^\d+(\.\d{1,2})?$/.test(amount)) {
      setError("Choose an account and enter a non-negative amount with up to two decimals.");
      return;
    }
    setSaving(true);
    setError("");
    try {
      const body = { account_id: accountId, budget_month: chosenMonth, amount: numericAmount };
      await request("account-budgets", existingBudget ? "PATCH" : "POST",
        existingBudget ? body : { ...body, organization_id: organizationId }, existingBudget ? String(existingBudget.id) : undefined);
      await refreshData();
      setBudgetDraft(null);
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : String(reason));
    } finally {
      setSaving(false);
    }
  }

  async function deleteBudget(budget: ReportRow) {
    if (!window.confirm("Delete this account budget?")) return;
    setSaving(true);
    setError("");
    try {
      await request("account-budgets", "DELETE", undefined, String(budget.id));
      await refreshData();
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : String(reason));
    } finally {
      setSaving(false);
    }
  }

  return (
    <>
      <ReportHeading eyebrow="PLANNING REPORTS" title="Budget vs. actual"
        description="Compare monthly account budgets with posted journal activity. Enter budgets by revenue or expense account." />
      <div className="panel table-panel">
        <div className="ledger-filters income-statement-filters">
          <label>Budget month<input type="month" value={month} onChange={(event) => setMonth(event.target.value)} /></label>
        </div>
        <form className="ledger-filters report-entry-form" onSubmit={saveBudget}>
          <label>Account<select value={accountId} required onChange={(event) => setAccountId(event.target.value)}>
            <option value="">Select a revenue or expense account</option>
            {accountOptions.map((account) => <option key={String(account.id)} value={String(account.id)}>{text(account.code)} · {text(account.name)}</option>)}
          </select></label>
          <label>Monthly budget<input type="number" min="0" step="0.01" value={amount} onChange={(event) => setBudgetDraft({ key: budgetDraftKey, value: event.target.value })} required /></label>
          <button className="primary-button" disabled={saving || !month || !accountId}>{saving ? "Saving…" : existingBudget ? "Update budget" : "Add budget"}</button>
          {error && <p className="field-error" role="alert">{error}</p>}
        </form>
        <div className="dashboard-grid" style={{ padding: 16 }}>
          <SummaryCard label="Total budget" value={money(totalBudget, currency)} />
          <SummaryCard label="Total actual" value={money(totalActual, currency)} />
          <SummaryCard label="Net variance (actual − budget)" value={money(totalActual - totalBudget, currency)} />
        </div>
        {reportRows.length ? <div className="table-scroll"><table>
          <thead><tr><th>Account</th><th>Type</th><th>Budget</th><th>Actual</th><th>Variance (actual − budget)</th><th>Action</th></tr></thead>
          <tbody>
            {reportRows.map((row) => <tr key={String(row.account.id)}>
              <td>{text(row.account.code)} · {text(row.account.name)}</td><td>{text(row.account.type)}</td>
              <td>{row.budget ? money(row.budgetCents, currency) : "No budget"}</td><td>{money(row.actualCents, currency)}</td>
              <td className="table-amount">{money(row.varianceCents, currency)}</td>
              <td>{row.budget ? <button className="secondary-button" type="button" disabled={saving} onClick={() => deleteBudget(row.budget!)}>Delete budget</button> : "—"}</td>
            </tr>)}
          </tbody>
        </table></div> : <EmptyReport message="No revenue or expense accounts are available." />}
      </div>
    </>
  );
}

export function BankReconciliationReport({
  accounts,
  journalEntries,
  journalLines,
  reconciliations,
  reconciliationItems,
  currency,
  organizationId,
  request,
  refreshData,
}: {
  accounts: ReportRow[];
  journalEntries: ReportRow[];
  journalLines: ReportRow[];
  reconciliations: ReportRow[];
  reconciliationItems: ReportRow[];
  currency: string;
  organizationId: string;
  request: ReportRequest;
  refreshData: () => Promise<void>;
}) {
  const cashAccounts = useMemo(() => accounts
    .filter((account) => account.type === "asset" && String(account.code ?? "").startsWith("10"))
    .sort((a, b) => String(a.code).localeCompare(String(b.code), undefined, { numeric: true })), [accounts]);
  const [accountId, setAccountId] = useState("");
  const activeAccountId = accountId || String(cashAccounts[0]?.id ?? "");
  const [statementDate, setStatementDate] = useState(todayInput);
  const [reconciliationDraft, setReconciliationDraft] = useState<{
    key: string;
    beginningBalance: string;
    endingBalance: string;
    clearedLineIds: Set<string>;
  } | null>(null);
  const [error, setError] = useState("");
  const [saving, setSaving] = useState(false);

  const matchingReconciliation = reconciliations.find((item) =>
    String(item.account_id) === activeAccountId && String(item.statement_date) === statementDate);
  const previousReconciliation = reconciliations
    .filter((item) => String(item.account_id) === activeAccountId &&
      isValidDate(String(item.statement_date ?? "")) && String(item.statement_date) < statementDate)
    .sort((a, b) => String(b.statement_date).localeCompare(String(a.statement_date)))[0];
  const previousItemIds = useMemo(() => new Set(reconciliationItems
    .filter((item) => String(item.reconciliation_id) === String(previousReconciliation?.id) && item.is_cleared === false)
    .map((item) => String(item.journal_line_id))), [previousReconciliation?.id, reconciliationItems]);
  const entryById = useMemo(() => new Map(journalEntries.map((entry) => [String(entry.id), entry])), [journalEntries]);
  const currentItems = reconciliationItems.filter((item) =>
    String(item.reconciliation_id) === String(matchingReconciliation?.id));
  const reconciliationDraftKey = `${activeAccountId}:${statementDate}`;
  const currentDraft = reconciliationDraft?.key === reconciliationDraftKey ? reconciliationDraft : null;
  const initialClearedLineIds = new Set(currentItems
    .filter((item) => item.is_cleared === true)
    .map((item) => String(item.journal_line_id)));
  const clearedLineIds = currentDraft?.clearedLineIds ?? initialClearedLineIds;

  const candidateLines = useMemo(() => journalLines.flatMap((line) => {
    const entry = entryById.get(String(line.journal_entry_id));
    const date = String(entry?.entry_date ?? "");
    const afterPrevious = !previousReconciliation || date > String(previousReconciliation.statement_date);
    const carriesForward = previousItemIds.has(String(line.id));
    if (String(line.account_id) !== activeAccountId || entry?.status !== "posted" ||
      !isValidDate(date) || date > statementDate || (!afterPrevious && !carriesForward)) return [];
    return [{ line, entry }];
  }).sort((a, b) => String(a.entry.entry_date).localeCompare(String(b.entry.entry_date)) ||
    String(a.entry.description ?? "").localeCompare(String(b.entry.description ?? ""))), [
    activeAccountId, entryById, journalLines, previousItemIds, previousReconciliation, statementDate,
  ]);
  const beginningBalance = previousReconciliation
    ? Number(previousReconciliation.ending_balance)
    : Number(currentDraft?.beginningBalance ?? matchingReconciliation?.beginning_balance ?? "0");
  const endingBalance = currentDraft?.endingBalance ?? String(matchingReconciliation?.ending_balance ?? "");
  const clearedBalance = candidateLines.reduce((sum, item) => {
    if (!clearedLineIds.has(String(item.line.id))) return sum;
    return sum + (item.line.amount_code === "D" ? cents(item.line.amount) : -cents(item.line.amount));
  }, 0);
  const endingCents = Number.isFinite(Number(endingBalance)) ? Math.round(Number(endingBalance) * 100) : 0;
  const difference = endingCents - (Math.round(beginningBalance * 100) + clearedBalance);

  function toggleLine(lineId: string) {
    const next = new Set(clearedLineIds);
    if (next.has(lineId)) next.delete(lineId);
    else next.add(lineId);
    setReconciliationDraft({
      key: reconciliationDraftKey,
      beginningBalance: String(beginningBalance),
      endingBalance,
      clearedLineIds: next,
    });
  }

  async function saveReconciliation() {
    if (!activeAccountId || !isValidDate(statementDate) || !Number.isFinite(beginningBalance) ||
      !endingBalance || !Number.isFinite(Number(endingBalance))) {
      setError("Select an account and statement date, then enter valid beginning and ending balances.");
      return;
    }
    setSaving(true);
    setError("");
    try {
      const balanced = difference === 0;
      const record = await request("bank-reconciliations", matchingReconciliation ? "PATCH" : "POST", {
        account_id: activeAccountId,
        statement_date: statementDate,
        beginning_balance: beginningBalance,
        ending_balance: Number(endingBalance),
        status: balanced ? "reconciled" : "draft",
        ...(!matchingReconciliation ? { organization_id: organizationId } : {}),
      }, matchingReconciliation ? String(matchingReconciliation.id) : undefined);
      if (!record || typeof record !== "object" || !("id" in record)) {
        throw new Error("The reconciliation was saved without returning its record ID.");
      }
      const reconciliationId = String(record.id);
      await Promise.all(candidateLines.map(({ line }) => {
        const existing = currentItems.find((item) => String(item.journal_line_id) === String(line.id));
        const body = {
          reconciliation_id: reconciliationId,
          journal_line_id: String(line.id),
          is_cleared: clearedLineIds.has(String(line.id)),
        };
        return request("bank-reconciliation-items", existing ? "PATCH" : "POST",
          existing ? body : { ...body, organization_id: organizationId },
          existing ? String(existing.id) : undefined);
      }));
      await refreshData();
      setReconciliationDraft(null);
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : String(reason));
    } finally {
      setSaving(false);
    }
  }

  return (
    <>
      <ReportHeading eyebrow="CASH MANAGEMENT" title="Bank reconciliation"
        description="Match posted cash-account journal lines to the statement. A reconciliation is complete when the difference is zero." />
      <div className="panel table-panel">
        {!cashAccounts.length ? <EmptyReport message="No cash accounts were found. Add an asset account with a code beginning with 10." /> : (
          <>
            <div className="ledger-filters">
              <label>Cash account<select value={activeAccountId} onChange={(event) => setAccountId(event.target.value)}>
                {cashAccounts.map((account) => <option key={String(account.id)} value={String(account.id)}>{text(account.code)} · {text(account.name)}</option>)}
              </select></label>
              <label>Statement date<input type="date" value={statementDate} aria-invalid={!isValidDate(statementDate)} onChange={(event) => setStatementDate(event.target.value)} /></label>
              <label>Beginning balance<input type="number" step="0.01" value={String(currentDraft?.beginningBalance ?? beginningBalance.toFixed(2))}
                readOnly={Boolean(previousReconciliation)} onChange={(event) => setReconciliationDraft({
                  key: reconciliationDraftKey,
                  beginningBalance: event.target.value,
                  endingBalance,
                  clearedLineIds,
                })} /></label>
              <label>Statement ending balance<input type="number" step="0.01" value={endingBalance} onChange={(event) => setReconciliationDraft({
                key: reconciliationDraftKey,
                beginningBalance: String(beginningBalance),
                endingBalance: event.target.value,
                clearedLineIds,
              })} /></label>
            </div>
            <div className="dashboard-grid" style={{ padding: 16 }}>
              <SummaryCard label="Cleared balance" value={money(Math.round(beginningBalance * 100) + clearedBalance, currency)} />
              <SummaryCard label="Statement ending balance" value={endingBalance ? money(endingCents, currency) : "—"} />
              <SummaryCard label="Difference" value={money(difference, currency)} />
            </div>
            {candidateLines.length ? <div className="table-scroll"><table>
              <thead><tr><th>Cleared</th><th>Date</th><th>Transaction</th><th>Reference</th><th>Debit</th><th>Credit</th></tr></thead>
              <tbody>{candidateLines.map(({ line, entry }) => <tr key={String(line.id)}>
                <td><input aria-label={`Mark ${text(entry.description, "journal line")} cleared`}
                  type="checkbox" checked={clearedLineIds.has(String(line.id))} onChange={() => toggleLine(String(line.id))} /></td>
                <td>{displayDate(entry.entry_date)}</td><td>{text(line.description, text(entry.description))}</td>
                <td>{text(entry.reference)}</td><td>{line.amount_code === "D" ? money(cents(line.amount), currency) : "—"}</td>
                <td>{line.amount_code === "C" ? money(cents(line.amount), currency) : "—"}</td>
              </tr>)}</tbody>
            </table></div> : <EmptyReport message="No posted cash transactions are available for this statement period." />}
            <div style={{ display: "flex", justifyContent: "flex-end", padding: 16 }}>
              <button type="button" className="primary-button" disabled={saving || !isValidDate(statementDate)} onClick={saveReconciliation}>
                {saving ? "Saving…" : matchingReconciliation ? "Update reconciliation" : "Save reconciliation"}
              </button>
            </div>
            {error && <p className="field-error" role="alert" style={{ padding: "0 16px 16px" }}>{error}</p>}
            {matchingReconciliation && <p className="muted" style={{ padding: "0 16px 16px" }}>
              Current status: <span className={`status-pill status-${String(matchingReconciliation.status)}`}>{text(matchingReconciliation.status)}</span>
            </p>}
          </>
        )}
      </div>
    </>
  );
}

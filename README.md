# Ledgerly Accounting

A Next.js and Tailwind CSS accounting MVP with Supabase Auth, a relational Postgres schema, row-level security, and REST CRUD endpoints.

## Features

- Supabase email/password sign-up and sign-in; each user gets a private business workspace.
- Dashboard with invoice, expense, and contact summaries.
- CRUD for accounts, contacts, invoices, expenses, journal entries, and journal lines.
- Double-entry journal constraints; posted entries must balance and their lines are immutable.
- Tenant-scoped row-level security and composite foreign keys to prevent cross-organization references.
- Responsive interface for desktop and mobile.

## Run locally

1. Create a Supabase project.
2. In the Supabase SQL editor, run [`supabase/schema.sql`](supabase/schema.sql). For an existing installation, run [`supabase/migrate_journal_lines_to_amount.sql`](supabase/migrate_journal_lines_to_amount.sql) if it still has debit/credit columns, then run [`supabase/add_inventory_table.sql`](supabase/add_inventory_table.sql).
3. Copy `.env.example` to `.env.local` and set your project URL and anon/publishable key.
4. In Supabase Auth settings, configure the site URL and redirect URLs for your local and deployed app. Email confirmation may be enabled or disabled to suit your project.
5. Install and start the app:

   ```sh
   npm install
   npm run dev
   ```

The app is available at `http://localhost:3000`. New users get a workspace and a starter chart of accounts on first sign-in.

## REST API

All endpoints require `Authorization: Bearer <supabase-access-token>`. Collection routes for organization-owned data also require `organizationId` as a query parameter. Supabase RLS provides the final authorization boundary.

| Resource | Collection endpoint |
| --- | --- |
| Organizations | `/api/organizations` |
| Accounts | `/api/accounts` |
| Inventory | `/api/inventory` |
| Contacts | `/api/contacts` |
| Invoices | `/api/invoices` |
| Invoice items | `/api/invoice-items` |
| Expenses | `/api/expenses` |
| Journal entries | `/api/journal-entries` |
| Journal lines | `/api/journal-lines` |

Use `GET` and `POST` on a collection; use `GET`, `PATCH`, and `DELETE` on `/api/{resource}/{id}`. Collection `GET` accepts `?organizationId=<uuid>` except for organizations, which are scoped to the signed-in owner. Create requests for tenant-owned data must include `organization_id`; the API only accepts resource-specific writable fields and the database verifies ownership and relationships.

Inventory items are managed through `/api/inventory`. `invoice_items.inventory_id` is optional, preserving free-form service lines, and is cleared if its inventory item is deleted.

Example:

```http
POST /api/contacts
Authorization: Bearer <supabase-access-token>
Content-Type: application/json

{
  "organization_id": "<organization-uuid>",
  "name": "Northwind Studio",
  "type": "customer",
  "email": "billing@example.com"
}
```

Amounts are stored as `numeric` values in the database. For production use, add migrations, automated tests, backups, audit trails, and a deployment-specific Supabase Auth redirect configuration.

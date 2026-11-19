-- Apply after the existing report/accounting migrations and add_extended_reports.sql.
begin;

create table if not exists public.organization_members (
  organization_id uuid not null references public.organizations(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (organization_id, user_id)
);

alter table public.organization_members enable row level security;
grant select, insert, delete on public.organization_members to authenticated;

create or replace function public.has_organization_access(p_organization_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select auth.uid() is not null and (
    exists (
      select 1 from public.organizations o
      where o.id = p_organization_id and o.owner_id = auth.uid()
    )
    or exists (
      select 1 from public.organization_members m
      where m.organization_id = p_organization_id and m.user_id = auth.uid()
    )
  );
$$;

revoke all on function public.has_organization_access(uuid) from public, anon;
grant execute on function public.has_organization_access(uuid) to authenticated;

drop policy if exists "Members can read their organization memberships" on public.organization_members;
create policy "Members can read their organization memberships"
on public.organization_members for select
using (
  user_id = auth.uid()
  or exists (
    select 1 from public.organizations o
    where o.id = organization_id and o.owner_id = auth.uid()
  )
);

drop policy if exists "Owners manage organization memberships" on public.organization_members;
create policy "Owners manage organization memberships"
on public.organization_members for all
using (
  exists (
    select 1 from public.organizations o
    where o.id = organization_id and o.owner_id = auth.uid()
  )
)
with check (
  exists (
    select 1 from public.organizations o
    where o.id = organization_id and o.owner_id = auth.uid()
  )
);

drop policy if exists "Members can read shared organizations" on public.organizations;
create policy "Members can read shared organizations"
on public.organizations for select
using (public.has_organization_access(id));

do $$
declare
  table_name text;
  policy_record record;
  tables text[] := array[
    'accounts', 'inventory', 'contacts', 'invoices', 'invoice_items',
    'invoice_payments', 'expenses', 'journal_entries', 'journal_lines',
    'account_budgets', 'bank_reconciliations', 'bank_reconciliation_items',
    'inventory_movements', 'fixed_assets', 'payroll_payments'
  ];
begin
  foreach table_name in array tables
  loop
    if to_regclass(format('%I.%I', 'public', table_name)) is null then
      raise exception 'Required table public.% is missing; apply the report/accounting migrations first.', table_name;
    end if;
  end loop;

  for policy_record in
    select tablename, policyname
    from pg_policies
    where schemaname = 'public'
      and tablename = any(tables)
      and policyname like 'Organization owners manage%'
  loop
    execute format('drop policy %I on public.%I',
      policy_record.policyname, policy_record.tablename);
  end loop;

  foreach table_name in array tables
  loop
    execute format(
      'create policy %I on public.%I for all using (public.has_organization_access(organization_id)) with check (public.has_organization_access(organization_id))',
      'Organization members manage ' || table_name, table_name
    );
  end loop;
end;
$$;

do $$
declare
  v_owner_id uuid;
  v_member_id uuid;
  v_organization_id uuid;
begin
  select id into v_owner_id from auth.users
  where lower(email) = 'apollo.estrella@gmail.com';

  select id into v_member_id from auth.users
  where lower(email) = 'adminledgerly@gmail.com';

  if v_owner_id is null or v_member_id is null then
    raise exception 'Both demo accounts must exist in Supabase Auth before sharing the organization.';
  end if;

  select id into v_organization_id from public.organizations
  where owner_id = v_owner_id;

  if v_organization_id is null then
    raise exception 'The organization owned by apollo.estrella@gmail.com was not found.';
  end if;

  insert into public.organization_members (organization_id, user_id)
  values (v_organization_id, v_member_id)
  on conflict do nothing;
end;
$$;

do $$
declare
  v_signature text;
  v_definition text;
begin
  foreach v_signature in array array[
    'public.save_journal_entry_with_lines(uuid,uuid,jsonb,jsonb)',
    'public.delete_journal_entry(uuid,uuid)',
    'public.create_paid_invoice_with_payment(uuid,jsonb,jsonb,jsonb)'
  ]
  loop
    if to_regprocedure(v_signature) is null then
      raise exception 'Required organization-scoped function is missing: %', v_signature;
    end if;

    select pg_get_functiondef(to_regprocedure(v_signature)) into v_definition;
    if position('public.has_organization_access(p_organization_id)' in v_definition) > 0 then
      continue;
    end if;
    if position('owner_id = auth.uid()' in v_definition) = 0 then
      raise exception 'Could not update the organization access check in %.', v_signature;
    end if;

    v_definition := replace(
      v_definition,
      'owner_id = auth.uid()',
      'public.has_organization_access(p_organization_id)'
    );
    execute v_definition;
  end loop;
end;
$$;

notify pgrst, 'reload schema';

commit;

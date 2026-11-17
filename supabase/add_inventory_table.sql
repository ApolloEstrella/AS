begin;

create table if not exists public.inventory (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  sku text not null check (length(trim(sku)) between 1 and 64),
  name text not null check (length(trim(name)) between 1 and 160),
  description text,
  unit text not null default 'each',
  quantity_on_hand numeric(12, 3) not null default 0 check (quantity_on_hand >= 0),
  unit_cost numeric(14, 2) not null default 0 check (unit_cost >= 0),
  unit_price numeric(14, 2) not null default 0 check (unit_price >= 0),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, sku),
  unique (id, organization_id)
);

alter table public.invoice_items
  add column if not exists inventory_id uuid;

create index if not exists invoice_items_inventory_idx
  on public.invoice_items (inventory_id, organization_id);

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.invoice_items'::regclass
      and conname = 'invoice_items_inventory_id_organization_id_fkey'
  ) then
    alter table public.invoice_items
      add constraint invoice_items_inventory_id_organization_id_fkey
      foreign key (inventory_id, organization_id)
      references public.inventory(id, organization_id)
      on delete set null (inventory_id);
  end if;

  if not exists (
    select 1 from pg_trigger
    where tgrelid = 'public.inventory'::regclass
      and tgname = 'set_inventory_updated_at'
      and not tgisinternal
  ) then
    create trigger set_inventory_updated_at
      before update on public.inventory
      for each row execute function public.set_updated_at();
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'inventory'
      and policyname = 'Organization owners manage inventory'
  ) then
    create policy "Organization owners manage inventory"
      on public.inventory for all
      using (exists (
        select 1 from public.organizations o
        where o.id = organization_id and o.owner_id = auth.uid()
      ))
      with check (exists (
        select 1 from public.organizations o
        where o.id = organization_id and o.owner_id = auth.uid()
      ));
  end if;
end;
$$;

alter table public.inventory enable row level security;

grant usage on schema public to authenticated;
grant select, insert, update, delete on table public.inventory to authenticated;

notify pgrst, 'reload schema';

commit;

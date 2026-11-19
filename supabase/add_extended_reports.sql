begin;

alter table public.inventory
  add column if not exists reorder_level numeric(12, 3) not null default 0
    check (reorder_level >= 0);

create table if not exists public.inventory_movements (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  inventory_id uuid not null,
  movement_type text not null check (movement_type in ('opening', 'receipt', 'issue', 'adjustment')),
  quantity_change numeric(12, 3) not null,
  unit_cost numeric(14, 2) not null default 0 check (unit_cost >= 0),
  movement_date date not null default current_date,
  reference text,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (inventory_id, organization_id)
    references public.inventory(id, organization_id) on delete cascade,
  check ((movement_type = 'opening' and quantity_change >= 0) or
    (movement_type <> 'opening' and quantity_change <> 0)),
  unique (id, organization_id)
);

create table if not exists public.fixed_assets (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null check (length(trim(name)) between 1 and 160),
  asset_number text not null check (length(trim(asset_number)) between 1 and 64),
  category text not null default 'Other' check (length(trim(category)) between 1 and 80),
  acquisition_date date not null,
  cost numeric(14, 2) not null check (cost > 0),
  salvage_value numeric(14, 2) not null default 0 check (salvage_value >= 0),
  useful_life_months integer not null check (useful_life_months > 0),
  disposed_date date,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, asset_number),
  unique (id, organization_id),
  check (salvage_value <= cost),
  check (disposed_date is null or disposed_date >= acquisition_date)
);

create table if not exists public.payroll_payments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  payee_name text not null check (length(trim(payee_name)) between 1 and 160),
  payee_type text not null check (payee_type in ('employee', 'contractor')),
  payment_date date not null,
  gross_amount numeric(14, 2) not null check (gross_amount > 0),
  income_tax_withheld numeric(14, 2) not null default 0 check (income_tax_withheld >= 0),
  other_tax_withheld numeric(14, 2) not null default 0 check (other_tax_withheld >= 0),
  reference text,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, organization_id),
  check (income_tax_withheld + other_tax_withheld <= gross_amount)
);

create index if not exists inventory_movements_org_date_idx
  on public.inventory_movements (organization_id, movement_date, inventory_id);
create index if not exists fixed_assets_org_date_idx
  on public.fixed_assets (organization_id, acquisition_date);
create index if not exists payroll_payments_org_date_idx
  on public.payroll_payments (organization_id, payment_date);

create or replace function public.record_inventory_opening_movement()
returns trigger
language plpgsql
as $$
begin
  insert into public.inventory_movements (
    organization_id, inventory_id, movement_type, quantity_change, unit_cost,
    movement_date, reference, notes
  ) values (
    new.organization_id, new.id, 'opening', new.quantity_on_hand, new.unit_cost,
    current_date, 'Opening balance', 'Opening quantity captured when the item was created.'
  );
  return new;
end;
$$;

drop trigger if exists record_inventory_opening_movement on public.inventory;
create trigger record_inventory_opening_movement
after insert on public.inventory
for each row execute function public.record_inventory_opening_movement();

create or replace function public.apply_inventory_movement()
returns trigger
language plpgsql
as $$
declare
  old_quantity numeric(12, 3) := 0;
  new_quantity numeric(12, 3) := 0;
  inventory_updated boolean := false;
begin
  if current_setting('app.skip_inventory_movement_sync', true) = 'on' then
    if tg_op = 'DELETE' then return old; end if;
    return new;
  end if;

  if tg_op in ('UPDATE', 'DELETE') and old.movement_type <> 'opening' then
    old_quantity := old.quantity_change;
    perform set_config('app.skip_inventory_movement_sync', 'on', true);
    update public.inventory
      set quantity_on_hand = quantity_on_hand - old_quantity
      where id = old.inventory_id and organization_id = old.organization_id;
    perform set_config('app.skip_inventory_movement_sync', 'off', true);
  elsif tg_op = 'UPDATE' then
    raise exception 'Opening inventory movements cannot be changed.';
  end if;

  if tg_op in ('INSERT', 'UPDATE') and new.movement_type <> 'opening' then
    new_quantity := new.quantity_change;
    perform set_config('app.skip_inventory_movement_sync', 'on', true);
    update public.inventory
      set quantity_on_hand = quantity_on_hand + new_quantity
      where id = new.inventory_id and organization_id = new.organization_id
        and quantity_on_hand + new_quantity >= 0;
    inventory_updated := found;
    perform set_config('app.skip_inventory_movement_sync', 'off', true);
    if not inventory_updated then
      raise exception 'Inventory movement would make the quantity on hand negative.';
    end if;
  end if;

  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

create or replace function public.record_inventory_quantity_adjustment()
returns trigger
language plpgsql
as $$
begin
  if current_setting('app.skip_inventory_movement_sync', true) = 'on' or
    new.quantity_on_hand = old.quantity_on_hand then
    return new;
  end if;

  perform set_config('app.skip_inventory_movement_sync', 'on', true);
  insert into public.inventory_movements (
    organization_id, inventory_id, movement_type, quantity_change, unit_cost,
    movement_date, reference, notes
  ) values (
    new.organization_id, new.id, 'adjustment',
    new.quantity_on_hand - old.quantity_on_hand, new.unit_cost,
    current_date, 'Quantity adjustment', 'Logged from an inventory quantity edit.'
  );
  perform set_config('app.skip_inventory_movement_sync', 'off', true);
  return new;
end;
$$;

drop trigger if exists record_inventory_quantity_adjustment on public.inventory;
create trigger record_inventory_quantity_adjustment
after update of quantity_on_hand on public.inventory
for each row execute function public.record_inventory_quantity_adjustment();

drop trigger if exists apply_inventory_movement on public.inventory_movements;
create trigger apply_inventory_movement
before insert or update or delete on public.inventory_movements
for each row execute function public.apply_inventory_movement();

insert into public.inventory_movements (
  organization_id, inventory_id, movement_type, quantity_change, unit_cost,
  movement_date, reference, notes
)
select i.organization_id, i.id, 'opening', i.quantity_on_hand, i.unit_cost,
  i.created_at::date, 'Opening balance', 'Opening quantity captured by the extended reports migration.'
from public.inventory i
where not exists (
  select 1 from public.inventory_movements m
  where m.inventory_id = i.id and m.organization_id = i.organization_id
    and m.movement_type = 'opening'
);

do $$
declare
  table_name text;
begin
  foreach table_name in array array['inventory_movements', 'fixed_assets', 'payroll_payments']
  loop
    execute format('drop policy if exists %I on public.%I',
      'Organization owners manage ' || table_name, table_name);
    execute format('drop trigger if exists %I on public.%I',
      'set_' || table_name || '_updated_at', table_name);
    execute format('create trigger %I before update on public.%I for each row execute function public.set_updated_at()',
      'set_' || table_name || '_updated_at', table_name);
    execute format('alter table public.%I enable row level security', table_name);
    execute format(
      'create policy %I on public.%I for all using (exists (select 1 from public.organizations o where o.id = organization_id and o.owner_id = auth.uid())) with check (exists (select 1 from public.organizations o where o.id = organization_id and o.owner_id = auth.uid()))',
      'Organization owners manage ' || table_name, table_name
    );
  end loop;
end;
$$;

grant usage on schema public to authenticated;
grant select, insert, update, delete on table
  public.inventory_movements, public.fixed_assets, public.payroll_payments to authenticated;

notify pgrst, 'reload schema';

commit;

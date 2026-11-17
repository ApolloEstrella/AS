-- Apply after the base schema and journal/ledger migrations.
begin;

create or replace function public.prevent_posted_journal_entry_changes()
returns trigger
language plpgsql
as $$
begin
  if old.status = 'posted' and
    current_setting('app.allow_posted_journal_entry_changes', true) is distinct from 'on' and (
      old.source_type is null
      or pg_trigger_depth() <= 1
    ) then
    raise exception 'Posted journal entries cannot be changed or deleted.';
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

create or replace function public.prevent_posted_journal_line_changes()
returns trigger
language plpgsql
as $$
declare
  entry_id uuid;
  org_id uuid;
begin
  if tg_op = 'DELETE' then
    entry_id := old.journal_entry_id;
    org_id := old.organization_id;
  else
    entry_id := new.journal_entry_id;
    org_id := new.organization_id;
  end if;

  if exists (
    select 1 from public.journal_entries
    where id = entry_id and organization_id = org_id and status = 'posted'
      and current_setting('app.allow_posted_journal_entry_changes', true) is distinct from 'on'
      and (
        source_type is null
        or pg_trigger_depth() <= 1
      )
  ) then
    raise exception 'Posted journal entries are immutable.';
  end if;

  if tg_op = 'UPDATE' and exists (
    select 1 from public.journal_entries
    where id = old.journal_entry_id and organization_id = old.organization_id and status = 'posted'
      and current_setting('app.allow_posted_journal_entry_changes', true) is distinct from 'on'
      and (
        source_type is null
        or pg_trigger_depth() <= 1
      )
  ) then
    raise exception 'Posted journal entries are immutable.';
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

create or replace function public.save_journal_entry_with_lines(
  p_organization_id uuid,
  p_entry_id uuid,
  p_entry jsonb,
  p_lines jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_entry_date date;
  v_description text;
  v_reference text;
  v_status text;
  v_line jsonb;
  v_account_id uuid;
  v_amount numeric;
  v_amount_code text;
  v_line_description text;
  v_debit_total numeric := 0;
  v_credit_total numeric := 0;
  v_entry public.journal_entries%rowtype;
  v_result_lines jsonb;
begin
  if auth.uid() is null or not exists (
    select 1
      from public.organizations
      where id = p_organization_id and owner_id = auth.uid()
  ) then
    raise exception 'You do not have access to this organization.';
  end if;
  perform set_config('app.allow_posted_journal_entry_changes', 'on', true);

  if jsonb_typeof(p_entry) is distinct from 'object' then
    raise exception 'Journal entry details are required.';
  end if;
  if jsonb_typeof(p_lines) is distinct from 'array' then
    raise exception 'Journal lines must be an array.';
  end if;
  if jsonb_array_length(p_lines) < 2 then
    raise exception 'Add at least two journal lines.';
  end if;

  if coalesce(p_entry->>'entry_date', '') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
    raise exception 'Enter a valid journal entry date.';
  end if;
  v_entry_date := (p_entry->>'entry_date')::date;
  v_description := btrim(coalesce(p_entry->>'description', ''));
  v_reference := nullif(btrim(coalesce(p_entry->>'reference', '')), '');
  v_status := coalesce(nullif(p_entry->>'status', ''), 'draft');

  if v_description = '' or length(v_description) > 500 then
    raise exception 'Description is required and must be 500 characters or fewer.';
  end if;
  if v_reference is not null and length(v_reference) > 100 then
    raise exception 'Reference must be 100 characters or fewer.';
  end if;
  if v_status not in ('draft', 'posted', 'void') then
    raise exception 'Choose a valid journal entry status.';
  end if;

  for v_line in select value from jsonb_array_elements(p_lines)
  loop
    if jsonb_typeof(v_line) is distinct from 'object' or
      coalesce(v_line->>'account_id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      raise exception 'Each journal line must have a valid account.';
    end if;
    v_account_id := (v_line->>'account_id')::uuid;
    if not exists (
      select 1 from public.accounts
      where id = v_account_id
        and organization_id = p_organization_id
        and is_active
    ) then
      raise exception 'Journal lines must use active accounts in this organization.';
    end if;

    if jsonb_typeof(v_line->'amount') is distinct from 'number' or
      coalesce(v_line->>'amount_code', '') not in ('D', 'C') then
      raise exception 'Each journal line needs a debit or credit amount.';
    end if;
    v_amount := (v_line->>'amount')::numeric;
    if v_amount <= 0 or v_amount > 999999999999.99 or v_amount <> round(v_amount, 2) then
      raise exception 'Journal line amounts must be positive with at most two decimal places.';
    end if;

    if v_line ? 'description' and jsonb_typeof(v_line->'description') not in ('string', 'null') then
      raise exception 'Journal line descriptions must be text.';
    end if;
    v_line_description := nullif(btrim(coalesce(v_line->>'description', '')), '');
    if v_line_description is not null and length(v_line_description) > 500 then
      raise exception 'Journal line descriptions must be 500 characters or fewer.';
    end if;

    v_amount_code := v_line->>'amount_code';
    if v_amount_code = 'D' then
      v_debit_total := v_debit_total + v_amount;
    else
      v_credit_total := v_credit_total + v_amount;
    end if;
  end loop;

  if v_debit_total <= 0 or v_debit_total <> v_credit_total then
    raise exception 'Total debits and credits must be equal and greater than zero.';
  end if;

  if p_entry_id is null then
    insert into public.journal_entries (
      organization_id, entry_date, description, reference, status
    )
    values (
      p_organization_id, v_entry_date, v_description, v_reference, 'draft'
    )
    returning * into v_entry;
  else
    select * into v_entry
      from public.journal_entries
      where id = p_entry_id and organization_id = p_organization_id
      for update;
    if not found then
      raise exception 'Journal entry not found.';
    end if;
    update public.journal_entries
      set entry_date = v_entry_date,
          description = v_description,
          reference = v_reference,
          status = 'draft'
      where id = p_entry_id and organization_id = p_organization_id
      returning * into v_entry;
    delete from public.journal_lines
      where journal_entry_id = p_entry_id and organization_id = p_organization_id;
  end if;

  for v_line in select value from jsonb_array_elements(p_lines)
  loop
    insert into public.journal_lines (
      organization_id, journal_entry_id, account_id, amount, amount_code, description
    )
    values (
      p_organization_id,
      v_entry.id,
      (v_line->>'account_id')::uuid,
      (v_line->>'amount')::numeric,
      v_line->>'amount_code',
      nullif(btrim(coalesce(v_line->>'description', '')), '')
    );
  end loop;

  update public.journal_entries
    set status = v_status
    where id = v_entry.id and organization_id = p_organization_id
    returning * into v_entry;

  select coalesce(jsonb_agg(to_jsonb(line) order by line.created_at, line.id), '[]'::jsonb)
    into v_result_lines
    from public.journal_lines as line
    where line.journal_entry_id = v_entry.id and line.organization_id = p_organization_id;

  return jsonb_build_object('entry', to_jsonb(v_entry), 'lines', v_result_lines);
end;
$$;

revoke all on function public.save_journal_entry_with_lines(uuid, uuid, jsonb, jsonb)
  from public, anon, authenticated;
grant execute on function public.save_journal_entry_with_lines(uuid, uuid, jsonb, jsonb)
  to authenticated;

create or replace function public.delete_journal_entry(
  p_organization_id uuid,
  p_entry_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_deleted_id uuid;
begin
  if auth.uid() is null or not exists (
    select 1
      from public.organizations
      where id = p_organization_id and owner_id = auth.uid()
  ) then
    raise exception 'You do not have access to this organization.';
  end if;
  perform set_config('app.allow_posted_journal_entry_changes', 'on', true);

  delete from public.journal_entries
    where id = p_entry_id and organization_id = p_organization_id
    returning id into v_deleted_id;
  if not found then
    raise exception 'Journal entry not found.';
  end if;

  return jsonb_build_object('id', v_deleted_id);
end;
$$;

revoke all on function public.delete_journal_entry(uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.delete_journal_entry(uuid, uuid)
  to authenticated;

notify pgrst, 'reload schema';
commit;

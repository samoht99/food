-- 016 : liste de courses « Autre », réservée à l'admin (côté site), même fonctionnement que la liste Suisse.
-- La base accepte la liste 'autre' pour les éléments : check de la table, add_shop_item, clear_shop_list, move_shop_item.
-- Sans risque à relancer.

alter table food.shop_items drop constraint if exists shop_items_list_check;
alter table food.shop_items add constraint shop_items_list_check check (list in ('france', 'suisse', 'autre'));

create or replace function food.add_shop_item(u text, p text, lst text, n text, cid smallint default null,
                                              q numeric default null, uid smallint default null)
returns jsonb
language plpgsql
security definer
set search_path = food, extensions
as $$
declare
  r text;
  c smallint := coalesce(cid, food._default_category());
  put jsonb;
begin
  r := food._check(u, p, array['write', 'admin']);
  if lst is null or lst not in ('france', 'suisse', 'autre') then
    raise exception 'invalid_list';
  end if;
  perform food._shop_check_item(n, c, q, uid);
  put := food._shop_put(lst, n, c, q, uid, true);
  perform food._audit(u, r, 'shop_add', btrim(n), null,
                      food._shop_item_state(lst, btrim(n), c, q, case when q is null then null else uid end)
                      || jsonb_build_object('merged', put -> 'merged'));
  return put;
end;
$$;

create or replace function food.clear_shop_list(u text, p text, lst text)
returns void
language plpgsql
security definer
set search_path = food, extensions
as $$
declare
  r text;
  n integer;
begin
  r := food._check(u, p, array['write', 'admin']);
  if lst is null or lst not in ('france', 'suisse', 'autre') then
    raise exception 'invalid_list';
  end if;
  select count(*) into n from food.shop_items s where s.list = lst;
  delete from food.shop_items where list = lst;
  if n > 0 then
    perform food._audit(u, r, 'shop_clear', lst, jsonb_build_object('list', lst, 'count', n), null);
  end if;
end;
$$;

create or replace function food.move_shop_item(u text, p text, iid bigint, to_list text)
returns jsonb
language plpgsql
security definer
set search_path = food, extensions
as $$
declare
  r text;
  itm record;
  nm boolean;
  m bigint;
  prev numeric;
begin
  r := food._check(u, p, array['write', 'admin']);
  if to_list is null or to_list not in ('france', 'suisse', 'autre') then
    raise exception 'invalid_list';
  end if;
  select s.* into itm from food.shop_items s where s.id = iid;
  if not found then
    raise exception 'unknown_item';
  end if;
  if itm.list = to_list then
    return jsonb_build_object('merged', false, 'id', iid);
  end if;
  select c.no_merge into nm from food.shop_categories c where c.id = itm.category_id;
  if not itm.checked and not nm then
    m := food._shop_match(to_list, itm.name, itm.category_id, itm.unit_id, itm.quantity is null);
  end if;
  if m is not null then
    if itm.quantity is not null then
      select s.quantity into prev from food.shop_items s where s.id = m;
      update food.shop_items set quantity = prev + itm.quantity where id = m;
    end if;
    delete from food.shop_items where id = iid;
  else
    update food.shop_items set list = to_list where id = iid;
  end if;
  perform food._audit(u, r, 'shop_move', itm.name,
                      food._shop_item_state(itm.list, itm.name, itm.category_id, itm.quantity, itm.unit_id),
                      food._shop_item_state(to_list, itm.name, itm.category_id, itm.quantity, itm.unit_id)
                      || jsonb_build_object('merged', m is not null));
  return jsonb_build_object('merged', m is not null, 'id', coalesce(m, iid));
end;
$$;


-- Migration : listes de courses France et Suisse, catégories de courses (specs v2-5).
-- À exécuter une fois dans Supabase (SQL Editor), en une seule fois, APRÈS la migration 013.
--
-- Ajoute :
--   food.shop_categories : catégories de courses (nom, rang dans les tris custom Carrefour Segny et Coop Vich,
--                          case « ne s'additionne pas »). « Autre » est créée d'office (catégorie par défaut) ;
--                          les autres sont créées dans l'Admin.
--   food.shop_items      : éléments des listes France et Suisse (nom libre, catégorie, quantité et unité
--                          facultatives, coché ou non). Aucun lien avec les ingrédients.
--   food.ingredients.category_id : catégorie de courses d'un ingrédient (null : « Autre »).
-- Fonctions : get_shop_categories, add/update/delete_shop_category, get_shop_items, add/update/delete_shop_item,
--   set_shop_item_checked, move_shop_item, clear_shop_list, preview_shop_generation, generate_shop ;
--   get_ingredients, add_ingredient, update_ingredient, delete_ingredient (catégorie) remplacées.
-- Le site v2-5 fonctionne aussi avant ce script (sans l'onglet Courses) : on peut publier le site d'abord.

begin;

-- ---------------------------------------------------------------- Tables
create table if not exists food.shop_categories (
  id            smallint generated always as identity primary key,
  name          text     not null check (name = btrim(name) and name <> '' and char_length(name) <= 40),
  pos_carrefour smallint not null,
  pos_coop      smallint not null,
  no_merge      boolean  not null default false,
  is_default    boolean  not null default false
);
create unique index if not exists shop_categories_name_key on food.shop_categories (lower(name));
create unique index if not exists shop_categories_default_key on food.shop_categories (is_default) where is_default;

insert into food.shop_categories (name, pos_carrefour, pos_coop, is_default)
select 'Autre', 1, 1, true
where not exists (select 1 from food.shop_categories where is_default);

alter table food.ingredients
  add column if not exists category_id smallint references food.shop_categories (id) on delete restrict;
create index if not exists ingredients_category_idx on food.ingredients (category_id);

create table if not exists food.shop_items (
  id          bigint generated always as identity primary key,
  list        text          not null check (list in ('france', 'suisse')),
  name        text          not null check (name = btrim(name) and name <> '' and char_length(name) <= 60),
  category_id smallint      not null references food.shop_categories (id) on delete restrict,
  quantity    numeric(10, 3) check (quantity > 0),
  unit_id     smallint      references food.units (id) on delete restrict,
  checked     boolean       not null default false,
  created_at  timestamptz   not null default now()
);
create index if not exists shop_items_list_idx on food.shop_items (list);
create index if not exists shop_items_category_idx on food.shop_items (category_id);

alter table food.shop_categories enable row level security;
alter table food.shop_items      enable row level security;
revoke all on food.shop_categories, food.shop_items from anon, authenticated;

alter table food.audit_log drop constraint if exists audit_log_action_check;
alter table food.audit_log add constraint audit_log_action_check check (action in
  ('meal_create', 'meal_update', 'meal_clear', 'food_add', 'food_update', 'food_delete',
   'day_constraint_create', 'day_constraint_update', 'day_constraint_clear',
   'constraint_add', 'constraint_update', 'constraint_delete',
   'ingredient_add', 'ingredient_update', 'ingredient_delete',
   'shop_add', 'shop_update', 'shop_delete', 'shop_move', 'shop_clear', 'shop_generate',
   'shop_category_add', 'shop_category_update', 'shop_category_delete'));

-- ------------------------------------------------------ Fonctions internes
create or replace function food._default_category()
returns smallint
language sql
stable
security definer
set search_path = food
as $$
  select c.id from food.shop_categories c where c.is_default limit 1;
$$;

-- Place une catégorie au rang pc (tri Carrefour) et au rang pk (tri Coop) : les autres catégories sont
-- décalées d'un cran, les rangs restent de 1 à N sans égalité ni trou. Un rang hors limites est ramené à 1 ou à N ;
-- null : le rang ne change pas.
create or replace function food._shop_place(cid smallint, pc integer, pk integer)
returns void
language plpgsql
security definer
set search_path = food
as $$
declare
  n integer;
begin
  select count(*) into n from food.shop_categories;
  if pc is not null then
    pc := greatest(1, least(pc, n));
    with others as (
      select c.id, row_number() over (order by c.pos_carrefour, c.id) as rn
      from food.shop_categories c where c.id <> cid
    ), placed as (
      select o.id, (case when o.rn >= pc then o.rn + 1 else o.rn end) as r from others o
      union all select cid, pc
    )
    update food.shop_categories c set pos_carrefour = p.r from placed p where p.id = c.id;
  end if;
  if pk is not null then
    pk := greatest(1, least(pk, n));
    with others as (
      select c.id, row_number() over (order by c.pos_coop, c.id) as rn
      from food.shop_categories c where c.id <> cid
    ), placed as (
      select o.id, (case when o.rn >= pk then o.rn + 1 else o.rn end) as r from others o
      union all select cid, pk
    )
    update food.shop_categories c set pos_coop = p.r from placed p where p.id = c.id;
  end if;
end;
$$;

-- Renumérote les rangs de 1 à N (après une suppression).
create or replace function food._shop_compact()
returns void
language sql
security definer
set search_path = food
as $$
  update food.shop_categories c set pos_carrefour = r.rn
  from (select id, row_number() over (order by pos_carrefour, id) as rn from food.shop_categories) r
  where r.id = c.id;
  update food.shop_categories c set pos_coop = r.rn
  from (select id, row_number() over (order by pos_coop, id) as rn from food.shop_categories) r
  where r.id = c.id;
$$;

-- État d'une catégorie pour l'audit : { name, carrefour, coop, no_merge }.
create or replace function food._shop_category_state(cid smallint)
returns jsonb
language sql
security definer
set search_path = food
as $$
  select jsonb_build_object('name', c.name, 'carrefour', c.pos_carrefour, 'coop', c.pos_coop, 'no_merge', c.no_merge)
  from food.shop_categories c where c.id = cid;
$$;

-- État d'un élément de liste pour l'audit : { list, name, category, quantity, unit }.
create or replace function food._shop_item_state(lst text, n text, cid smallint, q numeric, uid smallint)
returns jsonb
language sql
security definer
set search_path = food
as $$
  select jsonb_build_object('list', lst, 'name', n,
    'category', (select c.name from food.shop_categories c where c.id = cid),
    'quantity', q,
    'unit', (select u.name from food.units u where u.id = uid));
$$;

-- Contrôle des champs d'un élément (erreurs : invalid_name, unknown_category, invalid_quantity, unknown_unit).
create or replace function food._shop_check_item(n text, cid smallint, q numeric, uid smallint)
returns void
language plpgsql
security definer
set search_path = food
as $$
begin
  if n is null or btrim(n) = '' or char_length(btrim(n)) > 60 then
    raise exception 'invalid_name';
  end if;
  if cid is null or not exists (select 1 from food.shop_categories c where c.id = cid) then
    raise exception 'unknown_category';
  end if;
  if q is not null and not (q > 0 and q <= 99999 and round(q, 3) = q) then
    raise exception 'invalid_quantity';
  end if;
  if uid is not null and not exists (select 1 from food.units u where u.id = uid) then
    raise exception 'unknown_unit';
  end if;
end;
$$;

-- Élément avec lequel un nouvel élément peut fusionner : même liste, même nom (sans tenir compte de la casse),
-- même catégorie, même unité, tous deux sans quantité ou tous deux avec, jamais un élément coché, jamais une
-- catégorie « ne s'additionne pas ». Renvoie son id, ou null.
create or replace function food._shop_match(lst text, n text, cid smallint, uid smallint, qnull boolean)
returns bigint
language sql
stable
security definer
set search_path = food
as $$
  select s.id
  from food.shop_items s
  join food.shop_categories c on c.id = s.category_id
  where s.list = lst
    and lower(s.name) = lower(btrim(n))
    and s.category_id = cid
    and s.unit_id is not distinct from uid
    and (s.quantity is null) = qnull
    and not s.checked
    and not c.no_merge
  order by s.id
  limit 1;
$$;

-- Ajoute un élément à une liste (déjà contrôlé), en le fusionnant avec un élément existant si merge est vrai et
-- que la règle de fusion le permet. L'unité est ignorée sans quantité. Renvoie { merged, id, before, after }.
create or replace function food._shop_put(lst text, n text, cid smallint, q numeric, uid smallint, merge boolean)
returns jsonb
language plpgsql
security definer
set search_path = food
as $$
declare
  nm boolean;
  m bigint;
  prev numeric;
  u smallint := case when q is null then null else uid end;
begin
  select c.no_merge into nm from food.shop_categories c where c.id = cid;
  if merge and not nm then
    m := food._shop_match(lst, n, cid, u, q is null);
  end if;
  if m is not null then
    if q is null then
      return jsonb_build_object('merged', true, 'id', m, 'before', null, 'after', null);
    end if;
    select s.quantity into prev from food.shop_items s where s.id = m;
    update food.shop_items set quantity = prev + q where id = m;
    return jsonb_build_object('merged', true, 'id', m, 'before', prev, 'after', prev + q);
  end if;
  insert into food.shop_items (list, name, category_id, quantity, unit_id)
  values (lst, btrim(n), cid, q, u) returning id into m;
  return jsonb_build_object('merged', false, 'id', m);
end;
$$;

-- Génère la liste France à partir des repas de d_from à d_to (bornes incluses) et renvoie le résultat :
-- { added, replaced, merged: [{ name, unit, before, add, after }], split: [noms], no_qty: [noms] }.
-- mode : 'replace' (vide la liste d'abord), 'append' (ajoute sans fusionner avec l'existant), 'merge'
-- (fusionne selon la règle de fusion). Erreurs : invalid_mode, invalid_dates. N'écrit pas dans l'audit.
create or replace function food._shop_generate(lst text, d_from date, d_to date, mode text)
returns jsonb
language plpgsql
security definer
set search_path = food
as $$
declare
  def smallint := food._default_category();
  r record;
  q numeric;
  uid smallint;
  put jsonb;
  added integer := 0;
  replaced integer := 0;
  merged jsonb := '[]'::jsonb;
  split text[] := '{}';
  noqty text[] := '{}';
begin
  if mode is null or mode not in ('replace', 'append', 'merge') then
    raise exception 'invalid_mode';
  end if;
  if d_from is null or d_to is null or d_from < food._today() or d_to < d_from or d_to - d_from > 61 then
    raise exception 'invalid_dates';
  end if;
  if mode = 'replace' then
    select count(*) into replaced from food.shop_items s where s.list = lst;
    delete from food.shop_items where list = lst;
  end if;
  for r in
    select x.name, x.cid, x.uid, x.qnull, sum(x.qty) as total
    from (
      select i.name,
             coalesce(i.category_id, def) as cid,
             i.unit_id as uid,
             (fi.quantity is null) as qnull,
             fi.quantity * mi.portions as qty,
             case when c.no_merge then mi.meal_id::text || '-' || mi.food_id::text else '' end as grp
      from food.meals m
      join food.meal_items mi on mi.meal_id = m.id
      join food.food_ingredients fi on fi.food_id = mi.food_id
      join food.ingredients i on i.id = fi.ingredient_id
      join food.shop_categories c on c.id = coalesce(i.category_id, def)
      where m.meal_date between d_from and d_to
    ) x
    group by x.name, x.cid, x.uid, x.qnull, x.grp
    order by x.name, x.grp
  loop
    q := case when r.qnull then null else round(r.total, 3) end;
    uid := case when r.qnull then null else r.uid end;
    if r.qnull and not (r.name = any (noqty)) then
      noqty := noqty || r.name;
    end if;
    put := food._shop_put(lst, r.name, r.cid, q, uid, mode = 'merge');
    if (put ->> 'merged')::boolean then
      merged := merged || jsonb_build_array(jsonb_build_object(
        'name', r.name, 'unit', (select u.name from food.units u where u.id = uid),
        'before', put -> 'before', 'add', q, 'after', put -> 'after'));
    else
      added := added + 1;
      if mode = 'merge' and exists (
           select 1 from food.shop_items s
           join food.shop_categories c on c.id = s.category_id
           where s.list = lst and s.id <> (put ->> 'id')::bigint and lower(s.name) = lower(r.name)
             and s.category_id = r.cid and s.unit_id is not distinct from uid
             and (s.quantity is null) = r.qnull and s.checked and not c.no_merge)
         and not (r.name = any (split)) then
        split := split || r.name;
      end if;
    end if;
  end loop;
  return jsonb_build_object(
    'added', added, 'replaced', replaced, 'merged', merged,
    'split', to_jsonb(split), 'no_qty', to_jsonb(noqty));
end;
$$;

-- État d'un ingrédient pour l'audit : { name, unit, category }.
drop function if exists food._ingredient_state(text, smallint);
create or replace function food._ingredient_state(n text, uid smallint, cid smallint default null)
returns jsonb
language sql
security definer
set search_path = food
as $$
  select jsonb_build_object('name', n, 'unit', (select u.name from food.units u where u.id = uid))
         || case when cid is null then '{}'::jsonb
                 else jsonb_build_object('category', (select c.name from food.shop_categories c where c.id = cid)) end;
$$;

-- ----------------------------------------------------- Fonctions publiques
-- Catégories de courses (tous rôles), avec le nombre d'ingrédients et d'éléments de liste qui les utilisent.
create or replace function food.get_shop_categories(u text, p text)
returns table (id smallint, name text, pos_carrefour smallint, pos_coop smallint, no_merge boolean,
               is_default boolean, uses bigint)
language plpgsql
security definer
set search_path = food, extensions
as $$
begin
  perform food._check(u, p, array['read', 'write', 'admin']);
  return query
    select c.id, c.name, c.pos_carrefour, c.pos_coop, c.no_merge, c.is_default,
           (select count(*) from food.ingredients i where i.category_id = c.id)
           + (select count(*) from food.shop_items s where s.category_id = c.id)
    from food.shop_categories c
    order by c.name, c.id;
end;
$$;

-- Crée une catégorie (rôle admin uniquement). pc / pk : rangs dans les tris Carrefour et Coop (null : en dernier) ;
-- les catégories qui les occupaient sont décalées. Erreurs : invalid_name, category_exists.
create or replace function food.add_shop_category(u text, p text, n text, pc integer default null,
                                                  pk integer default null, nm boolean default false)
returns smallint
language plpgsql
security definer
set search_path = food, extensions
as $$
declare
  r text;
  name_ text := btrim(coalesce(n, ''));
  new_id smallint;
begin
  r := food._check(u, p, array['admin']);
  if name_ = '' or char_length(name_) > 40 then
    raise exception 'invalid_name';
  end if;
  if exists (select 1 from food.shop_categories c where lower(c.name) = lower(name_)) then
    raise exception 'category_exists';
  end if;
  insert into food.shop_categories (name, pos_carrefour, pos_coop, no_merge)
  values (name_,
          (select coalesce(max(c.pos_carrefour), 0) + 1 from food.shop_categories c),
          (select coalesce(max(c.pos_coop), 0) + 1 from food.shop_categories c),
          coalesce(nm, false))
  returning id into new_id;
  perform food._shop_place(new_id, pc, pk);
  perform food._audit(u, r, 'shop_category_add', name_, null, food._shop_category_state(new_id));
  return new_id;
end;
$$;

-- Modifie une catégorie (rôle admin uniquement). Mêmes règles de rang que add_shop_category (null : le rang ne
-- change pas). Erreurs : invalid_name, unknown_category, category_exists.
create or replace function food.update_shop_category(u text, p text, cid smallint, n text, pc integer default null,
                                                     pk integer default null, nm boolean default false)
returns void
language plpgsql
security definer
set search_path = food, extensions
as $$
declare
  r text;
  name_ text := btrim(coalesce(n, ''));
  old_name text;
  before_state jsonb;
begin
  r := food._check(u, p, array['admin']);
  if name_ = '' or char_length(name_) > 40 then
    raise exception 'invalid_name';
  end if;
  select c.name into old_name from food.shop_categories c where c.id = cid;
  if not found then
    raise exception 'unknown_category';
  end if;
  if exists (select 1 from food.shop_categories c where lower(c.name) = lower(name_) and c.id <> cid) then
    raise exception 'category_exists';
  end if;
  before_state := food._shop_category_state(cid);
  update food.shop_categories set name = name_, no_merge = coalesce(nm, false) where id = cid;
  perform food._shop_place(cid, pc, pk);
  if food._shop_category_state(cid) <> before_state then
    perform food._audit(u, r, 'shop_category_update', old_name, before_state, food._shop_category_state(cid));
  end if;
end;
$$;

-- Supprime une catégorie (rôle admin uniquement). Refusé pour « Autre » (category_default) et tant qu'un ingrédient
-- ou un élément de liste l'utilise (category_in_use, avec la liste en JSON { n, items }).
create or replace function food.delete_shop_category(u text, p text, cid smallint)
returns void
language plpgsql
security definer
set search_path = food, extensions
as $$
declare
  r text;
  n integer;
  items jsonb;
  old_name text;
  before_state jsonb;
  dflt boolean;
begin
  r := food._check(u, p, array['admin']);
  select c.name, c.is_default into old_name, dflt from food.shop_categories c where c.id = cid;
  if not found then
    return;
  end if;
  if dflt then
    raise exception 'category_default';
  end if;
  select count(*), coalesce(jsonb_agg(q.x order by q.x), '[]'::jsonb) into n, items
  from (
    select i.name || ' (ingrédient)' as x from food.ingredients i where i.category_id = cid
    union all
    select s.name || ' (liste ' || case s.list when 'france' then 'France' else 'Suisse' end || ')'
    from food.shop_items s where s.category_id = cid
  ) q;
  if n > 0 then
    raise exception 'category_in_use' using detail = jsonb_build_object('n', n, 'items', items)::text;
  end if;
  before_state := food._shop_category_state(cid);
  delete from food.shop_categories where id = cid;
  perform food._shop_compact();
  perform food._audit(u, r, 'shop_category_delete', old_name, before_state, null);
end;
$$;

-- Éléments des listes France et Suisse (tous rôles), du plus ancien au plus récent.
create or replace function food.get_shop_items(u text, p text)
returns table (id bigint, list text, name text, category_id smallint, quantity numeric, unit_id smallint,
               checked boolean, created_at timestamptz)
language plpgsql
security definer
set search_path = food, extensions
as $$
begin
  perform food._check(u, p, array['read', 'write', 'admin']);
  return query
    select s.id, s.list, s.name, s.category_id, s.quantity, s.unit_id, s.checked, s.created_at
    from food.shop_items s
    order by s.id;
end;
$$;

-- Ajoute un élément à une liste (rôles write et admin). cid null : « Autre ». Sans quantité l'unité est ignorée.
-- Fusion avec un élément existant selon la règle de fusion. Renvoie { merged, id, before, after }.
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
  if lst is null or lst not in ('france', 'suisse') then
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

-- Modifie un élément (rôles write et admin) : nom, catégorie, quantité, unité. Pas de fusion, la case ne change pas.
create or replace function food.update_shop_item(u text, p text, iid bigint, n text, cid smallint default null,
                                                 q numeric default null, uid smallint default null)
returns void
language plpgsql
security definer
set search_path = food, extensions
as $$
declare
  r text;
  c smallint := coalesce(cid, food._default_category());
  itm record;
  new_unit smallint := case when q is null then null else uid end;
begin
  r := food._check(u, p, array['write', 'admin']);
  select s.* into itm from food.shop_items s where s.id = iid;
  if not found then
    raise exception 'unknown_item';
  end if;
  perform food._shop_check_item(n, c, q, uid);
  if btrim(n) <> itm.name or c <> itm.category_id or q is distinct from itm.quantity
     or new_unit is distinct from itm.unit_id then
    update food.shop_items
    set name = btrim(n), category_id = c, quantity = q, unit_id = new_unit
    where id = iid;
    perform food._audit(u, r, 'shop_update', itm.name,
                        food._shop_item_state(itm.list, itm.name, itm.category_id, itm.quantity, itm.unit_id),
                        food._shop_item_state(itm.list, btrim(n), c, q, new_unit));
  end if;
end;
$$;

-- Coche ou décoche un élément (rôles write et admin). Non consigné dans l'audit.
create or replace function food.set_shop_item_checked(u text, p text, iid bigint, chk boolean)
returns void
language plpgsql
security definer
set search_path = food, extensions
as $$
begin
  perform food._check(u, p, array['write', 'admin']);
  update food.shop_items set checked = coalesce(chk, false) where id = iid;
  if not found then
    raise exception 'unknown_item';
  end if;
end;
$$;

-- Supprime un élément (rôles write et admin).
create or replace function food.delete_shop_item(u text, p text, iid bigint)
returns void
language plpgsql
security definer
set search_path = food, extensions
as $$
declare
  r text;
  itm record;
begin
  r := food._check(u, p, array['write', 'admin']);
  select s.* into itm from food.shop_items s where s.id = iid;
  if found then
    delete from food.shop_items where id = iid;
    perform food._audit(u, r, 'shop_delete', itm.name,
                        food._shop_item_state(itm.list, itm.name, itm.category_id, itm.quantity, itm.unit_id), null);
  end if;
end;
$$;

-- Vide une liste (rôles write et admin) : tous ses éléments, cochés ou non.
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
  if lst is null or lst not in ('france', 'suisse') then
    raise exception 'invalid_list';
  end if;
  select count(*) into n from food.shop_items s where s.list = lst;
  delete from food.shop_items where list = lst;
  if n > 0 then
    perform food._audit(u, r, 'shop_clear', lst, jsonb_build_object('list', lst, 'count', n), null);
  end if;
end;
$$;

-- Déplace un élément dans l'autre liste (rôles write et admin). Si l'élément n'est pas coché et qu'un élément de la
-- liste d'arrivée correspond (règle de fusion), les quantités s'additionnent et l'élément déplacé disparaît.
-- Renvoie { merged, id }.
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
  if to_list is null or to_list not in ('france', 'suisse') then
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

-- Aperçu de la génération de la liste France (rôles write et admin) : le résultat exact de generate_shop, calculé
-- puis annulé (rien n'est modifié). Erreurs : invalid_mode, invalid_dates.
create or replace function food.preview_shop_generation(u text, p text, d_from date, d_to date, mode text)
returns jsonb
language plpgsql
security definer
set search_path = food, extensions
as $$
declare
  res jsonb;
  d text;
begin
  perform food._check(u, p, array['write', 'admin']);
  begin
    res := food._shop_generate('france', d_from, d_to, mode);
    raise exception 'shop_preview' using detail = res::text;
  exception when raise_exception then
    if sqlerrm <> 'shop_preview' then
      raise;
    end if;
    get stacked diagnostics d = pg_exception_detail;
    return d::jsonb;
  end;
end;
$$;

-- Génère la liste France à partir des repas de d_from à d_to (rôles write et admin). Renvoie le même résultat que
-- preview_shop_generation.
create or replace function food.generate_shop(u text, p text, d_from date, d_to date, mode text)
returns jsonb
language plpgsql
security definer
set search_path = food, extensions
as $$
declare
  r text;
  res jsonb;
begin
  r := food._check(u, p, array['write', 'admin']);
  res := food._shop_generate('france', d_from, d_to, mode);
  perform food._audit(u, r, 'shop_generate', 'france', null,
                      jsonb_build_object('from', d_from, 'to', d_to, 'mode', mode, 'added', res -> 'added',
                                         'merged', jsonb_array_length(res -> 'merged'), 'replaced', res -> 'replaced'));
  return res;
end;
$$;

-- ------------------------------------------- Ingrédients : catégorie de courses
drop function if exists food.get_ingredients(text, text);
drop function if exists food.add_ingredient(text, text, text, smallint);
drop function if exists food.update_ingredient(text, text, bigint, text, smallint);

-- Ingrédients (rôle admin uniquement), avec le nombre d'aliments qui les utilisent, leur unité et leur catégorie.
create or replace function food.get_ingredients(u text, p text)
returns table (id bigint, name text, uses bigint, unit_id smallint, category_id smallint)
language plpgsql
security definer
set search_path = food, extensions
as $$
begin
  perform food._check(u, p, array['admin']);
  return query
    select i.id, i.name,
           (select count(*) from food.food_ingredients fi where fi.ingredient_id = i.id),
           i.unit_id, i.category_id
    from food.ingredients i
    order by i.name, i.id;
end;
$$;

-- Crée un ingrédient avec son unité (g par défaut) et sa catégorie de courses (null : aucune) (rôle admin uniquement).
create or replace function food.add_ingredient(u text, p text, n text, uid smallint default null, cid smallint default null)
returns bigint
language plpgsql
security definer
set search_path = food, extensions
as $$
declare
  r text;
  name_ text := lower(btrim(coalesce(n, '')));
  unit_ smallint := coalesce(uid, food._default_unit());
  new_id bigint;
begin
  r := food._check(u, p, array['admin']);
  if name_ = '' or char_length(name_) > 60 then
    raise exception 'invalid_name';
  end if;
  if not exists (select 1 from food.units un where un.id = unit_) then
    raise exception 'unknown_unit';
  end if;
  if cid is not null and not exists (select 1 from food.shop_categories c where c.id = cid) then
    raise exception 'unknown_category';
  end if;
  if exists (select 1 from food.ingredients i where i.name = name_) then
    raise exception 'ingredient_exists';
  end if;
  insert into food.ingredients (name, unit_id, category_id) values (name_, unit_, cid) returning id into new_id;
  perform food._audit(u, r, 'ingredient_add', name_, null, food._ingredient_state(name_, unit_, cid));
  return new_id;
end;
$$;

-- Modifie le nom, l'unité et la catégorie de courses d'un ingrédient (rôle admin uniquement ; uid null : l'unité ne
-- change pas ; cid -1 : la catégorie ne change pas, null : plus de catégorie). Les aliments qui l'utilisent suivent
-- automatiquement. Changer l'unité ne convertit pas les quantités déjà saisies.
create or replace function food.update_ingredient(u text, p text, iid bigint, n text, uid smallint default null,
                                                  cid smallint default -1)
returns void
language plpgsql
security definer
set search_path = food, extensions
as $$
declare
  r text;
  name_ text := lower(btrim(coalesce(n, '')));
  old_name text;
  old_unit smallint;
  old_cat smallint;
  unit_ smallint;
  cat_ smallint;
begin
  r := food._check(u, p, array['admin']);
  if name_ = '' or char_length(name_) > 60 then
    raise exception 'invalid_name';
  end if;
  select i.name, i.unit_id, i.category_id into old_name, old_unit, old_cat from food.ingredients i where i.id = iid;
  if not found then
    raise exception 'unknown_ingredient';
  end if;
  unit_ := coalesce(uid, old_unit);
  cat_ := case when cid = -1 then old_cat else cid end;
  if not exists (select 1 from food.units un where un.id = unit_) then
    raise exception 'unknown_unit';
  end if;
  if cat_ is not null and not exists (select 1 from food.shop_categories c where c.id = cat_) then
    raise exception 'unknown_category';
  end if;
  if exists (select 1 from food.ingredients i where i.name = name_ and i.id <> iid) then
    raise exception 'ingredient_exists';
  end if;

  -- Rien n'est écrit (ni consigné) si ni le nom, ni l'unité, ni la catégorie ne changent.
  if name_ <> old_name or unit_ <> old_unit or cat_ is distinct from old_cat then
    update food.ingredients set name = name_, unit_id = unit_, category_id = cat_ where id = iid;
    perform food._audit(u, r, 'ingredient_update', old_name,
                        food._ingredient_state(old_name, old_unit, old_cat), food._ingredient_state(name_, unit_, cat_));
  end if;
end;
$$;

-- Supprime un ingrédient (rôle admin uniquement), bloqué s'il est lié à au moins un aliment. S'il est utilisé,
-- l'erreur donne la liste des aliments (JSON { n, items }).
create or replace function food.delete_ingredient(u text, p text, iid bigint)
returns void
language plpgsql
security definer
set search_path = food, extensions
as $$
declare
  r text;
  n integer;
  items jsonb;
  old_name text;
  old_unit smallint;
  old_cat smallint;
begin
  r := food._check(u, p, array['admin']);
  select count(*) into n from food.food_ingredients fi where fi.ingredient_id = iid;
  if n > 0 then
    select coalesce(jsonb_agg(f.name order by f.name), '[]'::jsonb) into items
    from food.food_ingredients fi
    join food.foods f on f.id = fi.food_id
    where fi.ingredient_id = iid;
    raise exception 'ingredient_in_use' using detail = jsonb_build_object('n', n, 'items', items)::text;
  end if;
  select i.name, i.unit_id, i.category_id into old_name, old_unit, old_cat from food.ingredients i where i.id = iid;
  if found then
    delete from food.ingredients where id = iid;
    perform food._audit(u, r, 'ingredient_delete', old_name, food._ingredient_state(old_name, old_unit, old_cat), null);
  end if;
end;
$$;

-- ---------------------------------------------------------------- Droits
revoke execute on function food._default_category()                                             from public, anon, authenticated;
revoke execute on function food._shop_place(smallint, integer, integer)                         from public, anon, authenticated;
revoke execute on function food._shop_compact()                                                 from public, anon, authenticated;
revoke execute on function food._shop_category_state(smallint)                                  from public, anon, authenticated;
revoke execute on function food._shop_item_state(text, text, smallint, numeric, smallint)       from public, anon, authenticated;
revoke execute on function food._shop_check_item(text, smallint, numeric, smallint)             from public, anon, authenticated;
revoke execute on function food._shop_match(text, text, smallint, smallint, boolean)            from public, anon, authenticated;
revoke execute on function food._shop_put(text, text, smallint, numeric, smallint, boolean)     from public, anon, authenticated;
revoke execute on function food._shop_generate(text, date, date, text)                          from public, anon, authenticated;
revoke execute on function food._ingredient_state(text, smallint, smallint)                     from public, anon, authenticated;

revoke execute on function food.get_shop_categories(text, text)                                         from public;
revoke execute on function food.add_shop_category(text, text, text, integer, integer, boolean)          from public;
revoke execute on function food.update_shop_category(text, text, smallint, text, integer, integer, boolean) from public;
revoke execute on function food.delete_shop_category(text, text, smallint)                              from public;
revoke execute on function food.get_shop_items(text, text)                                              from public;
revoke execute on function food.add_shop_item(text, text, text, text, smallint, numeric, smallint)      from public;
revoke execute on function food.update_shop_item(text, text, bigint, text, smallint, numeric, smallint) from public;
revoke execute on function food.set_shop_item_checked(text, text, bigint, boolean)                      from public;
revoke execute on function food.delete_shop_item(text, text, bigint)                                    from public;
revoke execute on function food.clear_shop_list(text, text, text)                                       from public;
revoke execute on function food.move_shop_item(text, text, bigint, text)                                from public;
revoke execute on function food.preview_shop_generation(text, text, date, date, text)                   from public;
revoke execute on function food.generate_shop(text, text, date, date, text)                             from public;
revoke execute on function food.get_ingredients(text, text)                                             from public;
revoke execute on function food.add_ingredient(text, text, text, smallint, smallint)                    from public;
revoke execute on function food.update_ingredient(text, text, bigint, text, smallint, smallint)         from public;

grant execute on function food.get_shop_categories(text, text)                                          to anon, authenticated;
grant execute on function food.add_shop_category(text, text, text, integer, integer, boolean)           to anon, authenticated;
grant execute on function food.update_shop_category(text, text, smallint, text, integer, integer, boolean) to anon, authenticated;
grant execute on function food.delete_shop_category(text, text, smallint)                               to anon, authenticated;
grant execute on function food.get_shop_items(text, text)                                               to anon, authenticated;
grant execute on function food.add_shop_item(text, text, text, text, smallint, numeric, smallint)       to anon, authenticated;
grant execute on function food.update_shop_item(text, text, bigint, text, smallint, numeric, smallint)  to anon, authenticated;
grant execute on function food.set_shop_item_checked(text, text, bigint, boolean)                       to anon, authenticated;
grant execute on function food.delete_shop_item(text, text, bigint)                                     to anon, authenticated;
grant execute on function food.clear_shop_list(text, text, text)                                        to anon, authenticated;
grant execute on function food.move_shop_item(text, text, bigint, text)                                 to anon, authenticated;
grant execute on function food.preview_shop_generation(text, text, date, date, text)                    to anon, authenticated;
grant execute on function food.generate_shop(text, text, date, date, text)                              to anon, authenticated;
grant execute on function food.get_ingredients(text, text)                                              to anon, authenticated;
grant execute on function food.add_ingredient(text, text, text, smallint, smallint)                     to anon, authenticated;
grant execute on function food.update_ingredient(text, text, bigint, text, smallint, smallint)          to anon, authenticated;

commit;

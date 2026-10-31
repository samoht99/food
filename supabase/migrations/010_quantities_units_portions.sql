-- Migration : quantités des ingrédients, unités et portions (specs v2-3).
-- À exécuter une fois dans Supabase (SQL Editor), en une seule fois, APRÈS la migration 009.
--
-- Ajoute les unités (food.units, 5 unités de départ), l'unité de chaque ingrédient (g par défaut),
-- la quantité de base d'un ingrédient dans un aliment (pour 1 portion, facultative) et le nombre de
-- portions d'un aliment dans un repas (1 par défaut). Adapte les fonctions :
--   get_catalog   : unités + ingrédients (quantité, unité) de tous les aliments
--   get_meals     : colonne portions en plus
--   set_meal      : paramètre portions (tableau parallèle à food_ids)
--   add_food / update_food : ingrédients envoyés en JSON [{ name, quantity, unit_id }] (un tableau de
--                   noms, ancien format, reste accepté) ; 2 ingrédients ou plus => classe Recettes ajoutée
--   get_ingredients / add_ingredient / update_ingredient : unité de l'ingrédient
--   delete_food / delete_ingredient et l'audit : états avec quantités et unités
-- Aucune donnée existante n'est modifiée : les quantités sont « non définies » (null), les portions
-- valent 1 et les ingrédients sont en g. Pour donner leur unité aux ingrédients existants, exécuter
-- ensuite 011_units_of_existing_ingredients.sql (à relire et adapter).
-- Idéal : publier le site v2-3 (il fonctionne avant ce script), puis exécuter celui-ci, puis recharger.

begin;

-- -------------------------------------------------------------------- Unités
-- Liste fixe, créée / modifiée uniquement en SQL. id explicite : l'unité par défaut (g) vaut 1.
create table if not exists food.units (
  id       smallint primary key,
  name     text     not null unique check (name = btrim(name) and name <> ''),
  plural   text     not null check (plural = btrim(plural) and plural <> ''),
  position smallint not null default 0
);

insert into food.units (id, name, plural, position) values
  (1, 'g',          'g',          1),
  (2, 'ml',         'ml',         2),
  (3, 'pièce',      'pièces',     3),
  (4, 'c. à soupe', 'c. à soupe', 4),
  (5, 'c. à café',  'c. à café',  5)
on conflict (id) do nothing;

alter table food.units enable row level security;
revoke all on food.units from anon, authenticated;

-- Unité d'un ingrédient (g par défaut) : toutes ses quantités sont exprimées dans cette unité.
alter table food.ingredients
  add column if not exists unit_id smallint not null default 1 references food.units (id) on delete restrict;
create index if not exists ingredients_unit_idx on food.ingredients (unit_id);

-- Quantité d'un ingrédient pour 1 portion de l'aliment (null : non définie).
alter table food.food_ingredients
  add column if not exists quantity numeric(8, 3) check (quantity > 0);

-- Nombre de portions d'un aliment dans un repas (multiplicateur des quantités de base).
alter table food.meal_items
  add column if not exists portions numeric(4, 2) not null default 1 check (portions > 0 and portions <= 99);

-- ----------------------------------- Anciennes fonctions (signature qui change)
-- Supprimées d'abord : une surcharge ancienne + nouvelle rendrait les appels ambigus.
drop function if exists food.get_meals(text, text, date, date);
drop function if exists food.set_meal(text, text, date, text, bigint[]);
drop function if exists food.add_food(text, text, text, smallint[], text[]);
drop function if exists food.update_food(text, text, bigint, text, smallint[], text[]);
drop function if exists food.get_ingredients(text, text);
drop function if exists food.add_ingredient(text, text, text);
drop function if exists food.update_ingredient(text, text, bigint, text);
drop function if exists food._food_state(text, smallint[], text[]);
drop function if exists food._set_food_ingredients(bigint, text[]);
drop function if exists food._clean_ingredients(text[]);
drop function if exists food._food_ingredient_names(bigint);

-- ------------------------------------------------------ Fonctions internes
-- Unité par défaut (la première dans l'ordre d'affichage : g).
create or replace function food._default_unit()
returns smallint
language sql
stable
security definer
set search_path = food
as $$
  select u.id from food.units u order by u.position, u.id limit 1;
$$;

-- État d'un ingrédient pour l'audit : { name, unit }.
create or replace function food._ingredient_state(n text, uid smallint)
returns jsonb
language sql
security definer
set search_path = food
as $$
  select jsonb_build_object('name', n, 'unit', (select u.name from food.units u where u.id = uid));
$$;

-- Lignes d'ingrédients saisies pour un aliment : JSON [{ name, quantity, unit_id }] (un simple tableau de
-- noms est accepté). Renvoie les lignes normalisées : noms en minuscules sans doublon, quantité null ou
-- strictement positive (99999 au plus, 3 décimales au plus), unité = celle de l'ingrédient s'il existe,
-- sinon celle demandée (g par défaut). Erreurs : invalid_name, invalid_quantity, unknown_unit.
create or replace function food._clean_ing_rows(ings jsonb)
returns jsonb
language plpgsql
security definer
set search_path = food
as $$
declare
  e jsonb;
  nm text;
  q numeric;
  uid smallint;
  k smallint;
  res jsonb := '[]'::jsonb;
  seen text[] := '{}';
begin
  if ings is null or jsonb_typeof(ings) <> 'array' then
    return res;
  end if;
  for e in select value from jsonb_array_elements(ings) loop
    if jsonb_typeof(e) = 'string' then
      nm := lower(btrim(e #>> '{}'));
      q := null;
      uid := null;
    elsif jsonb_typeof(e) = 'object' then
      nm := lower(btrim(coalesce(e ->> 'name', '')));
      q := case when jsonb_typeof(e -> 'quantity') = 'number' then (e ->> 'quantity')::numeric end;
      uid := case when jsonb_typeof(e -> 'unit_id') = 'number' then (e ->> 'unit_id')::smallint end;
    else
      continue;
    end if;
    if nm = '' then
      continue;
    end if;
    if char_length(nm) > 60 then
      raise exception 'invalid_name';
    end if;
    if q is not null and not (q > 0 and q <= 99999 and round(q, 3) = q) then
      raise exception 'invalid_quantity';
    end if;
    if uid is not null and not exists (select 1 from food.units u where u.id = uid) then
      raise exception 'unknown_unit';
    end if;
    if nm = any (seen) then
      continue;
    end if;
    seen := seen || nm;
    select i.unit_id into k from food.ingredients i where i.name = nm;
    res := res || jsonb_build_object('name', nm, 'quantity', q, 'unit_id', coalesce(k, uid, food._default_unit()));
  end loop;
  return res;
end;
$$;

-- Ingrédients d'un aliment : JSON [{ name, quantity, unit_id }] trié par nom (quantity : null si non définie).
create or replace function food._food_ingredient_rows(fid bigint)
returns jsonb
language sql
stable
security definer
set search_path = food
as $$
  select coalesce(jsonb_agg(jsonb_build_object('name', i.name, 'quantity', fi.quantity, 'unit_id', i.unit_id)
                            order by i.name), '[]'::jsonb)
  from food.food_ingredients fi
  join food.ingredients i on i.id = fi.ingredient_id
  where fi.food_id = fid;
$$;

-- Remplace les ingrédients d'un aliment par les lignes données (déjà normalisées par _clean_ing_rows) :
-- les ingrédients qui n'existent pas sont créés (avec l'unité de la ligne), ceux qui existent sont réutilisés ;
-- la quantité du lien est celle de la ligne. Un ingrédient délié n'est jamais supprimé automatiquement.
create or replace function food._set_food_ingredients(fid bigint, lines jsonb)
returns void
language plpgsql
security definer
set search_path = food
as $$
declare
  l jsonb;
  iid bigint;
  iids bigint[] := '{}';
begin
  for l in select value from jsonb_array_elements(lines) loop
    select i.id into iid from food.ingredients i where i.name = (l ->> 'name');
    if iid is null then
      insert into food.ingredients (name, unit_id) values (l ->> 'name', (l ->> 'unit_id')::smallint)
      returning id into iid;
    end if;
    iids := iids || iid;
    insert into food.food_ingredients (food_id, ingredient_id, quantity)
    values (fid, iid, case when jsonb_typeof(l -> 'quantity') = 'number' then (l ->> 'quantity')::numeric end)
    on conflict (food_id, ingredient_id) do update set quantity = excluded.quantity;
  end loop;
  delete from food.food_ingredients where food_id = fid and not (ingredient_id = any (iids));
end;
$$;

-- État d'un aliment pour l'audit : { name, classes, ingredients: [{ name, quantity, unit }] }.
create or replace function food._food_state(n text, cids smallint[], lines jsonb)
returns jsonb
language sql
security definer
set search_path = food
as $$
  select jsonb_build_object(
    'name', n,
    'classes', food._class_names(cids),
    'ingredients', coalesce((
      select jsonb_agg(jsonb_build_object('name', e ->> 'name', 'quantity', e -> 'quantity',
                                          'unit', (select u.name from food.units u where u.id = (e ->> 'unit_id')::smallint))
                       order by e ->> 'name')
      from jsonb_array_elements(lines) e), '[]'::jsonb));
$$;

-- ----------------------------------------------------- Fonctions publiques
-- Classes, unités et aliments (tous rôles). Pour chaque aliment : nombre de repas où il est utilisé et ses
-- ingrédients { name, quantity (pour 1 portion, null si non définie), unit_id }.
create or replace function food.get_catalog(u text, p text)
returns jsonb
language plpgsql
security definer
set search_path = food, extensions
as $$
begin
  perform food._check(u, p, array['read', 'write', 'admin']);
  return jsonb_build_object(
    'classes', (select coalesce(jsonb_agg(jsonb_build_object(
                  'id', c.id, 'name', c.name, 'part_name', c.part_name, 'type', c.type)
                  order by c.position, c.id), '[]'::jsonb) from food.classes c),
    'units',   (select coalesce(jsonb_agg(jsonb_build_object(
                  'id', un.id, 'name', un.name, 'plural', un.plural)
                  order by un.position, un.id), '[]'::jsonb) from food.units un),
    'foods',   (select coalesce(jsonb_agg(jsonb_build_object(
                  'id', f.id, 'name', f.name,
                  'class_ids', (select coalesce(jsonb_agg(fc.class_id order by fc.class_id), '[]'::jsonb)
                                from food.food_classes fc where fc.food_id = f.id),
                  'uses', (select count(*) from food.meal_items mi where mi.food_id = f.id),
                  'ingredients', food._food_ingredient_rows(f.id))
                  order by f.name), '[]'::jsonb) from food.foods f)
  );
end;
$$;

-- Repas entre deux dates incluses (tous rôles). Une ligne par aliment ; class_ids ne contient que les
-- classes de type composante (les classes combo ne sont jamais affichées dans les repas) ; portions :
-- nombre de portions de l'aliment dans le repas.
create or replace function food.get_meals(u text, p text, d_from date, d_to date)
returns table (meal_date date, slot text, food_id bigint, food_name text, class_ids smallint[], portions numeric)
language plpgsql
security definer
set search_path = food, extensions
as $$
begin
  perform food._check(u, p, array['read', 'write', 'admin']);
  return query
    select m.meal_date, m.slot, f.id, f.name,
           (select array_agg(fc.class_id order by fc.class_id)
            from food.food_classes fc
            join food.classes c on c.id = fc.class_id
            where fc.food_id = f.id and c.type = 'composante'),
           mi.portions
    from food.meals m
    join food.meal_items mi on mi.meal_id = m.id
    join food.foods f on f.id = mi.food_id
    where m.meal_date between d_from and d_to
    order by m.meal_date, m.slot, f.name;
end;
$$;

-- Remplace entièrement un repas (rôles write et admin). Liste vide = repas vidé. `portions` : tableau
-- parallèle à food_ids (nombre de portions de chaque aliment ; 1 si absent) : strictement positif, 99 au
-- plus, 2 décimales au plus ('invalid_portions'). Un aliment en double compte une seule fois (le premier).
-- Seuls les jours des 15 derniers jours à +30 jours sont modifiables. Un créneau bloqué par une contrainte
-- du jour ne peut pas être rempli ('slot_blocked') ; le vider reste possible.
create or replace function food.set_meal(u text, p text, d date, s text, food_ids bigint[], portions numeric[] default null)
returns void
language plpgsql
security definer
set search_path = food, extensions
as $$
declare
  r text;
  slot_ text := lower(s);
  ids bigint[];
  ps numeric[];
  mid bigint;
  before_names jsonb;
  after_names jsonb;
begin
  r := food._check(u, p, array['write', 'admin']);
  if slot_ not in ('midi', 'soir') then
    raise exception 'invalid_slot';
  end if;
  if d < food._today() - 15 or d > food._today() + 30 then
    raise exception 'out_of_window';
  end if;

  select coalesce(array_agg(t.fid order by t.ord), '{}'), coalesce(array_agg(t.pv order by t.ord), '{}')
    into ids, ps
  from (
    select distinct on (x.fid) x.fid, x.ord, coalesce(pp.pv, 1) as pv
    from unnest(coalesce(food_ids, '{}')) with ordinality as x(fid, ord)
    left join unnest(coalesce(portions, '{}')) with ordinality as pp(pv, ord) on pp.ord = x.ord
    order by x.fid, x.ord
  ) t;
  if exists (select 1 from unnest(ps) v where v <= 0 or v > 99 or round(v, 2) <> v) then
    raise exception 'invalid_portions';
  end if;
  if (select count(*) from food.foods where id = any (ids)) <> cardinality(ids) then
    raise exception 'unknown_food';
  end if;
  if cardinality(ids) > 0 and exists (
       select 1 from food.day_constraints dc
       join food.constraints k on k.id = dc.constraint_id
       join food.effects e on e.id = k.effect_id
       where dc.day_date = d and e.blocked_slot = slot_) then
    raise exception 'slot_blocked';
  end if;

  -- Un aliment dont les portions ne valent pas 1 est écrit avec son multiplicateur (« poulet ×1.5 »).
  select coalesce(jsonb_agg(f.name || case when mi.portions <> 1 then ' ×' || trim_scale(mi.portions)::text else '' end
                            order by f.name), '[]'::jsonb) into before_names
  from food.meals m
  join food.meal_items mi on mi.meal_id = m.id
  join food.foods f on f.id = mi.food_id
  where m.meal_date = d and m.slot = slot_;
  select coalesce(jsonb_agg(f.name || case when t.pv <> 1 then ' ×' || trim_scale(t.pv)::text else '' end
                            order by f.name), '[]'::jsonb) into after_names
  from unnest(ids, ps) as t(fid, pv)
  join food.foods f on f.id = t.fid;

  -- Rien n'est écrit (ni consigné) si le repas ne change pas (aliments et portions).
  if before_names <> after_names then
    if cardinality(ids) = 0 then
      delete from food.meals where meal_date = d and slot = slot_;
    else
      insert into food.meals (meal_date, slot) values (d, slot_)
      on conflict (meal_date, slot) do update set slot = excluded.slot
      returning id into mid;
      delete from food.meal_items where meal_id = mid;
      insert into food.meal_items (meal_id, food_id, portions)
      select mid, t.fid, t.pv from unnest(ids, ps) as t(fid, pv);
    end if;

    perform food._audit(
      u, r,
      case when before_names = '[]'::jsonb then 'meal_create'
           when cardinality(ids) = 0 then 'meal_clear'
           else 'meal_update' end,
      d::text || ' ' || slot_, before_names, after_names);
  end if;

  perform food._purge_old_data();
end;
$$;

-- Ajoute un aliment avec une ou plusieurs classes (rôle admin uniquement). Au moins une classe de type
-- composante. `ings` : JSON [{ name, quantity, unit_id }] (quantité pour 1 portion, facultative ; unit_id
-- seulement pour un ingrédient créé). Un aliment simple a 1 ingrédient de même nom (seules la quantité et
-- l'unité de la première ligne comptent) ; une recette a au moins 1 ingrédient ; avec 2 ingrédients ou
-- plus la classe Recettes est ajoutée d'office.
create or replace function food.add_food(u text, p text, n text, cids smallint[], ings jsonb default null)
returns bigint
language plpgsql
security definer
set search_path = food, extensions
as $$
declare
  r text;
  name_ text := lower(btrim(coalesce(n, '')));
  ids smallint[];
  lines jsonb;
  first_row jsonb;
  uid smallint;
  combo smallint;
  new_id bigint;
begin
  r := food._check(u, p, array['admin']);
  if name_ = '' or char_length(name_) > 60 then
    raise exception 'invalid_name';
  end if;
  ids := food._clean_classes(cids);
  lines := food._clean_ing_rows(ings);
  if food._is_recipe(ids) or jsonb_array_length(lines) >= 2 then
    if jsonb_array_length(lines) = 0 then
      raise exception 'ingredients_required';
    end if;
    if not food._is_recipe(ids) then
      select c.id into combo from food.classes c where c.type = 'combo' order by c.position, c.id limit 1;
      if combo is not null then
        select array_agg(distinct x order by x) into ids from unnest(ids || combo) x;
      end if;
    end if;
  else
    first_row := lines -> 0;
    select i.unit_id into uid from food.ingredients i where i.name = name_;
    uid := coalesce(uid, (first_row ->> 'unit_id')::smallint, food._default_unit());
    lines := jsonb_build_array(jsonb_build_object('name', name_, 'quantity', first_row -> 'quantity', 'unit_id', uid));
  end if;
  if exists (select 1 from food.foods where name = name_) then
    raise exception 'food_exists';
  end if;
  insert into food.foods (name) values (name_) returning id into new_id;
  insert into food.food_classes (food_id, class_id) select new_id, unnest(ids);
  perform food._set_food_ingredients(new_id, lines);
  perform food._audit(u, r, 'food_add', name_, null,
                      food._food_state(name_, ids, food._food_ingredient_rows(new_id)));
  return new_id;
end;
$$;

-- Modifie le nom, les classes et les ingrédients (avec leurs quantités) d'un aliment (rôle admin
-- uniquement). Mêmes règles d'ingrédients que add_food. Les repas qui l'utilisent suivent automatiquement
-- (ils pointent vers l'id). Sur un aliment déjà utilisé dans des repas, on peut ajouter des classes de type
-- composante mais pas en retirer (la classe Recettes, de type combo, peut être ajoutée ou retirée librement).
create or replace function food.update_food(u text, p text, fid bigint, n text, cids smallint[], ings jsonb default null)
returns void
language plpgsql
security definer
set search_path = food, extensions
as $$
declare
  r text;
  name_ text := lower(btrim(coalesce(n, '')));
  ids smallint[];
  old_name text;
  old_ids smallint[];
  old_comp smallint[];
  old_rows jsonb;
  lines jsonb;
  new_rows jsonb;
  first_row jsonb;
  uid smallint;
  combo smallint;
begin
  r := food._check(u, p, array['admin']);
  if name_ = '' or char_length(name_) > 60 then
    raise exception 'invalid_name';
  end if;
  select f.name into old_name from food.foods f where f.id = fid;
  if not found then
    raise exception 'unknown_food';
  end if;
  ids := food._clean_classes(cids);
  lines := food._clean_ing_rows(ings);
  if food._is_recipe(ids) or jsonb_array_length(lines) >= 2 then
    if jsonb_array_length(lines) = 0 then
      raise exception 'ingredients_required';
    end if;
    if not food._is_recipe(ids) then
      select c.id into combo from food.classes c where c.type = 'combo' order by c.position, c.id limit 1;
      if combo is not null then
        select array_agg(distinct x order by x) into ids from unnest(ids || combo) x;
      end if;
    end if;
  else
    first_row := lines -> 0;
    select i.unit_id into uid from food.ingredients i where i.name = name_;
    uid := coalesce(uid, (first_row ->> 'unit_id')::smallint, food._default_unit());
    lines := jsonb_build_array(jsonb_build_object('name', name_, 'quantity', first_row -> 'quantity', 'unit_id', uid));
  end if;
  select coalesce(array_agg(fc.class_id order by fc.class_id), '{}') into old_ids
  from food.food_classes fc where fc.food_id = fid;
  select coalesce(array_agg(fc.class_id order by fc.class_id), '{}') into old_comp
  from food.food_classes fc
  join food.classes c on c.id = fc.class_id
  where fc.food_id = fid and c.type = 'composante';
  old_rows := food._food_ingredient_rows(fid);
  select coalesce(jsonb_agg(e order by e ->> 'name'), '[]'::jsonb) into new_rows from jsonb_array_elements(lines) e;
  if exists (select 1 from food.foods where name = name_ and id <> fid) then
    raise exception 'food_exists';
  end if;
  if not (old_comp <@ ids) and exists (select 1 from food.meal_items where food_id = fid) then
    raise exception 'food_in_use_class';
  end if;

  -- Rien n'est écrit (ni consigné) si l'aliment ne change pas (nom, classes, ingrédients et quantités).
  if name_ <> old_name or ids <> old_ids or new_rows <> old_rows then
    update food.foods set name = name_ where id = fid;
    delete from food.food_classes where food_id = fid and not (class_id = any (ids));
    insert into food.food_classes (food_id, class_id) select fid, unnest(ids)
    on conflict do nothing;
    perform food._set_food_ingredients(fid, lines);
    perform food._audit(u, r, 'food_update', old_name,
                        food._food_state(old_name, old_ids, old_rows),
                        food._food_state(name_, ids, food._food_ingredient_rows(fid)));
  end if;
end;
$$;

-- Supprime un aliment (rôle admin uniquement), bloqué s'il est utilisé dans un repas. Si c'est le cas, l'erreur
-- donne la liste des repas (JSON { n, items }). Ses ingrédients restent en base (aucun nettoyage automatique).
create or replace function food.delete_food(u text, p text, fid bigint)
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
  old_ids smallint[];
begin
  r := food._check(u, p, array['admin']);
  select count(*) into n from food.meal_items where food_id = fid;
  if n > 0 then
    select coalesce(jsonb_agg(m.meal_date::text || '|' || m.slot order by m.meal_date desc, m.slot), '[]'::jsonb)
      into items
    from food.meal_items mi
    join food.meals m on m.id = mi.meal_id
    where mi.food_id = fid;
    raise exception 'food_in_use' using detail = jsonb_build_object('n', n, 'items', items)::text;
  end if;
  select f.name into old_name from food.foods f where f.id = fid;
  if found then
    select coalesce(array_agg(fc.class_id order by fc.class_id), '{}') into old_ids
    from food.food_classes fc where fc.food_id = fid;
    perform food._audit(u, r, 'food_delete', old_name,
                        food._food_state(old_name, old_ids, food._food_ingredient_rows(fid)), null);
    delete from food.foods where id = fid;
  end if;
end;
$$;

-- Ingrédients (rôle admin uniquement), avec le nombre d'aliments qui les utilisent et leur unité.
create or replace function food.get_ingredients(u text, p text)
returns table (id bigint, name text, uses bigint, unit_id smallint)
language plpgsql
security definer
set search_path = food, extensions
as $$
begin
  perform food._check(u, p, array['admin']);
  return query
    select i.id, i.name,
           (select count(*) from food.food_ingredients fi where fi.ingredient_id = i.id),
           i.unit_id
    from food.ingredients i
    order by i.name, i.id;
end;
$$;

-- Crée un ingrédient avec son unité (g par défaut) (rôle admin uniquement). Le nom est unique, en minuscules.
create or replace function food.add_ingredient(u text, p text, n text, uid smallint default null)
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
  if exists (select 1 from food.ingredients i where i.name = name_) then
    raise exception 'ingredient_exists';
  end if;
  insert into food.ingredients (name, unit_id) values (name_, unit_) returning id into new_id;
  perform food._audit(u, r, 'ingredient_add', name_, null, food._ingredient_state(name_, unit_));
  return new_id;
end;
$$;

-- Modifie le nom et l'unité d'un ingrédient (rôle admin uniquement ; uid null : l'unité ne change pas). Les
-- aliments qui l'utilisent suivent automatiquement. Changer l'unité ne convertit pas les quantités déjà saisies.
-- Renommer est refusé si le nom existe déjà, ou si l'ingrédient est celui d'un aliment simple (il doit
-- garder le nom de son aliment).
create or replace function food.update_ingredient(u text, p text, iid bigint, n text, uid smallint default null)
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
  unit_ smallint;
begin
  r := food._check(u, p, array['admin']);
  if name_ = '' or char_length(name_) > 60 then
    raise exception 'invalid_name';
  end if;
  select i.name, i.unit_id into old_name, old_unit from food.ingredients i where i.id = iid;
  if not found then
    raise exception 'unknown_ingredient';
  end if;
  unit_ := coalesce(uid, old_unit);
  if not exists (select 1 from food.units un where un.id = unit_) then
    raise exception 'unknown_unit';
  end if;
  if exists (select 1 from food.ingredients i where i.name = name_ and i.id <> iid) then
    raise exception 'ingredient_exists';
  end if;

  -- Rien n'est écrit (ni consigné) si ni le nom ni l'unité ne changent.
  if name_ <> old_name or unit_ <> old_unit then
    if name_ <> old_name and exists (
         select 1 from food.food_ingredients fi
         where fi.ingredient_id = iid
           and not exists (select 1 from food.food_classes fc
                           join food.classes c on c.id = fc.class_id
                           where fc.food_id = fi.food_id and c.type = 'combo')) then
      raise exception 'ingredient_of_simple_food';
    end if;
    update food.ingredients set name = name_, unit_id = unit_ where id = iid;
    perform food._audit(u, r, 'ingredient_update', old_name,
                        food._ingredient_state(old_name, old_unit), food._ingredient_state(name_, unit_));
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
  select i.name, i.unit_id into old_name, old_unit from food.ingredients i where i.id = iid;
  if found then
    delete from food.ingredients where id = iid;
    perform food._audit(u, r, 'ingredient_delete', old_name, food._ingredient_state(old_name, old_unit), null);
  end if;
end;
$$;

-- ---------------------------------------------------------------- Droits
revoke execute on function food._default_unit()                          from public, anon, authenticated;
revoke execute on function food._ingredient_state(text, smallint)        from public, anon, authenticated;
revoke execute on function food._clean_ing_rows(jsonb)                   from public, anon, authenticated;
revoke execute on function food._food_ingredient_rows(bigint)            from public, anon, authenticated;
revoke execute on function food._set_food_ingredients(bigint, jsonb)     from public, anon, authenticated;
revoke execute on function food._food_state(text, smallint[], jsonb)     from public, anon, authenticated;

revoke execute on function food.get_meals(text, text, date, date)                            from public;
revoke execute on function food.set_meal(text, text, date, text, bigint[], numeric[])        from public;
revoke execute on function food.add_food(text, text, text, smallint[], jsonb)                from public;
revoke execute on function food.update_food(text, text, bigint, text, smallint[], jsonb)     from public;
revoke execute on function food.get_ingredients(text, text)                                  from public;
revoke execute on function food.add_ingredient(text, text, text, smallint)                   from public;
revoke execute on function food.update_ingredient(text, text, bigint, text, smallint)        from public;

grant execute on function food.get_meals(text, text, date, date)                             to anon, authenticated;
grant execute on function food.set_meal(text, text, date, text, bigint[], numeric[])         to anon, authenticated;
grant execute on function food.add_food(text, text, text, smallint[], jsonb)                 to anon, authenticated;
grant execute on function food.update_food(text, text, bigint, text, smallint[], jsonb)      to anon, authenticated;
grant execute on function food.get_ingredients(text, text)                                   to anon, authenticated;
grant execute on function food.add_ingredient(text, text, text, smallint)                    to anon, authenticated;
grant execute on function food.update_ingredient(text, text, bigint, text, smallint)         to anon, authenticated;

commit;

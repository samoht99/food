-- Migration : fin du lien entre un aliment simple et « son » ingrédient (specs v2-4).
-- À exécuter une fois dans Supabase (SQL Editor), APRÈS la migration 010 (et 011 / 012 si vous les utilisez).
--
-- Avant : un aliment simple avait un ingrédient de même nom, créé automatiquement et impossible à renommer
-- séparément. Maintenant : un aliment simple a exactement 1 ingrédient, quel que soit son nom, à choisir ou à
-- créer à la volée ; renommer l'un ne touche pas l'autre. Les données existantes ne changent pas (les
-- ingrédients actuels portent simplement le même nom que leur aliment).
--
-- Fonctions remplacées (mêmes signatures) : add_food, update_food, update_ingredient.
--   add_food / update_food : au moins 1 ingrédient pour tout aliment (ingredients_required) ; la classe
--     Recettes est ajoutée d'office à partir de 2 ingrédients ; plus d'ingrédient créé d'après le nom de l'aliment.
--   update_ingredient : plus d'erreur ingredient_of_simple_food.

begin;

-- Ajoute un aliment avec une ou plusieurs classes (rôle admin uniquement). Au moins une classe de type
-- composante. `ings` : JSON [{ name, quantity, unit_id }] (quantité pour 1 portion, facultative ; unit_id
-- seulement pour un ingrédient créé). Un aliment a au moins 1 ingrédient, de n'importe quel nom ; avec 2
-- ingrédients ou plus la classe Recettes est ajoutée d'office.
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
  combo smallint;
  new_id bigint;
begin
  r := food._check(u, p, array['admin']);
  if name_ = '' or char_length(name_) > 60 then
    raise exception 'invalid_name';
  end if;
  ids := food._clean_classes(cids);
  lines := food._clean_ing_rows(ings);
  if jsonb_array_length(lines) = 0 then
    raise exception 'ingredients_required';
  end if;
  if jsonb_array_length(lines) >= 2 and not food._is_recipe(ids) then
    select c.id into combo from food.classes c where c.type = 'combo' order by c.position, c.id limit 1;
    if combo is not null then
      select array_agg(distinct x order by x) into ids from unnest(ids || combo) x;
    end if;
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
  if jsonb_array_length(lines) = 0 then
    raise exception 'ingredients_required';
  end if;
  if jsonb_array_length(lines) >= 2 and not food._is_recipe(ids) then
    select c.id into combo from food.classes c where c.type = 'combo' order by c.position, c.id limit 1;
    if combo is not null then
      select array_agg(distinct x order by x) into ids from unnest(ids || combo) x;
    end if;
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

-- Modifie le nom et l'unité d'un ingrédient (rôle admin uniquement ; uid null : l'unité ne change pas). Les
-- aliments qui l'utilisent suivent automatiquement. Changer l'unité ne convertit pas les quantités déjà saisies.
-- Renommer est refusé si le nom existe déjà.
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
    update food.ingredients set name = name_, unit_id = unit_ where id = iid;
    perform food._audit(u, r, 'ingredient_update', old_name,
                        food._ingredient_state(old_name, old_unit), food._ingredient_state(name_, unit_));
  end if;
end;
$$;

commit;

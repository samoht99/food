-- Migration : recettes et ingrédients (specs v2-1), partie STRUCTURE.
-- À exécuter une fois dans Supabase (SQL Editor), en une seule fois, APRÈS la migration 005.
--
-- Ajoute un type aux classes (composante | combo), la classe Recettes (combo, sans partie de repas),
-- la liste des ingrédients (food.ingredients) et leur lien avec les aliments (food.food_ingredients),
-- les fonctions qui vont avec, étend le journal d'audit (3 nouvelles actions) et adapte
-- get_catalog, get_meals, add_food, update_food et delete_food.
-- add_food et update_food reçoivent un paramètre en plus (liste des ingrédients).
--
-- Ce script ne crée AUCUN ingrédient pour les aliments existants (c'est le rôle de 007).
-- Déroulement complet :
--   1. exécuter ce script (006)
--   2. marquer en SQL les aliments qui sont des recettes (ajouter la classe Recettes), par exemple :
--        insert into food.food_classes (food_id, class_id)
--        select f.id, (select id from food.classes where name = 'Recettes')
--        from food.foods f
--        where f.name in ('lasagnes', 'sandwich jambon-salade')
--        on conflict do nothing;
--   3. exécuter 007 (crée un ingrédient pour chaque aliment qui n'est pas une recette)
--   4. dans l'onglet Admin du site, ouvrir chaque recette et saisir ses ingrédients
-- Attention : après ce script, l'ancien site (v1) n'affiche plus correctement les repas
-- (la classe Recettes n'a pas de partie de repas). Idéal : exécuter 006, puis publier le site v2
-- (fusion dans main), puis recharger (Ctrl+F5).

begin;

-- ------------------------------------------------------------------ Classes
alter table food.classes add column if not exists type text not null default 'composante';
alter table food.classes drop constraint if exists classes_type_check;
alter table food.classes add constraint classes_type_check check (type in ('composante', 'combo'));
-- Une classe combo n'a pas de partie de repas ; une classe composante en a une.
alter table food.classes alter column part_name drop not null;
alter table food.classes drop constraint if exists classes_part_type_check;
alter table food.classes add constraint classes_part_type_check
  check ((type = 'composante') = (part_name is not null));

insert into food.classes (name, part_name, position, type) values
  ('Recettes', null, 6, 'combo')
on conflict do nothing;

-- -------------------------------------------------------------- Ingrédients
create table if not exists food.ingredients (
  id   bigint generated always as identity primary key,
  name text   not null unique
       check (name = lower(name) and name = btrim(name) and name <> '' and char_length(name) <= 60)
);

create table if not exists food.food_ingredients (
  food_id       bigint not null references food.foods (id) on delete cascade,
  ingredient_id bigint not null references food.ingredients (id) on delete restrict,
  primary key (food_id, ingredient_id)
);
create index if not exists food_ingredients_ingredient_idx on food.food_ingredients (ingredient_id);

alter table food.ingredients      enable row level security;
alter table food.food_ingredients enable row level security;
revoke all on food.ingredients, food.food_ingredients from anon, authenticated;

alter table food.audit_log drop constraint if exists audit_log_action_check;
alter table food.audit_log add constraint audit_log_action_check check (action in
  ('meal_create', 'meal_update', 'meal_clear', 'food_add', 'food_update', 'food_delete',
   'day_constraint_create', 'day_constraint_update', 'day_constraint_clear',
   'constraint_add', 'constraint_update', 'constraint_delete',
   'ingredient_add', 'ingredient_update', 'ingredient_delete'));

-- ------------------------------------------------------ Fonctions internes
-- Vrai si la liste de classes contient une classe de type combo (= l'aliment est une recette).
create or replace function food._is_recipe(cids smallint[])
returns boolean
language sql
stable
security definer
set search_path = food
as $$
  select exists (select 1 from food.classes c where c.id = any (cids) and c.type = 'combo');
$$;

-- Classes d'un aliment : liste normalisée (sans doublon, triée). Refuse une liste vide
-- ('invalid_classes'), une classe inconnue ('unknown_class') ou une liste sans aucune classe
-- de type composante ('class_component_required').
create or replace function food._clean_classes(cids smallint[])
returns smallint[]
language plpgsql
security definer
set search_path = food
as $$
declare
  ids smallint[];
begin
  select coalesce(array_agg(distinct x order by x), '{}') into ids
  from unnest(coalesce(cids, '{}')) x
  where x is not null;
  if cardinality(ids) = 0 then
    raise exception 'invalid_classes';
  end if;
  if (select count(*) from food.classes where id = any (ids)) <> cardinality(ids) then
    raise exception 'unknown_class';
  end if;
  if not exists (select 1 from food.classes c where c.id = any (ids) and c.type = 'composante') then
    raise exception 'class_component_required';
  end if;
  return ids;
end;
$$;

-- Noms d'ingrédients saisis : minuscules, sans espaces autour, sans vide ni doublon, triés.
-- Refuse un nom de plus de 60 caractères ('invalid_name').
create or replace function food._clean_ingredients(ings text[])
returns text[]
language plpgsql
security definer
set search_path = food
as $$
declare
  names text[];
begin
  select coalesce(array_agg(distinct s.n order by s.n), '{}') into names
  from (select lower(btrim(x)) as n from unnest(coalesce(ings, '{}')) x) s
  where s.n is not null and s.n <> '';
  if exists (select 1 from unnest(names) n where char_length(n) > 60) then
    raise exception 'invalid_name';
  end if;
  return names;
end;
$$;

-- Noms des ingrédients d'un aliment, triés.
create or replace function food._food_ingredient_names(fid bigint)
returns text[]
language sql
stable
security definer
set search_path = food
as $$
  select coalesce(array_agg(i.name order by i.name), '{}')
  from food.food_ingredients fi
  join food.ingredients i on i.id = fi.ingredient_id
  where fi.food_id = fid;
$$;

-- Remplace les ingrédients d'un aliment par la liste de noms donnée (déjà normalisée) :
-- les ingrédients qui n'existent pas sont créés, ceux qui existent sont réutilisés.
-- Un ingrédient délié d'un aliment n'est jamais supprimé automatiquement.
create or replace function food._set_food_ingredients(fid bigint, names text[])
returns void
language plpgsql
security definer
set search_path = food
as $$
declare
  iids bigint[];
begin
  insert into food.ingredients (name) select unnest(names) on conflict (name) do nothing;
  select coalesce(array_agg(i.id order by i.id), '{}') into iids
  from food.ingredients i where i.name = any (names);
  delete from food.food_ingredients where food_id = fid and not (ingredient_id = any (iids));
  insert into food.food_ingredients (food_id, ingredient_id) select fid, unnest(iids)
  on conflict do nothing;
end;
$$;

-- État d'un aliment pour l'audit : { name, classes } et, pour une recette, { ..., ingredients }.
create or replace function food._food_state(n text, cids smallint[], ings text[])
returns jsonb
language sql
security definer
set search_path = food
as $$
  select jsonb_build_object('name', n, 'classes', food._class_names(cids))
         || case when food._is_recipe(cids)
                 then jsonb_build_object('ingredients', to_jsonb(ings))
                 else '{}'::jsonb end;
$$;

-- ----------------------------------------------------- Fonctions publiques
-- Classes et aliments (tous rôles). Pour chaque aliment : nombre de repas où il est utilisé
-- et, pour une recette, ses ingrédients.
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
    'foods',   (select coalesce(jsonb_agg(jsonb_build_object(
                  'id', f.id, 'name', f.name,
                  'class_ids', (select coalesce(jsonb_agg(fc.class_id order by fc.class_id), '[]'::jsonb)
                                from food.food_classes fc where fc.food_id = f.id),
                  'uses', (select count(*) from food.meal_items mi where mi.food_id = f.id),
                  'ingredients', (select coalesce(jsonb_agg(i.name order by i.name), '[]'::jsonb)
                                  from food.food_ingredients fi
                                  join food.ingredients i on i.id = fi.ingredient_id
                                  where fi.food_id = f.id
                                    and exists (select 1 from food.food_classes fc2
                                                join food.classes c2 on c2.id = fc2.class_id
                                                where fc2.food_id = f.id and c2.type = 'combo')))
                  order by f.name), '[]'::jsonb) from food.foods f)
  );
end;
$$;

-- Repas entre deux dates incluses (tous rôles). Une ligne par aliment ; class_ids ne contient
-- que les classes de type composante (les classes combo ne sont jamais affichées dans les repas).
create or replace function food.get_meals(u text, p text, d_from date, d_to date)
returns table (meal_date date, slot text, food_id bigint, food_name text, class_ids smallint[])
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
            where fc.food_id = f.id and c.type = 'composante')
    from food.meals m
    join food.meal_items mi on mi.meal_id = m.id
    join food.foods f on f.id = mi.food_id
    where m.meal_date between d_from and d_to
    order by m.meal_date, m.slot, f.name;
end;
$$;

-- Ajoute un aliment avec une ou plusieurs classes (rôle admin uniquement). Au moins une classe
-- de type composante. Une recette (classe Recettes) exige au moins un ingrédient (ings) ; un aliment
-- simple reçoit automatiquement un ingrédient de même nom (ings est alors ignoré).
drop function if exists food.add_food(text, text, text, smallint[]);
create or replace function food.add_food(u text, p text, n text, cids smallint[], ings text[] default null)
returns bigint
language plpgsql
security definer
set search_path = food, extensions
as $$
declare
  r text;
  name_ text := lower(btrim(coalesce(n, '')));
  ids smallint[];
  names text[];
  new_id bigint;
begin
  r := food._check(u, p, array['admin']);
  if name_ = '' or char_length(name_) > 60 then
    raise exception 'invalid_name';
  end if;
  ids := food._clean_classes(cids);
  if food._is_recipe(ids) then
    names := food._clean_ingredients(ings);
    if cardinality(names) = 0 then
      raise exception 'ingredients_required';
    end if;
  else
    names := array[name_];
  end if;
  if exists (select 1 from food.foods where name = name_) then
    raise exception 'food_exists';
  end if;
  insert into food.foods (name) values (name_) returning id into new_id;
  insert into food.food_classes (food_id, class_id) select new_id, unnest(ids);
  perform food._set_food_ingredients(new_id, names);
  perform food._audit(u, r, 'food_add', name_, null, food._food_state(name_, ids, names));
  return new_id;
end;
$$;

-- Modifie le nom, les classes et (pour une recette) les ingrédients d'un aliment (rôle admin
-- uniquement). Les repas qui l'utilisent suivent automatiquement (ils pointent vers l'id).
-- Sur un aliment déjà utilisé dans des repas, on peut ajouter des classes de type composante mais
-- pas en retirer (la classe Recettes, de type combo, peut être ajoutée ou retirée librement).
drop function if exists food.update_food(text, text, bigint, text, smallint[]);
create or replace function food.update_food(u text, p text, fid bigint, n text, cids smallint[], ings text[] default null)
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
  old_ings text[];
  new_ings text[];
  recipe boolean;
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
  recipe := food._is_recipe(ids);
  select coalesce(array_agg(fc.class_id order by fc.class_id), '{}') into old_ids
  from food.food_classes fc where fc.food_id = fid;
  select coalesce(array_agg(fc.class_id order by fc.class_id), '{}') into old_comp
  from food.food_classes fc
  join food.classes c on c.id = fc.class_id
  where fc.food_id = fid and c.type = 'composante';
  old_ings := food._food_ingredient_names(fid);
  if recipe then
    new_ings := food._clean_ingredients(ings);
    if cardinality(new_ings) = 0 then
      raise exception 'ingredients_required';
    end if;
  else
    new_ings := array[name_];
  end if;
  if exists (select 1 from food.foods where name = name_ and id <> fid) then
    raise exception 'food_exists';
  end if;
  if not (old_comp <@ ids) and exists (select 1 from food.meal_items where food_id = fid) then
    raise exception 'food_in_use_class';
  end if;

  -- Rien n'est écrit (ni consigné) si l'aliment ne change pas.
  if name_ <> old_name or ids <> old_ids or (recipe and new_ings <> old_ings) then
    update food.foods set name = name_ where id = fid;
    delete from food.food_classes where food_id = fid and not (class_id = any (ids));
    insert into food.food_classes (food_id, class_id) select fid, unnest(ids)
    on conflict do nothing;
    perform food._set_food_ingredients(fid, new_ings);
    perform food._audit(u, r, 'food_update', old_name,
                        food._food_state(old_name, old_ids, old_ings),
                        food._food_state(name_, ids, new_ings));
  end if;
end;
$$;

-- Supprime un aliment (rôle admin uniquement), bloqué s'il est utilisé dans un repas.
-- Ses ingrédients restent en base (aucun nettoyage automatique).
create or replace function food.delete_food(u text, p text, fid bigint)
returns void
language plpgsql
security definer
set search_path = food, extensions
as $$
declare
  r text;
  n integer;
  old_name text;
  old_ids smallint[];
begin
  r := food._check(u, p, array['admin']);
  select count(*) into n from food.meal_items where food_id = fid;
  if n > 0 then
    raise exception 'food_in_use' using detail = n::text;
  end if;
  select f.name into old_name from food.foods f where f.id = fid;
  if found then
    select coalesce(array_agg(fc.class_id order by fc.class_id), '{}') into old_ids
    from food.food_classes fc where fc.food_id = fid;
    perform food._audit(u, r, 'food_delete', old_name,
                        food._food_state(old_name, old_ids, food._food_ingredient_names(fid)), null);
    delete from food.foods where id = fid;
  end if;
end;
$$;

-- Ingrédients (rôle admin uniquement), avec le nombre d'aliments qui les utilisent.
create or replace function food.get_ingredients(u text, p text)
returns table (id bigint, name text, uses bigint)
language plpgsql
security definer
set search_path = food, extensions
as $$
begin
  perform food._check(u, p, array['admin']);
  return query
    select i.id, i.name,
           (select count(*) from food.food_ingredients fi where fi.ingredient_id = i.id)
    from food.ingredients i
    order by i.name, i.id;
end;
$$;

-- Crée un ingrédient (rôle admin uniquement). Le nom est unique, en minuscules.
create or replace function food.add_ingredient(u text, p text, n text)
returns bigint
language plpgsql
security definer
set search_path = food, extensions
as $$
declare
  r text;
  name_ text := lower(btrim(coalesce(n, '')));
  new_id bigint;
begin
  r := food._check(u, p, array['admin']);
  if name_ = '' or char_length(name_) > 60 then
    raise exception 'invalid_name';
  end if;
  if exists (select 1 from food.ingredients i where i.name = name_) then
    raise exception 'ingredient_exists';
  end if;
  insert into food.ingredients (name) values (name_) returning id into new_id;
  perform food._audit(u, r, 'ingredient_add', name_, null, to_jsonb(name_));
  return new_id;
end;
$$;

-- Renomme un ingrédient (rôle admin uniquement). Les aliments qui l'utilisent suivent
-- automatiquement (ils pointent vers l'identifiant). Refusé si le nom existe déjà, ou si
-- l'ingrédient est celui d'un aliment simple (il doit garder le nom de son aliment).
create or replace function food.update_ingredient(u text, p text, iid bigint, n text)
returns void
language plpgsql
security definer
set search_path = food, extensions
as $$
declare
  r text;
  name_ text := lower(btrim(coalesce(n, '')));
  old_name text;
begin
  r := food._check(u, p, array['admin']);
  if name_ = '' or char_length(name_) > 60 then
    raise exception 'invalid_name';
  end if;
  select i.name into old_name from food.ingredients i where i.id = iid;
  if not found then
    raise exception 'unknown_ingredient';
  end if;
  if exists (select 1 from food.ingredients i where i.name = name_ and i.id <> iid) then
    raise exception 'ingredient_exists';
  end if;

  -- Rien n'est écrit (ni consigné) si le nom ne change pas.
  if name_ <> old_name then
    if exists (select 1 from food.food_ingredients fi
               where fi.ingredient_id = iid
                 and not exists (select 1 from food.food_classes fc
                                 join food.classes c on c.id = fc.class_id
                                 where fc.food_id = fi.food_id and c.type = 'combo')) then
      raise exception 'ingredient_of_simple_food';
    end if;
    update food.ingredients set name = name_ where id = iid;
    perform food._audit(u, r, 'ingredient_update', old_name, to_jsonb(old_name), to_jsonb(name_));
  end if;
end;
$$;

-- Supprime un ingrédient (rôle admin uniquement), bloqué s'il est lié à au moins un aliment.
create or replace function food.delete_ingredient(u text, p text, iid bigint)
returns void
language plpgsql
security definer
set search_path = food, extensions
as $$
declare
  r text;
  n integer;
  old_name text;
begin
  r := food._check(u, p, array['admin']);
  select count(*) into n from food.food_ingredients fi where fi.ingredient_id = iid;
  if n > 0 then
    raise exception 'ingredient_in_use' using detail = n::text;
  end if;
  select i.name into old_name from food.ingredients i where i.id = iid;
  if found then
    delete from food.ingredients where id = iid;
    perform food._audit(u, r, 'ingredient_delete', old_name, to_jsonb(old_name), null);
  end if;
end;
$$;

-- ---------------------------------------------------------------- Droits
revoke execute on function food._is_recipe(smallint[])                      from public, anon, authenticated;
revoke execute on function food._clean_classes(smallint[])                  from public, anon, authenticated;
revoke execute on function food._clean_ingredients(text[])                  from public, anon, authenticated;
revoke execute on function food._food_ingredient_names(bigint)              from public, anon, authenticated;
revoke execute on function food._set_food_ingredients(bigint, text[])       from public, anon, authenticated;
revoke execute on function food._food_state(text, smallint[], text[])       from public, anon, authenticated;

revoke execute on function food.add_food(text, text, text, smallint[], text[])             from public;
revoke execute on function food.update_food(text, text, bigint, text, smallint[], text[])  from public;
revoke execute on function food.get_ingredients(text, text)                                from public;
revoke execute on function food.add_ingredient(text, text, text)                           from public;
revoke execute on function food.update_ingredient(text, text, bigint, text)                from public;
revoke execute on function food.delete_ingredient(text, text, bigint)                      from public;

grant execute on function food.add_food(text, text, text, smallint[], text[])              to anon, authenticated;
grant execute on function food.update_food(text, text, bigint, text, smallint[], text[])   to anon, authenticated;
grant execute on function food.get_ingredients(text, text)                                 to anon, authenticated;
grant execute on function food.add_ingredient(text, text, text)                            to anon, authenticated;
grant execute on function food.update_ingredient(text, text, bigint, text)                 to anon, authenticated;
grant execute on function food.delete_ingredient(text, text, bigint)                       to anon, authenticated;

commit;

-- Migration : suppression d'un aliment, d'un ingrédient ou d'une contrainte utilisé(e) (specs v2-1).
-- À exécuter une fois dans Supabase (SQL Editor), APRÈS la migration 007.
--
-- Quand la suppression est bloquée parce que l'élément est utilisé, l'erreur ne donne plus
-- seulement le nombre d'utilisations : elle donne aussi la liste de ce qui l'utilise, sous forme
-- de JSON {"n": nombre, "items": [...]} dans le détail de l'erreur :
--   aliment    -> les repas ("2026-10-28|soir", du plus récent au plus ancien)
--   ingrédient -> les noms des aliments
--   contrainte -> les jours ("2026-10-28", du plus récent au plus ancien)
-- Aucune signature ne change : l'ancien site continue de fonctionner (il affichera le JSON à la
-- place du nombre dans le message d'erreur, jusqu'à la publication du nouveau site).

begin;

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
                        food._food_state(old_name, old_ids, food._food_ingredient_names(fid)), null);
    delete from food.foods where id = fid;
  end if;
end;
$$;

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
  select i.name into old_name from food.ingredients i where i.id = iid;
  if found then
    delete from food.ingredients where id = iid;
    perform food._audit(u, r, 'ingredient_delete', old_name, to_jsonb(old_name), null);
  end if;
end;
$$;

create or replace function food.delete_constraint(u text, p text, cid bigint)
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
begin
  r := food._check(u, p, array['admin']);
  select count(*) into n from food.day_constraints dc where dc.constraint_id = cid;
  if n > 0 then
    select coalesce(jsonb_agg(dc.day_date::text order by dc.day_date desc), '[]'::jsonb) into items
    from food.day_constraints dc
    where dc.constraint_id = cid;
    raise exception 'constraint_in_use' using detail = jsonb_build_object('n', n, 'items', items)::text;
  end if;
  select k.name into old_name from food.constraints k where k.id = cid;
  if found then
    delete from food.constraints where id = cid;
    perform food._audit(u, r, 'constraint_delete', old_name, to_jsonb(old_name), null);
  end if;
end;
$$;

commit;

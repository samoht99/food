-- Migration : un aliment peut appartenir à plusieurs classes (ex. un sandwich est à la fois
-- protéines, féculents et légumes).
-- À exécuter une fois dans Supabase (SQL Editor), en une seule fois, APRÈS la migration 002.
--
-- Les classes d'un aliment passent de la colonne food.foods.class_id à une table de liaison
-- food.food_classes. Les aliments existants sont recopiés (une ligne par aliment), puis la
-- colonne class_id est supprimée. Les fonctions add_food, update_food et get_meals changent
-- de signature : le site doit être mis à jour en même temps (pousser le site, puis exécuter
-- ce script, puis recharger le site avec Ctrl+F5). Entre les deux, l'écran Admin et l'ajout
-- d'aliments affichent une erreur : prévoir quelques minutes.

begin;

create table if not exists food.food_classes (
  food_id  bigint   not null references food.foods (id) on delete cascade,
  class_id smallint not null references food.classes (id) on delete restrict,
  primary key (food_id, class_id)
);
create index if not exists food_classes_class_idx on food.food_classes (class_id);
alter table food.food_classes enable row level security;
revoke all on food.food_classes from anon, authenticated;

do $$
begin
  if exists (select 1 from information_schema.columns
             where table_schema = 'food' and table_name = 'foods' and column_name = 'class_id') then
    insert into food.food_classes (food_id, class_id)
    select id, class_id from food.foods
    on conflict do nothing;
    alter table food.foods drop column class_id;
  end if;
end;
$$;

-- Anciennes fonctions (signature ou type de retour modifiés)
drop function if exists food.get_meals(text, text, date, date);
drop function if exists food.add_food(text, text, text, smallint);
drop function if exists food.update_food(text, text, bigint, text, smallint);

-- ------------------------------------------------------ Fonctions internes
-- Rôle de l'utilisateur ('read', 'write', 'admin'), ou null si l'identifiant ou le mot de
-- passe est faux. En cas d'échec, on ralentit (anti force brute).
create or replace function food._role(u text, p text)
returns text
language plpgsql
security definer
set search_path = food, extensions
as $$
declare
  r text;
  h text;
begin
  if u is not null and p is not null and p <> '' then
    select role, password_hash into r, h from food.users where user_id = lower(btrim(u));
    if found and h = crypt(p, h) then
      return r;
    end if;
  end if;
  perform pg_sleep(1);
  return null;
end;
$$;

-- Vérifie l'identifiant et le mot de passe, et que le rôle fait partie des rôles autorisés.
create or replace function food._check(u text, p text, allowed text[])
returns text
language plpgsql
security definer
set search_path = food, extensions
as $$
declare
  r text := food._role(u, p);
begin
  if r is null then
    raise exception 'invalid_password';
  end if;
  if not (r = any (allowed)) then
    raise exception 'forbidden';
  end if;
  return r;
end;
$$;

create or replace function food._today()
returns date
language sql
stable
as $$
  select (now() at time zone 'Europe/Zurich')::date;
$$;

-- Supprime les repas de plus de 30 jours (l'interface n'en affiche que 15)
-- et les lignes d'audit de plus de 12 mois.
create or replace function food._purge_old_data()
returns void
language plpgsql
security definer
set search_path = food
as $$
begin
  delete from food.meals where meal_date < food._today() - 30;
  delete from food.audit_log where logged_at < now() - interval '12 months';
end;
$$;

-- Écrit une ligne dans le journal d'audit (appelée uniquement par les fonctions ci-dessous,
-- dans la même transaction : si l'action échoue, rien n'est consigné).
create or replace function food._audit(u text, r text, act text, tgt text, bef jsonb, aft jsonb)
returns void
language sql
security definer
set search_path = food
as $$
  insert into food.audit_log (user_id, role, action, target, before, after)
  values (lower(btrim(u)), r, act, tgt, bef, aft);
$$;

-- ----------------------------------------------------- Fonctions publiques
-- Connexion : renvoie le rôle ('read', 'write', 'admin') ou null si l'identifiant
-- ou le mot de passe est faux.
create or replace function food.login(u text, p text)
returns text
language sql
security definer
set search_path = food, extensions
as $$
  select food._role(u, p);
$$;

-- Classes et aliments (tous rôles).
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
                  'id', c.id, 'name', c.name, 'part_name', c.part_name)
                  order by c.position, c.id), '[]'::jsonb) from food.classes c),
    'foods',   (select coalesce(jsonb_agg(jsonb_build_object(
                  'id', f.id, 'name', f.name,
                  'class_ids', (select coalesce(jsonb_agg(fc.class_id order by fc.class_id), '[]'::jsonb)
                                from food.food_classes fc where fc.food_id = f.id))
                  order by f.name), '[]'::jsonb) from food.foods f)
  );
end;
$$;

-- Repas entre deux dates incluses (tous rôles). Une ligne par aliment.
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
            from food.food_classes fc where fc.food_id = f.id)
    from food.meals m
    join food.meal_items mi on mi.meal_id = m.id
    join food.foods f on f.id = mi.food_id
    where m.meal_date between d_from and d_to
    order by m.meal_date, m.slot, f.name;
end;
$$;

-- Remplace entièrement un repas (rôle write uniquement). Liste vide = repas vidé.
-- Seuls les jours des 15 derniers jours à +30 jours sont modifiables.
create or replace function food.set_meal(u text, p text, d date, s text, food_ids bigint[])
returns void
language plpgsql
security definer
set search_path = food, extensions
as $$
declare
  r text;
  slot_ text := lower(s);
  ids bigint[];
  mid bigint;
  before_names jsonb;
  after_names jsonb;
begin
  r := food._check(u, p, array['write']);
  if slot_ not in ('midi', 'soir') then
    raise exception 'invalid_slot';
  end if;
  if d < food._today() - 15 or d > food._today() + 30 then
    raise exception 'out_of_window';
  end if;

  select coalesce(array_agg(distinct x), '{}') into ids from unnest(coalesce(food_ids, '{}')) x;
  if (select count(*) from food.foods where id = any (ids)) <> cardinality(ids) then
    raise exception 'unknown_food';
  end if;

  select coalesce(jsonb_agg(f.name order by f.name), '[]'::jsonb) into before_names
  from food.meals m
  join food.meal_items mi on mi.meal_id = m.id
  join food.foods f on f.id = mi.food_id
  where m.meal_date = d and m.slot = slot_;
  select coalesce(jsonb_agg(f.name order by f.name), '[]'::jsonb) into after_names
  from food.foods f
  where f.id = any (ids);

  -- Rien n'est écrit (ni consigné) si le repas ne change pas.
  if before_names <> after_names then
    if cardinality(ids) = 0 then
      delete from food.meals where meal_date = d and slot = slot_;
    else
      insert into food.meals (meal_date, slot) values (d, slot_)
      on conflict (meal_date, slot) do update set slot = excluded.slot
      returning id into mid;
      delete from food.meal_items where meal_id = mid;
      insert into food.meal_items (meal_id, food_id) select mid, unnest(ids);
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

-- Classes d'un aliment : liste normalisée (sans doublon, triée). Refuse une liste vide
-- ('invalid_classes') ou contenant une classe inconnue ('unknown_class').
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
  return ids;
end;
$$;

-- Noms des classes (dans l'ordre d'affichage) sous forme de tableau JSON, pour l'audit.
create or replace function food._class_names(ids smallint[])
returns jsonb
language sql
security definer
set search_path = food
as $$
  select coalesce(jsonb_agg(c.name order by c.position, c.id), '[]'::jsonb)
  from food.classes c
  where c.id = any (ids);
$$;

-- Ajoute un aliment avec une ou plusieurs classes (rôle admin uniquement).
create or replace function food.add_food(u text, p text, n text, cids smallint[])
returns bigint
language plpgsql
security definer
set search_path = food, extensions
as $$
declare
  r text;
  name_ text := lower(btrim(coalesce(n, '')));
  ids smallint[];
  new_id bigint;
begin
  r := food._check(u, p, array['admin']);
  if name_ = '' or char_length(name_) > 60 then
    raise exception 'invalid_name';
  end if;
  ids := food._clean_classes(cids);
  if exists (select 1 from food.foods where name = name_) then
    raise exception 'food_exists';
  end if;
  insert into food.foods (name) values (name_) returning id into new_id;
  insert into food.food_classes (food_id, class_id) select new_id, unnest(ids);
  perform food._audit(u, r, 'food_add', name_, null,
                      jsonb_build_object('name', name_, 'classes', food._class_names(ids)));
  return new_id;
end;
$$;

-- Modifie le nom et/ou les classes d'un aliment (rôle admin uniquement).
-- Les repas qui l'utilisent suivent automatiquement (ils pointent vers l'id).
-- Sur un aliment déjà utilisé dans des repas, on peut ajouter des classes mais pas en retirer.
create or replace function food.update_food(u text, p text, fid bigint, n text, cids smallint[])
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
  select coalesce(array_agg(fc.class_id order by fc.class_id), '{}') into old_ids
  from food.food_classes fc where fc.food_id = fid;
  if exists (select 1 from food.foods where name = name_ and id <> fid) then
    raise exception 'food_exists';
  end if;
  if not (old_ids <@ ids) and exists (select 1 from food.meal_items where food_id = fid) then
    raise exception 'food_in_use_class';
  end if;

  -- Rien n'est écrit (ni consigné) si l'aliment ne change pas.
  if name_ <> old_name or ids <> old_ids then
    update food.foods set name = name_ where id = fid;
    delete from food.food_classes where food_id = fid and not (class_id = any (ids));
    insert into food.food_classes (food_id, class_id) select fid, unnest(ids)
    on conflict do nothing;
    perform food._audit(u, r, 'food_update', old_name,
                        jsonb_build_object('name', old_name, 'classes', food._class_names(old_ids)),
                        jsonb_build_object('name', name_, 'classes', food._class_names(ids)));
  end if;
end;
$$;

-- Supprime un aliment (rôle admin uniquement), bloqué s'il est utilisé dans un repas.
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
    delete from food.foods where id = fid;
    perform food._audit(u, r, 'food_delete', old_name,
                        jsonb_build_object('name', old_name, 'classes', food._class_names(old_ids)), null);
  end if;
end;
$$;

-- ---------------------------------------------------------------- Droits
revoke execute on function food._role(text, text)                from public, anon, authenticated;
revoke execute on function food._check(text, text, text[])       from public, anon, authenticated;
revoke execute on function food._today()                         from public, anon, authenticated;
revoke execute on function food._purge_old_data()                from public, anon, authenticated;
revoke execute on function food._audit(text, text, text, text, jsonb, jsonb) from public, anon, authenticated;
revoke execute on function food._clean_classes(smallint[])         from public, anon, authenticated;
revoke execute on function food._class_names(smallint[])           from public, anon, authenticated;

revoke execute on function food.login(text, text)                                      from public;
revoke execute on function food.get_catalog(text, text)                                from public;
revoke execute on function food.get_meals(text, text, date, date)                      from public;
revoke execute on function food.set_meal(text, text, date, text, bigint[])             from public;
revoke execute on function food.add_food(text, text, text, smallint[])                   from public;
revoke execute on function food.update_food(text, text, bigint, text, smallint[])        from public;
revoke execute on function food.delete_food(text, text, bigint)                        from public;

grant execute on function food.login(text, text)                                       to anon, authenticated;
grant execute on function food.get_catalog(text, text)                                 to anon, authenticated;
grant execute on function food.get_meals(text, text, date, date)                       to anon, authenticated;
grant execute on function food.set_meal(text, text, date, text, bigint[])              to anon, authenticated;
grant execute on function food.add_food(text, text, text, smallint[])                    to anon, authenticated;
grant execute on function food.update_food(text, text, bigint, text, smallint[])         to anon, authenticated;
grant execute on function food.delete_food(text, text, bigint)                         to anon, authenticated;

commit;

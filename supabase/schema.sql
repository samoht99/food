-- Schéma des repas (schéma PostgreSQL "food").
-- À exécuter une fois dans Supabase : SQL Editor > New query > coller > Run.
-- Ensuite : Project Settings > Data API > Exposed schemas : ajouter "food".

create extension if not exists pgcrypto with schema extensions;

create schema if not exists food;
grant usage on schema food to anon, authenticated;

-- ---------------------------------------------------------------- Tables
create table if not exists food.app_config (
  key   text primary key,
  value text not null
);

-- Classes d'aliments. Créées / supprimées uniquement en SQL (jamais depuis le site).
-- name : 1re lettre en majuscule, le reste en minuscules. part_name : nom de la
-- partie de repas correspondante, en minuscules.
create table if not exists food.classes (
  id        smallint generated always as identity primary key,
  name      text     not null unique
            check (name = upper(left(name, 1)) || lower(substr(name, 2))),
  part_name text     not null unique check (part_name = lower(part_name)),
  position  smallint not null default 0
);

-- Un aliment appartient à une seule classe ; son nom est unique et en minuscules.
create table if not exists food.foods (
  id         bigint generated always as identity primary key,
  name       text     not null unique
             check (name = lower(name) and name = btrim(name) and name <> ''),
  class_id   smallint not null references food.classes (id) on delete restrict,
  created_at timestamptz not null default now()
);

-- Un repas = un jour + midi ou soir. Un repas vide n'a pas de ligne.
create table if not exists food.meals (
  id        bigint generated always as identity primary key,
  meal_date date not null,
  slot      text not null check (slot in ('midi', 'soir')),
  unique (meal_date, slot)
);

-- Aliments d'un repas. La partie du repas se déduit de la classe de l'aliment :
-- un aliment ne peut donc jamais se retrouver dans la mauvaise partie.
create table if not exists food.meal_items (
  meal_id bigint not null references food.meals (id) on delete cascade,
  food_id bigint not null references food.foods (id) on delete restrict,
  primary key (meal_id, food_id)
);
create index if not exists meal_items_food_idx on food.meal_items (food_id);

insert into food.classes (name, part_name, position) values
  ('Protéines', 'protéine', 1),
  ('Féculents', 'féculent', 2),
  ('Légumes',   'légume',   3),
  ('Laitages',  'laitage',  4),
  ('Fruits',    'fruit',    5)
on conflict do nothing;

-- RLS activée et AUCUNE policy : les rôles anon/authenticated n'ont aucun accès
-- direct aux tables. Seules les fonctions ci-dessous (security definer) y accèdent,
-- et uniquement avec un mot de passe dont le rôle est autorisé.
alter table food.app_config enable row level security;
alter table food.classes    enable row level security;
alter table food.foods      enable row level security;
alter table food.meals      enable row level security;
alter table food.meal_items enable row level security;
revoke all on food.app_config, food.classes, food.foods, food.meals, food.meal_items
  from anon, authenticated;

-- ------------------------------------------------------ Fonctions internes
-- Rôle correspondant au mot de passe : 'read', 'write', 'admin', ou null.
-- En cas d'échec, on ralentit (anti force brute).
create or replace function food._role(p text)
returns text
language plpgsql
security definer
set search_path = food, extensions
as $$
declare
  r text;
  h text;
begin
  if p is not null and p <> '' then
    for r in select unnest(array['read', 'write', 'admin']) loop
      select value into h from food.app_config where key = 'password_hash_' || r;
      if h is not null and h = crypt(p, h) then
        return r;
      end if;
    end loop;
  end if;
  perform pg_sleep(1);
  return null;
end;
$$;

-- Vérifie le mot de passe et que son rôle fait partie des rôles autorisés.
create or replace function food._check(p text, allowed text[])
returns text
language plpgsql
security definer
set search_path = food, extensions
as $$
declare
  r text := food._role(p);
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

-- Supprime les repas de plus de 30 jours (l'interface n'en affiche que 15).
create or replace function food._purge_old_meals()
returns void
language sql
security definer
set search_path = food
as $$
  delete from food.meals where meal_date < food._today() - 30;
$$;

-- ----------------------------------------------------- Fonctions publiques
-- Connexion : renvoie le rôle ('read', 'write', 'admin') ou null si le mot de passe est faux.
create or replace function food.login(p text)
returns text
language sql
security definer
set search_path = food, extensions
as $$
  select food._role(p);
$$;

-- Classes et aliments (tous rôles).
create or replace function food.get_catalog(p text)
returns jsonb
language plpgsql
security definer
set search_path = food, extensions
as $$
begin
  perform food._check(p, array['read', 'write', 'admin']);
  return jsonb_build_object(
    'classes', (select coalesce(jsonb_agg(jsonb_build_object(
                  'id', c.id, 'name', c.name, 'part_name', c.part_name)
                  order by c.position, c.id), '[]'::jsonb) from food.classes c),
    'foods',   (select coalesce(jsonb_agg(jsonb_build_object(
                  'id', f.id, 'name', f.name, 'class_id', f.class_id)
                  order by f.name), '[]'::jsonb) from food.foods f)
  );
end;
$$;

-- Repas entre deux dates incluses (tous rôles). Une ligne par aliment.
create or replace function food.get_meals(p text, d_from date, d_to date)
returns table (meal_date date, slot text, food_id bigint, food_name text, class_id smallint)
language plpgsql
security definer
set search_path = food, extensions
as $$
begin
  perform food._check(p, array['read', 'write', 'admin']);
  return query
    select m.meal_date, m.slot, f.id, f.name, f.class_id
    from food.meals m
    join food.meal_items mi on mi.meal_id = m.id
    join food.foods f on f.id = mi.food_id
    where m.meal_date between d_from and d_to
    order by m.meal_date, m.slot, f.name;
end;
$$;

-- Remplace entièrement un repas (rôle write uniquement). Liste vide = repas vidé.
-- Seuls les jours des 15 derniers jours à +30 jours sont modifiables.
create or replace function food.set_meal(p text, d date, s text, food_ids bigint[])
returns void
language plpgsql
security definer
set search_path = food, extensions
as $$
declare
  slot_ text := lower(s);
  ids bigint[];
  mid bigint;
begin
  perform food._check(p, array['write']);
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

  if cardinality(ids) = 0 then
    delete from food.meals where meal_date = d and slot = slot_;
  else
    insert into food.meals (meal_date, slot) values (d, slot_)
    on conflict (meal_date, slot) do update set slot = excluded.slot
    returning id into mid;
    delete from food.meal_items where meal_id = mid;
    insert into food.meal_items (meal_id, food_id) select mid, unnest(ids);
  end if;

  perform food._purge_old_meals();
end;
$$;

-- Ajoute un aliment (rôle admin uniquement).
create or replace function food.add_food(p text, n text, cid smallint)
returns bigint
language plpgsql
security definer
set search_path = food, extensions
as $$
declare
  name_ text := lower(btrim(coalesce(n, '')));
  existing smallint;
  new_id bigint;
begin
  perform food._check(p, array['admin']);
  if name_ = '' or char_length(name_) > 60 then
    raise exception 'invalid_name';
  end if;
  if not exists (select 1 from food.classes where id = cid) then
    raise exception 'unknown_class';
  end if;
  select class_id into existing from food.foods where name = name_;
  if found then
    raise exception '%', case when existing = cid then 'food_exists' else 'food_exists_other_class' end;
  end if;
  insert into food.foods (name, class_id) values (name_, cid) returning id into new_id;
  return new_id;
end;
$$;

-- Modifie le nom et/ou la classe d'un aliment (rôle admin uniquement).
-- Les repas qui l'utilisent suivent automatiquement (ils pointent vers l'id).
-- Changer la classe d'un aliment déjà utilisé est refusé.
create or replace function food.update_food(p text, fid bigint, n text, cid smallint)
returns void
language plpgsql
security definer
set search_path = food, extensions
as $$
declare
  name_ text := lower(btrim(coalesce(n, '')));
  old_class smallint;
  other_class smallint;
begin
  perform food._check(p, array['admin']);
  if name_ = '' or char_length(name_) > 60 then
    raise exception 'invalid_name';
  end if;
  select class_id into old_class from food.foods where id = fid;
  if not found then
    raise exception 'unknown_food';
  end if;
  if not exists (select 1 from food.classes where id = cid) then
    raise exception 'unknown_class';
  end if;
  select class_id into other_class from food.foods where name = name_ and id <> fid;
  if found then
    raise exception '%', case when other_class = cid then 'food_exists' else 'food_exists_other_class' end;
  end if;
  if cid <> old_class and exists (select 1 from food.meal_items where food_id = fid) then
    raise exception 'food_in_use_class';
  end if;
  update food.foods set name = name_, class_id = cid where id = fid;
end;
$$;

-- Supprime un aliment (rôle admin uniquement), bloqué s'il est utilisé dans un repas.
create or replace function food.delete_food(p text, fid bigint)
returns void
language plpgsql
security definer
set search_path = food, extensions
as $$
declare
  n integer;
begin
  perform food._check(p, array['admin']);
  select count(*) into n from food.meal_items where food_id = fid;
  if n > 0 then
    raise exception 'food_in_use' using detail = n::text;
  end if;
  delete from food.foods where id = fid;
end;
$$;

-- ---------------------------------------------------------------- Droits
revoke execute on function food._role(text)                      from public, anon, authenticated;
revoke execute on function food._check(text, text[])             from public, anon, authenticated;
revoke execute on function food._today()                         from public, anon, authenticated;
revoke execute on function food._purge_old_meals()               from public, anon, authenticated;

revoke execute on function food.login(text)                              from public;
revoke execute on function food.get_catalog(text)                        from public;
revoke execute on function food.get_meals(text, date, date)              from public;
revoke execute on function food.set_meal(text, date, text, bigint[])     from public;
revoke execute on function food.add_food(text, text, smallint)           from public;
revoke execute on function food.update_food(text, bigint, text, smallint) from public;
revoke execute on function food.delete_food(text, bigint)                from public;

grant execute on function food.login(text)                               to anon, authenticated;
grant execute on function food.get_catalog(text)                         to anon, authenticated;
grant execute on function food.get_meals(text, date, date)               to anon, authenticated;
grant execute on function food.set_meal(text, date, text, bigint[])      to anon, authenticated;
grant execute on function food.add_food(text, text, smallint)            to anon, authenticated;
grant execute on function food.update_food(text, bigint, text, smallint) to anon, authenticated;
grant execute on function food.delete_food(text, bigint)                 to anon, authenticated;

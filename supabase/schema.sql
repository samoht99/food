-- Schéma des repas (schéma PostgreSQL "food").
-- À exécuter une fois dans Supabase : SQL Editor > New query > coller > Run.
-- Ensuite : Project Settings > Data API > Exposed schemas : ajouter "food"
-- (cliquer sur Save ; si l'API répond « Invalid schema: food », retirer puis remettre "food" et sauvegarder).
-- Puis créer les utilisateurs (voir README, installation initiale, étape 2).

create extension if not exists pgcrypto with schema extensions;

create schema if not exists food;
grant usage on schema food to anon, authenticated;

-- ---------------------------------------------------------------- Tables
-- Utilisateurs : un identifiant, un rôle (read, write ou admin) et un mot de passe haché.
create table if not exists food.users (
  user_id       text primary key
                check (user_id = lower(user_id) and user_id = btrim(user_id) and user_id <> ''),
  role          text not null check (role in ('read', 'write', 'admin')),
  password_hash text not null
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

-- Journal d'audit : une ligne par action de modification réussie (rôles write et admin).
-- Les consultations, les connexions, les actions refusées, la purge automatique et ce qui est
-- fait directement en SQL n'y figurent pas. Conservé 12 mois (voir _purge_old_data).
-- target : "2026-10-28 soir" pour un repas, nom de l'aliment pour un aliment.
-- before / after : liste des noms d'aliments (repas) ou { name, class } (aliment).
create table if not exists food.audit_log (
  id      bigint generated always as identity primary key,
  logged_at timestamptz not null default now(),
  user_id text not null,
  role    text not null,
  action  text not null check (action in
            ('meal_create', 'meal_update', 'meal_clear', 'food_add', 'food_update', 'food_delete')),
  target  text not null,
  before  jsonb,
  after   jsonb
);
create index if not exists audit_log_at_idx on food.audit_log (logged_at);

insert into food.classes (name, part_name, position) values
  ('Protéines', 'protéine', 1),
  ('Féculents', 'féculent', 2),
  ('Légumes',   'légume',   3),
  ('Laitages',  'laitage',  4),
  ('Fruits',    'fruit',    5)
on conflict do nothing;

-- RLS activée et AUCUNE policy : les rôles anon/authenticated n'ont aucun accès
-- direct aux tables. Seules les fonctions ci-dessous (security definer) y accèdent,
-- et uniquement avec un identifiant et un mot de passe dont le rôle est autorisé.
alter table food.users      enable row level security;
alter table food.classes    enable row level security;
alter table food.foods      enable row level security;
alter table food.meals      enable row level security;
alter table food.meal_items enable row level security;
alter table food.audit_log  enable row level security;
revoke all on food.users, food.classes, food.foods, food.meals, food.meal_items, food.audit_log
  from anon, authenticated;

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
                  'id', f.id, 'name', f.name, 'class_id', f.class_id)
                  order by f.name), '[]'::jsonb) from food.foods f)
  );
end;
$$;

-- Repas entre deux dates incluses (tous rôles). Une ligne par aliment.
create or replace function food.get_meals(u text, p text, d_from date, d_to date)
returns table (meal_date date, slot text, food_id bigint, food_name text, class_id smallint)
language plpgsql
security definer
set search_path = food, extensions
as $$
begin
  perform food._check(u, p, array['read', 'write', 'admin']);
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

-- Ajoute un aliment (rôle admin uniquement).
create or replace function food.add_food(u text, p text, n text, cid smallint)
returns bigint
language plpgsql
security definer
set search_path = food, extensions
as $$
declare
  r text;
  name_ text := lower(btrim(coalesce(n, '')));
  existing smallint;
  class_name text;
  new_id bigint;
begin
  r := food._check(u, p, array['admin']);
  if name_ = '' or char_length(name_) > 60 then
    raise exception 'invalid_name';
  end if;
  select c.name into class_name from food.classes c where c.id = cid;
  if not found then
    raise exception 'unknown_class';
  end if;
  select class_id into existing from food.foods where name = name_;
  if found then
    raise exception '%', case when existing = cid then 'food_exists' else 'food_exists_other_class' end;
  end if;
  insert into food.foods (name, class_id) values (name_, cid) returning id into new_id;
  perform food._audit(u, r, 'food_add', name_, null,
                      jsonb_build_object('name', name_, 'class', class_name));
  return new_id;
end;
$$;

-- Modifie le nom et/ou la classe d'un aliment (rôle admin uniquement).
-- Les repas qui l'utilisent suivent automatiquement (ils pointent vers l'id).
-- Changer la classe d'un aliment déjà utilisé est refusé.
create or replace function food.update_food(u text, p text, fid bigint, n text, cid smallint)
returns void
language plpgsql
security definer
set search_path = food, extensions
as $$
declare
  r text;
  name_ text := lower(btrim(coalesce(n, '')));
  old_name text;
  old_class smallint;
  old_class_name text;
  new_class_name text;
  other_class smallint;
begin
  r := food._check(u, p, array['admin']);
  if name_ = '' or char_length(name_) > 60 then
    raise exception 'invalid_name';
  end if;
  select f.name, f.class_id, c.name into old_name, old_class, old_class_name
  from food.foods f join food.classes c on c.id = f.class_id
  where f.id = fid;
  if not found then
    raise exception 'unknown_food';
  end if;
  select c.name into new_class_name from food.classes c where c.id = cid;
  if not found then
    raise exception 'unknown_class';
  end if;
  select class_id into other_class from food.foods where name = name_ and id <> fid;
  if found then
    raise exception '%', case when other_class = cid then 'food_exists' else 'food_exists_other_class' end;
  end if;
  if cid <> old_class and exists (select 1 from food.meal_items where food_id = fid) then
    raise exception 'food_in_use_class';
  end if;

  -- Rien n'est écrit (ni consigné) si l'aliment ne change pas.
  if name_ <> old_name or cid <> old_class then
    update food.foods set name = name_, class_id = cid where id = fid;
    perform food._audit(u, r, 'food_update', old_name,
                        jsonb_build_object('name', old_name, 'class', old_class_name),
                        jsonb_build_object('name', name_, 'class', new_class_name));
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
  old_class_name text;
begin
  r := food._check(u, p, array['admin']);
  select count(*) into n from food.meal_items where food_id = fid;
  if n > 0 then
    raise exception 'food_in_use' using detail = n::text;
  end if;
  select f.name, c.name into old_name, old_class_name
  from food.foods f join food.classes c on c.id = f.class_id
  where f.id = fid;
  if found then
    delete from food.foods where id = fid;
    perform food._audit(u, r, 'food_delete', old_name,
                        jsonb_build_object('name', old_name, 'class', old_class_name), null);
  end if;
end;
$$;

-- ---------------------------------------------------------------- Droits
revoke execute on function food._role(text, text)                from public, anon, authenticated;
revoke execute on function food._check(text, text, text[])       from public, anon, authenticated;
revoke execute on function food._today()                         from public, anon, authenticated;
revoke execute on function food._purge_old_data()                from public, anon, authenticated;
revoke execute on function food._audit(text, text, text, text, jsonb, jsonb) from public, anon, authenticated;

revoke execute on function food.login(text, text)                                      from public;
revoke execute on function food.get_catalog(text, text)                                from public;
revoke execute on function food.get_meals(text, text, date, date)                      from public;
revoke execute on function food.set_meal(text, text, date, text, bigint[])             from public;
revoke execute on function food.add_food(text, text, text, smallint)                   from public;
revoke execute on function food.update_food(text, text, bigint, text, smallint)        from public;
revoke execute on function food.delete_food(text, text, bigint)                        from public;

grant execute on function food.login(text, text)                                       to anon, authenticated;
grant execute on function food.get_catalog(text, text)                                 to anon, authenticated;
grant execute on function food.get_meals(text, text, date, date)                       to anon, authenticated;
grant execute on function food.set_meal(text, text, date, text, bigint[])              to anon, authenticated;
grant execute on function food.add_food(text, text, text, smallint)                    to anon, authenticated;
grant execute on function food.update_food(text, text, bigint, text, smallint)         to anon, authenticated;
grant execute on function food.delete_food(text, text, bigint)                         to anon, authenticated;

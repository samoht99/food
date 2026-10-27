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

-- Un aliment : son nom est unique et en minuscules.
create table if not exists food.foods (
  id         bigint generated always as identity primary key,
  name       text     not null unique
             check (name = lower(name) and name = btrim(name) and name <> ''),
  created_at timestamptz not null default now()
);

-- Classes d'un aliment : un aliment peut en avoir plusieurs (ex. un sandwich est à la fois
-- protéines, féculents et légumes). Les fonctions exigent au moins une classe par aliment.
create table if not exists food.food_classes (
  food_id  bigint   not null references food.foods (id) on delete cascade,
  class_id smallint not null references food.classes (id) on delete restrict,
  primary key (food_id, class_id)
);
create index if not exists food_classes_class_idx on food.food_classes (class_id);

-- Un repas = un jour + midi ou soir. Un repas vide n'a pas de ligne.
create table if not exists food.meals (
  id        bigint generated always as identity primary key,
  meal_date date not null,
  slot      text not null check (slot in ('midi', 'soir')),
  unique (meal_date, slot)
);

-- Aliments d'un repas. Les parties du repas qu'un aliment remplit se déduisent de ses
-- classes : un aliment ne peut donc jamais se retrouver dans une mauvaise partie.
create table if not exists food.meal_items (
  meal_id bigint not null references food.meals (id) on delete cascade,
  food_id bigint not null references food.foods (id) on delete restrict,
  primary key (meal_id, food_id)
);
create index if not exists meal_items_food_idx on food.meal_items (food_id);

-- Contraintes de jour : la liste de toutes les contraintes possibles (ex. « Télétravail »,
-- « Invités »), gérée par l'admin. Pour l'instant une contrainte n'a qu'un nom ; elle est
-- uniquement informative (affichée sur le jour, sans effet sur le comportement du site).
-- Le nom est unique sans tenir compte de la casse ; il garde la casse saisie.
create table if not exists food.constraints (
  id   bigint generated always as identity primary key,
  name text not null check (name = btrim(name) and name <> '' and char_length(name) <= 60)
);
create unique index if not exists constraints_name_key on food.constraints (lower(name));

-- Contraintes attribuées à un jour : un jour peut en avoir plusieurs, et une contrainte peut être
-- attribuée à plusieurs jours. Un jour sans contrainte n'a pas de ligne.
create table if not exists food.day_constraints (
  day_date      date   not null,
  constraint_id bigint not null references food.constraints (id) on delete restrict,
  primary key (day_date, constraint_id)
);
create index if not exists day_constraints_constraint_idx on food.day_constraints (constraint_id);

-- Journal d'audit : une ligne par action de modification réussie (rôles write et admin).
-- Les consultations, les connexions, les actions refusées, la purge automatique et ce qui est
-- fait directement en SQL n'y figurent pas. Conservé 12 mois (voir _purge_old_data).
-- target : "2026-10-28 soir" pour un repas, nom de l'aliment ou de la contrainte, "2026-10-28"
-- pour les contraintes d'un jour.
-- before / after : liste des noms d'aliments (repas), { name, classes: [noms] } (aliment),
-- nom (contrainte) ou liste des noms de contraintes (contraintes d'un jour).
create table if not exists food.audit_log (
  id      bigint generated always as identity primary key,
  logged_at timestamptz not null default now(),
  user_id text not null,
  role    text not null,
  action  text not null check (action in
            ('meal_create', 'meal_update', 'meal_clear', 'food_add', 'food_update', 'food_delete',
             'day_constraint_create', 'day_constraint_update', 'day_constraint_clear',
             'constraint_add', 'constraint_update', 'constraint_delete')),
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
  ('Autres',    'divers',   5)
on conflict do nothing;

-- RLS activée et AUCUNE policy : les rôles anon/authenticated n'ont aucun accès
-- direct aux tables. Seules les fonctions ci-dessous (security definer) y accèdent,
-- et uniquement avec un identifiant et un mot de passe dont le rôle est autorisé.
alter table food.users      enable row level security;
alter table food.classes    enable row level security;
alter table food.foods        enable row level security;
alter table food.food_classes enable row level security;
alter table food.meals        enable row level security;
alter table food.meal_items   enable row level security;
alter table food.constraints     enable row level security;
alter table food.day_constraints enable row level security;
alter table food.audit_log    enable row level security;
revoke all on food.users, food.classes, food.foods, food.food_classes, food.meals,
  food.meal_items, food.constraints, food.day_constraints, food.audit_log from anon, authenticated;

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

-- Supprime les repas et les contraintes de jour de plus de 30 jours (l'interface n'en affiche
-- que 15) et les lignes d'audit de plus de 12 mois.
create or replace function food._purge_old_data()
returns void
language plpgsql
security definer
set search_path = food
as $$
begin
  delete from food.meals where meal_date < food._today() - 30;
  delete from food.day_constraints where day_date < food._today() - 30;
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

-- Remplace entièrement un repas (rôles write et admin). Liste vide = repas vidé.
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
  r := food._check(u, p, array['write', 'admin']);
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

-- Contraintes possibles (tous rôles), avec le nombre de jours où chacune est attribuée.
create or replace function food.get_constraints(u text, p text)
returns table (id bigint, name text, uses bigint)
language plpgsql
security definer
set search_path = food, extensions
as $$
begin
  perform food._check(u, p, array['read', 'write', 'admin']);
  return query
    select k.id, k.name,
           (select count(*) from food.day_constraints dc where dc.constraint_id = k.id)
    from food.constraints k
    order by lower(k.name), k.id;
end;
$$;

-- Contraintes attribuées aux jours entre deux dates incluses (tous rôles). Une ligne par contrainte.
create or replace function food.get_day_constraints(u text, p text, d_from date, d_to date)
returns table (day_date date, constraint_id bigint)
language plpgsql
security definer
set search_path = food, extensions
as $$
begin
  perform food._check(u, p, array['read', 'write', 'admin']);
  return query
    select dc.day_date, dc.constraint_id
    from food.day_constraints dc
    where dc.day_date between d_from and d_to
    order by dc.day_date, dc.constraint_id;
end;
$$;

-- Remplace entièrement les contraintes d'un jour (rôles write et admin). Liste vide = aucune.
-- Mêmes jours modifiables que les repas : 15 derniers jours à +30 jours.
create or replace function food.set_day_constraints(u text, p text, d date, cids bigint[])
returns void
language plpgsql
security definer
set search_path = food, extensions
as $$
declare
  r text;
  ids bigint[];
  before_names jsonb;
  after_names jsonb;
begin
  r := food._check(u, p, array['write', 'admin']);
  if d < food._today() - 15 or d > food._today() + 30 then
    raise exception 'out_of_window';
  end if;

  select coalesce(array_agg(distinct x), '{}') into ids
  from unnest(coalesce(cids, '{}')) x
  where x is not null;
  if (select count(*) from food.constraints where id = any (ids)) <> cardinality(ids) then
    raise exception 'unknown_constraint';
  end if;

  select coalesce(jsonb_agg(k.name order by lower(k.name), k.id), '[]'::jsonb) into before_names
  from food.day_constraints dc
  join food.constraints k on k.id = dc.constraint_id
  where dc.day_date = d;
  select coalesce(jsonb_agg(k.name order by lower(k.name), k.id), '[]'::jsonb) into after_names
  from food.constraints k
  where k.id = any (ids);

  -- Rien n'est écrit (ni consigné) si les contraintes du jour ne changent pas.
  if before_names <> after_names then
    delete from food.day_constraints where day_date = d;
    insert into food.day_constraints (day_date, constraint_id) select d, unnest(ids);
    perform food._audit(
      u, r,
      case when before_names = '[]'::jsonb then 'day_constraint_create'
           when cardinality(ids) = 0 then 'day_constraint_clear'
           else 'day_constraint_update' end,
      d::text, before_names, after_names);
  end if;

  perform food._purge_old_data();
end;
$$;

-- Crée une contrainte (rôle admin uniquement). Le nom est unique, sans tenir compte de la casse.
create or replace function food.add_constraint(u text, p text, n text)
returns bigint
language plpgsql
security definer
set search_path = food, extensions
as $$
declare
  r text;
  name_ text := btrim(coalesce(n, ''));
  new_id bigint;
begin
  r := food._check(u, p, array['admin']);
  if name_ = '' or char_length(name_) > 60 then
    raise exception 'invalid_name';
  end if;
  if exists (select 1 from food.constraints k where lower(k.name) = lower(name_)) then
    raise exception 'constraint_exists';
  end if;
  insert into food.constraints (name) values (name_) returning id into new_id;
  perform food._audit(u, r, 'constraint_add', name_, null, to_jsonb(name_));
  return new_id;
end;
$$;

-- Renomme une contrainte (rôle admin uniquement). Les jours qui l'utilisent suivent
-- automatiquement (ils pointent vers l'identifiant).
create or replace function food.update_constraint(u text, p text, cid bigint, n text)
returns void
language plpgsql
security definer
set search_path = food, extensions
as $$
declare
  r text;
  name_ text := btrim(coalesce(n, ''));
  old_name text;
begin
  r := food._check(u, p, array['admin']);
  if name_ = '' or char_length(name_) > 60 then
    raise exception 'invalid_name';
  end if;
  select k.name into old_name from food.constraints k where k.id = cid;
  if not found then
    raise exception 'unknown_constraint';
  end if;
  if exists (select 1 from food.constraints k where lower(k.name) = lower(name_) and k.id <> cid) then
    raise exception 'constraint_exists';
  end if;

  -- Rien n'est écrit (ni consigné) si le nom ne change pas.
  if name_ <> old_name then
    update food.constraints set name = name_ where id = cid;
    perform food._audit(u, r, 'constraint_update', old_name, to_jsonb(old_name), to_jsonb(name_));
  end if;
end;
$$;

-- Supprime une contrainte (rôle admin uniquement), bloqué si elle est attribuée à au moins un jour.
create or replace function food.delete_constraint(u text, p text, cid bigint)
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
  select count(*) into n from food.day_constraints dc where dc.constraint_id = cid;
  if n > 0 then
    raise exception 'constraint_in_use' using detail = n::text;
  end if;
  select k.name into old_name from food.constraints k where k.id = cid;
  if found then
    delete from food.constraints where id = cid;
    perform food._audit(u, r, 'constraint_delete', old_name, to_jsonb(old_name), null);
  end if;
end;
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
revoke execute on function food.get_constraints(text, text)                            from public;
revoke execute on function food.get_day_constraints(text, text, date, date)            from public;
revoke execute on function food.set_day_constraints(text, text, date, bigint[])        from public;
revoke execute on function food.add_constraint(text, text, text)                       from public;
revoke execute on function food.update_constraint(text, text, bigint, text)            from public;
revoke execute on function food.delete_constraint(text, text, bigint)                  from public;
revoke execute on function food.add_food(text, text, text, smallint[])                   from public;
revoke execute on function food.update_food(text, text, bigint, text, smallint[])        from public;
revoke execute on function food.delete_food(text, text, bigint)                        from public;

grant execute on function food.login(text, text)                                       to anon, authenticated;
grant execute on function food.get_catalog(text, text)                                 to anon, authenticated;
grant execute on function food.get_meals(text, text, date, date)                       to anon, authenticated;
grant execute on function food.set_meal(text, text, date, text, bigint[])              to anon, authenticated;
grant execute on function food.get_constraints(text, text)                             to anon, authenticated;
grant execute on function food.get_day_constraints(text, text, date, date)             to anon, authenticated;
grant execute on function food.set_day_constraints(text, text, date, bigint[])         to anon, authenticated;
grant execute on function food.add_constraint(text, text, text)                        to anon, authenticated;
grant execute on function food.update_constraint(text, text, bigint, text)             to anon, authenticated;
grant execute on function food.delete_constraint(text, text, bigint)                   to anon, authenticated;
grant execute on function food.add_food(text, text, text, smallint[])                    to anon, authenticated;
grant execute on function food.update_food(text, text, bigint, text, smallint[])         to anon, authenticated;
grant execute on function food.delete_food(text, text, bigint)                         to anon, authenticated;

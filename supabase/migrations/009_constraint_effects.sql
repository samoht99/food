-- Migration : effets des contraintes de jour (specs v2-2).
-- À exécuter une fois dans Supabase (SQL Editor), en une seule fois, APRÈS la migration 008.
--
-- Ajoute la table des effets (food.effects : nom, description, créneau bloqué) avec deux effets de
-- départ (« Pas de repas le midi » / « Pas de repas le soir »), une colonne effect_id sur les
-- contraintes (une contrainte a un effet ou aucun), et fait respecter la règle par la base :
-- un repas ne peut pas être rempli sur un créneau bloqué par une contrainte du jour.
-- get_constraints, add_constraint et update_constraint changent de signature (paramètre / colonne
-- en plus) ; le site v2-2 fonctionne aussi avant ce script (sans effets), mais l'ajout et la
-- modification d'une contrainte depuis l'Admin demandent ce script pour enregistrer un effet.
-- Aucune contrainte existante n'a d'effet : à définir dans l'onglet Admin, partie Contraintes.

begin;

-- ------------------------------------------------------------------ Effets
create table if not exists food.effects (
  id           smallint generated always as identity primary key,
  name         text not null unique check (name = btrim(name) and name <> ''),
  description  text not null check (btrim(description) <> ''),
  blocked_slot text check (blocked_slot in ('midi', 'soir'))
);

insert into food.effects (name, description, blocked_slot) values
  ('Pas de repas le midi', 'Aucun repas ne peut être généré pour le midi de ce jour.', 'midi'),
  ('Pas de repas le soir', 'Aucun repas ne peut être généré pour le soir de ce jour.', 'soir')
on conflict (name) do nothing;

alter table food.constraints
  add column if not exists effect_id smallint references food.effects (id) on delete restrict;
create index if not exists constraints_effect_idx on food.constraints (effect_id);

alter table food.effects enable row level security;
revoke all on food.effects from anon, authenticated;

-- ------------------------------------------------------ Fonctions internes
-- Nom d'un effet (null si aucun).
create or replace function food._effect_name(eid smallint)
returns text
language sql
stable
security definer
set search_path = food
as $$
  select e.name from food.effects e where e.id = eid;
$$;

-- État d'une contrainte pour l'audit : { name, effect } (effect : nom de l'effet, ou null).
create or replace function food._constraint_state(n text, eid smallint)
returns jsonb
language sql
security definer
set search_path = food
as $$
  select jsonb_build_object('name', n, 'effect', food._effect_name(eid));
$$;

-- ----------------------------------------------------- Fonctions publiques
-- Effets possibles (tous rôles : l'onglet Repas doit savoir quels créneaux sont bloqués).
create or replace function food.get_effects(u text, p text)
returns table (id smallint, name text, description text, blocked_slot text)
language plpgsql
security definer
set search_path = food, extensions
as $$
begin
  perform food._check(u, p, array['read', 'write', 'admin']);
  return query
    select e.id, e.name, e.description, e.blocked_slot
    from food.effects e
    order by e.id;
end;
$$;

-- Contraintes possibles (tous rôles), avec le nombre de jours où chacune est attribuée et son effet.
drop function if exists food.get_constraints(text, text);
create or replace function food.get_constraints(u text, p text)
returns table (id bigint, name text, uses bigint, effect_id smallint)
language plpgsql
security definer
set search_path = food, extensions
as $$
begin
  perform food._check(u, p, array['read', 'write', 'admin']);
  return query
    select k.id, k.name,
           (select count(*) from food.day_constraints dc where dc.constraint_id = k.id),
           k.effect_id
    from food.constraints k
    order by lower(k.name), k.id;
end;
$$;

-- Remplace entièrement un repas (rôles write et admin). Liste vide = repas vidé.
-- Seuls les jours des 15 derniers jours à +30 jours sont modifiables.
-- Un créneau bloqué par une contrainte du jour ne peut pas être rempli ('slot_blocked') ; le vider
-- reste possible.
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
  if cardinality(ids) > 0 and exists (
       select 1 from food.day_constraints dc
       join food.constraints k on k.id = dc.constraint_id
       join food.effects e on e.id = k.effect_id
       where dc.day_date = d and e.blocked_slot = slot_) then
    raise exception 'slot_blocked';
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

-- Remplace entièrement les contraintes d'un jour (rôles write et admin). Liste vide = aucune.
-- Mêmes jours modifiables que les repas : 15 derniers jours à +30 jours.
-- Une contrainte nouvellement ajoutée au jour qui bloque un créneau dont le repas est déjà rempli
-- est refusée ('meal_in_blocked_slot', le détail donne le créneau) : il faut d'abord vider ce repas.
create or replace function food.set_day_constraints(u text, p text, d date, cids bigint[])
returns void
language plpgsql
security definer
set search_path = food, extensions
as $$
declare
  r text;
  ids bigint[];
  before_ids bigint[];
  blocked text;
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

  select coalesce(array_agg(dc.constraint_id), '{}') into before_ids
  from food.day_constraints dc where dc.day_date = d;
  select e.blocked_slot into blocked
  from food.constraints k
  join food.effects e on e.id = k.effect_id
  where k.id = any (ids) and not (k.id = any (before_ids)) and e.blocked_slot is not null
    and exists (select 1 from food.meals m where m.meal_date = d and m.slot = e.blocked_slot)
  limit 1;
  if blocked is not null then
    raise exception 'meal_in_blocked_slot' using detail = blocked;
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

-- Crée une contrainte, avec un effet ou aucun (rôle admin uniquement). Le nom est unique, sans tenir
-- compte de la casse.
drop function if exists food.add_constraint(text, text, text);
create or replace function food.add_constraint(u text, p text, n text, eid smallint default null)
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
  if eid is not null and not exists (select 1 from food.effects e where e.id = eid) then
    raise exception 'unknown_effect';
  end if;
  if exists (select 1 from food.constraints k where lower(k.name) = lower(name_)) then
    raise exception 'constraint_exists';
  end if;
  insert into food.constraints (name, effect_id) values (name_, eid) returning id into new_id;
  perform food._audit(u, r, 'constraint_add', name_, null, food._constraint_state(name_, eid));
  return new_id;
end;
$$;

-- Modifie le nom et l'effet d'une contrainte (rôle admin uniquement). Les jours qui l'utilisent
-- suivent automatiquement (ils pointent vers l'identifiant). Donner ou changer un effet bloquant est
-- refusé ('effect_conflict', le détail donne les jours) si la contrainte est attribuée à des jours
-- dont le repas du créneau bloqué est rempli.
drop function if exists food.update_constraint(text, text, bigint, text);
create or replace function food.update_constraint(u text, p text, cid bigint, n text, eid smallint default null)
returns void
language plpgsql
security definer
set search_path = food, extensions
as $$
declare
  r text;
  name_ text := btrim(coalesce(n, ''));
  old_name text;
  old_eid smallint;
  slot_ text;
  cnt integer;
  days jsonb;
begin
  r := food._check(u, p, array['admin']);
  if name_ = '' or char_length(name_) > 60 then
    raise exception 'invalid_name';
  end if;
  select k.name, k.effect_id into old_name, old_eid from food.constraints k where k.id = cid;
  if not found then
    raise exception 'unknown_constraint';
  end if;
  if eid is not null and not exists (select 1 from food.effects e where e.id = eid) then
    raise exception 'unknown_effect';
  end if;
  if exists (select 1 from food.constraints k where lower(k.name) = lower(name_) and k.id <> cid) then
    raise exception 'constraint_exists';
  end if;

  -- Rien n'est écrit (ni consigné) si le nom et l'effet ne changent pas.
  if name_ <> old_name or eid is distinct from old_eid then
    if eid is distinct from old_eid then
      select e.blocked_slot into slot_ from food.effects e where e.id = eid;
      if slot_ is not null then
        select count(*), coalesce(jsonb_agg(dc.day_date::text order by dc.day_date desc), '[]'::jsonb)
          into cnt, days
        from food.day_constraints dc
        join food.meals m on m.meal_date = dc.day_date and m.slot = slot_
        where dc.constraint_id = cid;
        if cnt > 0 then
          raise exception 'effect_conflict'
            using detail = jsonb_build_object('n', cnt, 'slot', slot_, 'items', days)::text;
        end if;
      end if;
    end if;
    update food.constraints set name = name_, effect_id = eid where id = cid;
    perform food._audit(u, r, 'constraint_update', old_name,
                        food._constraint_state(old_name, old_eid), food._constraint_state(name_, eid));
  end if;
end;
$$;

-- Supprime une contrainte (rôle admin uniquement), bloqué si elle est attribuée à au moins un jour.
-- Si elle est utilisée, l'erreur donne la liste des jours (JSON { n, items }).
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
  old_eid smallint;
begin
  r := food._check(u, p, array['admin']);
  select count(*) into n from food.day_constraints dc where dc.constraint_id = cid;
  if n > 0 then
    select coalesce(jsonb_agg(dc.day_date::text order by dc.day_date desc), '[]'::jsonb) into items
    from food.day_constraints dc
    where dc.constraint_id = cid;
    raise exception 'constraint_in_use' using detail = jsonb_build_object('n', n, 'items', items)::text;
  end if;
  select k.name, k.effect_id into old_name, old_eid from food.constraints k where k.id = cid;
  if found then
    delete from food.constraints where id = cid;
    perform food._audit(u, r, 'constraint_delete', old_name, food._constraint_state(old_name, old_eid), null);
  end if;
end;
$$;

-- ---------------------------------------------------------------- Droits
revoke execute on function food._effect_name(smallint)                       from public, anon, authenticated;
revoke execute on function food._constraint_state(text, smallint)            from public, anon, authenticated;

revoke execute on function food.get_effects(text, text)                      from public;
revoke execute on function food.get_constraints(text, text)                  from public;
revoke execute on function food.add_constraint(text, text, text, smallint)   from public;
revoke execute on function food.update_constraint(text, text, bigint, text, smallint) from public;

grant execute on function food.get_effects(text, text)                       to anon, authenticated;
grant execute on function food.get_constraints(text, text)                   to anon, authenticated;
grant execute on function food.add_constraint(text, text, text, smallint)    to anon, authenticated;
grant execute on function food.update_constraint(text, text, bigint, text, smallint) to anon, authenticated;

commit;

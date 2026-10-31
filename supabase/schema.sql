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
-- type : 'composante' (une partie de repas, affichée dans les repas) ou 'combo' (indique seulement
-- qu'un aliment est une recette composée de plusieurs ingrédients : pas de partie de repas,
-- jamais affichée dans les repas).
create table if not exists food.classes (
  id        smallint generated always as identity primary key,
  name      text     not null unique
            check (name = upper(left(name, 1)) || lower(substr(name, 2))),
  part_name text     unique check (part_name = lower(part_name)),
  position  smallint not null default 0,
  type      text     not null default 'composante' check (type in ('composante', 'combo')),
  check ((type = 'composante') = (part_name is not null))
);

-- Un aliment : son nom est unique et en minuscules.
create table if not exists food.foods (
  id         bigint generated always as identity primary key,
  name       text     not null unique
             check (name = lower(name) and name = btrim(name) and name <> ''),
  created_at timestamptz not null default now()
);

-- Classes d'un aliment : un aliment peut en avoir plusieurs (ex. un sandwich est à la fois
-- protéines, féculents et légumes). Les fonctions exigent au moins une classe de type composante
-- par aliment.
create table if not exists food.food_classes (
  food_id  bigint   not null references food.foods (id) on delete cascade,
  class_id smallint not null references food.classes (id) on delete restrict,
  primary key (food_id, class_id)
);
create index if not exists food_classes_class_idx on food.food_classes (class_id);

-- Unités des ingrédients. Liste fixe, créée / modifiée uniquement en SQL (jamais depuis le site).
-- id explicite : l'unité par défaut (g) vaut 1. name : singulier ; plural : pluriel (à partir de 2).
create table if not exists food.units (
  id       smallint primary key,
  name     text     not null unique check (name = btrim(name) and name <> ''),
  plural   text     not null check (plural = btrim(plural) and plural <> ''),
  position smallint not null default 0
);

-- Ingrédients : un nom unique, en minuscules, et une unité (g par défaut) dans laquelle toutes ses
-- quantités sont exprimées. Aucun nettoyage automatique : un ingrédient lié à aucun aliment reste en
-- base jusqu'à ce que l'admin le supprime.
create table if not exists food.ingredients (
  id      bigint generated always as identity primary key,
  name    text     not null unique
          check (name = lower(name) and name = btrim(name) and name <> '' and char_length(name) <= 60),
  unit_id smallint not null default 1 references food.units (id) on delete restrict
);
create index if not exists ingredients_unit_idx on food.ingredients (unit_id);

-- Ingrédients d'un aliment. Un aliment simple (sans classe combo) a exactement un ingrédient, de
-- même nom que lui, créé par les fonctions. Une recette (classe Recettes) a au moins un ingrédient,
-- saisis par l'admin. quantity : quantité d'ingrédient pour 1 portion de l'aliment, dans l'unité de
-- l'ingrédient (null : non définie).
create table if not exists food.food_ingredients (
  food_id       bigint not null references food.foods (id) on delete cascade,
  ingredient_id bigint not null references food.ingredients (id) on delete restrict,
  quantity      numeric(8, 3) check (quantity > 0),
  primary key (food_id, ingredient_id)
);
create index if not exists food_ingredients_ingredient_idx on food.food_ingredients (ingredient_id);

-- Un repas = un jour + midi ou soir. Un repas vide n'a pas de ligne.
create table if not exists food.meals (
  id        bigint generated always as identity primary key,
  meal_date date not null,
  slot      text not null check (slot in ('midi', 'soir')),
  unique (meal_date, slot)
);

-- Aliments d'un repas. Les parties du repas qu'un aliment remplit se déduisent de ses
-- classes : un aliment ne peut donc jamais se retrouver dans une mauvaise partie.
-- portions : nombre de portions de l'aliment dans ce repas (multiplicateur des quantités de base de
-- ses ingrédients) ; 1 par défaut, 99 au plus, 2 décimales au plus.
create table if not exists food.meal_items (
  meal_id  bigint        not null references food.meals (id) on delete cascade,
  food_id  bigint        not null references food.foods (id) on delete restrict,
  portions numeric(4, 2) not null default 1 check (portions > 0 and portions <= 99),
  primary key (meal_id, food_id)
);
create index if not exists meal_items_food_idx on food.meal_items (food_id);

-- Effets possibles d'une contrainte de jour. Créés / modifiés / supprimés uniquement en SQL (jamais
-- depuis le site). name : affiché dans une pastille ; description : texte simple qui explique
-- l'effet ; blocked_slot : créneau de repas ('midi' ou 'soir') qui ne peut pas être rempli un jour
-- qui a une contrainte ayant cet effet (null : l'effet ne bloque aucun créneau).
create table if not exists food.effects (
  id           smallint generated always as identity primary key,
  name         text not null unique check (name = btrim(name) and name <> ''),
  description  text not null check (btrim(description) <> ''),
  blocked_slot text check (blocked_slot in ('midi', 'soir'))
);

-- Contraintes de jour : la liste de toutes les contraintes possibles (ex. « Télétravail »,
-- « Invités »), gérée par l'admin. Une contrainte a un nom et, éventuellement, un effet (effect_id) ;
-- sans effet elle est uniquement informative (affichée sur le jour).
-- Le nom est unique sans tenir compte de la casse ; il garde la casse saisie.
create table if not exists food.constraints (
  id        bigint generated always as identity primary key,
  name      text not null check (name = btrim(name) and name <> '' and char_length(name) <= 60),
  effect_id smallint references food.effects (id) on delete restrict
);
create unique index if not exists constraints_name_key on food.constraints (lower(name));
create index if not exists constraints_effect_idx on food.constraints (effect_id);

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
-- { name, unit } (ingrédient), { name, effect } (contrainte) ou liste des noms de contraintes (contraintes
-- d'un jour). L'état d'un aliment contient en plus ingredients: [{ name, quantity, unit }]. Dans un repas,
-- un aliment dont les portions ne valent pas 1 est écrit avec son multiplicateur (« poulet ×1.5 »).
create table if not exists food.audit_log (
  id      bigint generated always as identity primary key,
  logged_at timestamptz not null default now(),
  user_id text not null,
  role    text not null,
  action  text not null check (action in
            ('meal_create', 'meal_update', 'meal_clear', 'food_add', 'food_update', 'food_delete',
             'day_constraint_create', 'day_constraint_update', 'day_constraint_clear',
             'constraint_add', 'constraint_update', 'constraint_delete',
             'ingredient_add', 'ingredient_update', 'ingredient_delete')),
  target  text not null,
  before  jsonb,
  after   jsonb
);
create index if not exists audit_log_at_idx on food.audit_log (logged_at);

insert into food.classes (name, part_name, position, type) values
  ('Protéines', 'protéine', 1, 'composante'),
  ('Féculents', 'féculent', 2, 'composante'),
  ('Légumes',   'légume',   3, 'composante'),
  ('Laitages',  'laitage',  4, 'composante'),
  ('Autres',    'divers',   5, 'composante'),
  ('Recettes',  null,       6, 'combo')
on conflict do nothing;

insert into food.units (id, name, plural, position) values
  (1, 'g',          'g',          1),
  (2, 'ml',         'ml',         2),
  (3, 'pièce',      'pièces',     3),
  (4, 'c. à soupe', 'c. à soupe', 4),
  (5, 'c. à café',  'c. à café',  5)
on conflict (id) do nothing;

insert into food.effects (name, description, blocked_slot) values
  ('Pas de repas le midi', 'Aucun repas ne peut être généré pour le midi de ce jour.', 'midi'),
  ('Pas de repas le soir', 'Aucun repas ne peut être généré pour le soir de ce jour.', 'soir')
on conflict (name) do nothing;

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
alter table food.effects          enable row level security;
alter table food.units            enable row level security;
alter table food.ingredients      enable row level security;
alter table food.food_ingredients enable row level security;
alter table food.audit_log    enable row level security;
revoke all on food.users, food.classes, food.foods, food.food_classes, food.meals,
  food.meal_items, food.constraints, food.day_constraints, food.ingredients, food.food_ingredients,
  food.effects, food.units, food.audit_log from anon, authenticated;

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

-- ---------------------------------------------------------------- Droits
revoke execute on function food._role(text, text)                from public, anon, authenticated;
revoke execute on function food._check(text, text, text[])       from public, anon, authenticated;
revoke execute on function food._today()                         from public, anon, authenticated;
revoke execute on function food._purge_old_data()                from public, anon, authenticated;
revoke execute on function food._audit(text, text, text, text, jsonb, jsonb) from public, anon, authenticated;
revoke execute on function food._clean_classes(smallint[])         from public, anon, authenticated;
revoke execute on function food._class_names(smallint[])           from public, anon, authenticated;
revoke execute on function food._is_recipe(smallint[])             from public, anon, authenticated;
revoke execute on function food._default_unit()                    from public, anon, authenticated;
revoke execute on function food._ingredient_state(text, smallint)  from public, anon, authenticated;
revoke execute on function food._clean_ing_rows(jsonb)             from public, anon, authenticated;
revoke execute on function food._food_ingredient_rows(bigint)      from public, anon, authenticated;
revoke execute on function food._set_food_ingredients(bigint, jsonb) from public, anon, authenticated;
revoke execute on function food._food_state(text, smallint[], jsonb) from public, anon, authenticated;
revoke execute on function food._effect_name(smallint)             from public, anon, authenticated;
revoke execute on function food._constraint_state(text, smallint)  from public, anon, authenticated;

revoke execute on function food.login(text, text)                                      from public;
revoke execute on function food.get_catalog(text, text)                                from public;
revoke execute on function food.get_meals(text, text, date, date)                      from public;
revoke execute on function food.set_meal(text, text, date, text, bigint[], numeric[])  from public;
revoke execute on function food.get_constraints(text, text)                            from public;
revoke execute on function food.get_day_constraints(text, text, date, date)            from public;
revoke execute on function food.set_day_constraints(text, text, date, bigint[])        from public;
revoke execute on function food.add_constraint(text, text, text, smallint)             from public;
revoke execute on function food.update_constraint(text, text, bigint, text, smallint)  from public;
revoke execute on function food.get_effects(text, text)                                from public;
revoke execute on function food.delete_constraint(text, text, bigint)                  from public;
revoke execute on function food.add_food(text, text, text, smallint[], jsonb)          from public;
revoke execute on function food.update_food(text, text, bigint, text, smallint[], jsonb) from public;
revoke execute on function food.delete_food(text, text, bigint)                        from public;
revoke execute on function food.get_ingredients(text, text)                            from public;
revoke execute on function food.add_ingredient(text, text, text, smallint)             from public;
revoke execute on function food.update_ingredient(text, text, bigint, text, smallint)  from public;
revoke execute on function food.delete_ingredient(text, text, bigint)                  from public;

grant execute on function food.login(text, text)                                       to anon, authenticated;
grant execute on function food.get_catalog(text, text)                                 to anon, authenticated;
grant execute on function food.get_meals(text, text, date, date)                       to anon, authenticated;
grant execute on function food.set_meal(text, text, date, text, bigint[], numeric[])   to anon, authenticated;
grant execute on function food.get_constraints(text, text)                             to anon, authenticated;
grant execute on function food.get_day_constraints(text, text, date, date)             to anon, authenticated;
grant execute on function food.set_day_constraints(text, text, date, bigint[])         to anon, authenticated;
grant execute on function food.add_constraint(text, text, text, smallint)              to anon, authenticated;
grant execute on function food.update_constraint(text, text, bigint, text, smallint)   to anon, authenticated;
grant execute on function food.get_effects(text, text)                                 to anon, authenticated;
grant execute on function food.delete_constraint(text, text, bigint)                   to anon, authenticated;
grant execute on function food.add_food(text, text, text, smallint[], jsonb)           to anon, authenticated;
grant execute on function food.update_food(text, text, bigint, text, smallint[], jsonb) to anon, authenticated;
grant execute on function food.delete_food(text, text, bigint)                         to anon, authenticated;
grant execute on function food.get_ingredients(text, text)                             to anon, authenticated;
grant execute on function food.add_ingredient(text, text, text, smallint)              to anon, authenticated;
grant execute on function food.update_ingredient(text, text, bigint, text, smallint)   to anon, authenticated;
grant execute on function food.delete_ingredient(text, text, bigint)                   to anon, authenticated;

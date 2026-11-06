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

-- Catégories de courses (listes France et Suisse). « Autre » (is_default) est créée d'office et ne peut pas
-- être supprimée ; les autres sont gérées par l'admin. pos_carrefour / pos_coop : rang de la catégorie dans les
-- tris custom Carrefour Segny et Coop Vich (de 1 à N, sans égalité ni trou, maintenus par les fonctions).
-- no_merge : les éléments de cette catégorie ne s'additionnent jamais (viande, poisson...).
create table if not exists food.shop_categories (
  id            smallint generated always as identity primary key,
  name          text     not null check (name = btrim(name) and name <> '' and char_length(name) <= 40),
  pos_carrefour smallint not null,
  pos_coop      smallint not null,
  no_merge      boolean  not null default false,
  is_default    boolean  not null default false
);
create unique index if not exists shop_categories_name_key on food.shop_categories (lower(name));
create unique index if not exists shop_categories_default_key on food.shop_categories (is_default) where is_default;

-- Ingrédients : un nom unique, en minuscules, une unité (g par défaut) dans laquelle toutes ses
-- quantités sont exprimées, et une catégorie de courses facultative (null : « Autre »). Aucun nettoyage automatique : un ingrédient lié à aucun aliment reste en
-- base jusqu'à ce que l'admin le supprime.
create table if not exists food.ingredients (
  id      bigint generated always as identity primary key,
  name    text     not null unique
          check (name = lower(name) and name = btrim(name) and name <> '' and char_length(name) <= 60),
  unit_id     smallint not null default 1 references food.units (id) on delete restrict,
  category_id smallint references food.shop_categories (id) on delete restrict
);
create index if not exists ingredients_unit_idx on food.ingredients (unit_id);
create index if not exists ingredients_category_idx on food.ingredients (category_id);

-- Ingrédients d'un aliment. Tout aliment a au moins un ingrédient, de n'importe quel nom (aucun lien de
-- nom) : un seul pour un aliment simple, 2 ou plus pour une recette (classe Recettes, ajoutée d'office
-- à partir de 2). quantity : quantité d'ingrédient pour 1 portion de l'aliment, dans l'unité de
-- l'ingrédient (null : non définie).
create table if not exists food.food_ingredients (
  food_id       bigint not null references food.foods (id) on delete cascade,
  ingredient_id bigint not null references food.ingredients (id) on delete restrict,
  quantity      numeric(8, 3) check (quantity > 0),
  primary key (food_id, ingredient_id)
);
create index if not exists food_ingredients_ingredient_idx on food.food_ingredients (ingredient_id);

-- Éléments des listes de courses France et Suisse : nom libre (aucun lien avec les ingrédients), catégorie,
-- quantité et unité facultatives (sans quantité, pas d'unité), coché ou non. Ils restent en base jusqu'à ce qu'on les
-- supprime, vide la liste ou écrase la liste par une génération.
create table if not exists food.shop_items (
  id          bigint generated always as identity primary key,
  list        text          not null check (list in ('france', 'suisse', 'autre')),
  name        text          not null check (name = btrim(name) and name <> '' and char_length(name) <= 60),
  category_id smallint      not null references food.shop_categories (id) on delete restrict,
  quantity    numeric(10, 3) check (quantity > 0),
  unit_id     smallint      references food.units (id) on delete restrict,
  checked     boolean       not null default false,
  created_at  timestamptz   not null default now()
);
create index if not exists shop_items_list_idx on food.shop_items (list);
create index if not exists shop_items_category_idx on food.shop_items (category_id);

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
-- { name, unit, category } (ingrédient), { name, effect } (contrainte) ou liste des noms de contraintes (contraintes
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
             'ingredient_add', 'ingredient_update', 'ingredient_delete',
             'shop_add', 'shop_update', 'shop_delete', 'shop_move', 'shop_clear', 'shop_generate',
             'shop_category_add', 'shop_category_update', 'shop_category_delete')),
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

insert into food.shop_categories (name, pos_carrefour, pos_coop, is_default)
select 'Autre', 1, 1, true
where not exists (select 1 from food.shop_categories where is_default);

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
alter table food.shop_categories enable row level security;
alter table food.shop_items      enable row level security;
alter table food.audit_log    enable row level security;
revoke all on food.users, food.classes, food.foods, food.food_classes, food.meals,
  food.meal_items, food.constraints, food.day_constraints, food.ingredients, food.food_ingredients,
  food.effects, food.units, food.shop_categories, food.shop_items, food.audit_log from anon, authenticated;

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

create or replace function food._ingredient_state(n text, uid smallint, cid smallint default null)
returns jsonb
language sql
security definer
set search_path = food
as $$
  select jsonb_build_object('name', n, 'unit', (select u.name from food.units u where u.id = uid))
         || case when cid is null then '{}'::jsonb
                 else jsonb_build_object('category', (select c.name from food.shop_categories c where c.id = cid)) end;
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

-- Ingrédients (rôle admin uniquement), avec le nombre d'aliments qui les utilisent, leur unité et leur catégorie.
create or replace function food.get_ingredients(u text, p text)
returns table (id bigint, name text, uses bigint, unit_id smallint, category_id smallint)
language plpgsql
security definer
set search_path = food, extensions
as $$
begin
  perform food._check(u, p, array['admin']);
  return query
    select i.id, i.name,
           (select count(*) from food.food_ingredients fi where fi.ingredient_id = i.id),
           i.unit_id, i.category_id
    from food.ingredients i
    order by i.name, i.id;
end;
$$;


-- Crée un ingrédient avec son unité (g par défaut) et sa catégorie de courses (null : aucune) (rôle admin uniquement).
create or replace function food.add_ingredient(u text, p text, n text, uid smallint default null, cid smallint default null)
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
  if cid is not null and not exists (select 1 from food.shop_categories c where c.id = cid) then
    raise exception 'unknown_category';
  end if;
  if exists (select 1 from food.ingredients i where i.name = name_) then
    raise exception 'ingredient_exists';
  end if;
  insert into food.ingredients (name, unit_id, category_id) values (name_, unit_, cid) returning id into new_id;
  perform food._audit(u, r, 'ingredient_add', name_, null, food._ingredient_state(name_, unit_, cid));
  return new_id;
end;
$$;


-- Modifie le nom, l'unité et la catégorie de courses d'un ingrédient (rôle admin uniquement ; uid null : l'unité ne
-- change pas ; cid -1 : la catégorie ne change pas, null : plus de catégorie). Les aliments qui l'utilisent suivent
-- automatiquement. Changer l'unité ne convertit pas les quantités déjà saisies.
create or replace function food.update_ingredient(u text, p text, iid bigint, n text, uid smallint default null,
                                                  cid smallint default -1)
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
  old_cat smallint;
  unit_ smallint;
  cat_ smallint;
begin
  r := food._check(u, p, array['admin']);
  if name_ = '' or char_length(name_) > 60 then
    raise exception 'invalid_name';
  end if;
  select i.name, i.unit_id, i.category_id into old_name, old_unit, old_cat from food.ingredients i where i.id = iid;
  if not found then
    raise exception 'unknown_ingredient';
  end if;
  unit_ := coalesce(uid, old_unit);
  cat_ := case when cid = -1 then old_cat else cid end;
  if not exists (select 1 from food.units un where un.id = unit_) then
    raise exception 'unknown_unit';
  end if;
  if cat_ is not null and not exists (select 1 from food.shop_categories c where c.id = cat_) then
    raise exception 'unknown_category';
  end if;
  if exists (select 1 from food.ingredients i where i.name = name_ and i.id <> iid) then
    raise exception 'ingredient_exists';
  end if;

  -- Rien n'est écrit (ni consigné) si ni le nom, ni l'unité, ni la catégorie ne changent.
  if name_ <> old_name or unit_ <> old_unit or cat_ is distinct from old_cat then
    update food.ingredients set name = name_, unit_id = unit_, category_id = cat_ where id = iid;
    perform food._audit(u, r, 'ingredient_update', old_name,
                        food._ingredient_state(old_name, old_unit, old_cat), food._ingredient_state(name_, unit_, cat_));
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
  old_cat smallint;
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
  select i.name, i.unit_id, i.category_id into old_name, old_unit, old_cat from food.ingredients i where i.id = iid;
  if found then
    delete from food.ingredients where id = iid;
    perform food._audit(u, r, 'ingredient_delete', old_name, food._ingredient_state(old_name, old_unit, old_cat), null);
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

-- ------------------------------------------------------ Fonctions internes
create or replace function food._default_category()
returns smallint
language sql
stable
security definer
set search_path = food
as $$
  select c.id from food.shop_categories c where c.is_default limit 1;
$$;

-- Place une catégorie au rang pc (tri Carrefour) et au rang pk (tri Coop) : les autres catégories sont
-- décalées d'un cran, les rangs restent de 1 à N sans égalité ni trou. Un rang hors limites est ramené à 1 ou à N ;
-- null : le rang ne change pas.
create or replace function food._shop_place(cid smallint, pc integer, pk integer)
returns void
language plpgsql
security definer
set search_path = food
as $$
declare
  n integer;
begin
  select count(*) into n from food.shop_categories;
  if pc is not null then
    pc := greatest(1, least(pc, n));
    with others as (
      select c.id, row_number() over (order by c.pos_carrefour, c.id) as rn
      from food.shop_categories c where c.id <> cid
    ), placed as (
      select o.id, (case when o.rn >= pc then o.rn + 1 else o.rn end) as r from others o
      union all select cid, pc
    )
    update food.shop_categories c set pos_carrefour = p.r from placed p where p.id = c.id;
  end if;
  if pk is not null then
    pk := greatest(1, least(pk, n));
    with others as (
      select c.id, row_number() over (order by c.pos_coop, c.id) as rn
      from food.shop_categories c where c.id <> cid
    ), placed as (
      select o.id, (case when o.rn >= pk then o.rn + 1 else o.rn end) as r from others o
      union all select cid, pk
    )
    update food.shop_categories c set pos_coop = p.r from placed p where p.id = c.id;
  end if;
end;
$$;

-- Renumérote les rangs de 1 à N (après une suppression).
create or replace function food._shop_compact()
returns void
language sql
security definer
set search_path = food
as $$
  update food.shop_categories c set pos_carrefour = r.rn
  from (select id, row_number() over (order by pos_carrefour, id) as rn from food.shop_categories) r
  where r.id = c.id;
  update food.shop_categories c set pos_coop = r.rn
  from (select id, row_number() over (order by pos_coop, id) as rn from food.shop_categories) r
  where r.id = c.id;
$$;

-- État d'une catégorie pour l'audit : { name, carrefour, coop, no_merge }.
create or replace function food._shop_category_state(cid smallint)
returns jsonb
language sql
security definer
set search_path = food
as $$
  select jsonb_build_object('name', c.name, 'carrefour', c.pos_carrefour, 'coop', c.pos_coop, 'no_merge', c.no_merge)
  from food.shop_categories c where c.id = cid;
$$;

-- État d'un élément de liste pour l'audit : { list, name, category, quantity, unit }.
create or replace function food._shop_item_state(lst text, n text, cid smallint, q numeric, uid smallint)
returns jsonb
language sql
security definer
set search_path = food
as $$
  select jsonb_build_object('list', lst, 'name', n,
    'category', (select c.name from food.shop_categories c where c.id = cid),
    'quantity', q,
    'unit', (select u.name from food.units u where u.id = uid));
$$;

-- Contrôle des champs d'un élément (erreurs : invalid_name, unknown_category, invalid_quantity, unknown_unit).
create or replace function food._shop_check_item(n text, cid smallint, q numeric, uid smallint)
returns void
language plpgsql
security definer
set search_path = food
as $$
begin
  if n is null or btrim(n) = '' or char_length(btrim(n)) > 60 then
    raise exception 'invalid_name';
  end if;
  if cid is null or not exists (select 1 from food.shop_categories c where c.id = cid) then
    raise exception 'unknown_category';
  end if;
  if q is not null and not (q > 0 and q <= 99999 and round(q, 3) = q) then
    raise exception 'invalid_quantity';
  end if;
  if uid is not null and not exists (select 1 from food.units u where u.id = uid) then
    raise exception 'unknown_unit';
  end if;
end;
$$;

-- Élément avec lequel un nouvel élément peut fusionner : même liste, même nom (sans tenir compte de la casse),
-- même catégorie, même unité, tous deux sans quantité ou tous deux avec, jamais un élément coché, jamais une
-- catégorie « ne s'additionne pas ». Renvoie son id, ou null.
create or replace function food._shop_match(lst text, n text, cid smallint, uid smallint, qnull boolean)
returns bigint
language sql
stable
security definer
set search_path = food
as $$
  select s.id
  from food.shop_items s
  join food.shop_categories c on c.id = s.category_id
  where s.list = lst
    and lower(s.name) = lower(btrim(n))
    and s.category_id = cid
    and s.unit_id is not distinct from uid
    and (s.quantity is null) = qnull
    and not s.checked
    and not c.no_merge
  order by s.id
  limit 1;
$$;

-- Ajoute un élément à une liste (déjà contrôlé), en le fusionnant avec un élément existant si merge est vrai et
-- que la règle de fusion le permet. L'unité est ignorée sans quantité. Renvoie { merged, id, before, after }.
create or replace function food._shop_put(lst text, n text, cid smallint, q numeric, uid smallint, merge boolean)
returns jsonb
language plpgsql
security definer
set search_path = food
as $$
declare
  nm boolean;
  m bigint;
  prev numeric;
  u smallint := case when q is null then null else uid end;
begin
  select c.no_merge into nm from food.shop_categories c where c.id = cid;
  if merge and not nm then
    m := food._shop_match(lst, n, cid, u, q is null);
  end if;
  if m is not null then
    if q is null then
      return jsonb_build_object('merged', true, 'id', m, 'before', null, 'after', null);
    end if;
    select s.quantity into prev from food.shop_items s where s.id = m;
    update food.shop_items set quantity = prev + q where id = m;
    return jsonb_build_object('merged', true, 'id', m, 'before', prev, 'after', prev + q);
  end if;
  insert into food.shop_items (list, name, category_id, quantity, unit_id)
  values (lst, btrim(n), cid, q, u) returning id into m;
  return jsonb_build_object('merged', false, 'id', m);
end;
$$;

-- Génère la liste France à partir des repas de d_from à d_to (bornes incluses) et renvoie le résultat :
-- { added, replaced, merged: [{ name, unit, before, add, after }], split: [noms], no_qty: [noms] }.
-- mode : 'replace' (vide la liste d'abord), 'append' (ajoute sans fusionner avec l'existant), 'merge'
-- (fusionne selon la règle de fusion). Erreurs : invalid_mode, invalid_dates. N'écrit pas dans l'audit.
create or replace function food._shop_generate(lst text, d_from date, d_to date, mode text)
returns jsonb
language plpgsql
security definer
set search_path = food
as $$
declare
  def smallint := food._default_category();
  r record;
  q numeric;
  uid smallint;
  put jsonb;
  added integer := 0;
  replaced integer := 0;
  merged jsonb := '[]'::jsonb;
  split text[] := '{}';
  noqty text[] := '{}';
begin
  if mode is null or mode not in ('replace', 'append', 'merge') then
    raise exception 'invalid_mode';
  end if;
  if d_from is null or d_to is null or d_from < food._today() or d_to < d_from or d_to - d_from > 61 then
    raise exception 'invalid_dates';
  end if;
  if mode = 'replace' then
    select count(*) into replaced from food.shop_items s where s.list = lst;
    delete from food.shop_items where list = lst;
  end if;
  for r in
    select x.name, x.cid, x.uid, x.qnull, sum(x.qty) as total
    from (
      select i.name,
             coalesce(i.category_id, def) as cid,
             i.unit_id as uid,
             (fi.quantity is null) as qnull,
             fi.quantity * mi.portions as qty,
             case when c.no_merge then mi.meal_id::text || '-' || mi.food_id::text else '' end as grp
      from food.meals m
      join food.meal_items mi on mi.meal_id = m.id
      join food.food_ingredients fi on fi.food_id = mi.food_id
      join food.ingredients i on i.id = fi.ingredient_id
      join food.shop_categories c on c.id = coalesce(i.category_id, def)
      where m.meal_date between d_from and d_to
    ) x
    group by x.name, x.cid, x.uid, x.qnull, x.grp
    order by x.name, x.grp
  loop
    q := case when r.qnull then null else round(r.total, 3) end;
    uid := case when r.qnull then null else r.uid end;
    if r.qnull and not (r.name = any (noqty)) then
      noqty := noqty || r.name;
    end if;
    put := food._shop_put(lst, r.name, r.cid, q, uid, mode = 'merge');
    if (put ->> 'merged')::boolean then
      merged := merged || jsonb_build_array(jsonb_build_object(
        'name', r.name, 'unit', (select u.name from food.units u where u.id = uid),
        'before', put -> 'before', 'add', q, 'after', put -> 'after'));
    else
      added := added + 1;
      if mode = 'merge' and exists (
           select 1 from food.shop_items s
           join food.shop_categories c on c.id = s.category_id
           where s.list = lst and s.id <> (put ->> 'id')::bigint and lower(s.name) = lower(r.name)
             and s.category_id = r.cid and s.unit_id is not distinct from uid
             and (s.quantity is null) = r.qnull and s.checked and not c.no_merge)
         and not (r.name = any (split)) then
        split := split || r.name;
      end if;
    end if;
  end loop;
  return jsonb_build_object(
    'added', added, 'replaced', replaced, 'merged', merged,
    'split', to_jsonb(split), 'no_qty', to_jsonb(noqty));
end;
$$;

-- ----------------------------------------------------- Fonctions publiques
-- Catégories de courses (tous rôles), avec le nombre d'ingrédients et d'éléments de liste qui les utilisent.
create or replace function food.get_shop_categories(u text, p text)
returns table (id smallint, name text, pos_carrefour smallint, pos_coop smallint, no_merge boolean,
               is_default boolean, uses bigint)
language plpgsql
security definer
set search_path = food, extensions
as $$
begin
  perform food._check(u, p, array['read', 'write', 'admin']);
  return query
    select c.id, c.name, c.pos_carrefour, c.pos_coop, c.no_merge, c.is_default,
           (select count(*) from food.ingredients i where i.category_id = c.id)
           + (select count(*) from food.shop_items s where s.category_id = c.id)
    from food.shop_categories c
    order by c.name, c.id;
end;
$$;

-- Crée une catégorie (rôle admin uniquement). pc / pk : rangs dans les tris Carrefour et Coop (null : en dernier) ;
-- les catégories qui les occupaient sont décalées. Erreurs : invalid_name, category_exists.
create or replace function food.add_shop_category(u text, p text, n text, pc integer default null,
                                                  pk integer default null, nm boolean default false)
returns smallint
language plpgsql
security definer
set search_path = food, extensions
as $$
declare
  r text;
  name_ text := btrim(coalesce(n, ''));
  new_id smallint;
begin
  r := food._check(u, p, array['admin']);
  if name_ = '' or char_length(name_) > 40 then
    raise exception 'invalid_name';
  end if;
  if exists (select 1 from food.shop_categories c where lower(c.name) = lower(name_)) then
    raise exception 'category_exists';
  end if;
  insert into food.shop_categories (name, pos_carrefour, pos_coop, no_merge)
  values (name_,
          (select coalesce(max(c.pos_carrefour), 0) + 1 from food.shop_categories c),
          (select coalesce(max(c.pos_coop), 0) + 1 from food.shop_categories c),
          coalesce(nm, false))
  returning id into new_id;
  perform food._shop_place(new_id, pc, pk);
  perform food._audit(u, r, 'shop_category_add', name_, null, food._shop_category_state(new_id));
  return new_id;
end;
$$;

-- Modifie une catégorie (rôle admin uniquement). Mêmes règles de rang que add_shop_category (null : le rang ne
-- change pas). Erreurs : invalid_name, unknown_category, category_exists.
create or replace function food.update_shop_category(u text, p text, cid smallint, n text, pc integer default null,
                                                     pk integer default null, nm boolean default false)
returns void
language plpgsql
security definer
set search_path = food, extensions
as $$
declare
  r text;
  name_ text := btrim(coalesce(n, ''));
  old_name text;
  before_state jsonb;
begin
  r := food._check(u, p, array['admin']);
  if name_ = '' or char_length(name_) > 40 then
    raise exception 'invalid_name';
  end if;
  select c.name into old_name from food.shop_categories c where c.id = cid;
  if not found then
    raise exception 'unknown_category';
  end if;
  if exists (select 1 from food.shop_categories c where lower(c.name) = lower(name_) and c.id <> cid) then
    raise exception 'category_exists';
  end if;
  before_state := food._shop_category_state(cid);
  update food.shop_categories set name = name_, no_merge = coalesce(nm, false) where id = cid;
  perform food._shop_place(cid, pc, pk);
  if food._shop_category_state(cid) <> before_state then
    perform food._audit(u, r, 'shop_category_update', old_name, before_state, food._shop_category_state(cid));
  end if;
end;
$$;

-- Supprime une catégorie (rôle admin uniquement). Refusé pour « Autre » (category_default) et tant qu'un ingrédient
-- ou un élément de liste l'utilise (category_in_use, avec la liste en JSON { n, items }).
create or replace function food.delete_shop_category(u text, p text, cid smallint)
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
  before_state jsonb;
  dflt boolean;
begin
  r := food._check(u, p, array['admin']);
  select c.name, c.is_default into old_name, dflt from food.shop_categories c where c.id = cid;
  if not found then
    return;
  end if;
  if dflt then
    raise exception 'category_default';
  end if;
  select count(*), coalesce(jsonb_agg(q.x order by q.x), '[]'::jsonb) into n, items
  from (
    select i.name || ' (ingrédient)' as x from food.ingredients i where i.category_id = cid
    union all
    select s.name || ' (liste ' || case s.list when 'france' then 'France' else 'Suisse' end || ')'
    from food.shop_items s where s.category_id = cid
  ) q;
  if n > 0 then
    raise exception 'category_in_use' using detail = jsonb_build_object('n', n, 'items', items)::text;
  end if;
  before_state := food._shop_category_state(cid);
  delete from food.shop_categories where id = cid;
  perform food._shop_compact();
  perform food._audit(u, r, 'shop_category_delete', old_name, before_state, null);
end;
$$;

-- Éléments des listes France et Suisse (tous rôles), du plus ancien au plus récent.
create or replace function food.get_shop_items(u text, p text)
returns table (id bigint, list text, name text, category_id smallint, quantity numeric, unit_id smallint,
               checked boolean, created_at timestamptz)
language plpgsql
security definer
set search_path = food, extensions
as $$
begin
  perform food._check(u, p, array['read', 'write', 'admin']);
  return query
    select s.id, s.list, s.name, s.category_id, s.quantity, s.unit_id, s.checked, s.created_at
    from food.shop_items s
    order by s.id;
end;
$$;

-- Ajoute un élément à une liste (rôles write et admin). cid null : « Autre ». Sans quantité l'unité est ignorée.
-- Fusion avec un élément existant selon la règle de fusion. Renvoie { merged, id, before, after }.
create or replace function food.add_shop_item(u text, p text, lst text, n text, cid smallint default null,
                                              q numeric default null, uid smallint default null)
returns jsonb
language plpgsql
security definer
set search_path = food, extensions
as $$
declare
  r text;
  c smallint := coalesce(cid, food._default_category());
  put jsonb;
begin
  r := food._check(u, p, array['write', 'admin']);
  if lst is null or lst not in ('france', 'suisse', 'autre') then
    raise exception 'invalid_list';
  end if;
  perform food._shop_check_item(n, c, q, uid);
  put := food._shop_put(lst, n, c, q, uid, true);
  perform food._audit(u, r, 'shop_add', btrim(n), null,
                      food._shop_item_state(lst, btrim(n), c, q, case when q is null then null else uid end)
                      || jsonb_build_object('merged', put -> 'merged'));
  return put;
end;
$$;

-- Modifie un élément (rôles write et admin) : nom, catégorie, quantité, unité. Pas de fusion, la case ne change pas.
create or replace function food.update_shop_item(u text, p text, iid bigint, n text, cid smallint default null,
                                                 q numeric default null, uid smallint default null)
returns void
language plpgsql
security definer
set search_path = food, extensions
as $$
declare
  r text;
  c smallint := coalesce(cid, food._default_category());
  itm record;
  new_unit smallint := case when q is null then null else uid end;
begin
  r := food._check(u, p, array['write', 'admin']);
  select s.* into itm from food.shop_items s where s.id = iid;
  if not found then
    raise exception 'unknown_item';
  end if;
  perform food._shop_check_item(n, c, q, uid);
  if btrim(n) <> itm.name or c <> itm.category_id or q is distinct from itm.quantity
     or new_unit is distinct from itm.unit_id then
    update food.shop_items
    set name = btrim(n), category_id = c, quantity = q, unit_id = new_unit
    where id = iid;
    perform food._audit(u, r, 'shop_update', itm.name,
                        food._shop_item_state(itm.list, itm.name, itm.category_id, itm.quantity, itm.unit_id),
                        food._shop_item_state(itm.list, btrim(n), c, q, new_unit));
  end if;
end;
$$;

-- Coche ou décoche un élément (rôles read, write et admin). Non consigné dans l'audit.
create or replace function food.set_shop_item_checked(u text, p text, iid bigint, chk boolean)
returns void
language plpgsql
security definer
set search_path = food, extensions
as $$
begin
  perform food._check(u, p, array['read', 'write', 'admin']);
  update food.shop_items set checked = coalesce(chk, false) where id = iid;
  if not found then
    raise exception 'unknown_item';
  end if;
end;
$$;

-- Supprime un élément (rôles write et admin).
create or replace function food.delete_shop_item(u text, p text, iid bigint)
returns void
language plpgsql
security definer
set search_path = food, extensions
as $$
declare
  r text;
  itm record;
begin
  r := food._check(u, p, array['write', 'admin']);
  select s.* into itm from food.shop_items s where s.id = iid;
  if found then
    delete from food.shop_items where id = iid;
    perform food._audit(u, r, 'shop_delete', itm.name,
                        food._shop_item_state(itm.list, itm.name, itm.category_id, itm.quantity, itm.unit_id), null);
  end if;
end;
$$;

-- Vide une liste (rôles write et admin) : tous ses éléments, cochés ou non.
create or replace function food.clear_shop_list(u text, p text, lst text)
returns void
language plpgsql
security definer
set search_path = food, extensions
as $$
declare
  r text;
  n integer;
begin
  r := food._check(u, p, array['write', 'admin']);
  if lst is null or lst not in ('france', 'suisse', 'autre') then
    raise exception 'invalid_list';
  end if;
  select count(*) into n from food.shop_items s where s.list = lst;
  delete from food.shop_items where list = lst;
  if n > 0 then
    perform food._audit(u, r, 'shop_clear', lst, jsonb_build_object('list', lst, 'count', n), null);
  end if;
end;
$$;

-- Déplace un élément dans l'autre liste (rôles write et admin). Si l'élément n'est pas coché et qu'un élément de la
-- liste d'arrivée correspond (règle de fusion), les quantités s'additionnent et l'élément déplacé disparaît.
-- Renvoie { merged, id }.
create or replace function food.move_shop_item(u text, p text, iid bigint, to_list text)
returns jsonb
language plpgsql
security definer
set search_path = food, extensions
as $$
declare
  r text;
  itm record;
  nm boolean;
  m bigint;
  prev numeric;
begin
  r := food._check(u, p, array['write', 'admin']);
  if to_list is null or to_list not in ('france', 'suisse', 'autre') then
    raise exception 'invalid_list';
  end if;
  select s.* into itm from food.shop_items s where s.id = iid;
  if not found then
    raise exception 'unknown_item';
  end if;
  if itm.list = to_list then
    return jsonb_build_object('merged', false, 'id', iid);
  end if;
  select c.no_merge into nm from food.shop_categories c where c.id = itm.category_id;
  if not itm.checked and not nm then
    m := food._shop_match(to_list, itm.name, itm.category_id, itm.unit_id, itm.quantity is null);
  end if;
  if m is not null then
    if itm.quantity is not null then
      select s.quantity into prev from food.shop_items s where s.id = m;
      update food.shop_items set quantity = prev + itm.quantity where id = m;
    end if;
    delete from food.shop_items where id = iid;
  else
    update food.shop_items set list = to_list where id = iid;
  end if;
  perform food._audit(u, r, 'shop_move', itm.name,
                      food._shop_item_state(itm.list, itm.name, itm.category_id, itm.quantity, itm.unit_id),
                      food._shop_item_state(to_list, itm.name, itm.category_id, itm.quantity, itm.unit_id)
                      || jsonb_build_object('merged', m is not null));
  return jsonb_build_object('merged', m is not null, 'id', coalesce(m, iid));
end;
$$;

-- Aperçu de la génération de la liste France (rôles write et admin) : le résultat exact de generate_shop, calculé
-- puis annulé (rien n'est modifié). Erreurs : invalid_mode, invalid_dates.
create or replace function food.preview_shop_generation(u text, p text, d_from date, d_to date, mode text)
returns jsonb
language plpgsql
security definer
set search_path = food, extensions
as $$
declare
  res jsonb;
  d text;
begin
  perform food._check(u, p, array['write', 'admin']);
  begin
    res := food._shop_generate('france', d_from, d_to, mode);
    raise exception 'shop_preview' using detail = res::text;
  exception when raise_exception then
    if sqlerrm <> 'shop_preview' then
      raise;
    end if;
    get stacked diagnostics d = pg_exception_detail;
    return d::jsonb;
  end;
end;
$$;

-- Génère la liste France à partir des repas de d_from à d_to (rôles write et admin). Renvoie le même résultat que
-- preview_shop_generation.
create or replace function food.generate_shop(u text, p text, d_from date, d_to date, mode text)
returns jsonb
language plpgsql
security definer
set search_path = food, extensions
as $$
declare
  r text;
  res jsonb;
begin
  r := food._check(u, p, array['write', 'admin']);
  res := food._shop_generate('france', d_from, d_to, mode);
  perform food._audit(u, r, 'shop_generate', 'france', null,
                      jsonb_build_object('from', d_from, 'to', d_to, 'mode', mode, 'added', res -> 'added',
                                         'merged', jsonb_array_length(res -> 'merged'), 'replaced', res -> 'replaced'));
  return res;
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
revoke execute on function food._ingredient_state(text, smallint, smallint) from public, anon, authenticated;
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
revoke execute on function food.add_ingredient(text, text, text, smallint, smallint)             from public;
revoke execute on function food.update_ingredient(text, text, bigint, text, smallint, smallint)  from public;
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
grant execute on function food.add_ingredient(text, text, text, smallint, smallint)              to anon, authenticated;
grant execute on function food.update_ingredient(text, text, bigint, text, smallint, smallint)   to anon, authenticated;
grant execute on function food.delete_ingredient(text, text, bigint)                   to anon, authenticated;

-- Listes de courses (v2-5)
revoke execute on function food._default_category()                                             from public, anon, authenticated;
revoke execute on function food._shop_place(smallint, integer, integer)                         from public, anon, authenticated;
revoke execute on function food._shop_compact()                                                 from public, anon, authenticated;
revoke execute on function food._shop_category_state(smallint)                                  from public, anon, authenticated;
revoke execute on function food._shop_item_state(text, text, smallint, numeric, smallint)       from public, anon, authenticated;
revoke execute on function food._shop_check_item(text, smallint, numeric, smallint)             from public, anon, authenticated;
revoke execute on function food._shop_match(text, text, smallint, smallint, boolean)            from public, anon, authenticated;
revoke execute on function food._shop_put(text, text, smallint, numeric, smallint, boolean)     from public, anon, authenticated;
revoke execute on function food._shop_generate(text, date, date, text)                          from public, anon, authenticated;
revoke execute on function food.get_shop_categories(text, text)                                         from public;
revoke execute on function food.add_shop_category(text, text, text, integer, integer, boolean)          from public;
revoke execute on function food.update_shop_category(text, text, smallint, text, integer, integer, boolean) from public;
revoke execute on function food.delete_shop_category(text, text, smallint)                              from public;
revoke execute on function food.get_shop_items(text, text)                                              from public;
revoke execute on function food.add_shop_item(text, text, text, text, smallint, numeric, smallint)      from public;
revoke execute on function food.update_shop_item(text, text, bigint, text, smallint, numeric, smallint) from public;
revoke execute on function food.set_shop_item_checked(text, text, bigint, boolean)                      from public;
revoke execute on function food.delete_shop_item(text, text, bigint)                                    from public;
revoke execute on function food.clear_shop_list(text, text, text)                                       from public;
revoke execute on function food.move_shop_item(text, text, bigint, text)                                from public;
revoke execute on function food.preview_shop_generation(text, text, date, date, text)                   from public;
revoke execute on function food.generate_shop(text, text, date, date, text)                             from public;
grant execute on function food.get_shop_categories(text, text)                                          to anon, authenticated;
grant execute on function food.add_shop_category(text, text, text, integer, integer, boolean)           to anon, authenticated;
grant execute on function food.update_shop_category(text, text, smallint, text, integer, integer, boolean) to anon, authenticated;
grant execute on function food.delete_shop_category(text, text, smallint)                               to anon, authenticated;
grant execute on function food.get_shop_items(text, text)                                               to anon, authenticated;
grant execute on function food.add_shop_item(text, text, text, text, smallint, numeric, smallint)       to anon, authenticated;
grant execute on function food.update_shop_item(text, text, bigint, text, smallint, numeric, smallint)  to anon, authenticated;
grant execute on function food.set_shop_item_checked(text, text, bigint, boolean)                       to anon, authenticated;
grant execute on function food.delete_shop_item(text, text, bigint)                                     to anon, authenticated;
grant execute on function food.clear_shop_list(text, text, text)                                        to anon, authenticated;
grant execute on function food.move_shop_item(text, text, bigint, text)                                 to anon, authenticated;
grant execute on function food.preview_shop_generation(text, text, date, date, text)                    to anon, authenticated;
grant execute on function food.generate_shop(text, text, date, date, text)                              to anon, authenticated;

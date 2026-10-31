-- Migration : recettes et ingrédients (specs v2-1), partie DONNÉES.
-- À exécuter une fois dans Supabase (SQL Editor), APRÈS la migration 006 et APRÈS avoir marqué en
-- SQL les aliments qui sont des recettes (voir l'en-tête de 006).
--
-- Crée un ingrédient de même nom pour chaque aliment qui n'est PAS une recette (aucune classe de
-- type combo) et fait le lien. Les recettes ne sont pas touchées : leurs ingrédients se saisissent
-- ensuite dans l'onglet Admin.
-- Ce script peut être relancé sans risque (par exemple après avoir ajouté des aliments en SQL).

begin;

insert into food.ingredients (name)
select f.name
from food.foods f
where not exists (select 1 from food.food_classes fc
                  join food.classes c on c.id = fc.class_id
                  where fc.food_id = f.id and c.type = 'combo')
on conflict (name) do nothing;

insert into food.food_ingredients (food_id, ingredient_id)
select f.id, i.id
from food.foods f
join food.ingredients i on i.name = f.name
where not exists (select 1 from food.food_classes fc
                  join food.classes c on c.id = fc.class_id
                  where fc.food_id = f.id and c.type = 'combo')
on conflict do nothing;

commit;

-- Contrôle : recettes encore sans ingrédient (à compléter dans l'onglet Admin)
-- select f.name from food.foods f
-- where exists (select 1 from food.food_classes fc join food.classes c on c.id = fc.class_id
--               where fc.food_id = f.id and c.type = 'combo')
--   and not exists (select 1 from food.food_ingredients fi where fi.food_id = f.id);

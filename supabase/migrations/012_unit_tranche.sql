-- Données : nouvelle unité « tranche » et ingrédients qui s'y comptent (à relire avant de l'exécuter).
-- À exécuter une fois dans Supabase (SQL Editor), APRÈS les migrations 010 et 011.
--
-- Ajoute l'unité tranche / tranches dans food.units, puis y passe les ingrédients de la liste ci-dessous.
-- Un nom absent de la base est simplement ignoré. Modifiez la liste selon vos besoins : pour changer un
-- autre ingrédient plus tard, il suffit de refaire un update avec son nom.
-- Les quantités déjà saisies ne sont pas converties : seul leur sens change (2 pièces -> 2 tranches).
-- Le script peut être relancé sans risque.

begin;

insert into food.units (id, name, plural, position) values
  (6, 'tranche', 'tranches', 6)
on conflict (id) do nothing;

update food.ingredients
set unit_id = (select u.id from food.units u where u.name = 'tranche')
where name in (
  'fromage croque-monsieur', 'jambon', 'raclette', 'charcuterie'
);

commit;

-- Contrôle : ingrédients en tranches
-- select i.name, u.name as unit from food.ingredients i join food.units u on u.id = i.unit_id where u.name = 'tranche' order by i.name;

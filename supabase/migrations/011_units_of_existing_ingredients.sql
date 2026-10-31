-- Données : unité des ingrédients existants (à relire et adapter avant de l'exécuter).
-- À exécuter une fois dans Supabase (SQL Editor), APRÈS la migration 010.
--
-- Après 010, tous les ingrédients sont en g. Ce script met en « pièce » ceux qui se comptent à la pièce
-- et en « ml » la sauce tomate ; les autres restent en g. Liste établie d'après les ingrédients présents en
-- base le jour où le script a été écrit : un nom qui n'existe pas est simplement ignoré, un ingrédient
-- absent de la liste garde g. Modifiez les listes ci-dessous si une unité ne convient pas, par exemple :
--   - passer « jambon » en pièce (tranches) : l'ajouter à la liste des pièces ;
--   - repasser « pain » en g : le retirer de cette liste.
-- Les quantités déjà saisies ne sont pas converties : exécutez ce script AVANT de saisir des quantités.
-- Le script peut être relancé sans risque.

begin;

update food.ingredients
set unit_id = (select u.id from food.units u where u.name = 'pièce')
where name in (
  'aubergine', 'avocat', 'concombre', 'cornichons', 'courgette',
  'fromage croque-monsieur', 'knackies', 'magret canard', 'oeuf',
  'pain', 'pain hotdog', 'pain mie', 'pain noir', 'poisson pâné',
  'poivron', 'poulet rôti', 'tomate', 'vache qui rit', 'yaourt'
);

update food.ingredients
set unit_id = (select u.id from food.units u where u.name = 'ml')
where name in ('sauce tomate');

commit;

-- Contrôle : unité de chaque ingrédient
-- select i.name, u.name as unit from food.ingredients i join food.units u on u.id = i.unit_id order by u.position, i.name;

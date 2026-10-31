# Repas

Petit site statique (HTML/CSS/JS) hébergé sur GitHub Pages pour planifier les repas du midi et du soir. Les données sont dans Supabase (schéma `food` du projet `family`).

- On se connecte avec un identifiant et un mot de passe. Trois utilisateurs, trois modes : `reader` (**Read** : voir les repas), `writer` (**Write** : Read + modifier les repas), `admin` (**Admin** : Read + Write + gestion des aliments, des ingrédients et des contraintes dans l'onglet Admin). L'admin peut donc tout faire depuis une seule connexion, sans changer d'utilisateur.
- Les specs sont dans [`specs/`](specs/) (une version par fichier, la plus récente fait foi).

## Comment ça marche

- `index.html`, `style.css`, `app.js` : le site.
- `supabase/schema.sql` : tables et fonctions de la base (installation neuve).
- `supabase/migrations/` : scripts à exécuter, dans l'ordre (001, 002, 003…), sur une base déjà installée. `schema.sql` est l'état final, pour une installation neuve (pas besoin des migrations dans ce cas).
- `test/` : version du site avec une fausse API en mémoire, pour essayer l'interface sans Supabase (ouvrir `test/index.html` ; identifiant / mot de passe : `reader` / `r`, `writer` / `w`, `admin` / `a`). Non utilisée par le vrai site.

La sécurité repose sur la base : les tables sont verrouillées (RLS sans policy) et le site n'y accède que via des fonctions qui vérifient l'identifiant et le mot de passe (stocké haché) **et** le rôle autorisé pour chaque action. L'URL et la clé `sb_publishable_…` présentes dans le code sont publiques par conception. **Ne jamais commiter** la clé `sb_secret_…`, le mot de passe de la base ni les mots de passe du site.

Sessions : `reader` et `writer` restent connectés (identifiant et mot de passe gardés dans le navigateur) jusqu'au clic sur « Quitter ». `admin` est révoqué à la fermeture de l'onglet.

## Installation initiale (une seule fois)

1. Dans Supabase : **SQL Editor > New query**, coller le contenu de `supabase/schema.sql`, **Run**. Les tables et fonctions sont dans le schéma `food` (les 6 classes d'aliments sont créées : 5 composantes et Recettes).
   Puis **Project Settings > Data API > Exposed schemas** : ajouter `food`, sinon le site n'a pas accès à l'API.
2. Créer les trois utilisateurs (remplacer `MDP_READER`, `MDP_WRITER`, `MDP_ADMIN`) :
   ```sql
   insert into food.users (user_id, role, password_hash) values
     ('reader', 'read',  extensions.crypt('MDP_READER', extensions.gen_salt('bf'))),
     ('writer', 'write', extensions.crypt('MDP_WRITER', extensions.gen_salt('bf'))),
     ('admin',  'admin', extensions.crypt('MDP_ADMIN',  extensions.gen_salt('bf')))
   on conflict (user_id) do update set role = excluded.role, password_hash = excluded.password_hash;
   ```
3. Activer GitHub Pages : dépôt GitHub > **Settings > Pages** > Source : *Deploy from a branch*, branche `main`, dossier `/ (root)`.
4. Le site est alors disponible à `https://samoht99.github.io/food/`.

## Mise à jour vers la v2 (recettes et ingrédients)

Sur une base déjà installée (v1), dans Supabase (**SQL Editor**), dans cet ordre :

1. Exécuter `supabase/migrations/006_recipes_ingredients.sql` (structure : type des classes, classe Recettes, tables d'ingrédients, fonctions). Après ce script, l'ancien site (v1) n'affiche plus correctement les repas : publier le site v2 (fusion dans `main`) juste après, puis recharger (Ctrl+F5).
2. Marquer en SQL les aliments qui sont des recettes (ils gardent leurs autres classes) :
   ```sql
   insert into food.food_classes (food_id, class_id)
   select f.id, (select id from food.classes where name = 'Recettes')
   from food.foods f
   where f.name in ('lasagnes', 'sandwich jambon-salade')
   on conflict do nothing;
   ```
3. Exécuter `supabase/migrations/007_backfill_ingredients.sql` (crée un ingrédient de même nom pour chaque aliment qui n'est pas une recette ; peut être relancé sans risque).
4. Dans l'onglet Admin, ouvrir chaque recette (**Modifier**) et saisir ses ingrédients (au moins 1).
5. Exécuter `supabase/migrations/008_usage_details.sql` : quand on tente de supprimer un aliment, un ingrédient ou une contrainte utilisé(e), le site affiche la liste de ce qui l'utilise (repas, aliments ou jours).
6. Exécuter `supabase/migrations/009_constraint_effects.sql` (effets des contraintes de jour, voir plus bas). Ensuite, dans l'onglet Admin > Contraintes, donner un effet aux contraintes voulues (par exemple « Resto midi » avec « Pas de repas le midi »).
7. Exécuter `supabase/migrations/010_quantities_units_portions.sql` (unités, quantités des ingrédients, portions des repas). Le site fonctionne aussi avant ce script (sans unités ni portions) : on peut publier le site d'abord, puis exécuter le script, puis recharger (Ctrl+F5).
8. Relire, adapter si besoin puis exécuter `supabase/migrations/011_units_of_existing_ingredients.sql` : il donne leur unité (pièce, ml) aux ingrédients existants qui ne se comptent pas en g. À faire avant de saisir des quantités (changer l'unité ne convertit pas les quantités déjà saisies).
9. Dans l'onglet Admin > Aliments, saisir la quantité de base de chaque aliment (« quantité à définir » signale ceux qui manquent).

10. Facultatif : exécuter `supabase/migrations/012_unit_tranche.sql` (unité « tranche » et ingrédients qui s'y comptent ; à relire avant).
11. Exécuter `supabase/migrations/013_unlink_simple_food_ingredient.sql` : un aliment simple n'est plus lié à un ingrédient de même nom (renommer l'un ne touche plus l'autre ; l'ingrédient se choisit ou se crée à la volée). À exécuter juste après la publication du site.

## Actions réservées au SQL

Le site ne permet pas ces actions, elles se font dans Supabase (**SQL Editor**) :

```sql
-- Créer une classe (name : 1re lettre en majuscule ; part_name : minuscules ; type : 'composante',
-- une partie de repas affichée dans les repas, ou 'combo', sans partie de repas : part_name vaut alors null)
insert into food.classes (name, part_name, position, type) values ('Boissons', 'boisson', 7, 'composante');

-- Supprimer une classe : d'abord les aliments qui n'ont que cette classe (ils ne doivent plus
-- être dans aucun repas), puis le lien des autres aliments avec cette classe, puis la classe
delete from food.foods f
where exists (select 1 from food.food_classes where food_id = f.id and class_id = 6)
  and (select count(*) from food.food_classes where food_id = f.id) = 1;
delete from food.food_classes where class_id = 6;
delete from food.classes where id = 6;

-- Supprimer tous les aliments (vide d'abord les repas ; les ingrédients restent, à supprimer aussi si besoin)
delete from food.meals;
delete from food.foods;
delete from food.ingredients;
```

Changer le mot de passe d'un utilisateur (les personnes déjà connectées avec lui devront le ressaisir) :

```sql
update food.users
set password_hash = extensions.crypt('NOUVEAU_MDP', extensions.gen_salt('bf'))
where user_id = 'writer';
```

Ajouter un utilisateur (`role` : `read`, `write` ou `admin` ; `user_id` en minuscules) :

```sql
insert into food.users (user_id, role, password_hash)
values ('thomas', 'write', extensions.crypt('MDP', extensions.gen_salt('bf')));
```

Supprimer un utilisateur : `delete from food.users where user_id = 'thomas';`

## Règles de données

- Aliments, noms de repas (`midi`, `soir`) et parties de repas en minuscules ; classes avec une majuscule initiale.
- Un aliment a une ou plusieurs classes (ex. un sandwich : Protéines, Féculents, Légumes), table `food.food_classes`. Il remplit toutes les parties de repas correspondantes à la fois et n'est compté qu'une fois dans le repas.
- Le nom d'un aliment est unique : deux noms identiques (même casse) sont refusés, même avec des classes différentes. « creme » et « crème » sont deux aliments différents. Pour une variante, créer un aliment distinct.
- Un aliment utilisé dans un repas ne peut pas être supprimé, et on ne peut pas lui retirer de classe (on peut en ajouter). Le renommer le renomme dans tous les repas.
- Chaque classe a un **type** : `composante` (Protéines, Féculents, Légumes, Laitages, Autres : une partie de repas, affichée dans les repas) ou `combo` (Recettes : pas de partie de repas, jamais affichée dans les repas, visible dans l'Admin). Un aliment doit avoir au moins une classe de type composante. Un aliment qui a la classe Recettes est une **recette** ; la règle « on ne peut pas retirer de classe à un aliment utilisé » ne concerne que les classes de type composante.
- Les **ingrédients** (tables `food.ingredients` et `food.food_ingredients`) : un nom unique en minuscules, sans quantité. Tout aliment a au moins un ingrédient, de n'importe quel nom, saisi dans l'Admin (un ingrédient inconnu est créé à la volée) ; aucun lien de nom entre un aliment simple et son ingrédient. Un ingrédient ne peut pas être supprimé tant qu'un aliment l'utilise. Aucun nettoyage automatique : un ingrédient inutilisé reste en base jusqu'à sa suppression. Les ingrédients ne sont pas affichés dans les repas.
- Dans l'onglet Admin, chaque aliment, ingrédient et contrainte indique s'il est utilisé (aliment : présent dans au moins un repas encore en base ; ingrédient : lié à au moins un aliment ; contrainte : attribuée à au moins un jour), avec un filtre Tous / Utilisés / Non utilisés.
- Pour analyser les données, un repas passé compte les classes **actuelles** de ses aliments. Exemple, nombre de repas par classe sur les 30 derniers jours :

  ```sql
  select c.name, count(distinct m.id) as repas
  from food.meals m
  join food.meal_items mi on mi.meal_id = m.id
  join food.food_classes fc on fc.food_id = mi.food_id
  join food.classes c on c.id = fc.class_id
  where m.meal_date >= current_date - 30
  group by c.name, c.position
  order by c.position;
  ```
- Le site affiche les 15 derniers jours et les 30 prochains. Les repas passés sont gardés 30 jours en base puis supprimés automatiquement, mais seulement quand quelqu'un enregistre ou vide un repas (quel que soit le jour modifié). Il en va de même pour la purge du journal d'audit (12 mois).
- Un jour peut avoir une ou plusieurs **contraintes** (par exemple « Télétravail », « Invités ») : un texte affiché en haut à droite du jour, purement informatif sauf si la contrainte a un **effet** (voir plus bas). La liste des contraintes possibles (table `food.constraints`, un nom unique sans tenir compte de la casse) est gérée par l'admin, dans l'onglet Admin, partie « Contraintes » (créer, renommer, supprimer ; une contrainte attribuée à au moins un jour ne peut pas être supprimée). Le rôle write choisit les contraintes d'un jour parmi cette liste (table `food.day_constraints`), sur les mêmes jours que les repas ; retirer toutes les contraintes d'un jour demande une confirmation. Les attributions de plus de 30 jours sont supprimées avec les vieux repas.
- **Effets des contraintes** (table `food.effects` : nom, description, créneau bloqué `midi` ou `soir`) : une contrainte a un effet ou aucun (`food.constraints.effect_id`). Deux effets au départ : « Pas de repas le midi » et « Pas de repas le soir ». Un jour qui a une contrainte avec un tel effet ne peut pas avoir de repas sur le créneau bloqué : le site affiche « pas de repas » sans bouton de génération, et la base refuse de remplir ce repas (vider reste possible). Pour le remplir à nouveau, retirer la contrainte du jour. Attribuer une contrainte bloquante à un jour dont le repas est déjà rempli est refusé (vider d'abord ce repas) ; donner un effet bloquant à une contrainte déjà attribuée à de tels jours aussi (la liste des jours est affichée). Les effets se créent en SQL uniquement :

  ```sql
  insert into food.effects (name, description, blocked_slot)
  values ('Pas de repas le midi', 'Aucun repas ne peut être généré pour le midi de ce jour.', 'midi');
  ```
- **Quantités** : chaque ingrédient a une **unité** (table `food.units` : g, ml, pièce, c. à soupe, c. à café ; liste fixe, créée en SQL) et toutes ses quantités sont exprimées dans cette unité. Chaque lien aliment-ingrédient porte la **quantité pour 1 portion** de l'aliment (facultative : « non définie » tant qu'elle n'est pas saisie), y compris pour un aliment simple (son unique ingrédient). Chaque aliment d'un repas a un nombre de **portions** (1 par défaut, 99 au plus, 2 décimales : 0,5, 0,75…) : la quantité d'un ingrédient dans un repas = quantité de base × portions. Le bouton « Ingrédients » de chaque repas déplie ces quantités. À partir de 2 ingrédients un aliment devient une recette (la classe Recettes est ajoutée). Pour créer une unité :

  ```sql
  insert into food.units (id, name, plural, position) values (6, 'tranche', 'tranches', 6);
  ```
- « Aujourd'hui » est calculé en heure de Zurich.

## Journal d'audit

Chaque action de modification **réussie** faite depuis le site est consignée dans `food.audit_log` : `meal_create`, `meal_update`, `meal_clear`, `day_constraint_create`, `day_constraint_update`, `day_constraint_clear` (rôles write et admin), `food_add`, `food_update`, `food_delete`, `constraint_add`, `constraint_update`, `constraint_delete`, `ingredient_add`, `ingredient_update`, `ingredient_delete` (rôle admin). Le rôle de l'utilisateur qui a fait l'action est enregistré (un repas modifié par `admin` est consigné avec le rôle admin). Chaque ligne contient la date, l'identifiant, le rôle, la cible et l'état avant / après (noms d'aliments, de contraintes ou d'ingrédients ; pour une recette, l'état d'un aliment contient aussi la liste de ses ingrédients ; pour une contrainte, `{ name, effect }` ; pour un ingrédient, `{ name, unit }` ; l'état d'un aliment contient ses ingrédients avec leurs quantités ; dans un repas, un aliment dont les portions ne valent pas 1 est écrit avec son multiplicateur).

Ne sont **pas** consignés : les consultations, les connexions, les actions refusées, un enregistrement qui ne change rien, la suppression automatique des vieux repas et contraintes de jour et tout ce qui est fait directement en SQL. Les lignes de plus de 12 mois sont supprimées automatiquement (en même temps que les vieux repas, à chaque enregistrement de repas).

Consulter le journal (SQL Editor) :

```sql
select logged_at, user_id, action, target, before, after
from food.audit_log
order by logged_at desc
limit 100;
```

## Mise en pause de Supabase

Le plan gratuit de Supabase met en pause un projet resté inactif 7 jours. Il n'y a pas d'appel automatique pour l'éviter : l'activité normale (insertions dans la base, utilisation du site) suffit. Si le projet est mis en pause, le réactiver depuis le dashboard Supabase (les données sont conservées).

## Limites connues

- Le mot de passe est protégé contre la force brute par un délai d'1 s par tentative, pas par un blocage strict.
- L'identifiant et le mot de passe sont conservés tels quels dans le navigateur (reader/writer) et envoyé à chaque appel, comme pour la liste de naissance.

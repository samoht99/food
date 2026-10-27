# Repas

Petit site statique (HTML/CSS/JS) hébergé sur GitHub Pages pour planifier les repas du midi et du soir. Les données sont dans Supabase (schéma `food` du projet `family`).

- On se connecte avec un identifiant et un mot de passe. Trois utilisateurs, trois modes : `reader` (**Read** : voir les repas), `writer` (**Write** : Read + modifier les repas), `admin` (**Admin** : Read + gérer les aliments, pas de modification des repas).
- Les specs sont dans [`specs/`](specs/) (une version par fichier, la plus récente fait foi).

## Comment ça marche

- `index.html`, `style.css`, `app.js` : le site.
- `supabase/schema.sql` : tables et fonctions de la base (installation neuve).
- `supabase/migrations/` : scripts à exécuter, dans l'ordre (001, 002, 003…), sur une base déjà installée. `schema.sql` est l'état final, pour une installation neuve (pas besoin des migrations dans ce cas).
- `test/` : version du site avec une fausse API en mémoire, pour essayer l'interface sans Supabase (ouvrir `test/index.html` ; identifiant / mot de passe : `reader` / `r`, `writer` / `w`, `admin` / `a`). Non utilisée par le vrai site.

La sécurité repose sur la base : les tables sont verrouillées (RLS sans policy) et le site n'y accède que via des fonctions qui vérifient l'identifiant et le mot de passe (stocké haché) **et** le rôle autorisé pour chaque action. L'URL et la clé `sb_publishable_…` présentes dans le code sont publiques par conception. **Ne jamais commiter** la clé `sb_secret_…`, le mot de passe de la base ni les mots de passe du site.

Sessions : `reader` et `writer` restent connectés (identifiant et mot de passe gardés dans le navigateur) jusqu'au clic sur « Quitter ». `admin` est révoqué à la fermeture de l'onglet.

## Installation initiale (une seule fois)

1. Dans Supabase : **SQL Editor > New query**, coller le contenu de `supabase/schema.sql`, **Run**. Les tables et fonctions sont dans le schéma `food` (les 5 classes d'aliments sont créées).
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

## Actions réservées au SQL

Le site ne permet pas ces actions, elles se font dans Supabase (**SQL Editor**) :

```sql
-- Créer une classe (name : 1re lettre en majuscule ; part_name : minuscules)
insert into food.classes (name, part_name, position) values ('Boissons', 'boisson', 6);

-- Supprimer une classe : d'abord les aliments qui n'ont que cette classe (ils ne doivent plus
-- être dans aucun repas), puis le lien des autres aliments avec cette classe, puis la classe
delete from food.foods f
where exists (select 1 from food.food_classes where food_id = f.id and class_id = 6)
  and (select count(*) from food.food_classes where food_id = f.id) = 1;
delete from food.food_classes where class_id = 6;
delete from food.classes where id = 6;

-- Supprimer tous les aliments (vide d'abord les repas)
delete from food.meals;
delete from food.foods;
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
- « Aujourd'hui » est calculé en heure de Zurich.

## Journal d'audit

Chaque action de modification **réussie** faite depuis le site est consignée dans `food.audit_log` : `meal_create`, `meal_update`, `meal_clear` (rôle write), `food_add`, `food_update`, `food_delete` (rôle admin). Chaque ligne contient la date, l'identifiant, le rôle, la cible et l'état avant / après (noms d'aliments).

Ne sont **pas** consignés : les consultations, les connexions, les actions refusées, un enregistrement qui ne change rien, la suppression automatique des vieux repas et tout ce qui est fait directement en SQL. Les lignes de plus de 12 mois sont supprimées automatiquement (en même temps que les vieux repas, à chaque enregistrement de repas).

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

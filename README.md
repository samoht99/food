# Repas

Petit site statique (HTML/CSS/JS) hébergé sur GitHub Pages pour planifier les repas du midi et du soir. Les données sont dans Supabase (schéma `food` du projet `family`).

- Trois mots de passe donnent trois modes : **Read** (voir les repas), **Write** (Read + modifier les repas), **Admin** (Read + gérer les aliments, pas de modification des repas).
- Les specs sont dans [`specs/`](specs/) (une version par fichier, la plus récente fait foi).

## Comment ça marche

- `index.html`, `style.css`, `app.js` : le site.
- `supabase/schema.sql` : tables et fonctions de la base (installation neuve).
- `supabase/migrations/` : scripts à exécuter, dans l'ordre, sur une base déjà installée.
- `test/` : version du site avec une fausse API en mémoire, pour essayer l'interface sans Supabase (ouvrir `test/index.html` ; mots de passe `r`, `w`, `a`). Non utilisée par le vrai site.

La sécurité repose sur la base : les tables sont verrouillées (RLS sans policy) et le site n'y accède que via des fonctions qui vérifient le mot de passe (stocké haché) **et** le rôle autorisé pour chaque action. L'URL et la clé `sb_publishable_…` présentes dans le code sont publiques par conception. **Ne jamais commiter** la clé `sb_secret_…`, le mot de passe de la base ni les mots de passe du site.

Sessions : Read et Write restent connectés (mot de passe gardé dans le navigateur) jusqu'au clic sur « Quitter ». Admin est révoqué à la fermeture de l'onglet.

## Installation initiale (une seule fois)

1. Dans Supabase : **SQL Editor > New query**, coller le contenu de `supabase/schema.sql`, **Run**. Les tables et fonctions sont dans le schéma `food` (les 5 classes d'aliments sont créées).
   Puis **Project Settings > Data API > Exposed schemas** : ajouter `food`, sinon le site n'a pas accès à l'API.
2. Définir les trois mots de passe (remplacer `MDP_READ`, `MDP_WRITE`, `MDP_ADMIN`, qui doivent être différents) :
   ```sql
   insert into food.app_config (key, value) values
     ('password_hash_read',  extensions.crypt('MDP_READ',  extensions.gen_salt('bf'))),
     ('password_hash_write', extensions.crypt('MDP_WRITE', extensions.gen_salt('bf'))),
     ('password_hash_admin', extensions.crypt('MDP_ADMIN', extensions.gen_salt('bf')))
   on conflict (key) do update set value = excluded.value;
   ```
3. Activer GitHub Pages : dépôt GitHub > **Settings > Pages** > Source : *Deploy from a branch*, branche `main`, dossier `/ (root)`.
4. Le site est alors disponible à `https://samoht99.github.io/food/`.

## Actions réservées au SQL

Le site ne permet pas ces actions, elles se font dans Supabase (**SQL Editor**) :

```sql
-- Créer une classe (name : 1re lettre en majuscule ; part_name : minuscules)
insert into food.classes (name, part_name, position) values ('Boissons', 'boisson', 6);

-- Supprimer une classe (d'abord ses aliments, qui ne doivent plus être dans aucun repas)
delete from food.foods where class_id = 6;
delete from food.classes where id = 6;

-- Supprimer tous les aliments (vide d'abord les repas)
delete from food.meals;
delete from food.foods;
```

Changer un mot de passe : relancer l'étape 2 avec la nouvelle valeur (les personnes déjà connectées devront le ressaisir).

## Règles de données

- Aliments, noms de repas (`midi`, `soir`) et parties de repas en minuscules ; classes avec une majuscule initiale.
- Un aliment appartient à une seule classe ; deux noms identiques (même casse) sont refusés. « creme » et « crème » sont deux aliments différents.
- Un aliment utilisé dans un repas ne peut être ni supprimé ni changé de classe. Le renommer le renomme dans tous les repas.
- Le site affiche les 15 derniers jours et les 30 prochains. Les repas passés sont gardés 30 jours en base puis supprimés automatiquement, mais seulement quand quelqu'un enregistre ou vide un repas (quel que soit le jour modifié).
- « Aujourd'hui » est calculé en heure de Zurich.

## Mise en pause de Supabase

Le plan gratuit de Supabase met en pause un projet resté inactif 7 jours. Il n'y a pas d'appel automatique pour l'éviter : l'activité normale (insertions dans la base, utilisation du site) suffit. Si le projet est mis en pause, le réactiver depuis le dashboard Supabase (les données sont conservées).

## Limites connues

- Le mot de passe est protégé contre la force brute par un délai d'1 s par tentative, pas par un blocage strict.
- Le mot de passe est conservé tel quel dans le navigateur (Read/Write) et envoyé à chaque appel, comme pour la liste de naissance.

-- Migration : supprime la fonction ping (et son horodatage) devenue inutile.
-- À exécuter une fois dans Supabase (SQL Editor) sur une base déjà installée.
-- Le workflow GitHub Actions qui l'appelait est supprimé du dépôt : pousser ce changement
-- avant (ou en même temps), sinon le workflow échoue tant que la fonction n'existe plus.

drop function if exists food.ping();
delete from food.app_config where key = 'last_ping';

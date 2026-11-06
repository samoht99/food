-- 017 : suggestions de noms d'ingrédients à l'ajout d'un élément d'une liste de courses.
-- Fonction de lecture seule pour les rôles write et admin : nom, unité et catégorie de chaque ingrédient.
-- Aucune table ni donnée en plus. Sans risque à relancer.

create or replace function food.get_ingredient_names(u text, p text)
returns table (name text, unit_id smallint, category_id smallint)
language plpgsql
security definer
set search_path = food, extensions
as $$
begin
  perform food._check(u, p, array['write', 'admin']);
  return query
    select i.name, i.unit_id, i.category_id
    from food.ingredients i
    order by i.name;
end;
$$;

revoke execute on function food.get_ingredient_names(text, text) from public;
grant execute on function food.get_ingredient_names(text, text) to anon, authenticated;

-- 015 : le rôle read peut cocher et décocher les éléments des listes de courses.
-- Seule set_shop_item_checked change : read, write et admin y ont droit (toujours non consignée dans l'audit).
-- Sans risque à relancer.

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

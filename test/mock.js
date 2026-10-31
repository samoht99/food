// Fausse API en mémoire pour tester le site sans Supabase.
// Utilisateurs : reader / r (Read), writer / w (Write), admin / a (Admin). Les données sont perdues au rechargement.
// Reproduit les règles de supabase/schema.sql (rôles, fenêtre de dates, doublons, aliment utilisé).
(() => {
  try { localStorage.removeItem("food_session"); sessionStorage.removeItem("food_session"); } catch {}

  const classes = [
    { id: 1, name: "Protéines", part_name: "protéine", type: "composante" },
    { id: 2, name: "Féculents", part_name: "féculent", type: "composante" },
    { id: 3, name: "Légumes", part_name: "légume", type: "composante" },
    { id: 4, name: "Laitages", part_name: "laitage", type: "composante" },
    { id: 5, name: "Autres", part_name: "divers", type: "composante" },
    { id: 6, name: "Recettes", part_name: null, type: "combo" }, // pas de partie de repas
  ];
  const typeOf = (cid) => classes.find((c) => c.id === cid).type;
  const isRecipe = (cids) => cids.some((c) => typeOf(c) === "combo");
  const seed = {
    1: ["poulet", "poisson", "oeuf", "boeuf haché", "jambon"],
    2: ["riz", "pâtes", "pomme de terre", "polenta", "quinoa"],
    3: ["brocoli", "carotte", "courgette", "épinards", "haricots verts"],
    4: ["yaourt", "fromage blanc", "emmental"],
    5: ["pomme", "banane", "poire", "orange"],
  };
  let nextId = 1;
  let foods = [];
  for (const cid in seed) for (const name of seed[cid]) foods.push({ id: nextId++, name, class_ids: [Number(cid)] });
  foods.push({ id: nextId++, name: "sandwich jambon-salade", class_ids: [1, 2, 3, 6] }); // recette
  foods.push({ id: nextId++, name: "pizza", class_ids: [1, 2, 4] });
  foods.push({ id: nextId++, name: "lasagnes", class_ids: [1, 2, 6] }); // recette
  const byName = (n) => foods.find((f) => f.name === n).id;

  // Ingrédients : un aliment simple a un ingrédient de même nom ; une recette a ceux qu'on lui donne.
  let nextIngId = 1;
  let ingredients = []; // [{ id, name }]
  const foodIngs = new Map(); // id d'aliment -> [ids d'ingrédients]
  const ingredientId = (name) => {
    let i = ingredients.find((x) => x.name === name);
    if (!i) { i = { id: nextIngId++, name }; ingredients.push(i); }
    return i.id;
  };
  const setIngredients = (fid, names) => foodIngs.set(fid, names.map(ingredientId));
  const ingName = (id) => ingredients.find((i) => i.id === id).name;
  const recipeSeed = {
    "sandwich jambon-salade": ["pain", "jambon", "salade", "tomate"],
    lasagnes: ["pâtes à lasagne", "boeuf haché", "sauce tomate", "béchamel"],
  };
  for (const f of foods) setIngredients(f.id, isRecipe(f.class_ids) ? recipeSeed[f.name] : [f.name]);
  ingredientId("basilic"); // ingrédient inutilisé (pour essayer le filtre)
  // Noms d'ingrédients saisis : minuscules, sans vide ni doublon ; null si l'un dépasse 60 caractères.
  const cleanIngs = (arr) => {
    const names = [...new Set((arr || []).map(clean).filter(Boolean))].sort();
    return names.some((n) => n.length > 60) ? null : names;
  };
  const usedIn = (fid) => [...meals.values()].filter((ids) => ids.includes(fid)).length;

  const meals = new Map(); // "date|slot" -> [food ids]
  let nextConId = 1;
  // Effets possibles d'une contrainte (liste fixe, gérée en SQL) : nom, description, créneau bloqué.
  const effects = [
    { id: 1, name: "Pas de repas le midi", description: "Aucun repas ne peut être généré pour le midi de ce jour.", blocked_slot: "midi" },
    { id: 2, name: "Pas de repas le soir", description: "Aucun repas ne peut être généré pour le soir de ce jour.", blocked_slot: "soir" },
  ];
  let constraints = ["Télétravail", "Repas au bureau", "Invités", "Sans viande"].map((name) => ({ id: nextConId++, name, effect_id: null }));
  constraints.push({ id: nextConId++, name: "Resto midi", effect_id: 1 }, { id: nextConId++, name: "Resto soir", effect_id: 2 });
  const dayCons = new Map(); // "date" -> [ids de contraintes]
  const users = { reader: ["r", "read"], writer: ["w", "write"], admin: ["a", "admin"] };

  const zurichToday = () => new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/Zurich" }).format(new Date());
  const addDays = (ds, n) => {
    const [y, m, d] = ds.split("-").map(Number);
    return new Date(Date.UTC(y, m - 1, d + n)).toISOString().slice(0, 10);
  };
  const t = zurichToday();
  const put = (offset, slot, names) => meals.set(`${addDays(t, offset)}|${slot}`, names.map(byName));
  put(-2, "midi", ["poulet", "riz", "brocoli", "pomme"]);
  put(-2, "soir", ["oeuf", "pomme de terre", "carotte", "yaourt"]);
  put(-1, "soir", ["poisson", "quinoa", "courgette"]);
  put(0, "midi", ["poulet", "riz", "brocoli", "carotte", "pomme"]);
  put(1, "midi", ["boeuf haché", "pâtes", "épinards", "fromage blanc", "banane"]);
  put(2, "soir", ["jambon", "polenta", "haricots verts"]);
  put(1, "soir", ["sandwich jambon-salade", "pomme"]);
  dayCons.set(addDays(t, 0), [1]);
  dayCons.set(addDays(t, 1), [3, 4]);
  dayCons.set(addDays(t, 3), [5]); // Resto midi : pas de repas le midi
  dayCons.set(addDays(t, 4), [6]); // Resto soir : pas de repas le soir
  dayCons.set(addDays(t, -20), [2]); // hors des 15 jours affichés
  put(-20, "midi", ["poisson", "riz", "courgette", "yaourt"]); // hors des 15 jours affichés, encore en base

  const fail = (message, details) => ({ ok: false, status: 400, json: async () => ({ message, details }) });
  const ok = (body) => ({ ok: true, status: 200, text: async () => JSON.stringify(body), json: async () => body });
  // Fonction PostgreSQL qui renvoie void : PostgREST répond 204 avec un corps vide (res.json() échoue).
  const voidOk = () => ({
    ok: true, status: 204, text: async () => "",
    json: async () => { throw new SyntaxError("Unexpected end of JSON input"); },
  });
  const inWindow = (d) => d >= addDays(zurichToday(), -15) && d <= addDays(zurichToday(), 30);
  const slotOfEffect = (eid) => (effects.find((e) => e.id === eid) || {}).blocked_slot || null;
  // Créneaux bloqués un jour donné par les effets des contraintes de ce jour.
  const blockedSlots = (d) => new Set((dayCons.get(d) || [])
    .map((id) => slotOfEffect(constraints.find((k) => k.id === id).effect_id)).filter(Boolean));
  const clean = (n) => String(n || "").trim().toLowerCase();

  window.fetch = async (url, opts) => {
    await new Promise((r) => setTimeout(r, 150)); // latence réseau simulée
    const fn = String(url).split("/rpc/")[1];
    const a = JSON.parse(opts.body);
    const user = users[clean(a.u)];
    const role = user && user[0] === a.p ? user[1] : null;
    if (fn === "login") return ok(role);
    if (!role) return fail("invalid_password");

    switch (fn) {
      case "get_catalog":
        return ok({
          classes,
          foods: [...foods].sort((x, y) => x.name.localeCompare(y.name)).map((f) => ({
            id: f.id,
            name: f.name,
            class_ids: [...f.class_ids].sort((x, y) => x - y),
            uses: usedIn(f.id),
            ingredients: isRecipe(f.class_ids) ? (foodIngs.get(f.id) || []).map(ingName).sort() : [],
          })),
        });

      case "get_meals": {
        const rows = [];
        for (const [key, ids] of meals) {
          const [d, s] = key.split("|");
          if (d < a.d_from || d > a.d_to) continue;
          for (const id of ids) {
            const f = foods.find((x) => x.id === id);
            // Seules les classes de type composante sont renvoyées (les classes combo ne s'affichent jamais dans les repas).
            const cids = f.class_ids.filter((c) => typeOf(c) === "composante").sort((x, y) => x - y);
            rows.push({ meal_date: d, slot: s, food_id: id, food_name: f.name, class_ids: cids });
          }
        }
        return ok(rows);
      }

      case "get_effects":
        return ok(effects);

      case "get_constraints":
        return ok([...constraints]
          .sort((x, y) => x.name.localeCompare(y.name, "fr"))
          .map((k) => ({
            id: k.id, name: k.name, effect_id: k.effect_id,
            uses: [...dayCons.values()].filter((ids) => ids.includes(k.id)).length,
          })));

      case "get_day_constraints": {
        const rows = [];
        for (const [d, ids] of [...dayCons].sort()) {
          if (d < a.d_from || d > a.d_to) continue;
          for (const id of [...ids].sort((x, y) => x - y)) rows.push({ day_date: d, constraint_id: id });
        }
        return ok(rows);
      }

      case "set_day_constraints": {
        if (role !== "write" && role !== "admin") return fail("forbidden");
        if (!inWindow(a.d)) return fail("out_of_window");
        const ids = [...new Set(a.cids || [])];
        if (ids.some((id) => !constraints.some((k) => k.id === id))) return fail("unknown_constraint");
        // Une contrainte nouvellement ajoutée qui bloque un créneau dont le repas est déjà rempli est refusée.
        const before = dayCons.get(a.d) || [];
        for (const id of ids.filter((x) => !before.includes(x))) {
          const slot = slotOfEffect(constraints.find((k) => k.id === id).effect_id);
          if (slot && meals.has(`${a.d}|${slot}`)) return fail("meal_in_blocked_slot", slot);
        }
        if (ids.length) dayCons.set(a.d, ids);
        else dayCons.delete(a.d);
        return voidOk();
      }

      case "add_constraint": {
        if (role !== "admin") return fail("forbidden");
        const name = String(a.n || "").trim();
        if (!name || name.length > 60) return fail("invalid_name");
        if (constraints.some((k) => k.name.toLowerCase() === name.toLowerCase())) return fail("constraint_exists");
        const eid = a.eid === undefined ? null : a.eid;
        if (eid !== null && !effects.some((e) => e.id === eid)) return fail("unknown_effect");
        constraints.push({ id: nextConId++, name, effect_id: eid });
        return ok(nextConId - 1);
      }

      case "update_constraint": {
        if (role !== "admin") return fail("forbidden");
        const name = String(a.n || "").trim();
        const k = constraints.find((x) => x.id === a.cid);
        if (!name || name.length > 60) return fail("invalid_name");
        if (!k) return fail("unknown_constraint");
        if (constraints.some((x) => x.id !== a.cid && x.name.toLowerCase() === name.toLowerCase())) return fail("constraint_exists");
        const eid = a.eid === undefined ? null : a.eid;
        if (eid !== null && !effects.some((e) => e.id === eid)) return fail("unknown_effect");
        // Un effet bloquant est refusé si la contrainte est attribuée à des jours dont ce repas est rempli.
        const slot = eid !== k.effect_id ? slotOfEffect(eid) : null;
        if (slot) {
          const days = [...dayCons].filter(([d, ids]) => ids.includes(a.cid) && meals.has(`${d}|${slot}`))
            .map(([d]) => d).sort().reverse();
          if (days.length) return fail("effect_conflict", JSON.stringify({ n: days.length, slot, items: days }));
        }
        k.name = name;
        k.effect_id = eid;
        return voidOk();
      }

      case "delete_constraint": {
        if (role !== "admin") return fail("forbidden");
        const days = [...dayCons].filter(([, ids]) => ids.includes(a.cid)).map(([d]) => d).sort().reverse();
        if (days.length) return fail("constraint_in_use", JSON.stringify({ n: days.length, items: days }));
        constraints = constraints.filter((k) => k.id !== a.cid);
        return voidOk();
      }

      case "set_meal": {
        if (role !== "write" && role !== "admin") return fail("forbidden");
        if (!["midi", "soir"].includes(a.s)) return fail("invalid_slot");
        if (!inWindow(a.d)) return fail("out_of_window");
        const ids = [...new Set(a.food_ids)];
        if (ids.some((id) => !foods.some((f) => f.id === id))) return fail("unknown_food");
        if (ids.length && blockedSlots(a.d).has(a.s)) return fail("slot_blocked"); // vider reste possible
        if (ids.length) meals.set(`${a.d}|${a.s}`, ids);
        else meals.delete(`${a.d}|${a.s}`);
        return voidOk();
      }

      case "add_food": {
        if (role !== "admin") return fail("forbidden");
        const name = clean(a.n);
        if (!name || name.length > 60) return fail("invalid_name");
        const cids = [...new Set(a.cids || [])].sort((x, y) => x - y);
        if (!cids.length) return fail("invalid_classes");
        if (cids.some((c) => !classes.some((k) => k.id === c))) return fail("unknown_class");
        if (!cids.some((c) => typeOf(c) === "composante")) return fail("class_component_required");
        // Recette : ingrédients saisis (au moins 1). Aliment simple : un ingrédient de même nom, automatique.
        let names = [name];
        if (isRecipe(cids)) {
          names = cleanIngs(a.ings);
          if (!names) return fail("invalid_name");
          if (!names.length) return fail("ingredients_required");
        }
        if (foods.some((f) => f.name === name)) return fail("food_exists");
        const created = { id: nextId++, name, class_ids: cids };
        foods.push(created);
        setIngredients(created.id, names);
        return ok(created.id);
      }

      case "update_food": {
        if (role !== "admin") return fail("forbidden");
        const name = clean(a.n);
        const f = foods.find((x) => x.id === a.fid);
        if (!name || name.length > 60) return fail("invalid_name");
        if (!f) return fail("unknown_food");
        const cids = [...new Set(a.cids || [])].sort((x, y) => x - y);
        if (!cids.length) return fail("invalid_classes");
        if (cids.some((c) => !classes.some((k) => k.id === c))) return fail("unknown_class");
        if (!cids.some((c) => typeOf(c) === "composante")) return fail("class_component_required");
        let names = [name];
        if (isRecipe(cids)) {
          names = cleanIngs(a.ings);
          if (!names) return fail("invalid_name");
          if (!names.length) return fail("ingredients_required");
        }
        if (foods.some((x) => x.name === name && x.id !== a.fid)) return fail("food_exists");
        const used = [...meals.values()].some((ids) => ids.includes(a.fid));
        // On peut ajouter des classes de type composante à un aliment utilisé, pas en retirer
        // (la classe Recettes, de type combo, peut être ajoutée ou retirée librement).
        if (used && f.class_ids.some((c) => typeOf(c) === "composante" && !cids.includes(c))) return fail("food_in_use_class");
        f.name = name;
        f.class_ids = cids;
        setIngredients(f.id, names);
        return voidOk();
      }

      case "delete_food": {
        if (role !== "admin") return fail("forbidden");
        // Repas qui l'utilisent, du plus récent au plus ancien (midi avant soir) : { n, items } en JSON.
        const items = [...meals].filter(([, ids]) => ids.includes(a.fid)).map(([k]) => k)
          .sort((x, y) => (x.split("|")[0] === y.split("|")[0]
            ? (x < y ? -1 : 1) : (x.split("|")[0] < y.split("|")[0] ? 1 : -1)));
        if (items.length) return fail("food_in_use", JSON.stringify({ n: items.length, items }));
        foods = foods.filter((f) => f.id !== a.fid);
        foodIngs.delete(a.fid); // ses ingrédients restent en base (aucun nettoyage automatique)
        return voidOk();
      }

      case "get_ingredients": {
        if (role !== "admin") return fail("forbidden");
        return ok([...ingredients]
          .sort((x, y) => x.name.localeCompare(y.name, "fr"))
          .map((i) => ({ id: i.id, name: i.name, uses: [...foodIngs.values()].filter((ids) => ids.includes(i.id)).length })));
      }

      case "add_ingredient": {
        if (role !== "admin") return fail("forbidden");
        const name = clean(a.n);
        if (!name || name.length > 60) return fail("invalid_name");
        if (ingredients.some((i) => i.name === name)) return fail("ingredient_exists");
        return ok(ingredientId(name));
      }

      case "update_ingredient": {
        if (role !== "admin") return fail("forbidden");
        const name = clean(a.n);
        const i = ingredients.find((x) => x.id === a.iid);
        if (!name || name.length > 60) return fail("invalid_name");
        if (!i) return fail("unknown_ingredient");
        if (ingredients.some((x) => x.id !== a.iid && x.name === name)) return fail("ingredient_exists");
        if (name !== i.name) {
          // L'ingrédient d'un aliment simple doit garder le nom de son aliment.
          const ofSimpleFood = [...foodIngs].some(([fid, ids]) =>
            ids.includes(a.iid) && !isRecipe(foods.find((f) => f.id === fid).class_ids));
          if (ofSimpleFood) return fail("ingredient_of_simple_food");
          i.name = name;
        }
        return voidOk();
      }

      case "delete_ingredient": {
        if (role !== "admin") return fail("forbidden");
        const users = [...foodIngs].filter(([, ids]) => ids.includes(a.iid))
          .map(([fid]) => foods.find((f) => f.id === fid).name).sort();
        if (users.length) return fail("ingredient_in_use", JSON.stringify({ n: users.length, items: users }));
        ingredients = ingredients.filter((i) => i.id !== a.iid);
        return voidOk();
      }
    }
    return fail("unknown_function");
  };

  const banner = document.createElement("div");
  banner.textContent = "MODE TEST : données fictives en mémoire, rien n'est envoyé à Supabase. Identifiant / mot de passe : reader / r, writer / w, admin / a.";
  banner.style.cssText = "background:#fff3cd;color:#664d03;font:13px system-ui;padding:6px 12px;text-align:center;position:relative;z-index:10";
  document.addEventListener("DOMContentLoaded", () => document.body.prepend(banner));
})();

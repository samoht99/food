// Fausse API en mémoire pour tester le site sans Supabase.
// Utilisateurs : reader / r (Read), writer / w (Write), admin / a (Admin). Les données sont perdues au rechargement.
// Reproduit les règles de supabase/schema.sql (rôles, fenêtre de dates, doublons, aliment utilisé).
//
// Quantités (specs v2-3, pas encore dans la base) : contrat de l'API que la migration devra respecter :
// - get_catalog : { classes, units: [{ id, name, plural }], foods: [{ ..., ingredients: [{ name, quantity, unit_id }] }] }
//   (quantity : quantité d'ingrédient pour 1 portion, ou null si non définie ; ingredients : pour tous les aliments)
// - get_meals : une colonne portions en plus (multiplicateur de l'aliment dans le repas, 1 par défaut)
// - set_meal(food_ids, portions) : portions = tableau parallèle à food_ids (> 0, 99 au plus, 2 décimales)
// - add_food / update_food(ings) : ings = [{ name, quantity, unit_id }] (unit_id : seulement pour un ingrédient créé)
//   tout aliment a au moins 1 ingrédient, de n'importe quel nom (plus de lien de nom) ; 2 ingrédients ou plus : la classe Recettes est ajoutée
// - get_ingredients : unit_id en plus ; add_ingredient(uid) ; update_ingredient(uid)
// Listes de courses (specs v2-5) : get_ingredients (category_id), add_ingredient(cid), update_ingredient(cid : -1 = inchangée) ;
// get_shop_categories ; add_shop_category(n, pc, pk, nm) ; update_shop_category(cid, n, pc, pk, nm) ; delete_shop_category(cid) ;
// get_shop_items ; add_shop_item(lst, n, cid, q, uid) -> { merged, id } ; update_shop_item(iid, n, cid, q, uid) ;
// set_shop_item_checked(iid, chk) ; delete_shop_item(iid) ; clear_shop_list(lst) ; move_shop_item(iid, to_list) -> { merged, id } ;
// preview_shop_generation(d_from, d_to, mode) et generate_shop(...) -> { added, replaced, merged, split, no_qty }
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
  const RECIPES = 6; // id de la classe Recettes
  const typeOf = (cid) => classes.find((c) => c.id === cid).type;
  const isRecipe = (cids) => cids.some((c) => typeOf(c) === "combo");

  // Unités possibles (liste fixe, gérée en SQL) : nom au singulier et au pluriel.
  const units = [
    { id: 1, name: "g", plural: "g" },
    { id: 2, name: "ml", plural: "ml" },
    { id: 3, name: "pièce", plural: "pièces" },
    { id: 4, name: "c. à soupe", plural: "c. à soupe" },
    { id: 5, name: "c. à café", plural: "c. à café" },
  ];
  const G = 1, ML = 2, PIECE = 3;

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
  foods.push({ id: nextId++, name: "sandwich jambon-salade", class_ids: [1, 2, 3, RECIPES] }); // recette
  foods.push({ id: nextId++, name: "pizza", class_ids: [1, 2, 4] });
  foods.push({ id: nextId++, name: "lasagnes", class_ids: [1, 2, RECIPES] }); // recette
  const byName = (n) => foods.find((f) => f.name === n).id;

  // Ingrédients : un aliment a les ingrédients qu'on lui donne (aucun lien de nom avec l'aliment ; seuls les noms de ce tableau diffèrent).
  // Chaque lien aliment-ingrédient porte la quantité pour 1 portion (dans l'unité de l'ingrédient).
  let nextIngId = 1;
  let ingredients = []; // [{ id, name, unit_id }]
  const foodIngs = new Map(); // id d'aliment -> [{ id: id d'ingrédient, quantity }]
  const ingredientId = (name, unit_id = G) => {
    let i = ingredients.find((x) => x.name === name);
    if (!i) { i = { id: nextIngId++, name, unit_id }; ingredients.push(i); }
    return i.id;
  };
  const setIngredients = (fid, rows) =>
    foodIngs.set(fid, rows.map((r) => ({ id: ingredientId(r.name, r.unit_id), quantity: r.quantity })));
  const ingName = (id) => ingredients.find((i) => i.id === id).name;
  // [quantité pour 1 portion, unité] des aliments simples (null : quantité non définie, pour essayer l'indication).
  const simpleSeed = {
    poulet: [150, G], poisson: [null, G], oeuf: [2, PIECE], "boeuf haché": [120, G], jambon: [60, G],
    riz: [80, G], pâtes: [90, G], "pomme de terre": [200, G], polenta: [null, G], quinoa: [70, G],
    brocoli: [150, G], carotte: [100, G], courgette: [150, G], épinards: [120, G], "haricots verts": [150, G],
    yaourt: [1, PIECE], "fromage blanc": [100, G], emmental: [30, G],
    pomme: [1, PIECE], banane: [1, PIECE], poire: [1, PIECE], orange: [1, PIECE], pizza: [1, PIECE],
  };
  // Aliments simples dont l'ingrédient a un autre nom que l'aliment.
  const seedIngName = { pizza: "pâte à pizza", "pomme de terre": "pommes de terre" };
  const recipeSeed = {
    "sandwich jambon-salade": [
      { name: "pain", quantity: 2, unit_id: PIECE }, { name: "jambon", quantity: 40, unit_id: G },
      { name: "salade", quantity: 30, unit_id: G }, { name: "tomate", quantity: 0.5, unit_id: PIECE },
    ],
    lasagnes: [
      { name: "pâtes à lasagne", quantity: 250, unit_id: G }, { name: "boeuf haché", quantity: 400, unit_id: G },
      { name: "sauce tomate", quantity: 200, unit_id: ML }, { name: "béchamel", quantity: 250, unit_id: ML },
    ],
  };
  for (const f of foods) {
    if (isRecipe(f.class_ids)) setIngredients(f.id, recipeSeed[f.name]);
    else { const [quantity, unit_id] = simpleSeed[f.name]; setIngredients(f.id, [{ name: seedIngName[f.name] || f.name, quantity, unit_id }]); }
  }
  ingredientId("basilic"); // ingrédient inutilisé (pour essayer le filtre)

  // Lignes d'ingrédients saisies : [{ name, quantity, unit_id }] -> nettoyées, ou un code d'erreur.
  const cleanIngs = (arr) => {
    const rows = [];
    for (const r of Array.isArray(arr) ? arr : []) {
      const name = clean(r && r.name);
      if (!name) continue;
      if (name.length > 60) return "invalid_name";
      const q = r.quantity === undefined || r.quantity === null || r.quantity === "" ? null : Number(r.quantity);
      if (q !== null && !(q > 0 && q <= 99999 && Math.round(q * 1000) / 1000 === q)) return "invalid_quantity";
      const unit_id = r.unit_id === undefined || r.unit_id === null ? G : r.unit_id;
      if (!units.some((u) => u.id === unit_id)) return "unknown_unit";
      if (!rows.some((x) => x.name === name)) rows.push({ name, quantity: q, unit_id });
    }
    return rows;
  };
  // Règle des ingrédients d'un aliment : au moins 1 ingrédient ; 2 ingrédients ou plus => la classe Recettes
  // est ajoutée d'office. Renvoie { rows, cids } ou { error }.
  const foodIngredients = (name, cids, ings) => {
    const rows = cleanIngs(ings);
    if (typeof rows === "string") return { error: rows };
    if (!rows.length) return { error: "ingredients_required" };
    return { rows, cids: isRecipe(cids) || rows.length < 2 ? cids : [...cids, RECIPES].sort((x, y) => x - y) };
  };
  const usedIn = (fid) => [...meals.values()].filter((items) => items.some((it) => it.id === fid)).length;

  const meals = new Map(); // "date|slot" -> [{ id: id d'aliment, portions }]
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
  // Un aliment : "nom" (1 portion) ou ["nom", portions].
  const put = (offset, slot, entries) => meals.set(`${addDays(t, offset)}|${slot}`,
    entries.map((e) => (Array.isArray(e) ? { id: byName(e[0]), portions: e[1] } : { id: byName(e), portions: 1 })));
  put(-2, "midi", ["poulet", "riz", "brocoli", "pomme"]);
  put(-2, "soir", ["oeuf", "pomme de terre", "carotte", "yaourt"]);
  put(-1, "soir", ["poisson", "quinoa", "courgette"]);
  put(0, "midi", [["poulet", 1.5], "riz", "brocoli", "carotte", "pomme"]);
  put(1, "midi", ["boeuf haché", "pâtes", "épinards", "fromage blanc", "banane"]);
  put(2, "soir", ["jambon", "polenta", "haricots verts"]);
  put(2, "midi", [["lasagnes", 1.5], "brocoli", "yaourt"]); // une recette, 1,5 portion
  put(1, "soir", ["sandwich jambon-salade", "pomme"]);
  dayCons.set(addDays(t, 0), [1]);
  dayCons.set(addDays(t, 1), [3, 4]);
  dayCons.set(addDays(t, 3), [5]); // Resto midi : pas de repas le midi
  dayCons.set(addDays(t, 4), [6]); // Resto soir : pas de repas le soir
  dayCons.set(addDays(t, -20), [2]); // hors des 15 jours affichés
  put(-20, "midi", ["poisson", "riz", "courgette", "yaourt"]); // hors des 15 jours affichés, encore en base

  // Listes de courses (specs v2-5). Catégories : rangs dans les tris custom (1 à N, sans égalité ni trou).
  units.push({ id: 6, name: "tranche", plural: "tranches" });
  const TRANCHE = 6;
  const shopCats = [];
  let nextCatId = 1;
  const catOf = (id) => shopCats.find((c) => c.id === id);
  // Place une catégorie à un rang (les autres sont décalées) : même algorithme que la base.
  const shopPlace = (cid, pc, pk) => {
    for (const [col, pos] of [["pos_carrefour", pc], ["pos_coop", pk]]) {
      if (pos === null || pos === undefined) continue;
      const p = Math.max(1, Math.min(Number(pos), shopCats.length));
      const others = shopCats.filter((c) => c.id !== cid).sort((x, y) => x[col] - y[col] || x.id - y.id);
      others.forEach((c, i) => { c[col] = i + 1 >= p ? i + 2 : i + 1; });
      catOf(cid)[col] = p;
    }
  };
  const addShopCat = (name, no_merge = false, is_default = false, pc = null, pk = null) => {
    const c = { id: nextCatId++, name, pos_carrefour: shopCats.length + 1, pos_coop: shopCats.length + 1, no_merge, is_default };
    shopCats.push(c);
    shopPlace(c.id, pc, pk);
    return c.id;
  };
  const compactCats = () => {
    for (const col of ["pos_carrefour", "pos_coop"]) [...shopCats].sort((x, y) => x[col] - y[col]).forEach((c, i) => { c[col] = i + 1; });
  };
  const AUTRE = addShopCat("Autre", false, true);
  const FRUITS = addShopCat("Fruits et légumes", false, false, 1, 2);
  const CREMERIE = addShopCat("Crémerie", false, false, 2, 1);
  const VIANDE = addShopCat("Viande", true, false, 3, 3);
  const POISSON = addShopCat("Poisson", true, false, 4, 4);
  const EPICERIE = addShopCat("Épicerie", false, false, 5, 6);
  const catOfIng = {
    poulet: VIANDE, jambon: VIANDE, "boeuf haché": VIANDE, poisson: POISSON,
    brocoli: FRUITS, carotte: FRUITS, courgette: FRUITS, épinards: FRUITS, "haricots verts": FRUITS,
    pomme: FRUITS, banane: FRUITS, poire: FRUITS, orange: FRUITS, salade: FRUITS, tomate: FRUITS,
    yaourt: CREMERIE, "fromage blanc": CREMERIE, emmental: CREMERIE,
    riz: EPICERIE, pâtes: EPICERIE, quinoa: EPICERIE, polenta: EPICERIE, "pâtes à lasagne": EPICERIE, "sauce tomate": EPICERIE,
  };
  for (const i of ingredients) i.category_id = catOfIng[i.name] || null; // oeuf, pizza... : aucune catégorie (Autre)

  const shopItems = [];
  let nextShopId = 1;
  const lc = (s) => String(s).trim().toLowerCase();
  const round3 = (n) => Math.round(n * 1000) / 1000;
  const matchItem = (list, name, cid, uid, qnull) => {
    if (catOf(cid).no_merge) return null;
    return shopItems.find((s) => s.list === list && lc(s.name) === lc(name) && s.category_id === cid
      && s.unit_id === uid && (s.quantity === null) === qnull && !s.checked) || null;
  };
  // Ajoute un élément (déjà contrôlé), fusionné avec un élément existant si merge et si la règle le permet.
  const shopPut = (list, name, cid, q, uid, merge) => {
    const u = q === null ? null : (uid === undefined ? null : uid);
    const m = merge ? matchItem(list, name, cid, u, q === null) : null;
    if (m) {
      if (q === null) return { merged: true, id: m.id, before: null, after: null };
      const before = m.quantity;
      m.quantity = round3(before + q);
      return { merged: true, id: m.id, before, after: m.quantity };
    }
    const it = { id: nextShopId++, list, name: String(name).trim(), category_id: cid, quantity: q, unit_id: u, checked: false };
    shopItems.push(it);
    return { merged: false, id: it.id };
  };
  const shopItemError = (n, cid, q, uid) => {
    if (!String(n || "").trim() || String(n).trim().length > 60) return "invalid_name";
    if (!catOf(cid)) return "unknown_category";
    if (q !== undefined && q !== null && !(q > 0 && q <= 99999 && round3(q) === q)) return "invalid_quantity";
    if (uid !== undefined && uid !== null && !units.some((u) => u.id === uid)) return "unknown_unit";
    return null;
  };
  const unitName = (id) => (units.find((u) => u.id === id) || {}).name || null;
  const dayDiff = (a, b) => Math.round((Date.parse(b) - Date.parse(a)) / 86400000);
  // Génération de la liste France à partir des repas (même algorithme que la base). Renvoie un résultat ou un code d'erreur.
  const shopGenerate = (d_from, d_to, mode, simulate) => {
    if (!["replace", "append", "merge"].includes(mode)) return "invalid_mode";
    if (!d_from || !d_to || d_from < zurichToday() || d_to < d_from || dayDiff(d_from, d_to) > 61) return "invalid_dates";
    const snap = simulate ? JSON.parse(JSON.stringify(shopItems)) : null;
    const snapId = nextShopId;
    let replaced = 0;
    if (mode === "replace") {
      replaced = shopItems.filter((s) => s.list === "france").length;
      for (let i = shopItems.length - 1; i >= 0; i--) if (shopItems[i].list === "france") shopItems.splice(i, 1);
    }
    const rows = new Map();
    for (const [key, items] of meals) {
      const d = key.split("|")[0];
      if (d < d_from || d > d_to) continue;
      for (const it of items) {
        for (const l of foodIngs.get(it.id) || []) {
          const ing = ingredients.find((x) => x.id === l.id);
          const cid = ing.category_id || AUTRE;
          const qnull = l.quantity === null;
          const grp = catOf(cid).no_merge ? `${key}-${it.id}` : "";
          const k = [ing.name, cid, ing.unit_id, qnull, grp].join("|");
          const r = rows.get(k) || { name: ing.name, cid, uid: ing.unit_id, qnull, total: 0, grp };
          if (!qnull) r.total += l.quantity * it.portions;
          rows.set(k, r);
        }
      }
    }
    const res = { added: 0, replaced, merged: [], split: [], no_qty: [] };
    for (const r of [...rows.values()].sort((x, y) => x.name.localeCompare(y.name) || x.grp.localeCompare(y.grp))) {
      const q = r.qnull ? null : round3(r.total);
      const uid = r.qnull ? null : r.uid;
      if (r.qnull && !res.no_qty.includes(r.name)) res.no_qty.push(r.name);
      const put = shopPut("france", r.name, r.cid, q, uid, mode === "merge");
      if (put.merged) {
        res.merged.push({ name: r.name, unit: unitName(uid), before: put.before, add: q, after: put.after });
      } else {
        res.added++;
        if (mode === "merge" && !catOf(r.cid).no_merge && !res.split.includes(r.name)
            && shopItems.some((s) => s.list === "france" && s.id !== put.id && lc(s.name) === lc(r.name)
              && s.category_id === r.cid && s.unit_id === uid && (s.quantity === null) === r.qnull && s.checked)) res.split.push(r.name);
      }
    }
    if (simulate) { shopItems.splice(0, shopItems.length, ...snap); nextShopId = snapId; }
    return res;
  };
  // Quelques éléments de départ (le beurre déjà coché : une génération en fusion crée une nouvelle ligne).
  shopPut("france", "beurre", CREMERIE, 100, G, false); shopItems[0].checked = true;
  shopPut("france", "concombre", FRUITS, 3, PIECE, false);
  shopPut("france", "pâtes", EPICERIE, 200, G, false);
  shopPut("france", "fromage croque-monsieur", CREMERIE, 4, TRANCHE, false);
  shopPut("france", "sel", AUTRE, null, null, false);
  shopPut("suisse", "chocolat noir", EPICERIE, 3, PIECE, false);
  shopPut("suisse", "fromage à raclette", CREMERIE, 600, G, false);
  shopPut("suisse", "papier toilette", AUTRE, 1, PIECE, false);

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
  const linksIngredient = (rows, iid) => rows.some((r) => r.id === iid);

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
          units,
          foods: [...foods].sort((x, y) => x.name.localeCompare(y.name)).map((f) => ({
            id: f.id,
            name: f.name,
            class_ids: [...f.class_ids].sort((x, y) => x - y),
            uses: usedIn(f.id),
            // Ingrédients de tous les aliments, avec la quantité pour 1 portion (null : non définie).
            ingredients: (foodIngs.get(f.id) || [])
              .map((l) => ({ name: ingName(l.id), quantity: l.quantity, unit_id: ingredients.find((i) => i.id === l.id).unit_id }))
              .sort((x, y) => x.name.localeCompare(y.name, "fr")),
          })),
        });

      case "get_meals": {
        const rows = [];
        for (const [key, items] of meals) {
          const [d, s] = key.split("|");
          if (d < a.d_from || d > a.d_to) continue;
          for (const it of items) {
            const f = foods.find((x) => x.id === it.id);
            // Seules les classes de type composante sont renvoyées (les classes combo ne s'affichent jamais dans les repas).
            const cids = f.class_ids.filter((c) => typeOf(c) === "composante").sort((x, y) => x - y);
            rows.push({ meal_date: d, slot: s, food_id: it.id, food_name: f.name, class_ids: cids, portions: it.portions });
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
        // portions : tableau parallèle à food_ids (1 par défaut) ; > 0, 99 au plus, 2 décimales au plus.
        const items = new Map();
        (a.food_ids || []).forEach((id, i) => {
          const p = a.portions && a.portions[i] !== undefined && a.portions[i] !== null ? Number(a.portions[i]) : 1;
          if (!items.has(id)) items.set(id, p);
        });
        if ([...items.values()].some((p) => !(p > 0 && p <= 99 && Math.round(p * 100) / 100 === p))) return fail("invalid_portions");
        if ([...items.keys()].some((id) => !foods.some((f) => f.id === id))) return fail("unknown_food");
        if (items.size && blockedSlots(a.d).has(a.s)) return fail("slot_blocked"); // vider reste possible
        if (items.size) meals.set(`${a.d}|${a.s}`, [...items].map(([id, portions]) => ({ id, portions })));
        else meals.delete(`${a.d}|${a.s}`);
        return voidOk();
      }

      case "add_food": {
        if (role !== "admin") return fail("forbidden");
        const name = clean(a.n);
        if (!name || name.length > 60) return fail("invalid_name");
        let cids = [...new Set(a.cids || [])].sort((x, y) => x - y);
        if (!cids.length) return fail("invalid_classes");
        if (cids.some((c) => !classes.some((k) => k.id === c))) return fail("unknown_class");
        if (!cids.some((c) => typeOf(c) === "composante")) return fail("class_component_required");
        const r = foodIngredients(name, cids, a.ings);
        if (r.error) return fail(r.error);
        if (foods.some((f) => f.name === name)) return fail("food_exists");
        const created = { id: nextId++, name, class_ids: r.cids };
        foods.push(created);
        setIngredients(created.id, r.rows);
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
        const r = foodIngredients(name, cids, a.ings);
        if (r.error) return fail(r.error);
        if (foods.some((x) => x.name === name && x.id !== a.fid)) return fail("food_exists");
        const used = usedIn(a.fid) > 0;
        // On peut ajouter des classes de type composante à un aliment utilisé, pas en retirer
        // (la classe Recettes, de type combo, peut être ajoutée ou retirée librement).
        if (used && f.class_ids.some((c) => typeOf(c) === "composante" && !r.cids.includes(c))) return fail("food_in_use_class");
        f.name = name;
        f.class_ids = r.cids;
        setIngredients(f.id, r.rows);
        return voidOk();
      }

      case "delete_food": {
        if (role !== "admin") return fail("forbidden");
        // Repas qui l'utilisent, du plus récent au plus ancien (midi avant soir) : { n, items } en JSON.
        const items = [...meals].filter(([, list]) => list.some((it) => it.id === a.fid)).map(([k]) => k)
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
          .map((i) => ({
            id: i.id, name: i.name, unit_id: i.unit_id, category_id: i.category_id || null,
            uses: [...foodIngs.values()].filter((rows) => linksIngredient(rows, i.id)).length,
          })));
      }

      case "add_ingredient": {
        if (role !== "admin") return fail("forbidden");
        const name = clean(a.n);
        if (!name || name.length > 60) return fail("invalid_name");
        const uid = a.uid === undefined || a.uid === null ? G : a.uid;
        if (!units.some((u) => u.id === uid)) return fail("unknown_unit");
        const cid = a.cid === undefined || a.cid === null ? null : a.cid;
        if (cid !== null && !catOf(cid)) return fail("unknown_category");
        if (ingredients.some((i) => i.name === name)) return fail("ingredient_exists");
        const iid = ingredientId(name, uid);
        ingredients.find((i) => i.id === iid).category_id = cid;
        return ok(iid);
      }

      case "update_ingredient": {
        if (role !== "admin") return fail("forbidden");
        const name = clean(a.n);
        const i = ingredients.find((x) => x.id === a.iid);
        if (!name || name.length > 60) return fail("invalid_name");
        if (!i) return fail("unknown_ingredient");
        const uid = a.uid === undefined || a.uid === null ? i.unit_id : a.uid;
        if (!units.some((u) => u.id === uid)) return fail("unknown_unit");
        // cid : -1 ou absent = inchangée, null = aucune catégorie.
        const cid = a.cid === undefined || a.cid === -1 ? (i.category_id || null) : a.cid;
        if (cid !== null && !catOf(cid)) return fail("unknown_category");
        if (ingredients.some((x) => x.id !== a.iid && x.name === name)) return fail("ingredient_exists");
        i.name = name;
        i.unit_id = uid;
        i.category_id = cid;
        return voidOk();
      }

      case "delete_ingredient": {
        if (role !== "admin") return fail("forbidden");
        const users = [...foodIngs].filter(([, rows]) => linksIngredient(rows, a.iid))
          .map(([fid]) => foods.find((f) => f.id === fid).name).sort();
        if (users.length) return fail("ingredient_in_use", JSON.stringify({ n: users.length, items: users }));
        ingredients = ingredients.filter((i) => i.id !== a.iid);
        return voidOk();
      }

      case "get_shop_categories":
        return ok([...shopCats].sort((x, y) => x.name.localeCompare(y.name, "fr")).map((c) => ({
          ...c,
          uses: ingredients.filter((i) => i.category_id === c.id).length + shopItems.filter((s) => s.category_id === c.id).length,
        })));

      case "add_shop_category": {
        if (role !== "admin") return fail("forbidden");
        const name = String(a.n || "").trim();
        if (!name || name.length > 40) return fail("invalid_name");
        if (shopCats.some((c) => lc(c.name) === lc(name))) return fail("category_exists");
        return ok(addShopCat(name, !!a.nm, false, a.pc === undefined ? null : a.pc, a.pk === undefined ? null : a.pk));
      }

      case "update_shop_category": {
        if (role !== "admin") return fail("forbidden");
        const name = String(a.n || "").trim();
        const c = catOf(a.cid);
        if (!name || name.length > 40) return fail("invalid_name");
        if (!c) return fail("unknown_category");
        if (shopCats.some((x) => x.id !== a.cid && lc(x.name) === lc(name))) return fail("category_exists");
        c.name = name;
        c.no_merge = !!a.nm;
        shopPlace(c.id, a.pc === undefined ? null : a.pc, a.pk === undefined ? null : a.pk);
        return voidOk();
      }

      case "delete_shop_category": {
        if (role !== "admin") return fail("forbidden");
        const c = catOf(a.cid);
        if (!c) return voidOk();
        if (c.is_default) return fail("category_default");
        const items = [
          ...ingredients.filter((i) => i.category_id === c.id).map((i) => `${i.name} (ingrédient)`),
          ...shopItems.filter((s) => s.category_id === c.id).map((s) => `${s.name} (liste ${s.list === "france" ? "France" : "Suisse"})`),
        ].sort();
        if (items.length) return fail("category_in_use", JSON.stringify({ n: items.length, items }));
        shopCats.splice(shopCats.indexOf(c), 1);
        compactCats();
        return voidOk();
      }

      case "get_shop_items":
        return ok(shopItems.map((s) => ({ ...s })));

      case "add_shop_item": {
        if (role !== "write" && role !== "admin") return fail("forbidden");
        if (!["france", "suisse"].includes(a.lst)) return fail("invalid_list");
        const cid = a.cid === undefined || a.cid === null ? AUTRE : a.cid;
        const err = shopItemError(a.n, cid, a.q, a.uid);
        if (err) return fail(err);
        return ok(shopPut(a.lst, a.n, cid, a.q === undefined ? null : a.q, a.uid === undefined ? null : a.uid, true));
      }

      case "update_shop_item": {
        if (role !== "write" && role !== "admin") return fail("forbidden");
        const s = shopItems.find((x) => x.id === a.iid);
        if (!s) return fail("unknown_item");
        const cid = a.cid === undefined || a.cid === null ? AUTRE : a.cid;
        const err = shopItemError(a.n, cid, a.q, a.uid);
        if (err) return fail(err);
        const q = a.q === undefined ? null : a.q;
        s.name = String(a.n).trim();
        s.category_id = cid;
        s.quantity = q;
        s.unit_id = q === null ? null : (a.uid === undefined ? null : a.uid);
        return voidOk();
      }

      case "set_shop_item_checked": {
        if (role !== "write" && role !== "admin") return fail("forbidden");
        const s = shopItems.find((x) => x.id === a.iid);
        if (!s) return fail("unknown_item");
        s.checked = !!a.chk;
        return voidOk();
      }

      case "delete_shop_item": {
        if (role !== "write" && role !== "admin") return fail("forbidden");
        const i = shopItems.findIndex((x) => x.id === a.iid);
        if (i >= 0) shopItems.splice(i, 1);
        return voidOk();
      }

      case "clear_shop_list": {
        if (role !== "write" && role !== "admin") return fail("forbidden");
        if (!["france", "suisse"].includes(a.lst)) return fail("invalid_list");
        for (let i = shopItems.length - 1; i >= 0; i--) if (shopItems[i].list === a.lst) shopItems.splice(i, 1);
        return voidOk();
      }

      case "move_shop_item": {
        if (role !== "write" && role !== "admin") return fail("forbidden");
        if (!["france", "suisse"].includes(a.to_list)) return fail("invalid_list");
        const s = shopItems.find((x) => x.id === a.iid);
        if (!s) return fail("unknown_item");
        if (s.list === a.to_list) return ok({ merged: false, id: s.id });
        const m = !s.checked ? matchItem(a.to_list, s.name, s.category_id, s.unit_id, s.quantity === null) : null;
        if (m) {
          if (s.quantity !== null) m.quantity = round3(m.quantity + s.quantity);
          shopItems.splice(shopItems.indexOf(s), 1);
          return ok({ merged: true, id: m.id });
        }
        s.list = a.to_list;
        return ok({ merged: false, id: s.id });
      }

      case "preview_shop_generation":
      case "generate_shop": {
        if (role !== "write" && role !== "admin") return fail("forbidden");
        const res = shopGenerate(a.d_from, a.d_to, a.mode, fn === "preview_shop_generation");
        return typeof res === "string" ? fail(res) : ok(res);
      }
    }
    return fail("unknown_function");
  };

  const banner = document.createElement("div");
  banner.textContent = "MODE TEST : données fictives en mémoire, rien n'est envoyé à Supabase. Identifiant / mot de passe : reader / r, writer / w, admin / a.";
  banner.style.cssText = "background:#fff3cd;color:#664d03;font:13px system-ui;padding:6px 12px;text-align:center;position:relative;z-index:10";
  document.addEventListener("DOMContentLoaded", () => document.body.prepend(banner));
})();

// Ces deux valeurs sont publiques par conception (la sécurité repose sur la base).
const SUPABASE_URL = "https://bwcizhvhtwkjfjadurcj.supabase.co";
const SUPABASE_KEY = "sb_publishable_KLQZ-MuQKYbV1_GUvOFk9Q_nfumGtNc";

const SUPABASE_SCHEMA = "food";

// Read et Write : mot de passe gardé dans le navigateur (session persistante).
// Admin : gardé uniquement le temps de l'onglet (révoqué à sa fermeture).
const STORAGE_KEY = "food_session"; // JSON { u: identifiant, p: mot de passe }

const DAYS_BEFORE = 15;
const DAYS_AFTER = 30;
const SLOTS = ["midi", "soir"];

const $ = (id) => document.getElementById(id);

// Texte de comparaison pour les recherches : minuscules et sans accents (« crème », « creme » et « créme » se valent).
const fold = (s) => s.normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase();
const gate = $("gate");
const gateForm = $("gate-form");
const gateError = $("gate-error");
const userInput = $("user-id");
const passwordInput = $("password");
const app = $("app");
const todayBtn = $("today-btn");

// Message d'erreur : bandeau fixe en haut de l'écran (visible quel que soit le défilement),
// qui disparaît seul ou au clic. Écrire dans statusEl.textContent l'affiche ; "" le masque.
const toast = $("status");
let toastTimer = 0;
const statusEl = {
  set textContent(msg) {
    clearTimeout(toastTimer);
    toast.textContent = msg;
    toast.hidden = !msg;
    if (msg) toastTimer = setTimeout(() => { toast.hidden = true; }, 8000);
  },
};
toast.addEventListener("click", () => { statusEl.textContent = ""; });

// Ferme une boîte de dialogue quand on clique en dehors de sa zone visible (sur le fond).
// On compare avec les coordonnées : un clic sur le bord intérieur de la boîte ne la ferme pas,
// et il faut que l'appui ET le relâchement soient en dehors (un clic qui commence dans la boîte
// et finit dehors, par exemple si la boîte change de taille, ne la ferme pas).
function closeOnBackdrop(dialog, value) {
  const outside = (e) => {
    const r = dialog.getBoundingClientRect();
    return e.clientX < r.left || e.clientX > r.right || e.clientY < r.top || e.clientY > r.bottom;
  };
  let pressedOutside = false;
  dialog.addEventListener("pointerdown", (e) => { pressedOutside = outside(e); });
  dialog.addEventListener("click", (e) => {
    if (pressedOutside && outside(e)) dialog.close(value);
    pressedOutside = false;
  });
}

let userId = "";
let password = "";
// Identifiants envoyés à chaque appel : la base revérifie le mot de passe et le rôle à chaque fois.
const auth = () => ({ u: userId, p: password });
let role = "";
let classes = [];
let foods = [];
// foods : [{ id, name, class_ids }] ; un aliment peut avoir plusieurs classes (ex. un sandwich).
let meals = new Map(); // "2026-10-27|midi" -> [{ id, name, class_ids }]
// Contraintes de jour : texte informatif affiché sur un jour, sans effet sur le comportement du site.
let constraints = []; // [{ id, name, uses }] : liste des contraintes possibles (gérée par l'admin)
let dayConstraints = new Map(); // "2026-10-27" -> [ids de contraintes]
let units = []; // [{ id, name, plural }] : unités possibles d'un ingrédient (liste fixe, gérée en SQL)
let effects = []; // [{ id, name, description, blocked_slot }] : effets possibles d'une contrainte (liste fixe, gérée en SQL)
let ingredients = []; // [{ id, name, uses }] : liste des ingrédients (admin uniquement)
let adminSection = "foods"; // onglet Admin : "foods" | "ingredients" | "constraints" | "categories"
let currentTab = "home";
let today = "";
let shopCats = []; // [{ id, name, pos_carrefour, pos_coop, no_merge, is_default, uses }] : catégories de courses (vide : base pas encore à jour)
let shopItems = []; // [{ id, list, name, category_id, quantity, unit_id, checked }] : éléments des listes de courses
let shopList = "france";// liste affichée : "france" | "suisse"
const SHOP_LISTS = {
  france: { label: "France", custom: "Carrefour Segny", pos: "pos_carrefour" },
  suisse: { label: "Suisse", custom: "Coop Vich", pos: "pos_coop" },
};
// Tri de chaque liste : propre à la session (onglet en cours), perdu à la déconnexion. Par défaut : A → Z.
const SORT_KEY = "food_shop_sort";
const defaultShopSorts = () => ({ france: "alpha", suisse: "alpha" });
function readShopSorts() {
  const sorts = defaultShopSorts();
  try {
    const s = JSON.parse(sessionStorage.getItem(SORT_KEY) || "{}");
    for (const k of Object.keys(sorts)) if (["alpha", "date", "custom"].includes(s[k])) sorts[k] = s[k];
  } catch {}
  return sorts;
}
let shopSorts = readShopSorts();
const saveShopSorts = () => { try { sessionStorage.setItem(SORT_KEY, JSON.stringify(shopSorts)); } catch {} };

// ------------------------------------------------------------------ Réseau
async function rpc(name, args) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      apikey: SUPABASE_KEY,
      "Content-Profile": SUPABASE_SCHEMA, // schéma PostgreSQL où vivent les fonctions
    },
    body: JSON.stringify(args),
  });
  if (!res.ok) {
    const body = await res.json().catch(() => ({}));
    const err = new Error(body.message || `Erreur ${res.status}`);
    err.code = body.message;
    err.details = body.details;
    err.invalidPassword = body.message === "invalid_password";
    throw err;
  }
  // Une fonction qui ne renvoie rien (set_meal, update_food, delete_food) répond avec un corps vide :
  // on ne lit donc pas la réponse comme du JSON sans vérifier qu'il y en a une.
  const text = await res.text();
  return text ? JSON.parse(text) : null;
}

// Quand la suppression d'un aliment, d'un ingrédient ou d'une contrainte est refusée parce qu'il est
// utilisé, la base renvoie en détail { n: nombre, items: [ce qui l'utilise] } (en texte JSON).
function usageOf(e) {
  try {
    const d = JSON.parse(e.details);
    return { n: Number(d.n) || 0, slot: d.slot || "", items: Array.isArray(d.items) ? d.items : [] };
  } catch {
    return { n: 0, slot: "", items: [] };
  }
}

function errorText(e) {
  switch (e.code) {
    case "food_exists": return "Cet aliment existe déjà.";
    case "food_in_use":
      return `Cet aliment est utilisé dans ${usageOf(e).n || "plusieurs"} repas. Retirez-le de ces repas avant de le supprimer.`;
    case "food_in_use_class":
      return "Cet aliment est utilisé dans des repas : vous pouvez lui ajouter des classes, mais pas en retirer.";
    case "invalid_classes": return "Choisissez au moins une classe.";
    case "class_component_required": return "Choisissez au moins une classe d'aliment autre que Recettes.";
    case "ingredients_required": return "Un aliment doit avoir au moins un ingrédient.";
    case "ingredient_exists": return "Cet ingrédient existe déjà.";
    case "ingredient_in_use":
      return `Cet ingrédient est utilisé par ${usageOf(e).n || "plusieurs"} aliment(s). Retirez-le de ces aliments avant de le supprimer.`;
    case "unknown_ingredient": return "Un ingrédient sélectionné n'existe plus. Rechargez la page.";
    case "invalid_portions": return "Le nombre de portions doit être supérieur à 0 (99 au plus, 2 décimales au plus).";
    case "invalid_quantity": return "La quantité doit être un nombre supérieur à 0 (laissez vide si elle n'est pas définie).";
    case "unknown_unit": return "Une unité sélectionnée n'existe plus. Rechargez la page.";
    case "slot_blocked": return "Ce repas est bloqué par une contrainte du jour : retirez-la pour pouvoir le remplir.";
    case "meal_in_blocked_slot":
      return `Le repas du ${e.details || "créneau bloqué"} de ce jour est rempli : videz-le avant d'attribuer cette contrainte.`;
    case "effect_conflict": return "Cet effet bloquerait des repas déjà remplis. Videz-les d'abord.";
    case "unknown_effect": return "Un effet sélectionné n'existe plus. Rechargez la page.";
    case "unknown_class": return "Une classe sélectionnée n'existe plus. Rechargez la page.";
    case "invalid_name": return "Le nom est invalide (1 à 60 caractères).";
    case "constraint_exists": return "Cette contrainte existe déjà.";
    case "constraint_in_use":
      return `Cette contrainte est attribuée à ${usageOf(e).n || "plusieurs"} jour(s). Retirez-la de ces jours avant de la supprimer.`;
    case "unknown_constraint": return "Une contrainte sélectionnée n'existe plus. Rechargez la page.";
    case "out_of_window": return "Ce jour n'est pas modifiable.";
    case "unknown_food": return "Un aliment sélectionné n'existe plus. Rechargez la page.";
    case "invalid_list": return "Cette liste n'existe pas.";
    case "unknown_item": return "Cet élément n'existe plus. Actualisez la liste.";
    case "unknown_category": return "Une catégorie sélectionnée n'existe plus. Rechargez la page.";
    case "category_exists": return "Cette catégorie existe déjà.";
    case "category_default": return "La catégorie « Autre » ne peut pas être supprimée.";
    case "category_in_use": return "Cette catégorie est encore utilisée.";
    case "invalid_position": return "La position doit être un nombre entier supérieur à 0.";
    case "invalid_dates": return "Choisissez des jours à partir d'aujourd'hui, 62 jours au plus.";
    case "invalid_mode": return "Choisissez comment générer la liste.";
    case "forbidden": return "Action non autorisée avec ce mot de passe.";
    default: return "Une erreur est survenue. Réessayez plus tard.";
  }
}

// Affiche l'erreur dans la zone voulue ; renvoie true si la session a expiré.
function fail(e, target = statusEl) {
  if (e.invalidPassword) { lock(); return true; }
  target.textContent = errorText(e);
  return false;
}

// --------------------------------------------------------- Quantités et unités
const numberFormat = new Intl.NumberFormat("fr-FR", { maximumFractionDigits: 2 });
const fmtNum = (n) => numberFormat.format(n);
const round2 = (n) => Math.round(n * 100) / 100;
const unitOf = (id) => units.find((u) => u.id === id) || { name: "", plural: "" };
// « 375 g », « 1,5 pièce », « 2 pièces » (pluriel à partir de 2).
const fmtQty = (q, unitId) => {
  const u = unitOf(unitId);
  return `${fmtNum(q)} ${q >= 2 ? u.plural : u.name}`.trim();
};
// Pas des boutons − / + d'une quantité selon l'unité : 25 pour g et ml, 0,5 pour pièce, 1 pour les autres.
const qtyStep = (uid) => ({ g: 25, ml: 25, "pièce": 0.5 })[unitOf(uid).name] || 1;

// ------------------------------------------------------------------- Dates
function zurichToday() {
  return new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/Zurich" }).format(new Date());
}

function addDays(ds, n) {
  const [y, m, d] = ds.split("-").map(Number);
  return new Date(Date.UTC(y, m - 1, d + n)).toISOString().slice(0, 10);
}

function fmtDay(ds) {
  const [y, m, d] = ds.split("-").map(Number);
  const s = new Date(Date.UTC(y, m - 1, d)).toLocaleDateString("fr-FR", {
    weekday: "long", day: "numeric", month: "long", timeZone: "UTC",
  });
  return s[0].toUpperCase() + s.slice(1);
}

// -------------------------------------------------------------------- Données
async function loadCatalog() {
  const cat = await rpc("get_catalog", auth());
  classes = cat.classes;
  units = cat.units || [];
  // Avant la migration des quantités (v2-3), les ingrédients d'une recette sont de simples noms : on les
  // convertit au nouveau format (quantité non définie, sans unité).
  foods = cat.foods.map((f) => ({
    ...f,
    ingredients: (f.ingredients || []).map((i) => (typeof i === "string" ? { name: i, quantity: null, unit_id: undefined } : i)),
  }));
}

// Les contraintes de jour sont accessoires : si leur chargement échoue (sauf mot de passe refusé),
// on affiche quand même les repas, sans contraintes.
const optional = (promise) => promise.catch((e) => {
  if (e.invalidPassword) throw e;
  return [];
});

async function loadConstraints() {
  constraints = await optional(rpc("get_constraints", auth()));
}

// Les effets des contraintes sont accessoires aussi : sans eux (base pas encore à jour), aucun créneau n'est bloqué.
async function loadEffects() {
  effects = await optional(rpc("get_effects", auth()));
}

const effectOf = (k) => effects.find((e) => e.id === k.effect_id) || null;

// Créneaux bloqués un jour donné par les effets des contraintes de ce jour :
// Map "midi" | "soir" -> nom de la contrainte qui le bloque.
function blockedSlots(date) {
  const slots = new Map();
  for (const id of dayConstraints.get(date) || []) {
    const k = constraints.find((c) => c.id === id);
    const e = k && effectOf(k);
    if (e && e.blocked_slot) slots.set(e.blocked_slot, k.name);
  }
  return slots;
}

// Les ingrédients ne concernent que l'admin (liste de l'onglet Admin, suggestions des recettes).
async function loadIngredients() {
  ingredients = role === "admin" ? await optional(rpc("get_ingredients", auth())) : [];
}

// Aliments et ingrédients vont ensemble : un aliment peut créer des ingrédients à la volée.
const loadFoodsAndIngredients = () => Promise.all([loadCatalog(), loadIngredients()]);

async function loadMeals() {
  today = zurichToday();
  const range = { d_from: addDays(today, -DAYS_BEFORE), d_to: addDays(today, DAYS_AFTER) };
  const [rows, dayRows] = await Promise.all([
    rpc("get_meals", { ...auth(), ...range }),
    optional(rpc("get_day_constraints", { ...auth(), ...range })),
  ]);
  dayConstraints = new Map();
  for (const r of dayRows) {
    if (!dayConstraints.has(r.day_date)) dayConstraints.set(r.day_date, []);
    dayConstraints.get(r.day_date).push(r.constraint_id);
  }
  meals = new Map();
  for (const r of rows) {
    const key = `${r.meal_date}|${r.slot}`;
    if (!meals.has(key)) meals.set(key, []);
    meals.get(key).push({ id: r.food_id, name: r.food_name, class_ids: r.class_ids || [], portions: Number(r.portions) || 1 });
  }
}

async function loadAll() {
  try {
    await Promise.all([loadCatalog(), loadConstraints(), loadMeals(), loadIngredients(), loadEffects(), loadShop()]);
    statusEl.textContent = "";
    render();
  } catch (e) {
    if (!fail(e)) statusEl.textContent = "Impossible de charger les données. Réessayez plus tard.";
  }
}

async function reloadMeals() {
  // L'indication d'utilisation de l'onglet Admin (aliments, contraintes) dépend des repas et des jours.
  await Promise.all([loadMeals(), role === "admin" ? Promise.all([loadCatalog(), loadConstraints()]) : null]);
  const y = window.scrollY;
  renderHome();
  renderMeals();
  renderAdmin();
  window.scrollTo(0, y);
  updateTodayBtn();
}

// ------------------------------------------------------------------ Rendu
function el(tag, cls, text) {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (text !== undefined) n.textContent = text;
  return n;
}

function button(cls, text, onClick) {
  const b = el("button", cls, text);
  b.type = "button";
  b.addEventListener("click", onClick);
  return b;
}

function mealBlock(date, slot, editable) {
  const items = meals.get(`${date}|${slot}`) || [];
  // Créneau bloqué par une contrainte du jour (effet) : pas de génération possible ; pour pouvoir le
  // remplir à nouveau il faut retirer la contrainte du jour.
  const blocked = blockedSlots(date).has(slot);
  const box = el("div", "meal");
  const head = el("div", "meal-head");
  head.append(el("span", "meal-name", slot));

  if (editable) {
    const btns = el("div", "meal-btns");
    if (items.length) {
      // Un repas déjà rempli sur un créneau bloqué (antérieur à la règle) ne peut plus qu'être vidé.
      if (!blocked) btns.append(button("btn-sm", "Modifier", () => openMeal(date, slot)));
      btns.append(button("btn-sm danger", "Vider", () => clearMeal(date, slot)));
    } else if (!blocked) {
      btns.append(button("btn-sm", "Générer repas manuel", () => openMeal(date, slot)));
    }
    if (btns.children.length) head.append(btns);
  }
  box.append(head);

  if (!items.length) {
    box.append(el("p", "meal-empty", blocked ? "pas de repas" : "vide"));
    return box;
  }
  // Les aliments qui ont exactement les mêmes classes sont regroupés sur une ligne
  // ("poulet, jambon · Protéines") ; un aliment multi-classes apparaît une seule fois
  // avec toutes ses classes ("sandwich · Protéines, Féculents, Légumes").
  const pos = (id) => classes.findIndex((c) => c.id === id);
  const groups = new Map();
  for (const f of items) {
    const key = f.class_ids.join(",");
    if (!groups.has(key)) groups.set(key, { ids: f.class_ids, names: [] });
    groups.get(key).names.push(f.name); // les portions ne s'affichent que dans le détail « Ingrédients »
  }
  const ordered = [...groups.values()].sort(
    (a, b) => Math.min(...a.ids.map(pos)) - Math.min(...b.ids.map(pos)) || a.ids.length - b.ids.length
  );
  for (const g of ordered) {
    const line = el("p", "meal-line", g.names.join(", "));
    const label = g.ids.map((id) => (classes[pos(id)] || {}).name).filter(Boolean).join(", ");
    line.append(el("span", "cls", label));
    box.append(line);
  }
  // Bouton « Ingrédients » : déplie les ingrédients de chaque aliment du repas avec leur quantité.
  const detail = mealIngredients(items);
  detail.hidden = true;
  const toggle = button("link-btn meal-ing-toggle", "Ingrédients ▾", () => {
    detail.hidden = !detail.hidden;
    toggle.textContent = detail.hidden ? "Ingrédients ▾" : "Ingrédients ▴";
  });
  box.append(toggle, detail);
  return box;
}

// Détail des ingrédients d'un repas : pour chaque aliment, ses ingrédients avec la quantité du repas
// (quantité pour 1 portion × nombre de portions de l'aliment dans ce repas).
function mealIngredients(items) {
  const box = el("div", "meal-detail");
  for (const it of [...items].sort((a, b) => a.name.localeCompare(b.name, "fr"))) {
    const food = foods.find((f) => f.id === it.id);
    const head = el("p", "md-food", it.name);
    if (it.portions !== 1) head.append(el("span", "md-portions", ` ×${fmtNum(it.portions)}`));
    box.append(head);
    const list = el("ul", "md-list");
    for (const ing of (food && food.ingredients) || []) {
      const li = el("li");
      li.append(el("span", "md-name", ing.name));
      li.append(el("span", ing.quantity == null ? "md-qty none" : "md-qty",
        ing.quantity == null ? "quantité non définie" : fmtQty(round2(ing.quantity * it.portions), ing.unit_id)));
      list.append(li);
    }
    if (!list.children.length) list.append(el("li", "md-none", "aucun ingrédient"));
    box.append(list);
  }
  return box;
}

function dayCard(date, editable) {
  const card = el("article", "day" + (date === today ? " today" : ""));
  card.dataset.date = date;
  const head = el("div", "day-head");
  const title = el("h3", "day-title", fmtDay(date));
  if (date === today) title.append(el("small", "", "aujourd'hui"));
  else if (date === addDays(today, 1)) title.append(el("small", "", "demain"));
  head.append(title);
  // Contraintes du jour, en haut à droite. Seul le mode write peut les modifier (clic dessus).
  const names = (dayConstraints.get(date) || [])
    .map((id) => constraints.find((k) => k.id === id))
    .filter(Boolean)
    .sort((a, b) => a.name.localeCompare(b.name, "fr"))
    .map((k) => k.name);
  const chips = () => names.map((n) => el("span", "day-chip", n));
  if (editable) {
    const b = el("button", "day-constraints editable");
    b.type = "button";
    b.setAttribute("aria-label", `Contraintes du ${fmtDay(date)}`);
    if (names.length) b.append(...chips());
    else b.append(el("span", "day-chip empty", "+ Contrainte"));
    b.addEventListener("click", () => openDayConstraints(date));
    head.append(b);
  } else if (names.length) {
    const box = el("div", "day-constraints");
    box.append(...chips());
    head.append(box);
  }
  card.append(head);
  for (const slot of SLOTS) card.append(mealBlock(date, slot, editable));
  return card;
}

function renderHome() {
  const root = $("tab-home");
  root.replaceChildren(el("h2", "section-title", "Aujourd'hui et demain"));
  root.append(dayCard(today, false), dayCard(addDays(today, 1), false));
  const more = el("p", "empty");
  more.append(button("btn-primary", "Voir tous les repas", () => switchTab("meals")));
  root.append(more);
}

function renderMeals() {
  const root = $("tab-meals");
  root.replaceChildren();
  const editable = role === "write" || role === "admin"; // l'admin a aussi les droits d'écriture sur les repas et les contraintes de jour
  for (let i = -DAYS_BEFORE; i <= DAYS_AFTER; i++) root.append(dayCard(addDays(today, i), editable));
}

function render() {
  renderHome();
  renderMeals();
  renderShop();
  renderAdmin();
}

// ------------------------------------------------------------------ Onglets
function switchTab(name) {
  currentTab = name;
  for (const t of ["home", "meals", "shop", "admin"]) $(`tab-${t}`).hidden = t !== name;
  for (const b of $("tabs").querySelectorAll("button")) b.classList.toggle("on", b.dataset.tab === name);
  if (name === "shop") refreshShop();
  if (name === "meals") scrollToToday();
  else window.scrollTo(0, 0);
  updateTodayBtn();
}

function todayCard() {
  return $("tab-meals").querySelector(".day.today");
}

function scrollToToday() {
  const t = todayCard();
  if (t) t.scrollIntoView({ block: "start" });
}

// Bouton « Aujourd'hui » flottant : visible seulement sur l'onglet Repas quand le jour
// d'aujourd'hui n'est pas à l'écran, avec une flèche vers sa position (haut ou bas).
function updateTodayBtn() {
  const t = currentTab === "meals" ? todayCard() : null;
  if (!t) { todayBtn.hidden = true; return; }
  const r = t.getBoundingClientRect();
  const navTop = $("tabs").getBoundingClientRect().top;
  const visible = r.bottom > 0 && r.top < navTop;
  todayBtn.hidden = visible;
  todayBtn.textContent = (r.top < 0 ? "↑ " : "↓ ") + "Aujourd'hui";
}

todayBtn.addEventListener("click", scrollToToday);
window.addEventListener("scroll", updateTodayBtn, { passive: true });
window.addEventListener("resize", updateTodayBtn);

$("tabs").addEventListener("click", (e) => {
  const b = e.target.closest("button[data-tab]");
  if (b) switchTab(b.dataset.tab);
});

// ------------------------------------------------------------ Confirmation
const confirmDialog = $("confirm");
closeOnBackdrop(confirmDialog, "no");
$("confirm-no").addEventListener("click", () => confirmDialog.close("no"));
$("confirm-yes").addEventListener("click", () => confirmDialog.close("yes"));

function confirmAction(title, detail = "") {
  return new Promise((resolve) => {
    $("confirm-title").textContent = title;
    $("confirm-detail").textContent = detail;
    confirmDialog.returnValue = "no";
    confirmDialog.addEventListener("close", () => resolve(confirmDialog.returnValue === "yes"), { once: true });
    confirmDialog.showModal();
  });
}

// ---------------------------------------------------------- Choix d'aliments
// Champ multi-sélection : cadres avec croix + liste déroulante filtrée (« contient »).
// `chosen` (Map id -> aliment) est partagé entre tous les champs du popup : un aliment multi-classes
// choisi dans un champ apparaît aussi dans ses autres classes, et l'enlever l'enlève partout.
// `onChange` rafraîchit tous les champs.
// Avec `allowNew` (ingrédients d'une recette), on peut aussi saisir un nom qui n'est pas dans la liste
// (« Créer « nom » ») : `chosen` est alors indexé par le nom, et sert de source des cadres affichés.
// Avec `tags: false`, les choix ne s'affichent pas en cadres (le champ ne sert qu'à ajouter : les lignes
// d'ingrédients d'un aliment sont affichées à part).
function createPicker(options, chosen, onChange, {
  allowNew = false, tags = true, placeholder = "Choisir…",
  none = "Aucun aliment", empty = "Aucun aliment dans cette classe",
} = {}) {
  const root = el("div", "picker");
  const field = el("div", "picker-field");
  const input = el("input");
  input.type = "text";
  input.autocomplete = "off";
  input.placeholder = placeholder;
  const list = el("ul", "picker-list");
  list.hidden = true;
  let active = -1;
  let shown = [];

  const current = () => (allowNew ? [...chosen.values()] : options.filter((f) => chosen.has(f.id)));

  function renderTags() {
    if (!tags) return;
    field.querySelectorAll(".tag").forEach((t) => t.remove());
    const mine = current();
    for (const f of mine) {
      const tag = el("span", "tag", f.name);
      const x = button("", "×", () => { chosen.delete(f.id); onChange(); });
      x.setAttribute("aria-label", `Retirer ${f.name}`);
      tag.append(x);
      field.insertBefore(tag, input);
    }
    input.placeholder = mine.length ? "" : placeholder;
  }

  function renderList() {
    const q = input.value.trim().toLowerCase();
    shown = options.filter((o) => !chosen.has(o.id) && fold(o.name).includes(fold(q)));
    if (allowNew && q && q.length <= 60 && !chosen.has(q) && !options.some((o) => o.id === q)) {
      shown.push({ id: q, name: q, isNew: true });
    }
    // Avec saisie libre, le nom tapé tel quel (existant ou à créer) est présélectionné.
    active = shown.length && q ? (allowNew ? shown.findIndex((o) => o.id === q) : 0) : -1;
    list.replaceChildren();
    if (!shown.length) {
      list.append(el("li", "none", options.length ? none : empty));
      return;
    }
    shown.forEach((o, i) => {
      const li = el("li", i === active ? "act" : "", o.isNew ? `Créer « ${o.name} »` : o.name);
      li.addEventListener("pointerdown", (e) => e.preventDefault()); // garde le focus dans le champ
      li.addEventListener("click", () => pick(o));
      list.append(li);
    });
  }

  function pick(o) {
    chosen.set(o.id, o);
    input.value = "";
    onChange();
    input.focus();
  }

  function move(delta) {
    if (!shown.length) return;
    active = (active + delta + shown.length) % shown.length;
    [...list.children].forEach((li, i) => li.classList.toggle("act", i === active));
    list.children[active].scrollIntoView({ block: "nearest" });
  }

  field.addEventListener("click", (e) => { if (e.target === field) input.focus(); });
  input.addEventListener("focus", () => { renderList(); list.hidden = false; });
  input.addEventListener("blur", () => { list.hidden = true; });
  input.addEventListener("input", () => { renderList(); list.hidden = false; });
  input.addEventListener("keydown", (e) => {
    if (e.key === "ArrowDown") { e.preventDefault(); move(1); }
    else if (e.key === "ArrowUp") { e.preventDefault(); move(-1); }
    else if (e.key === "Enter") { e.preventDefault(); if (shown[active]) pick(shown[active]); }
    else if (tags && e.key === "Backspace" && !input.value) {
      const mine = current();
      if (mine.length) { chosen.delete(mine[mine.length - 1].id); onChange(); }
    }
  });

  field.append(input);
  root.append(field, list);
  renderTags();
  return {
    el: root,
    refresh() { renderTags(); renderList(); },
    // Texte tapé mais pas encore validé (pour ne pas le perdre si on clique directement sur « Enregistrer »).
    pending() { return input.value.trim().toLowerCase(); },
    clear() { input.value = ""; },
  };
}

// Lignes d'ingrédients d'un aliment (ajout et modification) : nom, quantité pour 1 portion et unité.
// - Tout aliment a au moins 1 ingrédient, de n'importe quel nom (aucun lien de nom avec l'aliment) : on le
//   choisit dans la liste ou on le crée à la volée (on choisit alors son unité). Pour un ingrédient existant,
//   l'unité est celle de l'ingrédient (elle se change dans l'onglet Ingrédients).
// - Dès qu'on ajoute un 2e ingrédient, l'aliment devient une recette : onChange() laisse le formulaire
//   cocher (et verrouiller) la case Recettes.
// editor.payload() renvoie [{ name, quantity, unit_id }] ; editor.error() un code d'erreur ou null.
function ingredientEditor({ initial, onChange }) {
  const defaultUnit = (units[0] || {}).id;
  const rows = initial.map((r) => ({
    name: r.name,
    quantity: r.quantity === null || r.quantity === undefined ? "" : String(r.quantity),
    unit_id: r.unit_id === undefined ? defaultUnit : r.unit_id,
  }));
  const known = (name) => ingredients.find((i) => i.name === name);
  const chosen = new Map(rows.map((r) => [r.name, { id: r.name, name: r.name }]));

  const root = el("div", "ing-editor");
  const list = el("div", "ing-rows");
  const picker = createPicker(ingredients.map((i) => ({ id: i.name, name: i.name })), chosen, () => onPick(), {
    allowNew: true, tags: false, placeholder: "Ajouter un ingrédient…",
    none: "Aucun ingrédient", empty: "Tapez le nom d'un ingrédient",
  });

  function changed() {
    picker.refresh();
    renderRows();
    onChange();
  }

  function onPick() {
    for (const name of chosen.keys()) {
      if (rows.some((r) => r.name === name)) continue;
      const k = known(name);
      rows.push({ name, quantity: "", unit_id: k ? k.unit_id : defaultUnit });
    }
    changed();
  }

  function remove(row) {
    rows.splice(rows.indexOf(row), 1);
    chosen.delete(row.name);
    changed();
  }

  const unitIdOf = (row) => { const k = known(row.name); return k ? k.unit_id : row.unit_id; };

  function renderRows() {
    list.replaceChildren();
    if (!rows.length) list.append(el("p", "ing-empty muted", "Ajoutez au moins un ingrédient."));
    for (const row of rows) {
      const line = el("div", "ing-row");
      const qty = el("input", "ing-qty");
      qty.type = "number";
      qty.min = "0";
      qty.step = "any";
      qty.inputMode = "decimal";
      qty.placeholder = "quantité";
      qty.value = row.quantity;
      qty.setAttribute("aria-label", `Quantité de ${row.name} pour 1 portion`);
      qty.addEventListener("input", () => { row.quantity = qty.value; });
      const bump = (dir) => () => {
        const cur = Number(String(row.quantity).replace(",", ".")) || 0;
        const v = Math.round((cur + dir * qtyStep(unitIdOf(row))) * 1000) / 1000;
        if (v > 0 && v <= 99999) { row.quantity = String(v); qty.value = row.quantity; }
      };
      const less = button("btn-step", "−", bump(-1));
      const more = button("btn-step", "+", bump(1));
      less.setAttribute("aria-label", "Diminuer la quantité");
      more.setAttribute("aria-label", "Augmenter la quantité");
      const unitBox = el("span", "ing-unit");
      const k = known(row.name);
      if (k) {
        unitBox.append(unitOf(k.unit_id).name);
      } else {
        const sel = el("select");
        for (const u of units) sel.append(new Option(u.name, u.id, false, u.id === row.unit_id));
        sel.setAttribute("aria-label", "Unité du nouvel ingrédient");
        sel.addEventListener("change", () => { row.unit_id = Number(sel.value); });
        unitBox.append(sel);
      }
      const del = button("ing-del", "✕", () => remove(row));
      del.setAttribute("aria-label", "Retirer cet ingrédient");
      line.append(el("span", "ing-name", row.name), less, qty, more, unitBox, del);
      list.append(line);
    }
  }

  root.append(el("small", "ing-hint", "Quantité pour 1 portion"), list, picker.el);
  renderRows();

  root.count = () => rows.length;
  // Texte tapé dans le champ d'ajout mais pas encore validé : on l'ajoute pour ne pas le perdre.
  root.flushPending = () => {
    const typed = picker.pending();
    if (typed && typed.length <= 60 && !rows.some((r) => r.name === typed)) {
      chosen.set(typed, { id: typed, name: typed });
      onPick();
    }
    picker.clear();
  };
  root.payload = () => rows.map((r) => ({
    name: r.name,
    quantity: r.quantity === "" ? null : Number(String(r.quantity).replace(",", ".")),
    unit_id: r.unit_id,
  }));
  root.error = () => (rows.some((r) => r.quantity !== "" && !(Number(r.quantity) > 0 && Number(r.quantity) <= 99999))
    ? "invalid_quantity" : null);
  return root;
}

// Case Recettes d'un jeu de cases à cocher de classes (null s'il n'y a pas de classe de type combo).
const recipeCheckbox = (checks) => {
  const combo = classes.find((c) => c.type === "combo");
  return combo ? checks.querySelector(`input[value="${combo.id}"]`) : null;
};

// À partir de 2 ingrédients, l'aliment est une recette : la case Recettes est cochée et verrouillée.
function syncRecipeBox(checks, editor) {
  const cb = recipeCheckbox(checks);
  if (!cb) return;
  if (editor.count() >= 2) { cb.checked = true; cb.disabled = true; } else cb.disabled = false;
}

// ------------------------------------------------------------ Édition repas
const mealDialog = $("meal-dialog");
const mealError = $("meal-error");
const mealSave = $("meal-save");
let mealTarget = null; // { date, slot, chosen, portions, existing }

// Section « Portions » du popup : pour chaque aliment choisi (une seule fois, même s'il a plusieurs classes),
// un multiplicateur (1 par défaut ; 0,5 ou 0,75 possibles) appliqué aux quantités de ses ingrédients.
function renderPortions() {
  const { chosen, portions } = mealTarget;
  for (const id of [...portions.keys()]) if (!chosen.has(id)) portions.delete(id);
  for (const id of chosen.keys()) if (!portions.has(id)) portions.set(id, 1);
  const box = $("meal-portions");
  box.replaceChildren();
  if (!chosen.size || !units.length) return; // sans unités, la base ne gère pas encore les portions
  box.append(el("h3", "portions-title", "Portions"));
  const names = [...chosen.values()].sort((a, b) => a.name.localeCompare(b.name, "fr"));
  for (const f of names) {
    const row = el("div", "portion-row");
    const input = el("input", "portion-input");
    input.type = "number";
    input.min = "0.5";
    input.max = "99";
    input.step = "0.5";
    input.inputMode = "decimal";
    input.setAttribute("aria-label", `Portions de ${f.name}`);
    input.value = portions.get(f.id);
    // Valeur brute : la validation (> 0, 99 au plus, 2 décimales) est faite à l'enregistrement.
    input.addEventListener("input", () => portions.set(f.id, input.value === "" ? NaN : Number(input.value)));
    const step = (delta) => () => {
      const cur = portions.get(f.id);
      const v = round2((cur > 0 ? cur : 1) + delta);
      if (v > 0 && v <= 99) { portions.set(f.id, v); input.value = v; }
    };
    row.append(el("span", "portion-name", f.name), button("btn-step", "−", step(-0.5)), input, button("btn-step", "+", step(0.5)));
    box.append(row);
  }
}

function openMeal(date, slot) {
  const existing = meals.get(`${date}|${slot}`) || [];
  const chosen = new Map(existing.map((f) => [f.id, f]));
  const portions = new Map(existing.map((f) => [f.id, f.portions]));
  const rows = $("meal-rows");
  rows.replaceChildren();
  const pickers = [];
  const refreshAll = () => { pickers.forEach((p) => p.refresh()); renderPortions(); };
  // Seules les classes de type composante ont une partie de repas (pas les classes combo, comme Recettes).
  for (const c of classes.filter((k) => k.type === "composante")) {
    const options = foods.filter((f) => f.class_ids.includes(c.id));
    const picker = createPicker(options, chosen, refreshAll);
    pickers.push(picker);
    const label = el("div", "part-label", c.part_name);
    rows.append(label, picker.el);
  }
  mealTarget = { date, slot, chosen, portions, existing };
  renderPortions();
  fillCopyChoices(mealTarget, refreshAll);
  $("meal-title").textContent = `${fmtDay(date)} · ${slot}`;
  mealError.textContent = "";
  mealSave.disabled = false;
  mealDialog.showModal();
  // Sans ça, le navigateur met le focus dans le 1er champ et ouvre sa liste déroulante d'office.
  $("meal-title").tabIndex = -1;
  $("meal-title").focus();
}

// Copie d'un repas existant : la liste propose tous les repas non vides présents en base
// (y compris ceux qui ne sont plus affichés dans les 15 derniers jours), sauf le repas en cours
// de modification. Choisir un repas remplace la sélection du popup par ses aliments ; rien
// n'est enregistré tant qu'on n'a pas cliqué sur « Enregistrer ».
const copySelect = $("meal-copy");

async function fillCopyChoices(target, refreshAll) {
  copySelect.disabled = true;
  copySelect.replaceChildren(new Option("Chargement…", ""));
  let rows;
  try {
    rows = await rpc("get_meals", { ...auth(), d_from: "1970-01-01", d_to: "2999-12-31" });
  } catch (e) {
    if (mealTarget === target) {
      copySelect.replaceChildren(new Option("Liste indisponible", ""));
      fail(e, mealError);
    }
    return;
  }
  if (mealTarget !== target || !mealDialog.open) return; // la fenêtre a changé entre-temps

  const sources = new Map(); // "2026-10-27|midi" -> [{ id, name, class_ids }]
  for (const r of rows) {
    const key = `${r.meal_date}|${r.slot}`;
    if (key === `${target.date}|${target.slot}`) continue;
    if (!sources.has(key)) sources.set(key, []);
    sources.get(key).push({ id: r.food_id, name: r.food_name, class_ids: r.class_ids || [], portions: Number(r.portions) || 1 });
  }

  copySelect.replaceChildren(new Option(sources.size ? "Choisir un repas…" : "Aucun repas à copier", ""));
  const days = [...new Set([...sources.keys()].map((k) => k.split("|")[0]))].sort().reverse();
  for (const day of days) {
    const group = document.createElement("optgroup");
    group.label = fmtDay(day);
    for (const slot of SLOTS) {
      const items = sources.get(`${day}|${slot}`);
      if (!items) continue;
      const text = `${slot} · ${items.map((f) => f.name).join(", ")}`;
      group.append(new Option(text.length > 70 ? `${text.slice(0, 69)}…` : text, `${day}|${slot}`));
    }
    copySelect.append(group);
  }
  copySelect.disabled = !sources.size;

  copySelect.onchange = () => {
    const items = sources.get(copySelect.value);
    if (!items) return;
    target.chosen.clear();
    target.portions.clear();
    for (const f of items) {
      target.chosen.set(f.id, foods.find((x) => x.id === f.id) || f);
      target.portions.set(f.id, f.portions); // le repas copié garde ses nombres de portions
    }
    refreshAll();
  };
}

$("meal-cancel").addEventListener("click", () => mealDialog.close());
closeOnBackdrop(mealDialog);

mealSave.addEventListener("click", async () => {
  const { date, slot, chosen, portions, existing } = mealTarget;
  const ids = [...chosen.keys()];
  const ps = ids.map((id) => (portions.has(id) ? portions.get(id) : 1));
  if (ps.some((p) => !(p > 0 && p <= 99 && round2(p) === p))) { mealError.textContent = errorText({ code: "invalid_portions" }); return; }
  // Le repas ne change pas si ni les aliments ni leurs portions ne changent.
  const signature = (pairs) => pairs.map(([id, p]) => `${id}:${p}`).sort().join();
  if (signature(ids.map((id, i) => [id, ps[i]])) === signature(existing.map((f) => [f.id, f.portions]))) { mealDialog.close(); return; }

  if (existing.length) {
    const ok = await confirmAction(
      ids.length ? "Êtes-vous sûr de vouloir modifier ce repas ?" : "Êtes-vous sûr de vouloir vider ce repas ?",
      `${fmtDay(date)} · ${slot}`
    );
    if (!ok) return;
  }
  await saveMeal(date, slot, ids, ps, mealError, mealSave);
});

// portions : tableau parallèle à ids (nombre de portions de chaque aliment dans le repas).
async function saveMeal(date, slot, ids, portions, errorTarget, btn) {
  if (btn) btn.disabled = true;
  try {
    // Les portions ne sont envoyées que si la base les gère (migration v2-3 faite : les unités existent).
    await rpc("set_meal", { ...auth(), d: date, s: slot, food_ids: ids, ...(units.length ? { portions } : {}) });
    if (mealDialog.open) mealDialog.close();
    statusEl.textContent = "";
    await reloadMeals();
  } catch (e) {
    fail(e, errorTarget);
  }
  if (btn) btn.disabled = false;
}

async function clearMeal(date, slot) {
  const ok = await confirmAction("Êtes-vous sûr de vouloir vider ce repas ?", `${fmtDay(date)} · ${slot}`);
  if (ok) await saveMeal(date, slot, [], [], statusEl, null);
}

// ------------------------------------------------- Contraintes d'un jour (mode write)
const dayDialog = $("day-dialog");
const dayChecks = $("day-checks");
const dayError = $("day-error");
const daySave = $("day-save");
let dayTarget = null; // { date, before, box }

function openDayConstraints(date) {
  const before = dayConstraints.get(date) || [];
  $("day-title").textContent = fmtDay(date);
  dayError.textContent = "";
  daySave.disabled = false;
  let box = null;
  if (constraints.length) {
    // Une contrainte qui a un effet l'indique à côté de son nom.
    box = checkBoxes(constraints.map((k) => ({ id: k.id, name: k.name, meta: (effectOf(k) || {}).name })), new Set(before));
    dayChecks.replaceChildren(box);
  } else {
    dayChecks.replaceChildren(el("p", "empty", "Aucune contrainte n'est définie. Un admin peut en créer dans l'onglet Admin."));
  }
  dayTarget = { date, before, box };
  dayDialog.showModal();
}

$("day-cancel").addEventListener("click", () => dayDialog.close());
closeOnBackdrop(dayDialog);

daySave.addEventListener("click", async () => {
  const { date, before, box } = dayTarget;
  if (!box) { dayDialog.close(); return; }
  const ids = box.values();
  if (ids.length === before.length && ids.every((id) => before.includes(id))) { dayDialog.close(); return; }
  // Retirer toutes les contraintes d'un jour est une suppression : avec confirmation.
  if (!ids.length) {
    const ok = await confirmAction("Êtes-vous sûr de vouloir retirer toutes les contraintes de ce jour ?", fmtDay(date));
    if (!ok) return;
  }
  daySave.disabled = true;
  try {
    await rpc("set_day_constraints", { ...auth(), d: date, cids: ids });
    dayDialog.close();
    statusEl.textContent = "";
    await reloadMeals();
  } catch (e) {
    fail(e, dayError);
  }
  daySave.disabled = false;
});

// ------------------------------------------------------------------- Admin
// Cases à cocher : items = [{ id, name }] ; box.values() renvoie les identifiants cochés.
function checkBoxes(items, selected) {
  const box = el("div", "class-checks");
  for (const it of items) {
    const label = el("label", "class-check");
    const cb = el("input");
    cb.type = "checkbox";
    cb.value = it.id;
    cb.checked = selected.has(it.id);
    label.append(cb, document.createTextNode(it.name));
    if (it.meta) label.append(el("small", "check-meta", it.meta));
    box.append(label);
  }
  box.values = () => [...box.querySelectorAll("input:checked")].map((i) => Number(i.value));
  return box;
}

// Cases à cocher des classes d'un aliment.
function classChecks(selected) {
  return checkBoxes(classes, selected);
}

// Une recette est un aliment qui a une classe de type combo (Recettes).
const isRecipe = (cids) => cids.some((id) => (classes.find((c) => c.id === id) || {}).type === "combo");

// Contrôle fait avant l'envoi (la base refait les mêmes contrôles) : renvoie un code d'erreur ou null.
function foodFormError(cids, ings) {
  if (!cids.length) return "invalid_classes";
  if (!cids.some((id) => (classes.find((c) => c.id === id) || {}).type === "composante")) return "class_component_required";
  // Tout aliment a au moins 1 ingrédient (sauf tant que la base n'a pas les unités : elle crée alors celui d'un aliment simple).
  if (!ings.length && (units.length || isRecipe(cids))) return "ingredients_required";
  return null;
}

// ------------------------------------------------------------ Filtres de l'Admin
// Chaque liste de l'Admin a une recherche et un bouton « + Filtre » : on choisit les filtres à appliquer, puis leurs
// valeurs. Les filtres actifs s'affichent en puces. Ils se combinent en ET ; les valeurs d'un filtre à choix multiples
// se combinent en OU (aucune valeur choisie : tout passe). Gardés par section jusqu'au rechargement ou à la déconnexion.
let adminFilters = {}; // section -> { q: recherche, f: { clé de filtre: [valeurs choisies en texte] } }
const filterState = (section) => (adminFilters[section] = adminFilters[section] || { q: "", f: {} });

// Filtre « utilisation » (labels : [utilisé, non utilisé]).
const usageDef = (labels) => ({ k: "usage", label: "Utilisation", type: "one", options: [["used", labels[0]], ["unused", labels[1]]] });
const hasUsage = (st, uses) => {
  const v = (st.f.usage || [])[0];
  return !v || (v === "used") === (Number(uses) > 0);
};
// Vrai si aucune valeur n'est choisie pour le filtre k, ou si l'une des valeurs de l'élément est choisie.
const inFilter = (st, k, values) => {
  const s = st.f[k] || [];
  return !s.length || values.some((v) => s.includes(String(v)));
};

// Barre de recherche et de filtres d'une section. defs : [{ k, label, type: "one" | "multi", options: [[valeur, texte]] }].
// onChange() est appelé à chaque changement ; bar.setCount(n) affiche le nombre de résultats ; bar.isFiltering() dit
// si une recherche ou un filtre est actif.
function filterBar(section, defs, onChange) {
  const st = filterState(section);
  const root = el("div", "fbar");
  const search = el("input", "search");
  search.type = "search";
  search.placeholder = "Rechercher";
  search.value = st.q;
  search.addEventListener("input", () => { st.q = search.value; draw(); onChange(); });
  const chips = el("div", "fchips");
  const panel = el("div", "fpanel");
  const info = el("p", "fcount");
  root.append(search, chips, panel, info);
  let open = null; // null | "+" (liste des filtres) | clé du filtre dont on choisit les valeurs
  let count = 0;

  const chosen = (k) => st.f[k] || [];
  const activeCount = () => (st.q.trim() ? 1 : 0) + defs.filter((d) => !d.sort && chosen(d.k).length).length;
  root.isFiltering = () => activeCount() > 0;
  root.setCount = (n) => { count = n; draw(); };

  function chipText(d) {
    const s = chosen(d.k);
    if (!s.length) return `${d.label} : …`;
    const first = d.options.find((o) => o[0] === s[0]);
    return `${d.label} : ${first ? first[1] : ""}${s.length > 1 ? ` +${s.length - 1}` : ""}`;
  }

  function draw() {
    chips.replaceChildren();
    panel.replaceChildren();
    const active = defs.filter((d) => st.f[d.k] !== undefined);
    const free = defs.filter((d) => !d.sort && st.f[d.k] === undefined);
    const sortDef = defs.find((d) => d.sort); // le tri a son propre bouton, séparé des filtres
    for (const d of active) {
      const chip = el("span", "fchip" + (open === d.k ? " open" : ""));
      const x = button("fchip-x", "✕", () => { delete st.f[d.k]; if (open === d.k) open = null; draw(); onChange(); });
      x.setAttribute("aria-label", d.sort ? "Retirer le tri" : `Retirer le filtre ${d.label}`);
      chip.append(button("fchip-main", chipText(d), () => { open = open === d.k ? null : d.k; draw(); }), x);
      chips.append(chip);
    }
    if (free.length) chips.append(button("fadd" + (open === "+" ? " open" : ""), "+ Filtre ▾", () => { open = open === "+" ? null : "+"; draw(); }));
    if (sortDef && st.f[sortDef.k] === undefined) {
      chips.append(button("fadd" + (open === sortDef.k ? " open" : ""), "+ Tri ▾", () => { open = open === sortDef.k ? null : sortDef.k; draw(); }));
    }
    if (active.length || st.q.trim()) {
      chips.append(button("flink", "Tout effacer", () => { st.q = ""; st.f = {}; search.value = ""; open = null; draw(); onChange(); }));
    }
    if (open === "+") {
      panel.append(el("p", "fpanel-title", "Filtrer par…"));
      for (const d of free) panel.append(button("fopt", d.label, () => { st.f[d.k] = []; open = d.k; draw(); }));
    } else if (open) {
      const d = defs.find((x) => x.k === open);
      panel.append(el("p", "fpanel-title", d.sort ? "Trier par… (sans tri : A → Z)" : d.label + (d.type === "multi" ? " (plusieurs choix : l'un ou l'autre)" : "")));
      for (const [value, text] of d.options) {
        const on = chosen(d.k).includes(value);
        const opt = button("fopt" + (on ? " sel" : ""), "", () => {
          const s = chosen(d.k).slice();
          if (d.type === "one") st.f[d.k] = [value];
          else { const i = s.indexOf(value); if (i >= 0) s.splice(i, 1); else s.push(value); st.f[d.k] = s; }
          if (d.sort) open = null; // un tri se choisit en un clic
          draw();
          onChange();
        });
        opt.append(el("span", "fmark " + (d.type === "multi" ? "cb" : "rd"), on ? "✓" : ""), document.createTextNode(text));
        panel.append(opt);
      }
      if (!d.sort) panel.append(button("fdone", "OK", () => { if (!chosen(d.k).length) delete st.f[d.k]; open = null; draw(); onChange(); }));
    }
    const a = activeCount();
    info.textContent = `${count} résultat${count > 1 ? "s" : ""}` + (a ? ` · ${a} filtre${a > 1 ? "s" : ""}` : "");
  }
  draw();
  return root;
}

function renderAdmin() {
  const root = $("tab-admin");
  if (role !== "admin") { root.replaceChildren(); return; }
  root.replaceChildren();
  const seg = el("div", "segment");
  for (const [key, label] of [["foods", "Aliments"], ["ingredients", "Ingrédients"], ["constraints", "Contraintes"], ["categories", "Catégories"]]) {
    seg.append(button("seg" + (adminSection === key ? " on" : ""), label, () => {
      adminSection = key;
      renderAdmin();
    }));
  }
  root.append(seg);
  if (adminSection === "constraints") renderConstraintsAdmin(root);
  else if (adminSection === "categories") renderCategoriesAdmin(root);
  else if (adminSection === "ingredients") renderIngredientsAdmin(root);
  else renderFoodsAdmin(root);
}

function renderFoodsAdmin(root) {

  // Nouvel aliment : un popup (le même que pour la modification) avec un nom, une ou plusieurs classes
  // (la classe affichée est cochée d'office) et les ingrédients.
  root.append(button("btn-primary admin-add", "+ Ajouter un aliment", () => openFoodDialog(null)));

  const st = filterState("foods");
  const bar = filterBar("foods", [
    usageDef(["Utilisés", "Non utilisés"]),
    { k: "cls", label: "Classe", type: "multi", options: classes.map((c) => [String(c.id), c.name]) },
  ], () => fill());
  const list = el("ul", "food-list");
  root.append(bar, list);
  const fill = () => {
    const q = st.q.trim();
    const rows = foods
      .filter((f) => fold(f.name).includes(fold(q)) && hasUsage(st, f.uses) && inFilter(st, "cls", f.class_ids))
      .sort((a, b) => a.name.localeCompare(b.name, "fr"));
    bar.setCount(rows.length);
    list.replaceChildren();
    if (!rows.length) {
      const li = el("li", "empty", bar.isFiltering() ? "Aucun résultat" : "Aucun aliment pour le moment");
      list.append(li);
      return;
    }
    for (const f of rows) {
      const li = el("li", "food-row");
      const name = el("span", "fname", f.name);
      const others = f.class_ids
        .map((id) => (classes.find((c) => c.id === id) || {}).name).filter(Boolean);
      // Les classes de l'aliment : des pastilles à droite du nom.
      for (const cname of others) name.append(el("span", "cls-pill", cname));
      const uses = Number(f.uses) || 0;
      name.append(el("small", "fmeta", uses ? `utilisé dans ${uses} repas` : "non utilisé"));
      // Pour retrouver ce qu'il reste à remplir : au moins une quantité d'ingrédient n'est pas définie.
      if ((f.ingredients || []).some((i) => i.quantity === null)) name.append(el("small", "fmeta qty-missing", "quantité à définir"));
      li.append(name);
      li.append(button("btn-sm", "Modifier", () => openFoodDialog(f)));
      li.append(button("btn-sm danger", "Supprimer", () => deleteFood(f)));
      list.append(li);
    }
  };
  fill();
}

// ------------------------------------------- Suppression refusée : qu'est-ce qui l'utilise ?
// Fenêtre d'information (un seul bouton) qui liste les repas, aliments ou jours qui utilisent
// l'élément qu'on voulait supprimer.
const usageDialog = $("usage-dialog");
closeOnBackdrop(usageDialog);
$("usage-close").addEventListener("click", () => usageDialog.close());

function showUsage(title, name, hint, lines) {
  $("usage-title").textContent = title;
  $("usage-name").textContent = name;
  $("usage-hint").textContent = hint;
  $("usage-list").replaceChildren(...lines.map((t) => el("li", "", t)));
  usageDialog.showModal();
}

// Un élément utilisé ne peut pas être supprimé : inutile de demander une confirmation, on
// tente la suppression (la base refuse et renvoie la liste) et on montre ce qui l'utilise.
async function deleteFood(f) {
  if (!(Number(f.uses) > 0)) {
    const ok = await confirmAction("Êtes-vous sûr de vouloir supprimer cet aliment ?", f.name);
    if (!ok) return;
  }
  try {
    await rpc("delete_food", { ...auth(), fid: f.id });
    statusEl.textContent = "";
    await loadFoodsAndIngredients();
    renderAdmin();
  } catch (e) {
    if (e.code === "food_in_use") {
      const { n, items } = usageOf(e);
      showUsage("Suppression impossible", f.name,
        `Cet aliment est utilisé dans ${n || items.length || "plusieurs"} repas. Retirez-le de ces repas avant de le supprimer.`,
        items.map((it) => { const [d, slot] = it.split("|"); return `${fmtDay(d)} · ${slot}`; }));
    } else {
      fail(e);
    }
  }
}

// ------------------------------------------------- Admin : gestion des ingrédients
// Liste déroulante des unités (select.value : identifiant) ; `selected` : unité présélectionnée (la 1re par défaut).
function unitSelect(selected) {
  const sel = el("select", "unit-select");
  for (const u of units) sel.append(new Option(u.name, u.id, false, u.id === selected));
  return sel;
}

// Liste déroulante des catégories de courses d'un ingrédient : « Aucune (Autre) » puis les catégories (hors « Autre »).
function categorySelect(selected) {
  const sel = el("select", "unit-select");
  sel.append(new Option("Aucune (Autre)", "", false, selected === null || selected === undefined));
  for (const c of catsByName()) if (!c.is_default) sel.append(new Option(c.name, c.id, false, c.id === selected));
  return sel;
}

// Paramètre « unité » des appels (omis tant que la base n'a pas les unités).
const unitArg = (uid) => (units.length ? { uid } : {});

// Ingrédients envoyés pour un aliment : lignes { name, quantity, unit_id }, ou de simples noms tant que la base
// n'a pas les quantités (ancien format).
const ingsArg = (ings) => (units.length ? ings : ings.map((i) => i.name));

function renderIngredientsAdmin(root) {
  // Nouvel ingrédient : un popup (le même que pour la modification) avec un nom et une unité.
  root.append(button("btn-primary admin-add", "+ Ajouter un ingrédient", () => openIngredientDialog(null)));

  const st = filterState("ingredients");
  const defs = [usageDef(["Utilisés", "Non utilisés"])];
  if (shopCats.length) {
    defs.push({ k: "cat", label: "Catégorie de courses", type: "multi",
      options: [["none", "Sans catégorie"], ...catsByName().filter((c) => !c.is_default).map((c) => [String(c.id), c.name])] });
  }
  if (units.length) defs.push({ k: "unit", label: "Unité de mesure", type: "multi", options: units.map((u) => [String(u.id), u.name]) });
  const bar = filterBar("ingredients", defs, () => fill());
  const list = el("ul", "food-list");
  root.append(bar, list);
  const fill = () => {
    const q = st.q.trim();
    const rows = ingredients
      .filter((i) => fold(i.name).includes(fold(q)) && hasUsage(st, i.uses)
        && inFilter(st, "cat", [i.category_id == null ? "none" : i.category_id])
        && inFilter(st, "unit", i.unit_id === undefined ? [] : [i.unit_id]))
      .sort((a, b) => a.name.localeCompare(b.name, "fr"));
    bar.setCount(rows.length);
    list.replaceChildren();
    if (!rows.length) {
      list.append(el("li", "empty", bar.isFiltering() ? "Aucun résultat" : "Aucun ingrédient pour le moment"));
      return;
    }
    for (const i of rows) {
      const li = el("li", "food-row");
      const name = el("span", "fname", i.name);
      if (i.unit_id !== undefined) name.append(el("span", "cls-pill", unitOf(i.unit_id).name)); // son unité
      if (i.category_id) name.append(el("span", "cls-pill", shopCatOf(i.category_id).name)); // sa catégorie de courses
      const uses = Number(i.uses) || 0;
      name.append(el("small", "fmeta", uses ? `utilisé par ${uses} aliment${uses > 1 ? "s" : ""}` : "non utilisé"));
      li.append(name);
      li.append(button("btn-sm", "Modifier", () => openIngredientDialog(i)));
      li.append(button("btn-sm danger", "Supprimer", () => deleteIngredient(i)));
      list.append(li);
    }
  };
  fill();
}

async function deleteIngredient(i) {
  if (!(Number(i.uses) > 0)) {
    const ok = await confirmAction("Êtes-vous sûr de vouloir supprimer cet ingrédient ?", i.name);
    if (!ok) return;
  }
  try {
    await rpc("delete_ingredient", { ...auth(), iid: i.id });
    statusEl.textContent = "";
    await loadIngredients();
    renderAdmin();
  } catch (e) {
    if (e.code === "ingredient_in_use") {
      const { n, items } = usageOf(e);
      showUsage("Suppression impossible", i.name,
        `Cet ingrédient est utilisé par ${n || items.length || "plusieurs"} aliment(s). Retirez-le de ces aliments avant de le supprimer.`,
        items);
    } else {
      fail(e);
    }
  }
}

const ingredientDialog = $("ingredient-dialog");
const ingredientError = $("ingredient-error");
const ingredientName = $("ingredient-name");
let editingIngredient = null;

// Popup d'un ingrédient : i = l'ingrédient à modifier, ou null pour en ajouter un (unité : g par défaut).
function openIngredientDialog(i) {
  editingIngredient = i;
  $("ingredient-title").textContent = i ? "Modifier l'ingrédient" : "Nouvel ingrédient";
  $("ingredient-save").textContent = i ? "Enregistrer" : "Ajouter";
  ingredientName.value = i ? i.name : "";
  $("ingredient-unit").replaceChildren(unitSelect(i ? i.unit_id : undefined));
  $("ingredient-category").replaceChildren(categorySelect(i ? i.category_id : null));
  $("ingredient-category-row").hidden = !shopCats.length;
  ingredientError.textContent = "";
  ingredientDialog.showModal();
  ingredientName.focus();
  if (i) ingredientName.select();
}

$("ingredient-cancel").addEventListener("click", () => ingredientDialog.close());
closeOnBackdrop(ingredientDialog);
ingredientName.addEventListener("keydown", (e) => {
  if (e.key === "Enter") { e.preventDefault(); $("ingredient-save").click(); }
});
$("ingredient-save").addEventListener("click", async () => {
  const name = ingredientName.value.trim().toLowerCase();
  if (!name) { ingredientError.textContent = errorText({ code: "invalid_name" }); return; }
  const uid = Number($("ingredient-unit").querySelector("select").value);
  const catValue = $("ingredient-category").querySelector("select").value;
  const cid = catValue === "" ? null : Number(catValue);
  const catArg = shopCats.length ? { cid } : {};
  if (!editingIngredient) {
    const btn = $("ingredient-save");
    btn.disabled = true;
    try {
      await rpc("add_ingredient", { ...auth(), n: name, ...unitArg(uid), ...catArg });
      ingredientDialog.close();
      statusEl.textContent = "";
      await Promise.all([loadIngredients(), loadShop()]);
      renderAdmin();
    } catch (e) {
      fail(e, ingredientError);
    }
    btn.disabled = false;
    return;
  }
  const unitChanged = units.length > 0 && uid !== editingIngredient.unit_id;
  const catChanged = shopCats.length > 0 && cid !== (editingIngredient.category_id === undefined ? null : editingIngredient.category_id);
  if (name === editingIngredient.name && !unitChanged && !catChanged) { ingredientDialog.close(); return; }
  // Changer l'unité ne convertit pas les quantités déjà saisies : on demande confirmation si elles existent.
  if (unitChanged && Number(editingIngredient.uses) > 0) {
    const ok = await confirmAction("Changer l'unité de cet ingrédient ?",
      "Les quantités déjà saisies gardent leur valeur (aucune conversion) : pensez à les vérifier.");
    if (!ok) return;
  }
  const btn = $("ingredient-save");
  btn.disabled = true;
  try {
    await rpc("update_ingredient", { ...auth(), iid: editingIngredient.id, n: name, ...unitArg(uid), ...catArg });
    ingredientDialog.close();
    statusEl.textContent = "";
    await Promise.all([loadFoodsAndIngredients(), loadShop()]); // les recettes qui l'utilisent suivent
    renderAdmin();
  } catch (e) {
    fail(e, ingredientError);
  }
  btn.disabled = false;
});

// ---------------------------------------------------- Admin : gestion des contraintes
// Choix de l'effet d'une contrainte : « Aucun effet » et un choix par effet existant, exclusifs. La
// description de chaque effet est écrite sous son nom (lisible sans survol, smartphone compris).
// choice.value() renvoie l'identifiant de l'effet choisi, ou null.
let effectChoiceCount = 0;
function effectChoice(selectedId) {
  const box = el("div", "effect-choice");
  box.value = () => null;
  if (!effects.length) { box.hidden = true; return box; } // base pas encore à jour : pas d'effets
  const group = `effect-${effectChoiceCount++}`;
  const options = [{ id: null, name: "Aucun effet", description: "La contrainte est purement informative." }, ...effects];
  for (const o of options) {
    const label = el("label", "effect-opt");
    const radio = el("input");
    radio.type = "radio";
    radio.name = group;
    radio.value = o.id === null ? "" : String(o.id);
    radio.checked = o.id === (selectedId === undefined ? null : selectedId);
    const text = el("span", "effect-text");
    text.append(el("span", "effect-name", o.name), el("small", "check-meta", o.description));
    label.append(radio, text);
    box.append(label);
  }
  box.value = () => {
    const c = box.querySelector("input:checked");
    return c && c.value !== "" ? Number(c.value) : null;
  };
  return box;
}

// Paramètre « effet » des appels : omis tant que la base n'a pas les effets (ancienne signature).
const effectArg = (eid) => (effects.length ? { eid } : {});

function renderConstraintsAdmin(root) {
  // Nouvelle contrainte : un popup (le même que pour la modification) avec un nom et un effet.
  root.append(button("btn-primary admin-add", "+ Ajouter une contrainte", () => openConstraintDialog(null)));

  const st = filterState("constraints");
  const bar = filterBar("constraints", [usageDef(["Utilisées", "Non utilisées"])], () => fill());
  const list = el("ul", "food-list");
  root.append(bar, list);
  const fill = () => {
    const q = st.q.trim();
    const rows = constraints.filter((k) => fold(k.name).includes(fold(q)) && hasUsage(st, k.uses));
    bar.setCount(rows.length);
    list.replaceChildren();
    if (!rows.length) {
      list.append(el("li", "empty", bar.isFiltering() ? "Aucun résultat" : "Aucune contrainte pour le moment"));
      return;
    }
    for (const k of rows) {
      const li = el("li", "food-row");
      const name = el("span", "fname", k.name);
      const uses = Number(k.uses) || 0;
      // L'effet de la contrainte : une pastille à droite du nom. Survol (ordinateur) : infobulle ; clic ou
      // appui (smartphone compris) : la description s'affiche sous le nom, un second appui la masque.
      const eff = effectOf(k);
      let desc = null;
      if (eff) {
        const pill = button("cls-pill effect-pill", eff.name, () => desc.classList.toggle("open"));
        pill.title = eff.description;
        name.append(pill);
        desc = el("small", "fmeta effect-desc", eff.description);
      }
      name.append(el("small", "fmeta", uses ? `attribuée à ${uses} jour${uses > 1 ? "s" : ""}` : "non attribuée"));
      if (desc) name.append(desc);
      li.append(name);
      li.append(button("btn-sm", "Modifier", () => openConstraintDialog(k)));
      li.append(button("btn-sm danger", "Supprimer", () => deleteConstraint(k)));
      list.append(li);
    }
  };
  fill();
}

async function deleteConstraint(k) {
  if (!(Number(k.uses) > 0)) {
    const ok = await confirmAction("Êtes-vous sûr de vouloir supprimer cette contrainte ?", k.name);
    if (!ok) return;
  }
  try {
    await rpc("delete_constraint", { ...auth(), cid: k.id });
    statusEl.textContent = "";
    await loadConstraints();
    render();
  } catch (e) {
    if (e.code === "constraint_in_use") {
      const { n, items } = usageOf(e);
      showUsage("Suppression impossible", k.name,
        `Cette contrainte est attribuée à ${n || items.length || "plusieurs"} jour(s). Retirez-la de ces jours avant de la supprimer.`,
        items.map((d) => fmtDay(d)));
    } else {
      fail(e);
    }
  }
}

const constraintDialog = $("constraint-dialog");
const constraintError = $("constraint-error");
const constraintName = $("constraint-name");
let editingConstraint = null;
let editEffect = null;

// Popup d'une contrainte : k = la contrainte à modifier, ou null pour en ajouter une (sans effet par défaut).
function openConstraintDialog(k) {
  editingConstraint = k;
  $("constraint-title").textContent = k ? "Modifier la contrainte" : "Nouvelle contrainte";
  $("constraint-save").textContent = k ? "Enregistrer" : "Ajouter";
  constraintName.value = k ? k.name : "";
  editEffect = effectChoice(k && k.effect_id !== undefined ? k.effect_id : null);
  $("constraint-effects").replaceChildren(editEffect);
  constraintError.textContent = "";
  constraintDialog.showModal();
  constraintName.focus();
  if (k) constraintName.select();
}

$("constraint-cancel").addEventListener("click", () => constraintDialog.close());
closeOnBackdrop(constraintDialog);
constraintName.addEventListener("keydown", (e) => {
  if (e.key === "Enter") { e.preventDefault(); $("constraint-save").click(); }
});
$("constraint-save").addEventListener("click", async () => {
  const name = constraintName.value.trim();
  if (!name) { constraintError.textContent = errorText({ code: "invalid_name" }); return; }
  const eid = editEffect.value();
  if (!editingConstraint) {
    const btn = $("constraint-save");
    btn.disabled = true;
    try {
      await rpc("add_constraint", { ...auth(), n: name, ...effectArg(eid) });
      constraintDialog.close();
      statusEl.textContent = "";
      await loadConstraints();
      render();
    } catch (e) {
      fail(e, constraintError);
    }
    btn.disabled = false;
    return;
  }
  const oldEid = editingConstraint.effect_id === undefined ? null : editingConstraint.effect_id;
  if (name === editingConstraint.name && eid === oldEid) { constraintDialog.close(); return; }
  const btn = $("constraint-save");
  btn.disabled = true;
  try {
    await rpc("update_constraint", { ...auth(), cid: editingConstraint.id, n: name, ...effectArg(eid) });
    constraintDialog.close();
    statusEl.textContent = "";
    await loadConstraints();
    render();
  } catch (e) {
    if (e.code === "effect_conflict") {
      // L'effet bloquerait des repas déjà remplis : on montre les jours concernés.
      const { n, slot, items } = usageOf(e);
      constraintDialog.close();
      showUsage("Modification impossible", name,
        `Cette contrainte est attribuée à ${n || items.length} jour(s) dont le repas du ${slot} est déjà rempli. Videz ces repas avant de lui donner cet effet.`,
        items.map((d) => fmtDay(d)));
    } else {
      fail(e, constraintError);
    }
  }
  btn.disabled = false;
});

const foodDialog = $("food-dialog");
const foodEditError = $("food-edit-error");
let editingFood = null;
let editChecks = null;
let editIngredients = null;

// Popup d'un aliment : f = l'aliment à modifier, ou null pour en ajouter un.
function openFoodDialog(f) {
  editingFood = f;
  $("food-dialog-title").textContent = f ? "Modifier l'aliment" : "Nouvel aliment";
  $("food-edit-save").textContent = f ? "Enregistrer" : "Ajouter";
  $("food-edit-name").value = f ? f.name : "";
  const classIds = f ? f.class_ids : []; // à l'ajout : aucune classe cochée, on choisit
  editChecks = classChecks(new Set(classIds));
  $("food-edit-classes").replaceChildren(editChecks);
  // Ingrédients avec leur quantité pour 1 portion (au moins 1 pour tout aliment) ; à partir de 2 ingrédients
  // la case Recettes se coche toute seule.
  editIngredients = ingredientEditor({
    initial: f ? f.ingredients || [] : [],
    onChange: () => syncRecipeBox(editChecks, editIngredients),
  });
  $("food-edit-ingredients").replaceChildren(editIngredients);
  syncRecipeBox(editChecks, editIngredients);
  foodEditError.textContent = "";
  foodDialog.showModal();
  if (!f) $("food-edit-name").focus();
}

$("food-edit-cancel").addEventListener("click", () => foodDialog.close());
closeOnBackdrop(foodDialog);
$("food-edit-save").addEventListener("click", async () => {
  const name = $("food-edit-name").value.trim().toLowerCase();
  if (!name) { foodEditError.textContent = errorText({ code: "invalid_name" }); return; }
  editIngredients.flushPending();
  const cids = editChecks.values();
  const ings = editIngredients.payload();
  const problem = editIngredients.error() || foodFormError(cids, ings);
  if (problem) { foodEditError.textContent = errorText({ code: problem }); return; }
  const btn = $("food-edit-save");
  btn.disabled = true;
  try {
    if (editingFood) await rpc("update_food", { ...auth(), fid: editingFood.id, n: name, cids, ings: ingsArg(ings) });
    else await rpc("add_food", { ...auth(), n: name, cids, ings: ingsArg(ings) });
    foodDialog.close();
    statusEl.textContent = "";
    await loadAll();
  } catch (e) {
    fail(e, foodEditError);
  }
  btn.disabled = false;
});

// ------------------------------------------------------------ Listes de courses
// Deux listes (France, Suisse) d'éléments { id, list, name, category_id, quantity, unit_id, checked }, partagées
// entre tous les appareils. Lecture pour tous les rôles ; write et admin modifient. Aucun lien avec les ingrédients
// (la liste France se génère à partir des repas : voir openShopGenerate).
const canEditShop = () => role === "write" || role === "admin";
const shopCatOf = (id) => shopCats.find((c) => c.id === id) || { name: "Autre", pos_carrefour: 999, pos_coop: 999 };
const defaultShopCat = () => shopCats.find((c) => c.is_default) || shopCats[0];
const otherShopList = (k) => (k === "france" ? "suisse" : "france");
const plural = (n, one, many) => (n > 1 ? many : one);
const catsByName = () => [...shopCats].sort((a, b) => a.name.localeCompare(b.name, "fr"));

// strict : une erreur est remontée (actualisation) ; sinon un échec laisse les listes vides (base pas encore à jour).
async function loadShop(strict = false) {
  const get = (name) => (strict ? rpc(name, auth()) : optional(rpc(name, auth())));
  const [cats, items] = await Promise.all([get("get_shop_categories"), get("get_shop_items")]);
  shopCats = cats;
  shopItems = items.map((i) => ({ ...i, quantity: i.quantity === null ? null : Number(i.quantity) }));
}

async function refreshShop() {
  try {
    await loadShop(true);
    statusEl.textContent = "";
    renderShop();
    renderAdmin();
  } catch (e) {
    fail(e);
  }
}

// « 250 g », « 3 pièces », « 2 » (sans unité) ou rien (sans quantité).
const fmtShopQty = (it) => (it.quantity === null ? "" : it.unit_id ? fmtQty(it.quantity, it.unit_id) : fmtNum(it.quantity));

function sortedShopItems(list) {
  const items = shopItems.filter((i) => i.list === list);
  const byName = (a, b) => fold(a.name).localeCompare(fold(b.name), "fr") || (a.quantity || 0) - (b.quantity || 0) || a.id - b.id;
  const mode = shopSorts[list];
  if (mode === "date") return items.sort((a, b) => a.id - b.id);
  if (mode === "custom") {
    const pos = SHOP_LISTS[list].pos;
    return items.sort((a, b) => shopCatOf(a.category_id)[pos] - shopCatOf(b.category_id)[pos] || byName(a, b));
  }
  return items.sort(byName);
}

function renderShop() {
  $("tab-shop-btn").hidden = !shopCats.length;
  const root = $("tab-shop");
  root.replaceChildren();
  if (!shopCats.length) {
    if (currentTab === "shop") switchTab("home");
    return;
  }
  const editable = canEditShop();
  const conf = SHOP_LISTS[shopList];
  const seg = el("div", "segment");
  for (const k of Object.keys(SHOP_LISTS)) {
    const n = shopItems.filter((i) => i.list === k).length;
    seg.append(button("seg" + (k === shopList ? " on" : ""), `${SHOP_LISTS[k].label} (${n})`, () => { shopList = k; renderShop(); }));
  }
  root.append(seg);

  const actions = el("div", "shop-actions");
  if (editable) {
    if (shopList === "france") actions.append(button("btn-primary", "Générer", openShopGenerate));
    actions.append(button("btn-primary", "+ Ajouter", () => openShopEdit(null)));
    actions.append(button("btn-sm danger", "Vider", clearShopList));
  }
  actions.append(button("btn-sm", "Actualiser", refreshShop));
  root.append(actions);

  const mode = shopSorts[shopList];
  const sorts = el("div", "shop-sorts");
  sorts.append(el("span", "shop-sorts-label", "Tri"));
  for (const [key, label] of [["alpha", "A → Z"], ["date", "Date d'ajout"], ["custom", conf.custom]]) {
    sorts.append(button("chip" + (mode === key ? " on" : ""), label, () => {
      shopSorts[shopList] = key;
      saveShopSorts();
      renderShop();
    }));
  }
  root.append(sorts);

  const items = sortedShopItems(shopList);
  const list = el("ul", "shop-list");
  if (!items.length) list.append(el("li", "empty", "Cette liste est vide."));
  let lastCat = null;
  for (const it of items) {
    if (mode === "custom" && it.category_id !== lastCat) {
      list.append(el("li", "shop-head", shopCatOf(it.category_id).name));
      lastCat = it.category_id;
    }
    list.append(shopRow(it, mode !== "custom", editable));
  }
  root.append(list);
}

function shopRow(it, showCategory, editable) {
  const li = el("li", "shop-item" + (it.checked ? " done" : ""));
  const cb = el("input");
  cb.type = "checkbox";
  cb.checked = it.checked;
  cb.disabled = !editable;
  cb.setAttribute("aria-label", `${it.name} : acheté`);
  cb.addEventListener("change", () => toggleShopItem(it, cb.checked, li, cb));
  const main = el(editable ? "button" : "div", "shop-main");
  if (editable) {
    main.type = "button";
    main.addEventListener("click", () => openShopItemMenu(it));
  }
  const text = el("span", "shop-text");
  text.append(el("span", "shop-name", it.name));
  if (showCategory) text.append(el("small", "shop-cat", shopCatOf(it.category_id).name));
  main.append(text, el("span", "shop-qty", fmtShopQty(it)));
  li.append(cb, main);
  return li;
}

// Cocher ou décocher : sans confirmation (on le fait souvent en magasin). Annulé à l'écran si la base refuse.
async function toggleShopItem(it, checked, li, cb) {
  it.checked = checked;
  li.classList.toggle("done", checked);
  try {
    await rpc("set_shop_item_checked", { ...auth(), iid: it.id, chk: checked });
  } catch (e) {
    it.checked = !checked;
    li.classList.toggle("done", !checked);
    cb.checked = !checked;
    fail(e);
  }
}

async function clearShopList() {
  const label = SHOP_LISTS[shopList].label;
  const n = shopItems.filter((i) => i.list === shopList).length;
  if (!n) { statusEl.textContent = `La liste ${label} est déjà vide.`; return; }
  const ok = await confirmAction(`Vider la liste ${label} ?`,
    `${n} élément${plural(n, "", "s")} ${plural(n, "sera supprimé", "seront supprimés")}, cochés ou non.`);
  if (!ok) return;
  try {
    await rpc("clear_shop_list", { ...auth(), lst: shopList });
    await refreshShop();
  } catch (e) {
    fail(e);
  }
}

// ---- Élément : menu (modifier, déplacer, supprimer)
const shopItemDialog = $("shop-item-dialog");
closeOnBackdrop(shopItemDialog);
$("shop-item-close").addEventListener("click", () => shopItemDialog.close());

function openShopItemMenu(it) {
  const label = SHOP_LISTS[it.list].label;
  const other = otherShopList(it.list);
  $("shop-item-title").textContent = it.name;
  $("shop-item-meta").textContent = [fmtShopQty(it), shopCatOf(it.category_id).name, `liste ${label}`].filter(Boolean).join(" · ");
  $("shop-item-error").textContent = "";
  const menu = $("shop-item-menu");
  menu.replaceChildren(
    button("btn-sm", "Modifier", () => { shopItemDialog.close(); openShopEdit(it); }),
    button("btn-sm", `Déplacer vers ${SHOP_LISTS[other].label}`, () => { shopItemDialog.close(); moveShopItem(it); }),
    button("btn-sm danger", "Supprimer", () => { shopItemDialog.close(); deleteShopItem(it); }),
  );
  shopItemDialog.showModal();
}

async function moveShopItem(it) {
  const to = otherShopList(it.list);
  const ok = await confirmAction(`Déplacer vers la liste ${SHOP_LISTS[to].label} ?`,
    `${it.name}${fmtShopQty(it) ? " · " + fmtShopQty(it) : ""}. Il est fusionné avec un élément identique de cette liste s'il y en a un.`);
  if (!ok) return;
  try {
    await rpc("move_shop_item", { ...auth(), iid: it.id, to_list: to });
    await refreshShop();
  } catch (e) {
    fail(e);
    await refreshShop();
  }
}

async function deleteShopItem(it) {
  const ok = await confirmAction("Supprimer cet élément ?", `${it.name} (liste ${SHOP_LISTS[it.list].label})`);
  if (!ok) return;
  try {
    await rpc("delete_shop_item", { ...auth(), iid: it.id });
    await refreshShop();
  } catch (e) {
    fail(e);
  }
}

// ---- Élément : ajout et modification
const shopEditDialog = $("shop-edit-dialog");
const shopEditError = $("shop-edit-error");
let shopEditing = null; // élément modifié, ou null pour un ajout
let shopQty = null; // { value(), unit() } : champ quantité du popup

// Quantité avec boutons − / + (pas selon l'unité) et choix de l'unité (ou aucune). value() : null (vide), NaN
// (invalide) ou le nombre ; unit() : identifiant de l'unité ou null.
function qtyField(root, quantity, unitId) {
  root.replaceChildren();
  const input = el("input", "shop-qty-input");
  input.type = "number";
  input.min = "0";
  input.step = "any";
  input.inputMode = "decimal";
  input.placeholder = "quantité";
  input.value = quantity === null || quantity === undefined ? "" : String(quantity);
  input.setAttribute("aria-label", "Quantité");
  const sel = el("select", "unit-select");
  sel.setAttribute("aria-label", "Unité");
  sel.append(new Option("aucune", "", false, !unitId));
  for (const u of units) sel.append(new Option(u.name, u.id, false, u.id === unitId));
  const unit = () => (sel.value === "" ? null : Number(sel.value));
  const bump = (dir) => () => {
    const cur = Number(String(input.value).replace(",", ".")) || 0;
    const v = Math.round((cur + dir * qtyStep(unit() || 0)) * 1000) / 1000;
    if (v > 0 && v <= 99999) input.value = String(v);
  };
  root.append(button("btn-step", "−", bump(-1)), input, button("btn-step", "+", bump(1)), sel);
  return {
    unit,
    value: () => {
      const raw = input.value.trim().replace(",", ".");
      if (raw === "") return null;
      const v = Number(raw);
      return v > 0 && v <= 99999 && Math.round(v * 1000) / 1000 === v ? v : NaN;
    },
  };
}

function openShopEdit(it) {
  shopEditing = it;
  const label = SHOP_LISTS[it ? it.list : shopList].label;
  $("shop-edit-title").textContent = it ? `Modifier l'élément (${label})` : `Ajouter à la liste ${label}`;
  $("shop-edit-save").textContent = it ? "Enregistrer" : "Ajouter";
  $("shop-edit-name").value = it ? it.name : "";
  const sel = $("shop-edit-category");
  sel.replaceChildren();
  const current = it ? it.category_id : defaultShopCat().id;
  for (const c of catsByName()) sel.append(new Option(c.name, c.id, false, c.id === current));
  shopQty = qtyField($("shop-edit-qty"), it ? it.quantity : null, it ? it.unit_id : null);
  shopEditError.textContent = "";
  shopEditDialog.showModal();
  if (!it) $("shop-edit-name").focus();
}

$("shop-edit-cancel").addEventListener("click", () => shopEditDialog.close());
closeOnBackdrop(shopEditDialog);
$("shop-edit-name").addEventListener("keydown", (e) => {
  if (e.key === "Enter") { e.preventDefault(); $("shop-edit-save").click(); }
});
$("shop-edit-save").addEventListener("click", async () => {
  const name = $("shop-edit-name").value.trim();
  if (!name || name.length > 60) { shopEditError.textContent = errorText({ code: "invalid_name" }); return; }
  const q = shopQty.value();
  if (Number.isNaN(q)) { shopEditError.textContent = errorText({ code: "invalid_quantity" }); return; }
  const uid = q === null ? null : shopQty.unit();
  const cid = Number($("shop-edit-category").value);
  const list = shopEditing ? shopEditing.list : shopList;
  const qtyText = q === null ? "" : uid ? ` · ${fmtQty(q, uid)}` : ` · ${fmtNum(q)}`;
  const ok = await confirmAction(shopEditing ? "Modifier cet élément ?" : `Ajouter à la liste ${SHOP_LISTS[list].label} ?`,
    `${name}${qtyText} · ${shopCatOf(cid).name}`);
  if (!ok) return;
  const btn = $("shop-edit-save");
  btn.disabled = true;
  try {
    if (shopEditing) await rpc("update_shop_item", { ...auth(), iid: shopEditing.id, n: name, cid, q, uid });
    else await rpc("add_shop_item", { ...auth(), lst: list, n: name, cid, q, uid });
    shopEditDialog.close();
    await refreshShop();
  } catch (e) {
    fail(e, shopEditError);
  }
  btn.disabled = false;
});

// ---- Génération de la liste France à partir des repas
const SHOP_MODES = [
  ["replace", "Écraser la liste", "La liste actuelle est supprimée puis remplacée."],
  ["append", "Ajouter à la fin", "Les nouveaux éléments sont ajoutés sous la liste, sans fusion."],
  ["merge", "Fusionner", "Les quantités s'additionnent quand c'est possible."],
];
const shopGenDialog = $("shop-gen-dialog");
const shopGenError = $("shop-gen-error");
const shopPreviewDialog = $("shop-preview-dialog");
const shopPreviewError = $("shop-preview-error");
let shopGenArgs = null; // { d_from, d_to, mode } en attente de confirmation

function openShopGenerate() {
  $("shop-gen-from").min = today;
  $("shop-gen-to").min = today;
  $("shop-gen-from").value = today;
  $("shop-gen-to").value = addDays(today, 6);
  const box = $("shop-gen-modes");
  box.replaceChildren();
  for (const [key, name, desc] of SHOP_MODES) {
    const label = el("label", "effect-opt");
    const radio = el("input");
    radio.type = "radio";
    radio.name = "shop-gen-mode";
    radio.value = key;
    radio.checked = key === "merge";
    const text = el("span", "effect-text");
    text.append(el("span", "effect-name", name), el("small", "check-meta", desc));
    label.append(radio, text);
    box.append(label);
  }
  shopGenError.textContent = "";
  shopGenDialog.showModal();
}

$("shop-gen-cancel").addEventListener("click", () => shopGenDialog.close());
closeOnBackdrop(shopGenDialog);
$("shop-gen-next").addEventListener("click", async () => {
  const d_from = $("shop-gen-from").value;
  const d_to = $("shop-gen-to").value;
  const mode = $("shop-gen-modes").querySelector("input:checked").value;
  if (!d_from || !d_to || d_from < today || d_to < d_from) { shopGenError.textContent = errorText({ code: "invalid_dates" }); return; }
  const btn = $("shop-gen-next");
  btn.disabled = true;
  try {
    const res = await rpc("preview_shop_generation", { ...auth(), d_from, d_to, mode });
    shopGenArgs = { d_from, d_to, mode };
    shopGenDialog.close();
    showShopPreview(res, mode);
  } catch (e) {
    fail(e, shopGenError);
  }
  btn.disabled = false;
});

// Quantité écrite avec l'unité donnée par son nom (le résultat de la base ne renvoie que des noms d'unités).
const fmtByUnitName = (q, name) => {
  const u = units.find((x) => x.name === name);
  return `${fmtNum(q)}${name ? " " + (q >= 2 && u ? u.plural : name) : ""}`;
};

function showShopPreview(res, mode) {
  $("shop-preview-title").textContent = "Générer la liste France ?";
  const body = $("shop-preview-body");
  body.replaceChildren();
  const line = (text, cls) => body.append(el("p", cls || "shop-line", text));
  const heading = (text) => body.append(el("h3", "shop-sub", text));
  const mergedCount = res.merged.length;
  if (mode === "replace") {
    line(`La liste France actuelle (${res.replaced} élément${plural(res.replaced, "", "s")}) sera supprimée.`);
  }
  if (!res.added && !mergedCount) {
    line("Aucun ingrédient à ajouter : les repas de ces jours sont vides ou leurs aliments n'ont pas d'ingrédients.");
  } else {
    line(`${res.added} élément${plural(res.added, "", "s")} ${plural(res.added, "sera ajouté", "seront ajoutés")}`
      + (mergedCount ? `, ${mergedCount} ${plural(mergedCount, "fusionné", "fusionnés")}.` : "."));
  }
  if (mergedCount) {
    heading("Fusions");
    for (const m of res.merged) {
      line(m.before === null ? `${m.name} : déjà dans la liste (sans quantité)`
        : `${m.name} : ${fmtByUnitName(m.before, m.unit)} + ${fmtByUnitName(m.add, m.unit)} = ${fmtByUnitName(m.after, m.unit)}`, "shop-line shop-merge");
    }
  }
  if (res.split.length || res.no_qty.length) {
    heading("À vérifier");
    for (const name of res.split) line(`${name} : la ligne existante est cochée, une nouvelle ligne sera créée`, "shop-line shop-warn");
    if (res.no_qty.length) {
      line(`${res.no_qty.length} élément${plural(res.no_qty.length, "", "s")} sans quantité (${res.no_qty.join(", ")})`, "shop-line shop-warn");
    }
  }
  shopPreviewError.textContent = "";
  $("shop-preview-yes").disabled = false;
  shopPreviewDialog.showModal();
}

$("shop-preview-no").addEventListener("click", () => shopPreviewDialog.close());
closeOnBackdrop(shopPreviewDialog);
$("shop-preview-yes").addEventListener("click", async () => {
  const btn = $("shop-preview-yes");
  btn.disabled = true;
  try {
    await rpc("generate_shop", { ...auth(), ...shopGenArgs });
    shopPreviewDialog.close();
    shopList = "france";
    await refreshShop();
  } catch (e) {
    fail(e, shopPreviewError);
    btn.disabled = false;
  }
});

// ------------------------------------------------- Admin : catégories de courses
function renderCategoriesAdmin(root) {
  root.append(button("btn-primary admin-add", "+ Ajouter une catégorie", () => openCategoryDialog(null)));
  const st = filterState("categories");
  const bar = filterBar("categories", [
    { k: "merge", label: "Addition", type: "one", options: [["merge", "S'additionne"], ["nomerge", "Ne s'additionne pas"]] },
    // Tri de la liste (A → Z par défaut) : ordre d'un des deux tris custom (rangs de 1 à N). Affichage seulement,
    // pas compté comme un filtre.
    { k: "sort", label: "Tri", type: "one", sort: true, options: [["carrefour", "Carrefour Segny"], ["coop", "Coop Vich"]] },
  ], () => draw());
  root.append(bar);
  const list = el("ul", "food-list");
  root.append(list);
  if (!shopCats.length) {
    list.append(el("li", "empty", "Les listes de courses ne sont pas encore activées dans la base."));
    return;
  }
  const order = { carrefour: (a, b) => a.pos_carrefour - b.pos_carrefour, coop: (a, b) => a.pos_coop - b.pos_coop };
  const draw = () => {
  list.replaceChildren();
  const q = fold(st.q.trim());
  const m = (st.f.merge || [])[0];
  const sortKey = (st.f.sort || [])[0];
  const rows = (sortKey ? [...shopCats].sort(order[sortKey]) : catsByName())
    .filter((c) => fold(c.name).includes(q) && (!m || (m === "nomerge") === c.no_merge));
  bar.setCount(rows.length);
  if (!rows.length) list.append(el("li", "empty", bar.isFiltering() ? "Aucun résultat" : "Aucune catégorie"));
  for (const c of rows) {
    const li = el("li", "food-row");
    const name = el("span", "fname", c.name);
    name.append(el("span", "cls-pill", `Carrefour ${c.pos_carrefour}`), el("span", "cls-pill", `Coop ${c.pos_coop}`));
    if (c.no_merge) name.append(el("span", "cls-pill", "ne s'additionne pas"));
    if (c.is_default) name.append(el("span", "cls-pill", "par défaut"));
    const uses = Number(c.uses) || 0;
    name.append(el("small", "fmeta", uses ? `utilisée ${uses} fois (ingrédients et éléments de liste)` : "non utilisée"));
    li.append(name, button("btn-sm", "Modifier", () => openCategoryDialog(c)));
    if (!c.is_default) li.append(button("btn-sm danger", "Supprimer", () => deleteCategory(c)));
    list.append(li);
  }
  };
  draw();
}

async function deleteCategory(c) {
  if (!(Number(c.uses) > 0)) {
    const ok = await confirmAction("Êtes-vous sûr de vouloir supprimer cette catégorie ?", c.name);
    if (!ok) return;
  }
  try {
    await rpc("delete_shop_category", { ...auth(), cid: c.id });
    statusEl.textContent = "";
    await refreshShop();
  } catch (e) {
    if (e.code === "category_in_use") {
      const { n, items } = usageOf(e);
      showUsage("Suppression impossible", c.name,
        `Cette catégorie est utilisée ${n || items.length} fois. Changez la catégorie de ces ingrédients et de ces éléments de liste avant de la supprimer.`, items);
    } else {
      fail(e);
    }
  }
}

const categoryDialog = $("category-dialog");
const categoryError = $("category-error");
let editingCategory = null;

function openCategoryDialog(c) {
  editingCategory = c;
  $("category-title").textContent = c ? "Modifier la catégorie" : "Nouvelle catégorie";
  $("category-save").textContent = c ? "Enregistrer" : "Ajouter";
  $("category-name").value = c ? c.name : "";
  $("category-carrefour").value = c ? c.pos_carrefour : shopCats.length + 1; // à l'ajout : en dernier par défaut
  $("category-coop").value = c ? c.pos_coop : shopCats.length + 1;
  $("category-nomerge").checked = c ? c.no_merge : false;
  categoryError.textContent = "";
  categoryDialog.showModal();
  $("category-name").focus();
}

$("category-cancel").addEventListener("click", () => categoryDialog.close());
closeOnBackdrop(categoryDialog);
$("category-save").addEventListener("click", async () => {
  const name = $("category-name").value.trim();
  if (!name || name.length > 40) { categoryError.textContent = errorText({ code: "invalid_name" }); return; }
  const pc = Number($("category-carrefour").value);
  const pk = Number($("category-coop").value);
  if (!Number.isInteger(pc) || pc < 1 || !Number.isInteger(pk) || pk < 1) {
    categoryError.textContent = errorText({ code: "invalid_position" });
    return;
  }
  const nm = $("category-nomerge").checked;
  const btn = $("category-save");
  btn.disabled = true;
  try {
    if (editingCategory) await rpc("update_shop_category", { ...auth(), cid: editingCategory.id, n: name, pc, pk, nm });
    else await rpc("add_shop_category", { ...auth(), n: name, pc, pk, nm });
    categoryDialog.close();
    await refreshShop();
  } catch (e) {
    fail(e, categoryError);
  }
  btn.disabled = false;
});

// ------------------------------------------------------------------ Session
function storeSession(r) {
  const value = JSON.stringify({ u: userId, p: password });
  try {
    if (r === "admin") sessionStorage.setItem(STORAGE_KEY, value);
    else localStorage.setItem(STORAGE_KEY, value);
  } catch {}
}

function storedSession() {
  try {
    const raw = sessionStorage.getItem(STORAGE_KEY) || localStorage.getItem(STORAGE_KEY);
    const s = raw && JSON.parse(raw);
    return s && s.u && s.p ? s : null;
  } catch {
    return null;
  }
}

function clearSession() {
  try { sessionStorage.removeItem(STORAGE_KEY); } catch {}
  try { localStorage.removeItem(STORAGE_KEY); } catch {}
}

function unlock(r) {
  role = r;
  gate.hidden = true;
  app.hidden = false;
  $("role-badge").textContent = { read: "Lecture", write: "Écriture", admin: "Admin" }[r];
  $("tab-admin-btn").hidden = r !== "admin";
  statusEl.textContent = "";
  switchTab("home");
  loadAll();
}

function lock() {
  clearSession();
  userId = "";
  password = "";
  role = "";
  mealDialog.open && mealDialog.close();
  foodDialog.open && foodDialog.close();
  ingredientDialog.open && ingredientDialog.close();
  for (const d of [shopGenDialog, shopPreviewDialog, shopItemDialog, shopEditDialog, categoryDialog]) d.open && d.close();
  try { sessionStorage.removeItem(SORT_KEY); } catch {}
  shopSorts = defaultShopSorts();
  adminFilters = {};
  shopList = "france";
  shopCats = [];
  shopItems = [];
  usageDialog.open && usageDialog.close();
  app.hidden = true;
  todayBtn.hidden = true;
  gate.hidden = false;
  (userInput.value ? passwordInput : userInput).focus();
}

$("quit").addEventListener("click", lock);

gateForm.addEventListener("submit", async (e) => {
  e.preventDefault();
  const button = gateForm.querySelector("button");
  button.disabled = true;
  gateError.textContent = "";
  try {
    const u = userInput.value.trim().toLowerCase();
    const r = await rpc("login", { u, p: passwordInput.value });
    if (r) {
      userId = u;
      password = passwordInput.value;
      storeSession(r);
      userInput.value = "";
      passwordInput.value = "";
      unlock(r);
    } else {
      gateError.textContent = "Identifiant ou mot de passe incorrect.";
      passwordInput.value = "";
      passwordInput.focus();
    }
  } catch {
    gateError.textContent = "Connexion impossible. Réessayez plus tard.";
  }
  button.disabled = false;
});

// Si le site reste ouvert d'un jour à l'autre, on recalcule « aujourd'hui » au retour.
document.addEventListener("visibilitychange", () => {
  if (!document.hidden && role && zurichToday() !== today) loadAll();
});

// Reprise de session : on revérifie l'identifiant et le mot de passe (et le rôle) auprès de la base.
(async () => {
  try { localStorage.removeItem("food_pw"); } catch {} // ancienne session (mot de passe seul)
  const stored = storedSession();
  if (!stored) return;
  try {
    const r = await rpc("login", stored);
    if (r) { userId = stored.u; password = stored.p; unlock(r); } else clearSession();
  } catch {
    // Réseau indisponible : on garde la session et on affiche la page de connexion.
  }
})();

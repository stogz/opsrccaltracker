// Calorie Tracker — browser client.
//
// Everything here talks to Supabase through the anon key, which means every read
// and write is subject to the row level security in
// supabase/migrations/0002_rls.sql. There is no privileged path in this file and
// there must never be one: a user's diary is protected by the database, not by
// which buttons this page chooses to render.

import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm';
import { SUPABASE_URL, SUPABASE_ANON_KEY } from './config.js';

const $ = (id) => document.getElementById(id);

const MEALS = [
  ['breakfast', 'Breakfast'],
  ['lunch', 'Lunch'],
  ['dinner', 'Dinner'],
  ['snack', 'Snack'],
  ['other', 'Other'],
];

/* ------------------------------------------------------------------ setup */

if (!SUPABASE_ANON_KEY || SUPABASE_ANON_KEY === 'PASTE_YOUR_ANON_KEY_HERE') {
  $('setup').hidden = false;
  throw new Error('scripts/config.js still holds the placeholder anon key');
}

const db = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

/* ------------------------------------------------------------------ state */

// 'en-CA' formats as YYYY-MM-DD, and toLocaleDateString uses the *local* clock —
// so a 9pm snack lands on today rather than tomorrow's UTC date.
const localToday = () => new Date().toLocaleDateString('en-CA');

const state = {
  user: null,
  day: localToday(),
  goals: { kcal_goal: 2000, protein_goal_g: 150, fat_goal_g: 65, carbs_goal_g: 250 },
  entries: [],
  pending: null, // the food the log dialog is currently about
};

const num = (v) => (v === null || v === undefined ? 0 : Number(v));
const round = (v, places = 0) => {
  const f = 10 ** places;
  return Math.round(num(v) * f) / f;
};
const fmt = (v, places = 0) =>
  round(v, places).toLocaleString(undefined, { maximumFractionDigits: places });

function say(el, message, kind = '') {
  el.textContent = message;
  el.className = `status ${kind}`;
}

/* ------------------------------------------------------------------- auth */

$('signin-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const button = e.target.querySelector('button');
  const email = $('email').value.trim();
  button.disabled = true;
  say($('signin-status'), 'Sending…');

  const { error } = await db.auth.signInWithOtp({
    email,
    options: { emailRedirectTo: window.location.origin },
  });

  button.disabled = false;
  if (error) {
    // The built-in SMTP on the free tier allows only a handful of mails an hour.
    say($('signin-status'), error.message, 'error');
  } else {
    say($('signin-status'), `Check ${email} for your sign-in link.`, 'ok');
  }
});

$('sign-out').addEventListener('click', () => db.auth.signOut());

db.auth.onAuthStateChange((_event, session) => {
  state.user = session?.user ?? null;
  render();
});

async function render() {
  const signedIn = Boolean(state.user);
  $('signin').hidden = signedIn;
  $('app').hidden = !signedIn;
  $('account').hidden = !signedIn;

  if (!signedIn) return;

  $('who').textContent = state.user.email ?? '';
  $('day-picker').value = state.day;

  await loadGoals();
  await Promise.all([loadDay(), loadWeek(), loadRecent()]);
}

/* ------------------------------------------------------------------ goals */

async function loadGoals() {
  const { data, error } = await db
    .from('profiles')
    .select('kcal_goal, protein_goal_g, fat_goal_g, carbs_goal_g')
    .eq('id', state.user.id)
    .maybeSingle();

  if (error) return say($('goals-status'), error.message, 'error');

  if (data) {
    state.goals = data;
  } else {
    // Signed up before the profile trigger existed — create the row now.
    await db.from('profiles').insert({ id: state.user.id, ...state.goals });
  }

  $('goal-kcal').value = state.goals.kcal_goal;
  $('goal-protein').value = state.goals.protein_goal_g;
  $('goal-fat').value = state.goals.fat_goal_g;
  $('goal-carbs').value = state.goals.carbs_goal_g;
}

$('settings-toggle').addEventListener('click', () => {
  $('settings').hidden = !$('settings').hidden;
});

$('goals-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const goals = {
    kcal_goal: Number($('goal-kcal').value),
    protein_goal_g: Number($('goal-protein').value),
    fat_goal_g: Number($('goal-fat').value),
    carbs_goal_g: Number($('goal-carbs').value),
  };

  const { error } = await db.from('profiles').update(goals).eq('id', state.user.id);
  if (error) return say($('goals-status'), error.message, 'error');

  state.goals = goals;
  say($('goals-status'), 'Saved.', 'ok');
  drawTotals();
});

/* -------------------------------------------------------------- day + week */

$('day-picker').addEventListener('change', (e) => {
  state.day = e.target.value || localToday();
  loadDay();
  loadWeek();
});
$('prev-day').addEventListener('click', () => shiftDay(-1));
$('next-day').addEventListener('click', () => shiftDay(1));
$('today-btn').addEventListener('click', () => {
  state.day = localToday();
  $('day-picker').value = state.day;
  loadDay();
  loadWeek();
});

function shiftDay(days) {
  // Parse as noon UTC so a ±1 day step never trips over a DST boundary.
  const d = new Date(`${state.day}T12:00:00Z`);
  d.setUTCDate(d.getUTCDate() + days);
  state.day = d.toISOString().slice(0, 10);
  $('day-picker').value = state.day;
  loadDay();
  loadWeek();
}

async function loadDay() {
  const { data, error } = await db
    .from('entries')
    .select('id, food_name, meal, grams, kcal, protein_g, fat_g, carbs_g')
    .eq('logged_on', state.day)
    .order('id');

  if (error) {
    $('diary').innerHTML = `<p class="empty">${error.message}</p>`;
    return;
  }

  state.entries = data ?? [];
  drawTotals();
  drawDiary();
}

function dayTotals() {
  return state.entries.reduce(
    (t, e) => ({
      kcal: t.kcal + num(e.kcal),
      protein: t.protein + num(e.protein_g),
      fat: t.fat + num(e.fat_g),
      carbs: t.carbs + num(e.carbs_g),
    }),
    { kcal: 0, protein: 0, fat: 0, carbs: 0 }
  );
}

function drawTotals() {
  const t = dayTotals();
  const metrics = [
    ['kcal', 'Calories', t.kcal, state.goals.kcal_goal, 0],
    ['protein', 'Protein', t.protein, state.goals.protein_goal_g, 0],
    ['fat', 'Fat', t.fat, state.goals.fat_goal_g, 0],
    ['carbs', 'Carbs', t.carbs, state.goals.carbs_goal_g, 0],
  ];

  $('totals').innerHTML = metrics
    .map(([key, label, value, goal, places]) => {
      const target = num(goal);
      const pct = target > 0 ? Math.min(100, (value / target) * 100) : 0;
      const over = target > 0 && value > target;
      const unit = key === 'kcal' ? '' : ' g';
      return `
        <div class="metric m-${key}">
          <div class="metric-label">
            <span class="metric-name">${label}</span>
            <span class="metric-value">${fmt(value, places)}${unit}
              <span class="metric-goal">/ ${fmt(target, 0)}</span></span>
          </div>
          <div class="bar${over ? ' over' : ''}"
               role="meter" aria-label="${label}"
               aria-valuenow="${round(value)}" aria-valuemin="0" aria-valuemax="${round(target)}">
            <span style="width:${pct}%"></span>
          </div>
        </div>`;
    })
    .join('');
}

function drawDiary() {
  $('diary-date').textContent =
    state.day === localToday() ? '· today' : `· ${state.day}`;

  if (state.entries.length === 0) {
    $('diary').innerHTML = '<p class="empty">Nothing logged yet.</p>';
    return;
  }

  const html = MEALS.map(([key, label]) => {
    const rows = state.entries.filter((e) => e.meal === key);
    if (rows.length === 0) return '';

    const kcal = rows.reduce((s, e) => s + num(e.kcal), 0);
    const items = rows
      .map(
        (e) => `
        <div class="entry">
          <div class="entry-main">
            <strong>${escapeHtml(e.food_name)}</strong>
            <span class="entry-macros">${fmt(e.grams)} g ·
              P ${fmt(e.protein_g)} · F ${fmt(e.fat_g)} · C ${fmt(e.carbs_g)}</span>
          </div>
          <span class="entry-kcal">${fmt(e.kcal)} kcal</span>
          <button type="button" data-delete="${e.id}"
                  aria-label="Remove ${escapeHtml(e.food_name)}">✕</button>
        </div>`
      )
      .join('');

    return `<div class="meal-head"><span>${label}</span><span>${fmt(kcal)} kcal</span></div>${items}`;
  }).join('');

  $('diary').innerHTML = html;
}

$('diary').addEventListener('click', async (e) => {
  const id = e.target.closest('button[data-delete]')?.dataset.delete;
  if (!id) return;

  const { error } = await db.from('entries').delete().eq('id', id);
  if (error) return alert(error.message);
  await Promise.all([loadDay(), loadWeek(), loadRecent()]);
});

async function loadWeek() {
  const start = new Date(`${state.day}T12:00:00Z`);
  start.setUTCDate(start.getUTCDate() - 6);
  const from = start.toISOString().slice(0, 10);

  const { data, error } = await db
    .from('daily_totals')
    .select('logged_on, kcal')
    .gte('logged_on', from)
    .lte('logged_on', state.day);

  if (error) return;

  const byDay = new Map((data ?? []).map((r) => [r.logged_on, num(r.kcal)]));
  const goal = num(state.goals.kcal_goal) || 2000;
  const peak = Math.max(goal, ...byDay.values());

  const days = [];
  for (let i = 6; i >= 0; i--) {
    const d = new Date(`${state.day}T12:00:00Z`);
    d.setUTCDate(d.getUTCDate() - i);
    const iso = d.toISOString().slice(0, 10);
    const kcal = byDay.get(iso) ?? 0;
    days.push(`
      <li class="${iso === state.day ? 'is-current' : ''}" title="${iso}: ${fmt(kcal)} kcal">
        <div class="col"><span style="height:${peak > 0 ? (kcal / peak) * 100 : 0}%"></span></div>
        ${d.toLocaleDateString(undefined, { weekday: 'narrow', timeZone: 'UTC' })}
      </li>`);
  }
  $('week').innerHTML = days.join('');
}

/* ----------------------------------------------------------------- search */

let searchTimer;
$('search').addEventListener('input', (e) => {
  clearTimeout(searchTimer);
  const term = e.target.value.trim();
  searchTimer = setTimeout(() => (term ? runSearch(term) : loadRecent()), 200);
});

async function runSearch(term) {
  const { data, error } = await db.rpc('search_foods', { q: term, max_results: 20 });
  if (error) {
    $('results').innerHTML = `<li class="empty">${error.message}</li>`;
    return;
  }
  $('search-hint').textContent = data.length
    ? `${data.length} match${data.length === 1 ? '' : 'es'} — values are per 100 g`
    : 'No matches. Try fewer words, or add it as your own food.';
  drawResults(data);
}

async function loadRecent() {
  $('search-hint').textContent = 'Or pick something you eat often:';

  const { data, error } = await db.rpc('recent_foods', { max_results: 8 });
  if (error || !data?.length) {
    $('results').innerHTML = '';
    if (!error) $('search-hint').textContent = 'Search above to log your first food.';
    return;
  }

  // recent_foods returns log history, so fetch the current nutrition for each id.
  const ids = data.map((r) => r.food_id);
  const { data: foods } = await db
    .from('foods')
    .select('id, name, category, brand, kcal, protein_g, fat_g, carbs_g, owner_id')
    .in('id', ids);

  const byId = new Map((foods ?? []).map((f) => [f.id, f]));
  const ordered = data
    .map((r) => {
      const f = byId.get(r.food_id);
      return f && { ...f, is_custom: f.owner_id !== null, usual_grams: num(r.usual_grams) };
    })
    .filter(Boolean);

  drawResults(ordered);
}

function drawResults(foods) {
  $('results').innerHTML = foods
    .map((f) => {
      const sub = [f.brand, f.category].filter(Boolean).join(' · ');
      return `
      <li>
        <button type="button" class="row" data-food="${f.id}"
                data-usual="${f.usual_grams ?? ''}">
          <span class="row-name">
            <strong>${escapeHtml(f.name)}${f.is_custom ? '<span class="tag">yours</span>' : ''}</strong>
            <small>${escapeHtml(sub)}</small>
          </span>
          <span class="row-kcal">${fmt(f.kcal)} kcal · P ${fmt(f.protein_g)} F ${fmt(f.fat_g)} C ${fmt(f.carbs_g)}</span>
        </button>
      </li>`;
    })
    .join('');

  // Cache the row data so the dialog does not have to re-query for it.
  for (const f of foods) foodCache.set(String(f.id), f);
}

const foodCache = new Map();

$('results').addEventListener('click', (e) => {
  const button = e.target.closest('button[data-food]');
  if (button) openLogDialog(button.dataset.food, Number(button.dataset.usual) || null);
});

/* ------------------------------------------------------------- log dialog */

const dialog = $('log-dialog');

async function openLogDialog(foodId, usualGrams) {
  const food = foodCache.get(String(foodId));
  if (!food) return;

  state.pending = { food, units: [{ label: 'grams', gramsPer: 1 }] };

  $('log-name').textContent = food.name;
  $('log-per100').textContent =
    `Per 100 g: ${fmt(food.kcal)} kcal · ${fmt(food.protein_g)} g protein · ` +
    `${fmt(food.fat_g)} g fat · ${fmt(food.carbs_g)} g carbs`;

  const { data: portions } = await db
    .from('food_portions')
    .select('amount, unit, grams')
    .eq('food_id', food.id)
    .order('grams');

  for (const p of portions ?? []) {
    const gramsPer = num(p.grams) / num(p.amount);
    if (gramsPer > 0) {
      state.pending.units.push({
        label: `${p.unit} (${fmt(gramsPer)} g)`,
        gramsPer,
      });
    }
  }

  $('log-unit').innerHTML = state.pending.units
    .map((u, i) => `<option value="${i}">${escapeHtml(u.label)}</option>`)
    .join('');

  // Default to the household measure when there is one — most people log
  // "1 serving", not "140 grams".
  const preferPortion = state.pending.units.length > 1 && !usualGrams;
  $('log-unit').value = preferPortion ? '1' : '0';
  $('log-amount').value = preferPortion ? 1 : usualGrams || 100;

  $('log-meal').value = guessMeal();
  updatePreview();
  dialog.showModal();
  $('log-amount').focus();
  $('log-amount').select();
}

function guessMeal() {
  const h = new Date().getHours();
  if (h < 11) return 'breakfast';
  if (h < 15) return 'lunch';
  if (h < 21) return 'dinner';
  return 'snack';
}

function pendingGrams() {
  const unit = state.pending.units[Number($('log-unit').value)] ?? { gramsPer: 1 };
  return num($('log-amount').value) * unit.gramsPer;
}

function updatePreview() {
  if (!state.pending) return;
  const { food } = state.pending;
  const factor = pendingGrams() / 100;
  $('log-preview').textContent =
    `${fmt(pendingGrams(), 1)} g → ${fmt(num(food.kcal) * factor)} kcal · ` +
    `P ${fmt(num(food.protein_g) * factor, 1)} · ` +
    `F ${fmt(num(food.fat_g) * factor, 1)} · ` +
    `C ${fmt(num(food.carbs_g) * factor, 1)}`;
}

$('log-amount').addEventListener('input', updatePreview);
$('log-unit').addEventListener('change', updatePreview);
$('log-cancel').addEventListener('click', () => dialog.close());

// entries.grams is capped at 10000 by a check constraint; catch it here so the
// user gets a message instead of a failed insert.
const MAX_GRAMS = 10000;

$('log-form').addEventListener('submit', async (e) => {
  if (!state.pending) return;

  const grams = round(pendingGrams(), 2);
  if (!(grams > 0) || grams > MAX_GRAMS) {
    // preventDefault keeps the dialog open so the amount can be corrected.
    e.preventDefault();
    $('log-preview').textContent = `That works out to ${fmt(grams, 1)} g — enter something under ${fmt(MAX_GRAMS)} g.`;
    return;
  }

  const foodId = state.pending.food.id;
  const meal = $('log-meal').value;
  state.pending = null;

  // Only food_id and grams are sent: the database fills in user_id and the
  // nutrition snapshot (see entries_fill_nutrition in 0001_core.sql).
  const { error } = await db
    .from('entries')
    .insert({ food_id: foodId, logged_on: state.day, meal, grams });

  if (error) return alert(error.message);
  await Promise.all([loadDay(), loadWeek()]);
});

/* ----------------------------------------------------------- custom foods */

$('custom-toggle').addEventListener('click', () => {
  const form = $('custom-form');
  form.hidden = !form.hidden;
  if (!form.hidden) $('c-name').focus();
});

$('custom-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const food = {
    name: $('c-name').value.trim(),
    brand: $('c-brand').value.trim() || null,
    kcal: Number($('c-kcal').value),
    protein_g: numberOrNull($('c-protein').value),
    fat_g: numberOrNull($('c-fat').value),
    carbs_g: numberOrNull($('c-carbs').value),
  };

  const { data, error } = await db.from('foods').insert(food).select().single();
  if (error) return say($('custom-status'), error.message, 'error');

  say($('custom-status'), `Saved “${data.name}”. It's in your search results now.`, 'ok');
  e.target.reset();
  e.target.hidden = true;

  foodCache.set(String(data.id), { ...data, is_custom: true });
  openLogDialog(data.id, null);
});

const numberOrNull = (v) => (v === '' ? null : Number(v));

function escapeHtml(s) {
  return String(s ?? '').replace(/[&<>"']/g, (c) =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c])
  );
}

/* ------------------------------------------------------------------ start */

$('day-picker').value = state.day;
const { data: { session } } = await db.auth.getSession();
state.user = session?.user ?? null;
render();

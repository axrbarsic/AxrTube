// AxrTube "transcript hunter" client. Pure helpers are exported for tests and
// serialized into /app.js together with appMain. Text is always inserted with
// textContent, never as HTML.

export function videoIdFrom(raw) {
  const text = String(raw || '').trim();
  if (/^[\w-]{11}$/.test(text)) return text;
  const found = text.match(/https?:\/\/[^\s<>"']+/i);
  if (!found) return null;
  let u;
  try { u = new URL(found[0]); } catch { return null; }
  const host = u.hostname.replace(/^www\./, '').replace(/^m\./, '');
  let id = null;
  if (host === 'youtu.be') id = u.pathname.split('/')[1];
  else if (host === 'youtube.com' || host === 'music.youtube.com' || host === 'youtube-nocookie.com') {
    id = u.searchParams.get('v');
    const parts = u.pathname.split('/').filter(Boolean);
    if (!id && ['shorts', 'live', 'embed', 'v'].includes(parts[0])) id = parts[1];
  }
  return /^[\w-]{11}$/.test(id || '') ? id : null;
}

export function formatClock(seconds) {
  const s = Math.max(0, Math.floor(Number(seconds) || 0));
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), r = s % 60;
  const pad = n => String(n).padStart(2, '0');
  return h ? h + ':' + pad(m) + ':' + pad(r) : m + ':' + pad(r);
}

export function transcriptText(data, timed) {
  const paragraphs = (data?.sections || []).flatMap(s => s.paragraphs || []);
  const body = paragraphs.map(p => (timed ? '[' + formatClock(p.start) + '] ' : '') + p.text).join('\n\n');
  const head = [data?.title, data?.channel, data?.id ? 'https://youtu.be/' + data.id : ''].filter(Boolean).join('\n');
  return head ? head + '\n\n' + body : body;
}

export function countWords(text) {
  const m = String(text || '').match(/[\p{L}\p{N}]+(?:[-'’][\p{L}\p{N}]+)*/gu);
  return m ? m.length : 0;
}

export function relativeTime(iso, now = Date.now()) {
  const t = Date.parse(iso);
  if (!Number.isFinite(t)) return '';
  const s = Math.max(0, Math.round((now - t) / 1000));
  if (s < 60) return 'сейчас';
  if (s < 3600) return Math.floor(s / 60) + ' мин';
  if (s < 86400) return Math.floor(s / 3600) + ' ч';
  if (s < 86400 * 7) return Math.floor(s / 86400) + ' дн';
  const d = new Date(t), same = new Date(now).getFullYear() === d.getFullYear();
  const months = ['янв', 'фев', 'мар', 'апр', 'мая', 'июн', 'июл', 'авг', 'сен', 'окт', 'ноя', 'дек'];
  return d.getDate() + ' ' + months[d.getMonth()] + (same ? '' : ' ' + d.getFullYear());
}

export function compactNumber(n) {
  const v = Number(n) || 0;
  if (v < 1000) return String(v);
  if (v < 1e6) return (v / 1000).toFixed(v < 1e4 ? 1 : 0).replace(/\.0$/, '').replace('.', ',') + ' тыс.';
  return (v / 1e6).toFixed(1).replace(/\.0$/, '').replace('.', ',') + ' млн';
}

export function appMain() {
  const $ = id => document.getElementById(id);
  const root = $('app');
  function h(tag, attrs, ...children) {
    const el = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs || {})) {
      if (v === undefined || v === null || v === false) continue;
      if (k === 'class') el.className = v;
      else if (k === 'text') el.textContent = v;
      else if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
      else el.setAttribute(k, v === true ? '' : v);
    }
    for (const c of children.flat()) if (c !== null && c !== undefined && c !== false) el.append(c instanceof Node ? c : String(c));
    return el;
  }
  const state = { account: null, view: null, video: null, transcript: null, comments: null, replyTo: null };
  const store = {
    get(key, fallback) { try { const v = localStorage.getItem(key); return v ? JSON.parse(v) : fallback; } catch { return fallback; } },
    set(key, value) { try { localStorage.setItem(key, JSON.stringify(value)); } catch {} }
  };
  const recent = () => store.get('axr.recent', []);
  function remember(video) {
    if (!video?.id) return;
    const list = recent().filter(v => v.id !== video.id);
    list.unshift({ id: video.id, title: video.title || '', channel: video.channel || '', at: Date.now() });
    store.set('axr.recent', list.slice(0, 60));
  }
  function forget(id) { store.set('axr.recent', recent().filter(v => v.id !== id)); }

  let toastTimer;
  function toast(text) {
    const el = $('toast');
    el.textContent = text; el.hidden = false; el.classList.add('show');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { el.classList.remove('show'); setTimeout(() => { el.hidden = true; }, 250); }, 2200);
  }
  async function copyText(text) {
    try { await navigator.clipboard.writeText(text); return true; } catch {}
    const area = h('textarea', { class: 'clip', readonly: true });
    area.value = text; document.body.append(area); area.select(); area.setSelectionRange(0, text.length);
    let ok = false; try { ok = document.execCommand('copy'); } catch {}
    area.remove(); return ok;
  }
  async function api(path, options) {
    const r = await fetch(path, { credentials: 'same-origin', cache: 'no-store', ...options });
    let data = {}; try { data = await r.json(); } catch {}
    return { ok: r.ok, status: r.status, data };
  }
  function postForm(action) {
    const form = h('form', { method: 'POST', action });
    document.body.append(form); form.submit();
  }
  function signIn() {
    try { sessionStorage.setItem('axr.return', location.hash || ''); } catch {}
    postForm('/oauth/google/start?recommendations=1');
  }
  function signOut() { postForm('/oauth/google/logout'); }
  async function loadAccount() {
    const r = await api('/api/account');
    state.account = r.ok ? r.data : { signedIn: false, configured: r.data?.configured !== false };
    renderAccountButton();
    return state.account;
  }
  const thumb = id => 'https://i.ytimg.com/vi/' + id + '/mqdefault.jpg';
  function hideBroken(e) { e.target.classList.add('broken'); }

  // ---------- Header ----------
  function renderAccountButton() {
    const btn = $('account');
    btn.textContent = '';
    const a = state.account;
    if (a?.signedIn) { btn.append(h('span', { class: 'avatar small', text: (a.name || '?').trim().charAt(0).toUpperCase() })); btn.setAttribute('aria-label', 'Аккаунт: ' + (a.name || '')); }
    else { btn.append(h('span', { class: 'signin', text: 'Войти' })); btn.setAttribute('aria-label', 'Войти через Google'); }
  }
  $('account').addEventListener('click', () => {
    const a = state.account;
    if (!a?.signedIn) return signIn();
    openSheet(h('div', { class: 'sheet-body' },
      h('div', { class: 'sheet-title', text: a.name || 'Аккаунт YouTube' }),
      h('p', { class: 'muted', text: a.recommendationsAuthorized ? 'Можно читать и писать комментарии от вашего имени.' : 'Комментарии только для чтения. Чтобы отвечать, войдите заново и разрешите комментарии.' }),
      a.recommendationsAuthorized ? null : h('button', { class: 'btn primary wide', onclick: signIn, text: 'Разрешить комментарии' }),
      h('button', { class: 'btn wide', onclick: signOut, text: 'Выйти' })));
  });
  function openSheet(content) {
    const sheet = $('sheet');
    sheet.textContent = '';
    sheet.append(h('div', { class: 'sheet-scrim', onclick: closeSheet }), h('div', { class: 'sheet-panel', role: 'dialog' }, h('div', { class: 'grabber' }), content));
    sheet.hidden = false;
  }
  function closeSheet() { $('sheet').hidden = true; $('sheet').textContent = ''; }

  // ---------- Home ----------
  function videoRow(v, extra) {
    return h('a', { class: 'row', href: '#v=' + v.id, onclick: () => { state.video = { id: v.id, title: v.title, channel: v.channel }; } },
      h('div', { class: 'row-thumb' }, h('img', { src: v.thumbnail || thumb(v.id), alt: '', loading: 'lazy', onerror: hideBroken }), v.duration ? h('span', { class: 'badge', text: v.duration }) : null),
      h('div', { class: 'row-text' }, h('div', { class: 'row-title', text: v.title || v.id }),
        h('div', { class: 'row-meta', text: [v.channel, v.views, v.published].filter(Boolean).join(' · ') })),
      extra || null);
  }
  function renderHome() {
    state.view = 'home';
    document.title = 'AxrTube';
    $('back').hidden = true; $('title').textContent = 'AxrTube';
    $('composer').hidden = true;
    const input = h('input', { id: 'q', type: 'search', enterkeyhint: 'search', autocomplete: 'off', placeholder: 'Ссылка на ролик или поиск', 'aria-label': 'Ссылка на ролик или поиск' });
    const suggest = h('div', { class: 'suggest', hidden: true });
    const results = h('div', { class: 'list' });
    const pasteBtn = h('button', { type: 'button', class: 'btn', text: 'Вставить ссылку', onclick: async () => {
      try { const t = await navigator.clipboard.readText(); const id = videoIdFrom(t); if (id) { location.hash = 'v=' + id; return; } input.value = t; toast('В буфере нет ссылки на ролик'); }
      catch { input.focus(); toast('Вставьте ссылку в поле'); }
    } });
    async function search(q) {
      suggest.hidden = true;
      const id = videoIdFrom(q);
      if (id) { location.hash = 'v=' + id; return; }
      if (!q.trim()) return;
      results.textContent = ''; results.append(...skeletonRows(4));
      const r = await api('/api/catalog?' + new URLSearchParams({ q: q.trim() }));
      results.textContent = '';
      if (!r.ok) { results.append(errorBox(r.data?.error || 'Поиск не удался', () => search(q))); return; }
      const videos = (r.data.videos || []).filter(v => !v.isShort);
      if (!videos.length) { results.append(h('p', { class: 'empty', text: 'Ничего не нашлось' })); return; }
      results.append(h('div', { class: 'section-title', text: 'Результаты' }), ...videos.map(v => videoRow(v)));
    }
    let suggestTimer, suggestSeq = 0;
    input.addEventListener('input', () => {
      clearTimeout(suggestTimer);
      const q = input.value.trim();
      if (!q || videoIdFrom(q)) { suggest.hidden = true; return; }
      suggestTimer = setTimeout(async () => {
        const seq = ++suggestSeq;
        const r = await api('/api/suggest?' + new URLSearchParams({ q }));
        if (seq !== suggestSeq || input.value.trim() !== q) return;
        const items = r.data?.suggestions || [];
        suggest.textContent = '';
        items.forEach(s => suggest.append(h('button', { type: 'button', class: 'suggest-item', text: s, onclick: () => { input.value = s; search(s); } })));
        suggest.hidden = !items.length;
      }, 180);
    });
    const form = h('form', { class: 'search', onsubmit: e => { e.preventDefault(); input.blur(); search(input.value); } },
      h('div', { class: 'search-box' }, input, h('button', { class: 'btn primary', type: 'submit', text: 'Найти' })), suggest);
    const list = recent();
    const recentBox = h('div', { class: 'list' });
    if (list.length) {
      recentBox.append(h('div', { class: 'section-title', text: 'Недавние' }));
      for (const v of list) {
        const row = videoRow(v, h('button', { class: 'icon-btn', 'aria-label': 'Убрать из недавних', text: '×', onclick: e => { e.preventDefault(); e.stopPropagation(); forget(v.id); row.remove(); } }));
        recentBox.append(row);
      }
    }
    const hero = h('div', { class: 'hero' },
      h('h1', { text: 'Стенограммы и обсуждения' }),
      h('p', { class: 'muted', text: 'Вставьте ссылку на ролик YouTube или найдите его. Полный текст копируется одной кнопкой, а комментарии читаются как лента.' }));
    $('main').textContent = '';
    $('main').append(hero, form, h('div', { class: 'actions' }, pasteBtn), results, recentBox);
  }
  function skeletonRows(n) { return Array.from({ length: n }, () => h('div', { class: 'row skeleton' }, h('div', { class: 'row-thumb' }), h('div', { class: 'row-text' }, h('div', { class: 'line' }), h('div', { class: 'line short' })))); }
  function errorBox(text, retry) { return h('div', { class: 'error' }, h('p', { text }), retry ? h('button', { class: 'btn', text: 'Повторить', onclick: retry }) : null); }

  // ---------- Video ----------
  function renderVideo(id, tab) {
    const same = state.view === 'video' && state.video?.id === id;
    state.view = 'video';
    if (!same) { state.video = state.video?.id === id ? state.video : { id }; state.transcript = null; state.comments = null; state.replyTo = null; }
    $('back').hidden = false;
    $('title').textContent = state.video.title || 'Ролик';
    const header = h('div', { class: 'video-head' },
      h('a', { class: 'video-thumb', href: 'https://www.youtube.com/watch?v=' + id, target: '_blank', rel: 'noopener' }, h('img', { src: thumb(id), alt: '', onerror: hideBroken }), h('span', { class: 'play', text: '▶' })),
      h('div', { class: 'video-text' }, h('div', { class: 'video-title', id: 'vtitle', text: state.video.title || 'Загрузка…' }), h('div', { class: 'muted', id: 'vchannel', text: state.video.channel || '' })));
    const tabs = h('div', { class: 'tabs', role: 'tablist' },
      h('a', { class: 'tab' + (tab !== 'comments' ? ' active' : ''), href: '#v=' + id, role: 'tab', text: 'Стенограмма' }),
      h('a', { class: 'tab' + (tab === 'comments' ? ' active' : ''), href: '#v=' + id + '&tab=comments', role: 'tab', id: 'tabc', text: state.comments?.total ? 'Обсуждение · ' + compactNumber(state.comments.total) : 'Обсуждение' }));
    const pane = h('div', { class: 'pane', id: 'pane' });
    $('main').textContent = '';
    $('main').append(header, tabs, pane);
    if (tab === 'comments') showComments(id); else showTranscript(id);
  }
  function setVideoMeta(meta) {
    if (!state.video || meta.id && meta.id !== state.video.id) return;
    if (meta.title) state.video.title = meta.title;
    if (meta.channel) state.video.channel = meta.channel;
    const t = $('vtitle'), c = $('vchannel');
    if (t) t.textContent = state.video.title || '';
    if (c) c.textContent = state.video.channel || '';
    $('title').textContent = state.video.title || 'Ролик';
    document.title = (state.video.title || 'Ролик') + ' · AxrTube';
    remember(state.video);
  }
  async function loadMeta(id) {
    if (state.video?.title && state.video?.channel) { remember(state.video); return; }
    const r = await api('/api/video?id=' + id);
    if (r.ok) setVideoMeta({ id, title: r.data.title, channel: r.data.channel });
  }

  // ---------- Transcript ----------
  async function showTranscript(id, lang) {
    $('composer').hidden = true;
    const pane = $('pane'); pane.textContent = '';
    loadMeta(id);
    if (!state.transcript || state.transcript.id !== id || (lang && state.transcript.language !== lang)) {
      pane.append(h('div', { class: 'loading' }, h('div', { class: 'spinner' }), h('p', { class: 'muted', text: 'Получаем полную стенограмму…' })));
      const r = await api('/api/transcript?' + new URLSearchParams({ id, ...(lang ? { lang } : {}) }));
      if (state.video?.id !== id || state.view !== 'video') return;
      if (!r.ok) {
        pane.textContent = '';
        const text = r.data?.code === 'TRANSCRIPT_UNAVAILABLE' ? 'У этого ролика нет субтитров, поэтому стенограммы нет.' : r.data?.code === 'TRANSCRIPT_TOO_LARGE' ? 'Стенограмма слишком большая.' : 'YouTube сейчас не отдал субтитры. Попробуйте ещё раз через минуту.';
        pane.append(errorBox(text, r.data?.code === 'TRANSCRIPT_UNAVAILABLE' ? null : () => showTranscript(id, lang)));
        return;
      }
      state.transcript = r.data;
      setVideoMeta({ id, title: r.data.title, channel: r.data.channel });
    }
    if (!location.hash.includes('tab=comments')) renderTranscript();
  }
  function renderTranscript() {
    const data = state.transcript, pane = $('pane');
    pane.textContent = '';
    const plain = transcriptText(data, false);
    const words = countWords((data.sections || []).flatMap(s => s.paragraphs.map(p => p.text)).join(' '));
    const find = h('input', { type: 'search', class: 'find', placeholder: 'Поиск по тексту', 'aria-label': 'Поиск по тексту' });
    const counter = h('span', { class: 'muted find-count' });
    const langs = data.languages || [];
    const picker = langs.length > 1 ? h('select', { class: 'lang', 'aria-label': 'Язык субтитров', onchange: e => showTranscript(data.id, e.target.value) },
      langs.map(l => { const o = h('option', { value: l.code, text: l.name + (l.auto ? ' (авто)' : '') }); if (l.code === data.language) o.selected = true; return o; })) : null;
    const bar = h('div', { class: 'toolbar' },
      h('button', { class: 'btn primary', onclick: async () => { toast(await copyText(plain) ? 'Скопировано: ' + words.toLocaleString('ru-RU') + ' слов' : 'Не удалось скопировать'); }, text: 'Копировать всё' }),
      h('button', { class: 'btn', onclick: async () => { toast(await copyText(transcriptText(data, true)) ? 'Скопировано с таймкодами' : 'Не удалось скопировать'); }, text: 'С таймкодами' }),
      h('button', { class: 'btn icon', 'aria-label': 'Поделиться', text: '↗', onclick: async () => {
        if (navigator.share) { try { await navigator.share({ title: data.title, text: plain }); } catch {} }
        else toast(await copyText(plain) ? 'Скопировано' : 'Не удалось скопировать');
      } }));
    const info = h('div', { class: 'tinfo muted', text: [data.languageName && (data.languageName + (data.autoGenerated ? ', автосубтитры' : '')), words.toLocaleString('ru-RU') + ' слов', data.duration ? formatClock(data.duration) : ''].filter(Boolean).join(' · ') });
    const body = h('div', { class: 'tbody' });
    const paragraphs = [];
    for (const section of data.sections || []) for (const p of section.paragraphs || []) {
      const textEl = h('p', { class: 'ptext', text: p.text });
      paragraphs.push({ p, textEl });
      body.append(h('div', { class: 'para' },
        h('button', { class: 'time', text: formatClock(p.start), 'aria-label': 'Скопировать ссылку на ' + formatClock(p.start), onclick: async () => {
          toast(await copyText('https://youtu.be/' + data.id + '?t=' + Math.floor(p.start)) ? 'Ссылка на ' + formatClock(p.start) + ' скопирована' : 'Не удалось скопировать');
        } }), textEl));
    }
    let findTimer;
    find.addEventListener('input', () => { clearTimeout(findTimer); findTimer = setTimeout(() => highlight(find.value.trim()), 120); });
    function highlight(q) {
      let hits = 0, first = null;
      const lower = q.toLocaleLowerCase('ru');
      for (const { p, textEl } of paragraphs) {
        textEl.textContent = '';
        if (!q) { textEl.textContent = p.text; textEl.parentElement.hidden = false; continue; }
        const src = p.text, low = src.toLocaleLowerCase('ru');
        let at = 0, i = low.indexOf(lower);
        if (i < 0) { textEl.textContent = src; textEl.parentElement.hidden = true; continue; }
        textEl.parentElement.hidden = false;
        while (i >= 0) { textEl.append(src.slice(at, i), h('mark', { text: src.slice(i, i + q.length) })); hits++; at = i + q.length; i = low.indexOf(lower, at); }
        textEl.append(src.slice(at));
        first ||= textEl;
      }
      counter.textContent = q ? (hits ? hits + ' совп.' : 'нет совпадений') : '';
    }
    pane.append(h('div', { class: 'sticky' }, bar, h('div', { class: 'findrow' }, find, counter, picker)), info, body);
  }

  // ---------- Comments ----------
  function avatar(c) {
    if (c.avatar) return h('img', { class: 'avatar', src: c.avatar, alt: '', loading: 'lazy', referrerpolicy: 'no-referrer', onerror: e => e.target.replaceWith(h('span', { class: 'avatar', text: (c.author || '?').replace(/^@/, '').charAt(0).toUpperCase() })) });
    return h('span', { class: 'avatar', text: (c.author || '?').replace(/^@/, '').charAt(0).toUpperCase() });
  }
  function commentText(text) {
    const el = h('div', { class: 'ctext', text });
    if (text.length > 420 || text.split('\n').length > 7) {
      el.classList.add('clamped');
      const more = h('button', { class: 'more', text: 'Ещё', onclick: () => { el.classList.remove('clamped'); more.remove(); } });
      return [el, more];
    }
    return [el];
  }
  function commentCard(c, thread) {
    const card = h('article', { class: 'comment' + (c.parentId ? ' reply' : ''), 'data-id': c.id },
      avatar(c),
      h('div', { class: 'cbody' },
        h('div', { class: 'chead' }, h('span', { class: 'cname', text: c.author || 'Без имени' }), h('span', { class: 'muted', text: ' · ' + relativeTime(c.published) + (c.edited ? ' · изм.' : '') })),
        commentText(c.text),
        h('div', { class: 'cactions' },
          (thread ? thread.canReply : true) ? h('button', { class: 'link', text: 'Ответить', onclick: () => startReply(thread || c, c) }) : null,
          c.likes ? h('span', { class: 'muted likes', text: '♥ ' + compactNumber(c.likes) }) : null,
          h('button', { class: 'link', text: 'Копировать', onclick: async () => toast(await copyText(c.text) ? 'Комментарий скопирован' : 'Не удалось скопировать') }))));
    return card;
  }
  function threadView(t) {
    const box = h('div', { class: 'thread', 'data-thread': t.id });
    box.append(commentCard(t, t));
    const replies = h('div', { class: 'replies' });
    t.replies.forEach(r => replies.append(commentCard(r, t)));
    box.append(replies);
    if (t.replyCount > t.replies.length) {
      const btn = h('button', { class: 'link toggle', text: 'Показать все ответы (' + t.replyCount + ')' });
      btn.addEventListener('click', async () => {
        btn.disabled = true; btn.textContent = 'Загрузка…';
        const all = []; let page = '';
        do {
          const r = await api('/api/account/replies?' + new URLSearchParams({ parent: t.id, ...(page ? { page } : {}) }));
          if (!r.ok) { btn.disabled = false; btn.textContent = 'Не удалось загрузить. Повторить'; return; }
          all.push(...r.data.items); page = r.data.nextPage || '';
        } while (page && all.length < 500);
        t.replies = all.sort((a, b) => Date.parse(a.published) - Date.parse(b.published));
        replies.textContent = ''; t.replies.forEach(r => replies.append(commentCard(r, t)));
        btn.remove();
      });
      box.append(btn);
    }
    return box;
  }
  async function showComments(id) {
    const pane = $('pane'); pane.textContent = '';
    loadMeta(id);
    if (!state.account) await loadAccount();
    if (state.video?.id !== id || state.view !== 'video') return;
    if (!state.account?.signedIn) {
      $('composer').hidden = true;
      pane.append(h('div', { class: 'gate' },
        h('p', { text: 'Обсуждение читается и пишется через ваш аккаунт YouTube.' }),
        h('button', { class: 'btn primary', text: 'Войти через Google', onclick: signIn })));
      return;
    }
    if (!state.comments || state.comments.id !== id) state.comments = { id, order: 'relevance', items: [], nextPage: null, total: null, loaded: false };
    renderComments();
    if (!state.comments.loaded) loadComments(false);
  }
  function renderComments() {
    const pane = $('pane'), c = state.comments;
    pane.textContent = '';
    const seg = h('div', { class: 'segmented' },
      [['relevance', 'Популярные'], ['time', 'Новые']].map(([value, label]) => h('button', { class: c.order === value ? 'on' : '', text: label, onclick: () => {
        if (c.order === value) return; c.order = value; c.items = []; c.nextPage = null; c.loaded = false; renderComments(); loadComments(false);
      } })));
    const list = h('div', { class: 'threads', id: 'threads' });
    c.items.forEach(t => list.append(threadView(t)));
    const foot = h('div', { class: 'foot', id: 'cfoot' });
    pane.append(h('div', { class: 'sticky' }, seg), list, foot);
    renderFoot();
    $('composer').hidden = false;
    updateComposer();
  }
  function renderFoot() {
    const foot = $('cfoot'), c = state.comments; if (!foot) return;
    foot.textContent = '';
    if (c.error) foot.append(errorBox(c.error, () => { c.error = null; loadComments(c.items.length > 0); }));
    else if (!c.loaded) foot.append(h('div', { class: 'loading' }, h('div', { class: 'spinner' })));
    else if (c.nextPage) { const more = h('button', { class: 'btn wide', text: 'Загрузить ещё', onclick: () => loadComments(true) }); foot.append(more); observeMore(more); }
    else if (!c.items.length) foot.append(h('p', { class: 'empty', text: 'Комментариев пока нет. Будьте первым.' }));
    else foot.append(h('p', { class: 'empty', text: 'Это все комментарии' }));
  }
  let moreObserver;
  function observeMore(el) {
    moreObserver?.disconnect();
    if (!('IntersectionObserver' in window)) return;
    moreObserver = new IntersectionObserver(entries => { if (entries.some(e => e.isIntersecting)) { moreObserver.disconnect(); loadComments(true); } }, { rootMargin: '600px' });
    moreObserver.observe(el);
  }
  async function loadComments(more) {
    const c = state.comments, id = c.id, order = c.order;
    if (c.busy) return; c.busy = true; c.loaded = more ? c.loaded : false; renderFoot();
    const r = await api('/api/account/comments?' + new URLSearchParams({ id, order, ...(more && c.nextPage ? { page: c.nextPage } : {}) }));
    c.busy = false;
    if (state.comments !== c || c.order !== order) return;
    if (!r.ok) {
      c.loaded = true;
      if (r.status === 401) { await loadAccount(); if (!state.account?.signedIn) return showComments(id); }
      c.error = r.data?.error || 'Не удалось загрузить обсуждение'; renderFoot(); return;
    }
    c.loaded = true; c.error = null;
    if (r.data.total) { c.total = r.data.total; const tab = $('tabc'); if (tab) tab.textContent = 'Обсуждение · ' + compactNumber(c.total); }
    const list = $('threads');
    for (const t of r.data.items) { if (c.items.some(x => x.id === t.id)) continue; c.items.push(t); list?.append(threadView(t)); }
    c.nextPage = r.data.nextPage; renderFoot();
  }

  // ---------- Composer ----------
  const field = $('field'), send = $('send');
  function startReply(thread, target) {
    state.replyTo = { threadId: thread.id, author: target.author, mention: target.parentId && target.authorChannelId !== thread.authorChannelId ? target.author : '' };
    updateComposer();
    if (state.replyTo.mention && !field.value.startsWith(state.replyTo.mention)) field.value = state.replyTo.mention + ' ' + field.value;
    field.focus(); autosize();
  }
  function updateComposer() {
    const chip = $('replychip');
    chip.textContent = '';
    if (state.replyTo) {
      chip.append(h('span', { text: 'Ответ для ' + (state.replyTo.author || 'комментария') }), h('button', { class: 'icon-btn', 'aria-label': 'Отменить ответ', text: '×', onclick: () => { state.replyTo = null; updateComposer(); } }));
      chip.hidden = false; field.placeholder = 'Ваш ответ';
    } else { chip.hidden = true; field.placeholder = 'Написать комментарий'; }
    send.disabled = !field.value.trim();
  }
  function autosize() { field.style.height = 'auto'; field.style.height = Math.min(field.scrollHeight, 160) + 'px'; send.disabled = !field.value.trim(); }
  field.addEventListener('input', autosize);
  field.addEventListener('keydown', e => { if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) { e.preventDefault(); $('composer').requestSubmit(); } });
  $('composer').addEventListener('submit', async e => {
    e.preventDefault();
    const text = field.value.trim(), c = state.comments;
    if (!text || !c) return;
    const parent = state.replyTo?.threadId || null;
    send.disabled = true; field.disabled = true;
    const body = JSON.stringify(parent ? { parent, text } : { video: c.id, text });
    const post = () => api('/api/account/comment', { method: 'POST', headers: { 'content-type': 'application/json' }, body });
    let r = await post();
    if (r.status === 401) { await loadAccount(); if (state.account?.signedIn) r = await post(); }
    field.disabled = false;
    if (!r.ok) {
      send.disabled = false;
      if (r.data?.code === 'COMMENTS_SCOPE') openSheet(h('div', { class: 'sheet-body' }, h('div', { class: 'sheet-title', text: 'Нужно разрешение' }), h('p', { class: 'muted', text: 'Чтобы публиковать комментарии, войдите заново и разрешите приложению управлять комментариями.' }), h('button', { class: 'btn primary wide', text: 'Войти заново', onclick: signIn })));
      else toast(r.data?.error || 'Не удалось отправить');
      return;
    }
    field.value = ''; autosize();
    if (parent) {
      const thread = c.items.find(t => t.id === parent);
      if (thread) { thread.replies.push(r.data.item); thread.replyCount++; }
      const box = document.querySelector('[data-thread="' + CSS.escape(parent) + '"] .replies');
      const card = box && thread ? commentCard(r.data.item, thread) : null;
      if (card) { box.append(card); card.classList.add('fresh'); card.scrollIntoView({ block: 'center', behavior: 'smooth' }); }
    } else {
      c.items.unshift(r.data.item);
      const view = threadView(r.data.item); view.classList.add('fresh');
      $('threads')?.prepend(view); view.scrollIntoView({ block: 'center', behavior: 'smooth' });
    }
    state.replyTo = null; updateComposer();
    toast('Опубликовано');
  });

  // ---------- Router ----------
  function route() {
    closeSheet();
    const hash = location.hash.slice(1), params = new URLSearchParams(hash);
    const id = params.get('v');
    if (id && /^[\w-]{11}$/.test(id)) renderVideo(id, params.get('tab'));
    else renderHome();
    window.scrollTo(0, 0);
  }
  let inApp = false;
  $('back').addEventListener('click', () => { if (inApp) history.back(); else location.hash = ''; });
  window.addEventListener('hashchange', () => { inApp = true; route(); });
  const query = new URLSearchParams(location.search);
  if (query.has('auth') || location.hash === '#you') {
    let back = ''; try { back = sessionStorage.getItem('axr.return') || ''; sessionStorage.removeItem('axr.return'); } catch {}
    const auth = query.get('auth');
    history.replaceState(null, '', '/' + back);
    setTimeout(() => toast(auth === 'denied' ? 'Вход отменён' : auth === 'failed' ? 'Вход не удался' : auth === 'partial' ? 'Вход выполнен без права на комментарии' : 'Вы вошли'), 300);
  }
  loadAccount();
  route();
  if ('serviceWorker' in navigator) navigator.serviceWorker.register('/sw.js').catch(() => {});
}

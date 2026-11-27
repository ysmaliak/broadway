import Foundation
import WebKit

extension AgentPage {
    static let stateScript = """

    function broadwayState() {
      var st = window.__broadwayRefs;
      if (!st || !st.doc) {
        st = window.__broadwayRefs = { ids: new WeakMap(), map: {}, said: {}, target: {}, words: {}, tags: {}, seen: {}, place: {}, only: {}, next: typeof broadwayFrom === 'number' && broadwayFrom > 0 ? broadwayFrom : 1,
          doc: Date.now().toString(36) + Math.random().toString(36).slice(2, 10) };
      }
      if (!st.place) { st.place = {}; st.only = {}; }
      return st;
    }
    function broadwayRowOf(el) {
      var row = el.parentElement && el.parentElement.closest('li,tr,[role=row],[role=listitem],article,[role=article],[class*="card" i]');
      return row && row !== document.body && row !== document.documentElement ? row : null;
    }
    function broadwayRowName(row) {
      var label = row.getAttribute('aria-label');
      if (label) return broadwayFlat(label, 60);
      var words = '', walker = document.createTreeWalker(row, NodeFilter.SHOW_TEXT), n;
      while ((n = walker.nextNode()) && words.length < 200) {
        var p = n.parentElement, inside = p && p.closest('a,button,select,textarea,option,script,style,[role=button],[role=link],[aria-hidden=true]');
        if (!p || (inside && row.contains(inside))) continue;
        words += ' ' + n.data;
      }
      return broadwayFlat(words, 60);
    }
    function broadwayPlace(el) {
      var row = broadwayRowOf(el);
      if (row) return broadwayRowName(row);
      for (var up = el, depth = 0, looked = 0; up && up !== document.body && depth < 8; up = up.parentElement, depth++) {
        for (var s = up.previousElementSibling; s && looked < 40; s = s.previousElementSibling, looked++) {
          if (/^H[1-6]$/.test(s.tagName) || s.getAttribute('role') === 'heading') return '# ' + broadwayFlat(s.textContent, 60);
        }
      }
      return '';
    }
    function broadwayDanger(said) {
      return /\\b(delete|remove|erase|destroy|discard|trash|pay|buy|purchase|order|checkout|send|submit|transfer|publish|unsubscribe)\\b/i.test(said || '');
    }
    function broadwayCounts(rows) {
      var said = {}, shown = {};
      for (var i = 0; i < rows.length; i++) {
        var row = rows[i];
        if (!row.item || row.landmark) continue;
        var key = row.item.role + ' ' + (row.label || ''), seenAs = row.item.role + ' ' + row.item.name;
        said[key] = (said[key] || 0) + 1;
        shown[seenAs] = (shown[seenAs] || 0) + 1;
      }
      return { said: said, shown: shown };
    }
    function broadwayFlat(text, most) { return String(text || '').replace(/\\s+/g, ' ').trim().slice(0, most || 120); }
    function broadwayRead(el, target) { var d = describe(el, target || null); return d.kind + ' ' + d.label; }
    function broadwayRef(el, target) {
      var st = broadwayState(), number = st.ids.get(el);
      if (!number) { number = st.next++; st.ids.set(el, number); }
      var ref = 'e' + number;
      st.map[ref] = el;
      if (target) st.target[ref] = target;
      if (st.said[ref] === undefined) {
        st.said[ref] = broadwayRead(el, st.target[ref]);
        st.tags[ref] = el.tagName;
        st.words[ref] = broadwayFlat(el.innerText);
      }
      return ref;
    }
    function broadwayTell(ref, counts) {
      var st = broadwayState(), el = st.map[ref];
      if (!el) return;
      st.said[ref] = broadwayRead(el, st.target[ref]);
      st.place[ref] = broadwayPlace(el);
      if (counts) st.only[ref] = counts.said[st.said[ref]] === 1;
    }
    function broadwayGet(ref) {
      var st = window.__broadwayRefs;
      if (!st || !st.map) return { failed: '@' + ref + ' was never given on this page', code: 'stale_ref', why: 'unknown', doc: null };
      var el = st.map[ref], rebound = false;
      if (!el) return { failed: '@' + ref + ' was never given on this page', code: 'stale_ref', why: 'unknown', doc: st.doc, next: st.next };
      if (!el.isConnected) {
        var words = st.words[ref] || '', tag = st.tags[ref], twin = null, only = st.only[ref] === true;
        if (tag && (only || words.length >= 12)) {
          var same = document.getElementsByTagName(tag), hits = [];
          for (var i = 0; i < same.length && hits.length < 2; i++) {
            if (broadwayRead(same[i], null) === st.said[ref] && (only || broadwayFlat(same[i].innerText) === words)) hits.push(same[i]);
          }
          if (hits.length === 1) twin = hits[0];
        }
        if (twin && broadwayDanger(st.said[ref]) && st.place[ref] !== undefined && broadwayPlace(twin) !== st.place[ref]) twin = null;
        if (!twin) return { failed: '@' + ref + ' has left the page', code: 'stale_ref', why: 'gone', doc: st.doc };
        rebound = broadwayRef(twin, null);
        el = twin;
        st.map[ref] = twin;
        delete st.target[ref];
        broadwayTell(rebound);
      } else if (st.place[ref] !== undefined && (st.only[ref] !== true || broadwayDanger(st.said[ref])) && seen(el)) {
        var where = broadwayPlace(el), was = st.place[ref];
        if (where !== was) {
          st.place[ref] = where;
          var moved = describe(el, st.target[ref] || null);
          return { failed: '@' + ref + ' ' + moved.kind + ' "' + broadwayFlat(moved.label, 60) + '" was in "' + was.replace(/^# /, '') + '" and is now in "' + where.replace(/^# /, '') + '". Run the same command again to act on it there',
                   code: 'ref_changed', doc: st.doc };
        }
      }
      var target = st.target[ref] || null, reading = broadwayRead(el, target);
      if (st.said[ref] !== reading && seen(el)) {
        st.said[ref] = reading;
        var now = describe(el, target);
        return { failed: '@' + ref + ' now reads ' + now.kind + ' "' + now.label + '". Run the same command again to act on it as it is now',
                 code: 'ref_changed', now: { ref: ref, role: now.kind, name: now.label }, doc: st.doc };
      }
      return { el: el, target: target, rebound: rebound };
    }
    """

    static let walkScript = """

    function broadwayRGB(value) {
      var m = /^rgba?\\(([\\d.]+),\\s*([\\d.]+),\\s*([\\d.]+)(?:,\\s*([\\d.]+))?\\)/.exec(value || '');
      return m ? { r: +m[1], g: +m[2], b: +m[3], a: m[4] === undefined ? 1 : +m[4] } : null;
    }
    function broadwayLight(c) {
      function one(v) { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); }
      return 0.2126 * one(c.r) + 0.7152 * one(c.g) + 0.0722 * one(c.b);
    }
    function broadwayFaint(el, s, alpha, ground) {
      if (alpha < 0.1) return true;
      if (parseFloat(s.fontSize) < 6 && (el.innerText || '').trim()) return true;
      if (parseFloat(s.textIndent) < -500) return true;
      if ((s.clip && s.clip.indexOf('rect(0') === 0) || /circle\\(0/.test(s.clipPath || '')) return true;
      var fill = broadwayRGB(s.webkitTextFillColor), color = broadwayRGB(s.color);
      if ((fill && fill.a < 0.3) || (color && color.a < 0.3)) return true;
      if (color && ground) {
        var a = broadwayLight(color), b = broadwayLight(ground);
        if ((Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05) < 1.25) return true;
      }
      var r = el.getBoundingClientRect();
      if (r.right + scrollX < 0 || r.bottom + scrollY < 0) return true;
      return false;
    }
    function broadwayGround(el) {
      var alpha = 1, ground = { r: 255, g: 255, b: 255, a: 1 }, chain = [];
      for (var up = el; up && up.nodeType === 1; up = up.parentElement) chain.unshift(up);
      for (var i = 0; i < chain.length; i++) {
        var s = getComputedStyle(chain[i]);
        alpha *= parseFloat(s.opacity) || 0;
        if (s.backgroundImage && s.backgroundImage !== 'none') ground = null;
        else { var bg = broadwayRGB(s.backgroundColor); if (bg && bg.a > 0.5 && ground !== null) ground = bg; }
      }
      return { alpha: alpha, ground: ground };
    }
    function broadwayLegible(el) {
      if (!el || el.nodeType !== 1 || !seen(el)) return false;
      var at = broadwayGround(el);
      return !broadwayFaint(el, getComputedStyle(el), at.alpha, at.ground);
    }
    function broadwayVisibleText(root) {
      var out = [], kept = new Map(), walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT), node, count = 0;
      while ((node = walker.nextNode()) && count++ < 20000) {
        var parent = node.parentElement;
        if (!parent || /^(SCRIPT|STYLE|NOSCRIPT|TEMPLATE)$/.test(parent.tagName) || !node.data.trim()) continue;
        if (!kept.has(parent)) kept.set(parent, broadwayLegible(parent));
        if (kept.get(parent)) out.push(node.data);
      }
      return out.join(' ');
    }
    function broadwayNeeds() {
      var walls = document.querySelectorAll('iframe[src*="recaptcha"],iframe[src*="hcaptcha"],iframe[src*="challenges.cloudflare.com"],iframe[src*="arkoselabs"],iframe[src*="funcaptcha"],.g-recaptcha,.h-captcha,.cf-turnstile,#cf-challenge-running');
      for (var w = 0; w < walls.length; w++) {
        var wall = walls[w], wr = wall.getBoundingClientRect();
        var quiet = (wall.getAttribute('src') || '').indexOf('size=invisible') >= 0 || wall.getAttribute('data-size') === 'invisible';
        if (!quiet && wr.width >= 40 && wr.height >= 20 && seen(wall)) return 'captcha';
      }
      var boxes = document.querySelectorAll('input');
      var password = 0;
      for (var i = 0; i < boxes.length; i++) {
        var b = boxes[i];
        if (!seen(b) || b.disabled) continue;
        var called = ((b.getAttribute('autocomplete') || '') + ' ' + (b.name || '') + ' ' + (b.id || '') + ' ' + (b.getAttribute('aria-label') || '') + ' ' + (b.placeholder || '')).toLowerCase();
        if (b.labels) for (var l = 0; l < b.labels.length; l++) called += ' ' + (b.labels[l].textContent || '').toLowerCase();
        if (/one-time-code|\\botp\\b|one.?time|verification.?code|security.?code|2fa|two.?factor|authenticator|sms.?code/.test(called)) return 'code';
        if ((b.type || '').toLowerCase() !== 'password' || (b.getAttribute('autocomplete') || '').toLowerCase() === 'new-password') continue;
        if (b.value && window.__broadwaySealed && window.__broadwaySealed.has(b)) continue;
        if (/token|api.?key|\\bkey\\b|secret/.test(called) && !broadwaySignIn(b)) continue;
        password++;
      }
      return password === 1 ? 'password' : '';
    }
    function broadwaySignIn(box) {
      if ((box.getAttribute('autocomplete') || '').toLowerCase() === 'current-password') return true;
      var around = (box.closest('form') || document.body).querySelectorAll('input');
      for (var i = 0; i < around.length; i++) {
        var b = around[i], kind = (b.type || '').toLowerCase();
        if (b === box || kind === 'hidden' || kind === 'password' || !seen(b)) continue;
        var called = ((b.getAttribute('autocomplete') || '') + ' ' + (b.name || '') + ' ' + (b.id || '') + ' ' + (b.getAttribute('aria-label') || '') + ' ' + (b.placeholder || '')).toLowerCase();
        if (kind === 'email' || /user|email|e-mail|login|account/.test(called)) return true;
      }
      return false;
    }
    function broadwayWays() {
      var forms = Array.prototype.filter.call(document.querySelectorAll('input[type=password],input[type=email],input[autocomplete=username],input[autocomplete=email]'), seen);
      if (!forms.length) return [];
      var names = { google: 'Google', apple: 'Apple', github: 'GitHub', microsoft: 'Microsoft', facebook: 'Facebook' };
      var found = [];
      var near = forms[0].closest('form') || forms[0].parentElement;
      for (var up = 0; near && up < 4 && near.parentElement && near.parentElement !== document.body; up++) near = near.parentElement;
      (near || document.body).querySelectorAll('button,a,[role=button]').forEach(function (b) {
        if (!seen(b) || b.closest('footer,[role=contentinfo]')) return;
        var said = broadwayFlat(b.innerText || b.getAttribute('aria-label') || b.title || '', 60).toLowerCase();
        var hit = said.match(/^(?:continue|sign in|log in|sign up)\\s+with\\s+(google|apple|github|microsoft|facebook)$/) || said.match(/^(google|apple|github|microsoft|facebook)$/);
        if (hit && found.indexOf(names[hit[1]]) < 0) found.push(names[hit[1]]);
      });
      return found;
    }
    function broadwayValueOf(subject, kind) {
      if (!/^(textbox|combobox|searchbox|slider|spinbutton)$/.test(kind)) return undefined;
      if ('value' in subject && subject.value && subject.tagName !== 'BUTTON') return String(subject.value).slice(0, 200);
      if (subject.isContentEditable && subject.innerText.trim()) return subject.innerText.replace(/\\s+/g, ' ').trim().slice(0, 200);
      var aria = subject.getAttribute('aria-valuetext') || subject.getAttribute('aria-valuenow');
      return aria ? String(aria).slice(0, 200) : undefined;
    }
    function broadwayNearText(el) {
      for (var up = el.parentElement, i = 0; up && i < 4 && up !== document.body && up !== document.documentElement; up = up.parentElement, i++) {
        var words = '', walker = document.createTreeWalker(up, NodeFilter.SHOW_TEXT), n;
        while ((n = walker.nextNode()) && words.length < 200) {
          var p = n.parentElement;
          if (!p || p.closest('a,button,select,textarea,option,script,style,title,noscript,[role=button],[role=link],[role=option],[role=tab],[role=menuitem]')) continue;
          words += ' ' + n.data;
        }
        words = broadwayFlat(words, 80);
        if (words) return words;
      }
      return '';
    }
    function broadwayIcon(el) {
      function clean(t) {
        t = String(t || '').split(/[#\\/]/).pop().replace(/\\.(svg|png|gif|jpe?g|webp)$/i, '').replace(/^(icons?|ico|ic|i|svg|sprite|glyph)[-_:]/i, '').replace(/[-_]+/g, ' ').trim().toLowerCase();
        return t.length > 1 && t.length <= 30 && !/^\\d+$/.test(t) ? t : '';
      }
      var found = clean(el.getAttribute('data-icon')), inner = el.querySelector('[data-icon]');
      if (!found && inner) found = clean(inner.getAttribute('data-icon'));
      var use = el.querySelector('use');
      if (!found && use) found = clean(use.getAttribute('href') || use.getAttribute('xlink:href'));
      var title = el.querySelector('svg title');
      if (!found && title) found = clean(title.textContent);
      var marks = found ? [] : el.querySelectorAll('i,span,svg,img');
      for (var i = 0; i < marks.length && i < 6 && !found; i++) {
        var m = marks[i];
        if (m.tagName === 'IMG') { found = clean(m.getAttribute('alt')) || clean(m.getAttribute('src')); continue; }
        if (m.getAttribute('aria-hidden') !== 'true' && m.tagName !== 'I' && m.tagName.toLowerCase() !== 'svg') continue;
        var names = (m.getAttribute('class') || '').split(/\\s+/);
        for (var j = 0; j < names.length && !found; j++) {
          var hit = /^(?:fa|fas|far|fab|bi|icon|icons|ion|ri|mdi|ti|lucide|gg|feather|glyphicon|octicon|codicon|ph|tabler|heroicon)-(.+)$/i.exec(names[j]);
          if (hit && !/^(solid|regular|light|thin|brands|duotone|lg|sm|xs|xl|\\d+x|fw|spin|pulse|border|inverse|stack|outline|outlined|filled|sharp|round|rounded)$/i.test(hit[1])) found = clean(hit[1]);
        }
      }
      if (!found) found = clean(el.getAttribute('data-testid') || el.getAttribute('data-test-id'));
      return found;
    }
    function broadwayItem(el, target, kind, label, ref) {
      var boxed = /^(textbox|searchbox|combobox|slider|spinbutton|checkbox|radio|switch)$/.test(kind);
      var said = label || (kind === 'heading' || broadwayTold.test(kind) ? '' : boxed ? broadwayNearText(el) : nearby(el));
      if (!said && boxed && broadwaySecret(target || el)) said = ((target || el).getAttribute('type') || '').toLowerCase() === 'password' ? 'password field' : 'secret field';
      var subject = target || el;
      var line = '@' + ref + ' ' + kind + ' "' + said + '"', item = { ref: ref, role: kind, name: said };
      if (!label && !boxed && kind !== 'heading' && !broadwayTold.test(kind)) {
        var icon = broadwayIcon(el);
        if (icon) { item.icon = icon; line += ' icon="' + icon.replace(/"/g, "'") + '"'; }
      }
      var cut = line.length;
      var secret = broadwaySecret(subject);
      if (/^(textbox|combobox|searchbox|slider|spinbutton)$/.test(kind)) {
        if (secret) { line += ' value hidden'; item.hidden = true; }
        else {
          var value = broadwayValueOf(subject, kind);
          if (value !== undefined) { item.value = value; line += ' value="' + value.replace(/"/g, "'") + '"'; }
        }
      }
      if (subject.tagName === 'SELECT' && !secret) item.options = Array.from(subject.options).slice(0, 100).map(function (o) { return { value: o.value.slice(0, 200), label: o.label.slice(0, 120), disabled: o.disabled || (o.parentElement.tagName === 'OPTGROUP' && o.parentElement.disabled) }; });
      if (item.options) line += ' options=' + JSON.stringify(item.options);
      if (/^(checkbox|radio|switch|menuitemcheckbox|menuitemradio)$/.test(kind)) {
        var aria = subject.getAttribute('aria-checked');
        var mixed = subject.indeterminate === true || aria === 'mixed';
        var on = subject.tagName === 'INPUT' ? subject.checked : aria === 'true';
        item.checked = mixed ? 'mixed' : on;
        line += mixed ? ' mixed' : kind === 'switch' ? (on ? ' on' : ' off') : (on ? ' checked' : ' unchecked');
      } else if (subject.checked) { line += ' checked'; item.checked = true; }
      if (subject.getAttribute('aria-pressed') === 'true') { line += ' pressed'; item.pressed = true; }
      if (subject.getAttribute('aria-selected') === 'true') { line += ' selected'; item.selected = true; }
      var expanded = subject.getAttribute('aria-expanded');
      if (expanded === 'true' || expanded === 'false') { item.expanded = expanded === 'true'; line += item.expanded ? ' expanded' : ' collapsed'; }
      if (subject.type === 'file' && subject.tagName === 'INPUT') {
        item.upload = { accept: subject.accept || '', multiple: !!subject.multiple, files: subject.files ? subject.files.length : 0 };
        line += ' takes ' + (subject.multiple ? 'files' : 'a file') + (subject.accept ? ' accept="' + subject.accept.replace(/"/g, "'").slice(0, 120) + '"' : '');
        if (item.upload.files) {
          item.upload.names = Array.prototype.slice.call(subject.files, 0, 5).map(function (f) { return String(f.name).slice(0, 80); });
          line += ' has ' + item.upload.files + ' chosen="' + item.upload.names.join(', ').replace(/"/g, "'") + '"';
        }
      }
      if (subject.disabled || subject.getAttribute('aria-disabled') === 'true' || (subject.closest && subject.closest('fieldset[disabled]'))) { line += ' disabled'; item.disabled = true; }
      if (subject.required || subject.getAttribute('aria-required') === 'true') { line += ' required'; item.required = true; }
      var wrong = subject.getAttribute('aria-invalid') === 'true' || (subject.willValidate && subject.validity && !subject.validity.valid && subject.value && !secret);
      if (wrong) {
        var why = '', errs = subject.getAttribute('aria-errormessage') || subject.getAttribute('aria-describedby') || '';
        errs.split(/\\s+/).forEach(function (id) { var n = id && document.getElementById(id); if (n && !why) why = broadwayFlat(n.innerText || n.textContent, 80); });
        if (!why && subject.validationMessage) why = broadwayFlat(subject.validationMessage, 80);
        item.invalid = why || true;
        line += why ? ' invalid="' + why.replace(/"/g, "'") + '"' : ' invalid';
      }
      if (subject.readOnly && kind === 'textbox') { line += ' readonly'; item.readonly = true; }
      if (document.activeElement === subject || (subject.getRootNode && subject.getRootNode().activeElement === subject)) { line += ' focused'; item.focused = true; }
      if (kind === 'link') {
        try {
          var to = new URL(el.href);
          item.path = to.pathname;
          if (to.hostname === location.hostname || !/^https?:$/.test(to.protocol)) line += ' -> ' + item.path;
          else { item.href = to.href; line += ' -> ' + '\u{27EA}' + to.href + '\u{27EB}'; }
        } catch (e) {}
      }
      return { item: item, line: line, cut: cut, bare: !label };
    }
    function broadwayReading(item) {
      var marks = [];
      if (item.checked === 'mixed') marks.push('mixed');
      else if (item.checked === true) marks.push(item.role === 'switch' ? 'on' : 'checked');
      else if (item.checked === false && /^(checkbox|radio|switch|menuitemcheckbox|menuitemradio)$/.test(item.role)) marks.push(item.role === 'switch' ? 'off' : 'unchecked');
      if (item.pressed) marks.push('pressed');
      if (item.selected) marks.push('selected');
      if (item.expanded === true) marks.push('expanded');
      if (item.expanded === false) marks.push('collapsed');
      if (item.disabled) marks.push('disabled');
      if (item.upload && item.upload.files) marks.push('has ' + item.upload.files);
      var found = { ref: item.ref, role: item.role, name: item.name };
      if (item.value !== undefined && !item.hidden) found.value = item.value;
      if (marks.length) found.state = marks.join(' ');
      return found;
    }
    function broadwayLandmark(el) {
      var named = (el.getAttribute('role') || '').trim().split(/\\s+/)[0].toLowerCase(), tag = el.tagName.toLowerCase();
      var label = el.getAttribute('aria-label') || '';
      var by = el.getAttribute('aria-labelledby');
      if (!label && by) label = by.split(/\\s+/).map(function (id) { var n = document.getElementById(id); return n && n !== el ? n.innerText || n.textContent || '' : ''; }).join(' ');
      label = broadwayFlat(label, 80);
      var inside = el.parentElement && el.parentElement.closest('article,aside,main,nav,section,[role=main],[role=navigation],[role=complementary],[role=region]');
      if (named === 'main' || (!named && tag === 'main')) return { role: 'main', name: label };
      if (named === 'navigation' || (!named && tag === 'nav')) return { role: 'navigation', name: label };
      if (named === 'complementary' || (!named && tag === 'aside')) return { role: 'complementary', name: label };
      if (named === 'banner' || (!named && tag === 'header' && !inside)) return { role: 'banner', name: label };
      if (named === 'contentinfo' || (!named && tag === 'footer' && !inside)) return { role: 'contentinfo', name: label };
      if (named === 'search') return { role: 'search', name: label };
      if ((named === 'form' || (!named && tag === 'form')) && label) return { role: 'form', name: label };
      if ((named === 'region' || (!named && tag === 'section')) && label) return { role: 'region', name: label };
      if (named === 'dialog' || named === 'alertdialog' || (!named && tag === 'dialog')) return { role: named === 'alertdialog' ? 'alertdialog' : 'dialog', name: name(el) };
      return null;
    }
    function broadwayModal() {
      var all = document.querySelectorAll('dialog[open],[role=dialog],[role=alertdialog]');
      for (var i = all.length - 1; i >= 0; i--) {
        var d = all[i], modal = false;
        if (d.tagName === 'DIALOG') { try { modal = d.matches(':modal'); } catch (e) { modal = false; } }
        if (!modal) modal = d.getAttribute('aria-modal') === 'true';
        if (!modal || !seen(d)) continue;
        var hit = document.elementFromPoint(innerWidth / 2, innerHeight / 2), blocks = false;
        if (hit && (hit === d || d.contains(hit))) blocks = true;
        else if (hit) {
          var r = hit.getBoundingClientRect(), s = getComputedStyle(hit);
          blocks = (s.position === 'fixed' || s.position === 'absolute') && r.width >= innerWidth * 0.9 && r.height >= innerHeight * 0.9 && !hit.contains(d);
        }
        return { el: d, blocks: blocks };
      }
      return null;
    }
    function broadwayOwnText(el) {
      var words = '';
      for (var n = el.firstChild; n; n = n.nextSibling) if (n.nodeType === 3) words += n.data;
      return broadwayFlat(words, 160);
    }
    function broadwayInView(el) {
      var r = el.getBoundingClientRect();
      return r.bottom > 0 && r.right > 0 && r.top < innerHeight && r.left < innerWidth;
    }
    function broadwayWalk(root, o) {
      o = o || {};
      var cap = o.cap || 5000, count = 0, rows = [], regions = [], proxies = new Map();
      function proxyFor(input) {
        var labels = input.labels || [];
        for (var i = 0; i < labels.length; i++) if (seen(labels[i])) return labels[i];
        var up = input.parentElement;
        for (var depth = 0; up && depth < 3; up = up.parentElement, depth++) {
          if (!seen(up)) continue;
          if (input.type === 'file') {
            var buttons = up.querySelectorAll('button,[role=button],a,label');
            for (var b = 0; b < buttons.length; b++) if (seen(buttons[b])) return buttons[b];
          }
          var r = up.getBoundingClientRect();
          if (r.width * r.height <= 160000) return up;
        }
        return null;
      }
      function collect(at) {
        var inputs = at.querySelectorAll('input[type=checkbox],input[type=radio],input[type=file]');
        for (var i = 0; i < inputs.length; i++) {
          if (seen(inputs[i])) continue;
          var proxy = proxyFor(inputs[i]);
          if (proxy && !proxies.has(proxy)) proxies.set(proxy, inputs[i]);
        }
        var all = at.querySelectorAll('*');
        for (var j = 0; j < all.length; j++) if (all[j].shadowRoot) collect(all[j].shadowRoot);
      }
      var boxes = document.querySelectorAll('input[type=password]');
      for (var h = 0; h < boxes.length; h++) boxes[h].__broadwaySecret = true;
      collect(document);
      var unseen = 0;
      var fields = /^(textbox|searchbox|combobox|slider|spinbutton|checkbox|radio|switch|file)$/;
      var hovers = new Set(), rules = 0;
      try {
        for (var si = 0; si < document.styleSheets.length && rules < 300; si++) {
          var list;
          try { list = document.styleSheets[si].cssRules; } catch (e) { continue; }
          for (var ri = 0; list && ri < list.length && rules < 300; ri++) {
            var picked = list[ri].selectorText;
            if (!picked || picked.indexOf(':hover') < 0) continue;
            rules++;
            picked.split(',').forEach(function (part) {
              var at = part.indexOf(':hover');
              if (at < 0 || !/[\\s>+~]\\S/.test(part.slice(at + 6))) return;
              try { document.querySelectorAll(part.slice(0, at).trim() || '*').forEach(function (n) { hovers.add(n); }); } catch (e) {}
            });
          }
        }
      } catch (e) {}
      function hovered(el) {
        for (var up = el, depth = 0; up && depth < 4; up = up.parentElement, depth++) if (hovers.has(up)) return true;
        return false;
      }
      function scrolls(el, look) {
        if (el === document.body || el === document.documentElement) return false;
        if (!/(auto|scroll)/.test(look.overflowY + ' ' + look.overflowX)) return false;
        var r = el.getBoundingClientRect();
        var tall = el.scrollHeight > el.clientHeight + 4 && /(auto|scroll)/.test(look.overflowY), wide = el.scrollWidth > el.clientWidth + 4 && /(auto|scroll)/.test(look.overflowX);
        return r.width >= 40 && ((tall && r.height >= 40) || (wide && r.height >= 12));
      }
      function visit(el, region, alpha, ground) {
        if (count >= cap || el === o.skip) return;
        if (!seen(el)) {
          if (el.hidden || el.getAttribute('aria-hidden') === 'true') return;
          var faded = getComputedStyle(el);
          if (faded.display === 'none' || parseFloat(faded.opacity) < 0.1 || el.tagName === 'INPUT' || el.tagName === 'SELECT' || el.tagName === 'TEXTAREA') return;
          if (el.shadowRoot) for (var hs = el.shadowRoot.firstElementChild; hs; hs = hs.nextElementSibling) visit(hs, region, alpha, ground);
          for (var hc = el.firstElementChild; hc; hc = hc.nextElementSibling) visit(hc, region, alpha, ground);
          return;
        }
        var look = getComputedStyle(el);
        alpha = alpha * (parseFloat(look.opacity) || 0);
        if (look.backgroundImage && look.backgroundImage !== 'none') ground = null;
        else { var paint = broadwayRGB(look.backgroundColor); if (paint && paint.a > 0.5 && ground !== null) ground = paint; }
        if (el.tagName === 'INPUT' && !/^(checkbox|radio|file|hidden)$/i.test(el.type || '')) {
          var box = el.getBoundingClientRect();
          if (box.width < 4 || box.height < 4 || (el.tabIndex < 0 && el.getAttribute('aria-hidden') === 'true')) return;
        }
        var mark = broadwayLandmark(el), here = region;
        if (mark) {
          var rref = broadwayRef(el, null);
          regions.push({ ref: rref, role: mark.role, name: mark.name });
          if (mark.role === 'dialog' || mark.role === 'alertdialog') {
            count++;
            rows.push({ el: el, region: region, landmark: true, item: { ref: rref, role: mark.role, name: mark.name } });
          } else if (scrolls(el, look)) {
            count++;
            var lname = broadwayFlat(mark.name || '', 40), lbox = { ref: rref, role: 'scrollable', name: lname, scrolls: true };
            if (region) lbox.region = region;
            rows.push({ el: el, region: region, item: lbox, line: '@' + rref + ' scrollable "' + lname.replace(/"/g, "'") + '" scrolls' });
          }
          here = rref;
        } else {
          var target = proxies.get(el) || null, seenAs = describe(el, target), kind = seenAs.kind;
          if (kind && !fields.test(kind) && !target && !el.hasAttribute('aria-label') && !el.hasAttribute('aria-labelledby') && !el.hasAttribute('title') && !el.disabled && el.getAttribute('aria-disabled') !== 'true' && broadwayFaint(el, look, alpha, ground)) { unseen++; return; }
          if (!kind && el.hasAttribute('data-broadway-closed')) {
            count++;
            var cref = broadwayRef(el, null);
            var shut = { ref: cref, role: 'group', name: '', closed: true };
            if (here) shut.region = here;
            rows.push({ el: el, region: here, item: shut, line: '@' + cref + ' group closed to reading: broadway shot shows it, broadway click --at X,Y acts in it' });
          }
          if (!kind && scrolls(el, look)) {
            count++;
            var sref = broadwayRef(el, null);
            var called = broadwayFlat(el.getAttribute('aria-label') || (el.querySelector('h1,h2,h3,h4,[role=heading]') || {}).innerText || el.innerText, 40);
            var boxItem = { ref: sref, role: 'scrollable', name: called, scrolls: true };
            if (here) boxItem.region = here;
            rows.push({ el: el, region: here, item: boxItem, line: '@' + sref + ' scrollable "' + called.replace(/"/g, "'") + '" scrolls' });
          }
          if (kind) {
            count++;
            var ref = broadwayRef(el, target), built = broadwayItem(el, target, kind, seenAs.label, ref);
            if (here) built.item.region = here;
            if (hovers.size && !broadwayTold.test(kind) && kind !== 'heading' && hovered(el)) { built.item.hover = true; built.line += ' opens-on-hover'; }
            rows.push({ el: el, region: here, item: built.item, line: built.line, cut: built.cut, bare: built.bare, label: seenAs.label });
            var opens = kind === 'heading' || kind === 'dropzone' || el.tagName === 'SELECT' || kind === 'textbox' || (kind === 'combobox' && el.tagName !== 'INPUT') || broadwayTold.test(kind);
            if (!opens) return;
          } else if (o.text) {
            var words = broadwayOwnText(el);
            if (words && broadwayFaint(el, look, alpha, ground)) unseen++;
            else if (words) rows.push({ el: el, region: here, text: words });
          }
        }
        if (el.shadowRoot) for (var s = el.shadowRoot.firstElementChild; s; s = s.nextElementSibling) visit(s, here, alpha, ground);
        for (var c = el.firstElementChild; c; c = c.nextElementSibling) visit(c, here, alpha, ground);
      }
      if (root) {
        var start = root.parentElement ? broadwayGround(root.parentElement) : { alpha: 1, ground: { r: 255, g: 255, b: 255, a: 1 } };
        visit(root, o.region || '', start.alpha, start.ground);
      }
      return { rows: rows, regions: regions, cut: count >= cap, unseen: unseen };
    }
    function broadwayReadings(rows) {
      var map = {}, order = [];
      for (var i = 0; i < rows.length; i++) {
        if (!rows[i].item) continue;
        var r = broadwayReading(rows[i].item);
        if (map[r.ref]) continue;
        map[r.ref] = r;
        order.push(r.ref);
      }
      return { map: map, order: order };
    }
    function broadwayDiff(was, now, most) {
      var appeared = [], went = [], changed = [], extra = 0;
      for (var i = 0; i < now.order.length; i++) {
        var ref = now.order[i], n = now.map[ref], w = was.map[ref];
        if (!w) { if (appeared.length < most) appeared.push(n); else extra++; continue; }
        var before = {}, differs = false;
        if (w.name !== n.name) { before.name = w.name; differs = true; }
        if ((w.value || '') !== (n.value || '')) { before.value = w.value || ''; differs = true; }
        if ((w.state || '') !== (n.state || '')) { before.state = w.state || ''; differs = true; }
        if (differs) { var c = JSON.parse(JSON.stringify(n)); c.was = before; if (changed.length < most) changed.push(c); else extra++; }
      }
      for (var j = 0; j < was.order.length; j++) {
        var gone = was.order[j];
        if (now.map[gone]) continue;
        if (went.length < most) went.push(was.map[gone]); else extra++;
      }
      return { appeared: appeared, went: went, changed: changed, more: extra };
    }
    function broadwayLevel(el) {
      var tag = /^H([1-6])$/.exec(el.tagName || '');
      if (tag) return +tag[1];
      return (el.getAttribute && el.getAttribute('role') === 'heading') ? (+(el.getAttribute('aria-level')) || 2) : 0;
    }
    function broadwayScopes(words, targets) {
      var want = broadwayFlat(words, 200).toLowerCase(), marks = [], scopes = [];
      if (!want || !document.body) return scopes;
      function flat(el) { return broadwayFlat(el.innerText || '', 100000).toLowerCase(); }
      document.querySelectorAll('[aria-label],[aria-labelledby]').forEach(function (el) {
        if (seen(el) && broadwayFlat(name(el), 200).toLowerCase().indexOf(want) >= 0 && targets.some(function (t) { return el !== t && el.contains(t); })) scopes.push(el);
      });
      function dig(el) {
        var deeper = false;
        for (var c = el.firstElementChild; c; c = c.nextElementSibling) {
          if (/^(SCRIPT|STYLE|NOSCRIPT|TEMPLATE|TITLE)$/.test(c.tagName) || flat(c).indexOf(want) < 0) continue;
          deeper = true;
          if (marks.length < 40) dig(c);
        }
        if (!deeper && marks.length < 40) marks.push(el);
      }
      if (flat(document.body).indexOf(want) >= 0) dig(document.body);
      function blocked(up, mark, level) {
        if (marks.some(function (m) { return m !== mark && up.contains(m) && !m.contains(mark) && !mark.contains(m); })) return true;
        if (!level) return false;
        var heads = up.querySelectorAll('h1,h2,h3,h4,h5,h6,[role=heading]');
        for (var i = 0; i < heads.length; i++) if (heads[i] !== mark && !heads[i].contains(mark) && !mark.contains(heads[i]) && broadwayLevel(heads[i]) <= level) return true;
        return false;
      }
      marks.forEach(function (mark) {
        var level = broadwayLevel(mark);
        if (!level) for (var hup = mark.parentElement, d = 0; hup && d < 2 && !level; hup = hup.parentElement, d++) { if (broadwayLevel(hup)) { level = broadwayLevel(hup); mark = hup; } }
        for (var up = mark; up && up !== document.documentElement; up = up.parentElement) {
          if (up !== mark && blocked(up, mark, level)) break;
          if (targets.some(function (t) { return up.contains(t); })) { scopes.push(up); return; }
        }
        if (!level) return;
        for (var s = mark.nextElementSibling; s; s = s.nextElementSibling) {
          if (broadwayLevel(s) && broadwayLevel(s) <= level) break;
          var inner = s.querySelectorAll ? s.querySelectorAll('h1,h2,h3,h4,h5,h6,[role=heading]') : [];
          if (Array.prototype.some.call(inner, function (h) { return broadwayLevel(h) <= level; })) break;
          scopes.push(s);
        }
      });
      return scopes;
    }
    function broadwayNear(el) {
      var holder = el.parentElement && el.parentElement.closest('li,[role=listitem],tr,[role=row],article,[role=article],section,[role=region],form,fieldset,[role=group],dialog,[role=dialog],[role=alertdialog],[role=option]');
      if (!holder || holder === document.body) return null;
      var kinds = { LI: 'list item', TR: 'row', ARTICLE: 'article', SECTION: 'region', FORM: 'form', FIELDSET: 'group', DIALOG: 'dialog' };
      var named = (holder.getAttribute('role') || '').toLowerCase();
      var kind = named === 'listitem' ? 'list item' : named || kinds[holder.tagName] || 'part';
      var label = holder.getAttribute('aria-label') || '';
      if (!label) { var head = holder.querySelector('h1,h2,h3,h4,h5,h6,[role=heading],strong,b'); if (head && !head.contains(el)) label = head.innerText || ''; }
      if (!label) {
        var own = broadwayFlat(el.innerText, 200);
        label = broadwayFlat(holder.innerText, 300).replace(own, '').trim();
      }
      label = broadwayFlat(label, 60);
      return label ? { role: kind, name: label } : null;
    }
    """

    static let walkBase = PageSelection.secretCheck + "\n" + naming + stateScript + walkScript

    @MainActor static let closedWorld: WKContentWorld = {
        let made = WKContentWorld.Configuration()
        made.allowAccessingClosedShadowRoots = true
        return WKContentWorld(configuration: made)
    }()

    static let closedScript = """
    var found = 0;
    function mark(root) {
      var all = root.querySelectorAll('*');
      for (var i = 0; i < all.length && i < 20000 && found < 200; i++) {
        var inner = all[i].shadowRoot;
        if (!inner) continue;
        if (inner.mode === 'closed') {
          found++;
          if (!all[i].hasAttribute('data-broadway-closed')) all[i].setAttribute('data-broadway-closed', '');
        } else mark(inner);
      }
    }
    if (document.documentElement) mark(document);
    return found;
    """

    static func walks(_ script: String) -> Bool {
        script.components(separatedBy: "broadwayWalk(").count > 2
    }

    static let watchScript = """

    function broadwayWatch(texts) {
      var st = broadwayState();
      if (st.watch && st.watch.observer) st.watch.observer.disconnect();
      var w = st.watch = { last: performance.now(), touched: [], hosts: new Set(), before: new WeakMap(), texts: !!texts, orders: [] };
      if (texts && document.body) {
        var lists = document.body.querySelectorAll('tbody,ul,ol,[role=rowgroup],[role=list],[role=listbox]');
        for (var o = 0; o < lists.length && w.orders.length < 40; o++) {
          if (lists[o].children.length > 2) w.orders.push({ el: lists[o], kids: [].slice.call(lists[o].children, 0, 2000) });
        }
        var all = document.body.getElementsByTagName('*');
        for (var i = 0; i < all.length && i < 20000; i++) {
          var el = all[i];
          if (!broadwayOwnText(el)) continue;
          var t = broadwayFlat(el.textContent, 400);
          if (t.length <= 120) w.before.set(el, t);
        }
        var live = document.querySelectorAll('[role=status],[role=alert],[role=log],[aria-live]');
        for (var j = 0; j < live.length; j++) w.before.set(live[j], broadwayFlat(live[j].textContent, 300));
      }
      function note(host) {
        if (host && !w.hosts.has(host) && w.touched.length < 60) { w.hosts.add(host); w.touched.push(host); }
      }
      w.observer = new MutationObserver(function (list) {
        for (var k = 0; k < list.length; k++) {
          var m = list[k];
          if (m.type === 'attributes' && (m.attributeName === 'style' || /^data-broadway/.test(m.attributeName || ''))) continue;
          w.last = performance.now();
          if (!w.texts || m.type === 'attributes') continue;
          var node = m.type === 'characterData' ? m.target.parentElement : m.target, host = null;
          for (var up = node; up && up !== document.body && up !== document.documentElement; up = up.parentElement) {
            if (w.before.has(up)) { host = up; break; }
          }
          if (host) { note(host); continue; }
          for (var a = 0; a < m.addedNodes.length; a++) {
            var added = m.addedNodes[a];
            if (added.nodeType === 3 && node && node.nodeType === 1) { note(node); continue; }
            if (added.nodeType !== 1) continue;
            if (broadwayOwnText(added) && broadwayFlat(added.textContent, 400).length <= 120) note(added);
            else { var inner = added.querySelectorAll ? added.querySelectorAll('*') : []; for (var b = 0; b < inner.length && b < 40; b++) if (broadwayOwnText(inner[b]) && broadwayFlat(inner[b].textContent, 400).length <= 120) note(inner[b]); }
          }
        }
      });
      w.observer.observe(document, { subtree: true, childList: true, characterData: true, attributes: true });
      return w;
    }
    function broadwayOrderName(el) {
      var t = el.closest('table,[role=table],[role=grid]') || el, said = t.getAttribute('aria-label') || (t.caption && t.caption.textContent) || '';
      var by = t.getAttribute('aria-labelledby');
      if (!said && by) { var lb = document.getElementById(by.split(' ')[0]); if (lb) said = lb.textContent; }
      if (!said) {
        var hs = document.querySelectorAll('h1,h2,h3,h4,h5,h6,[role=heading]');
        for (var i = hs.length - 1; i >= 0; i--) if (hs[i].compareDocumentPosition(t) & Node.DOCUMENT_POSITION_FOLLOWING) { said = hs[i].textContent; break; }
      }
      return broadwayFlat(said || '', 80);
    }
    function broadwayOrders(w) {
      var out = [];
      if (!w || !w.orders) return out;
      for (var i = 0; i < w.orders.length && out.length < 3; i++) {
        var o = w.orders[i];
        if (!o.el.isConnected || !broadwayLegible(o.el)) continue;
        var kids = [].slice.call(o.el.children), last = -1, moved = false, kept = 0;
        for (var j = 0; j < o.kids.length; j++) {
          if (o.kids[j].parentElement !== o.el) continue;
          var at = kids.indexOf(o.kids[j]);
          kept++;
          if (at < last) moved = true;
          last = at;
        }
        if (!moved || kept < 3) continue;
        var rows = o.el.tagName === 'TBODY' || o.el.getAttribute('role') === 'rowgroup';
        out.push({ kind: rows ? 'rows' : 'items', name: broadwayOrderName(o.el), table: rows });
      }
      return out;
    }
    function broadwayTexts(w) {
      var out = [];
      if (!w) return out;
      for (var i = 0; i < w.touched.length && out.length < 5; i++) {
        var host = w.touched[i];
        if (!host.isConnected || !broadwayLegible(host)) continue;
        var now = broadwayFlat(host.textContent, 400), was = w.before.get(host) || '';
        if (now === was || (!now && !was)) continue;
        var skip = false;
        for (var up = host; up && up !== document.body; up = up.parentElement) {
          if (broadwaySecret(up) || up.isContentEditable && broadwaySecret(up)) { skip = true; break; }
          if (describe(up, null).kind) { skip = true; break; }
        }
        if (skip || host.querySelector('input[type=password]')) continue;
        out.push({ was: was.slice(0, 120), now: now.slice(0, 120) });
      }
      return out;
    }
    """

    static let beforeScript = walkBase + watchScript + """

    var st = broadwayState();
    var walked = broadwayWalk(document.body, { cap: 5000 });
    st.before = broadwayReadings(walked.rows);
    broadwayWatch(true);
    return { doc: st.doc, next: st.next, title: document.title, count: st.before.order.length };
    """

    static let pollScript = walkBase + watchScript + """

    var st = broadwayState();
    if (!st.watch) broadwayWatch(false);
    return { doc: st.doc, quiet: performance.now() - st.watch.last, ready: document.readyState };
    """

    static let afterScript = walkBase + watchScript + """

    var st = broadwayState(), w = st.watch;
    var walked = broadwayWalk(document.body, { cap: 5000 });
    var now = broadwayReadings(walked.rows);
    var out = { doc: st.doc, next: st.next, title: document.title };
    var headings = [];
    for (var i = 0; i < walked.rows.length && headings.length < 5; i++) {
      var item = walked.rows[i].item;
      if (item && item.role === 'heading' && item.name) headings.push(item.name);
    }
    out.headings = headings;
    if (!st.before) {
      out.fresh = true;
    } else {
      var diff = broadwayDiff(st.before, now, most || 40), counts = broadwayCounts(walked.rows);
      diff.appeared.forEach(function (e) { broadwayTell(e.ref, counts); });
      diff.changed.forEach(function (e) { broadwayTell(e.ref, counts); });
      out.appeared = diff.appeared;
      out.went = diff.went;
      out.changed = diff.changed;
      out.more = diff.more;
      out.text = broadwayTexts(w);
      out.reordered = broadwayOrders(w);
      out.total = now.order.length;
      out.counted = diff.appeared.length + diff.went.length + diff.changed.length + diff.more;
    }
    if (who) st.seen[who] = now;
    st.before = null;
    if (w && w.observer) w.observer.disconnect();
    st.watch = null;
    return out;
    """

    static let snapshotScript = walkBase + """

    var st = broadwayState();
    var root = document.body, scope = 'page', modal = false;
    if (inside) {
      var got = broadwayGet(inside);
      if (got.failed) return got;
      root = got.el;
      scope = '@' + inside;
    }
    var aside = null;
    if (!inside && !all) {
      var shown = broadwayModal();
      if (shown && shown.blocks) { root = shown.el; scope = 'dialog'; modal = true; }
      else if (shown) aside = shown.el;
    }
    var walked = broadwayWalk(root, { cap: 5000, text: !!text, skip: aside });
    if (aside) {
      var first = broadwayWalk(aside, { cap: 5000, text: !!text });
      walked = { rows: first.rows.concat(walked.rows), regions: first.regions.concat(walked.regions), cut: first.cut || walked.cut };
    }
    var whole = scope === 'page' && !text ? walked : broadwayWalk(document.body, { cap: 5000 });
    var now = broadwayReadings(whole.rows);
    var out = { doc: st.doc, next: st.next, title: document.title, scope: scope, modal: modal };
    if (since) {
      var before = who && st.seen[who];
      if (before) {
        var diff = broadwayDiff(before, now, 40), sinceCounts = broadwayCounts(whole.rows);
        diff.appeared.forEach(function (e) { broadwayTell(e.ref, sinceCounts); });
        diff.changed.forEach(function (e) { broadwayTell(e.ref, sinceCounts); });
        out.since = true;
        out.appeared = diff.appeared;
        out.went = diff.went;
        out.changed = diff.changed;
        out.more = diff.more;
        if (who) st.seen[who] = now;
        return out;
      }
      out.fresh = true;
    }
    var wanted = roles && roles.length ? roles.map(function (r) { return String(r).toLowerCase(); }) : null;
    var words = find ? String(find).toLowerCase() : '';
    var rows = walked.rows.filter(function (row) {
      if (row.landmark) return false;
      if (row.text) return !wanted && (!words || row.text.toLowerCase().indexOf(words) >= 0) && (!view || broadwayInView(row.el));
      if (wanted && wanted.indexOf(row.item.role) < 0) return false;
      if (words && (row.item.name || '').toLowerCase().indexOf(words) < 0 && (row.item.hidden || (row.item.value || '').toLowerCase().indexOf(words) < 0)) return false;
      if (view && !broadwayInView(row.el)) return false;
      return true;
    });
    var most = Math.max(1, Math.min(limit || 120, 2000));
    var picked = rows.slice(0, most), lines = [], items = [], headed = null;
    var names = {}, counts = broadwayCounts(whole.rows);
    walked.regions.forEach(function (r) { names[r.ref] = r; });
    picked.forEach(function (row) {
      var region = row.region || '';
      if (region !== headed && names[region]) {
        var r = names[region];
        lines.push('## ' + r.role + (r.name ? ' "' + r.name + '"' : ''));
      }
      headed = region;
      if (row.text) { lines.push('text "' + row.text.replace(/"/g, "'") + '"'); return; }
      if (row.bare || counts.shown[row.item.role + ' ' + row.item.name] > 1) {
        var holder = broadwayRowOf(row.el), where = holder ? broadwayRowName(holder) : '';
        if (where && where !== row.item.name) {
          row.item.in = where;
          row.line = row.line.slice(0, row.cut) + ' in="' + where.replace(/"/g, "'") + '"' + row.line.slice(row.cut);
        }
      }
      if (boxes) {
        var box = row.el.getBoundingClientRect();
        row.item.box = { x: Math.round(box.left * scale), y: Math.round(box.top * scale), width: Math.round(box.width * scale), height: Math.round(box.height * scale) };
        row.line += ' box=' + row.item.box.x + ',' + row.item.box.y + ',' + row.item.box.width + ',' + row.item.box.height;
      }
      broadwayTell(row.item.ref, counts);
      lines.push(row.line);
      items.push(row.item);
    });
    if (who) st.seen[who] = now;
    out.lines = lines;
    out.items = items;
    out.regions = walked.regions;
    out.total = rows.length;
    out.shown = picked.length;
    out.cut = walked.cut;
    out.unseen = walked.unseen || 0;
    out.needs = inside ? '' : broadwayNeeds();
    out.ways = inside ? [] : broadwayWays();
    out.y = window.scrollY;
    out.height = document.documentElement.scrollHeight;
    return out;
    """

    static let docScript = """
    return window.__broadwayRefs ? window.__broadwayRefs.doc : null;
    """

    static let pointScript = walkBase + """

    var el = document.elementFromPoint(x, y);
    if (!el || el === document.documentElement) return { failed: 'Nothing is at that point', code: 'not_found' };
    if (el.tagName === 'IFRAME' || el.tagName === 'FRAME') return { failed: 'That point is inside an embedded frame, so use a ref from broadway snapshot', code: 'not_actionable' };
    var hit = el.closest('button,a[href],input,select,textarea,summary,label,[role=button],[role=link],[role=checkbox],[role=radio],[role=switch],[role=tab],[role=menuitem],[role=option],[role=slider],[contenteditable=true],[onclick],[tabindex]') || el;
    if (broadwaySecret(el) || broadwaySecret(hit)) return { failed: 'That point is in a password, card or code field, and agents never act there. Ask the person to.', code: 'secret_field' };
    var told = describe(hit, null);
    var label = broadwayFlat(told.label || '', 60);
    var box = hit.getBoundingClientRect();
    return { ref: broadwayRef(hit, null), what: (told.kind || hit.tagName.toLowerCase()) + (label ? ' "' + label + '"' : ''), dx: x - box.left, dy: y - box.top };
    """

    static let resolveScript = walkBase + """

    var st = broadwayState(), root = document.body;
    if (inside) {
      var got = broadwayGet(inside);
      if (got.failed) return got;
      root = got.el;
    }
    var walked = broadwayWalk(root, { cap: 5000 });
    var wanted = roles && roles.length ? roles.map(function (r) { return String(r).toLowerCase(); }) : null;
    var fields = /^(textbox|searchbox|combobox|checkbox|radio|switch|slider|spinbutton|file)$/;
    var items = walked.rows.filter(function (row) { return row.item && !row.landmark; }).map(function (row) { return { row: row, item: row.item }; });
    if (wanted) items = items.filter(function (x) { return wanted.indexOf(x.item.role) >= 0; });
    if (label) items = items.filter(function (x) { return fields.test(x.item.role) || !!st.target[x.item.ref]; });
    var want = broadwayFlat(words || label || '', 200).toLowerCase();
    var named = function (x) { return (x.item.name || '').toLowerCase(); };
    var same = function (x) { return named(x) === want || (!!x.item.icon && x.item.icon === want); };
    var holds = function (x) { return named(x).indexOf(want) >= 0 || (!!x.item.icon && x.item.icon.indexOf(want) >= 0); };
    var hits = items;
    if (want) {
      var pool = items;
      if (prefer && prefer.length) {
        var liked = items.filter(function (x) { return prefer.indexOf(x.item.role) >= 0; });
        var likedHits = liked.filter(same);
        if (!likedHits.length) likedHits = liked.filter(holds);
        if (likedHits.length) pool = liked;
      }
      if (!wanted && !label) {
        var acting = pool.filter(function (x) { return x.item.role !== 'heading' && !broadwayTold.test(x.item.role); });
        if (acting.some(holds)) pool = acting;
      }
      hits = pool.filter(same);
      if (!hits.length) hits = pool.filter(holds);
      var parts = want.split(' ').filter(function (p) { return p; });
      if (!hits.length && parts.length > 1) {
        hits = pool.filter(function (x) {
          var holder = broadwayRowOf(x.row.el), bag = (named(x) + ' ' + (x.item.icon || '') + ' ' + (holder ? broadwayRowName(holder) : '')).toLowerCase();
          return parts.every(function (p) { return bag.indexOf(p) >= 0; });
        });
      }
    } else if (!wanted) {
      hits = [];
    }
    var unscoped = false;
    if (within) {
      var scopes = broadwayScopes(within, hits.map(function (x) { return x.row.el; }));
      hits = hits.filter(function (x) { return scopes.some(function (s) { return s.contains(x.row.el); }); });
      unscoped = !scopes.length;
    }
    var lastHead = '', headOf = new Map();
    walked.rows.forEach(function (row) {
      if (!row.item || row.landmark) return;
      if (row.item.role === 'heading') lastHead = row.item.name; else headOf.set(row.el, lastHead);
    });
    var counts = broadwayCounts(walked.rows);
    var out = hits.slice(0, most || 50).map(function (x) {
      broadwayTell(x.item.ref, inside ? null : counts);
      var found = { ref: x.item.ref, role: x.item.role, name: x.item.name, near: nearby(x.row.el), in_view: broadwayInView(x.row.el) };
      if (x.item.icon) found.icon = x.item.icon;
      var heading = headOf.get(x.row.el);
      if (heading) found.heading = heading;
      var holder = broadwayNear(x.row.el);
      if (holder) found.within = holder;
      return found;
    });
    return { doc: st.doc, next: st.next, title: document.title, found: out, count: hits.length, unscoped: unscoped };
    """

    static let snapshotArguments: [String: Any] = ["inside": "", "all": false, "text": false, "since": false, "who": "none", "roles": [String](),
                                                   "find": "", "view": false, "limit": 500, "boxes": false]

    static let readingScript = walkBase + """

    var got = broadwayGet(ref);
    if (got.failed) return got;
    var d = describe(got.el, got.target), said = broadwayState().said[ref] || '';
    if (!seen(got.el) && said.indexOf(d.kind + ' ') === 0) d.label = said.slice(d.kind.length + 1);
    return { ref: ref, role: d.kind, name: d.label || (d.kind === 'heading' ? '' : nearby(got.el)), rebound: got.rebound, doc: broadwayState().doc };
    """

    static let everythingScript = walkBase + """

    var st = broadwayState();
    var walked = broadwayWalk(document.body, { cap: 2000 });
    var items = walked.rows.filter(function (row) { return row.item && !row.landmark; }).map(function (row) { broadwayTell(row.item.ref); return row.item; });
    return { doc: st.doc, next: st.next, title: document.title, items: items };
    """
}

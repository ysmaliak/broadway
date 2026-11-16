import json
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv

sv.use("field-snippets")


def rows(*args):
    state = sv.cmd({"do": "fieldrows", "args": list(args)})
    if args == ("close",):
        time.sleep(0.35)
    return state


def snippets(action="list", **values):
    return sv.cmd({"do": "snippets", "action": action, **values})["snippets"]


def typed(text):
    for attempt in range(3):
        try:
            sv.cmd({"do": "field", "text": text, "type": True})
            break
        except RuntimeError as error:
            if "the address field has no editor" not in str(error) or attempt == 2:
                raise
            time.sleep(0.1)
    time.sleep(0.35)
    until = time.monotonic() + 2
    while time.monotonic() < until:
        privacy = sv.cmd({"do": "snippets", "action": "inspect"})
        if not privacy["waiting"] and privacy["checked"] != "expired":
            break
        time.sleep(0.05)
    return rows("answer")


def offered(state):
    return [row for row in state["rows"] if row[2] == "snippet"]


def clipboard():
    return subprocess.run(["pbpaste"], capture_output=True, text=True).stdout


def main():
    t = sv.T()
    before = clipboard()
    try:
        sv.setup(**{"search.suggest": True})
        for key, value in [("search.engine", "custom"), ("search.custom", sv.BASE + "/search?q=%s")]:
            subprocess.run(["defaults", "write", sv.SUITE, key, "-string", value], check=True)
        sv.launch()
        tab = sv.page("start")
        english = snippets("save", title="Mailing address", keyword="home", text="First line\nSecond line\n")[0]
        russian = snippets("save", title="Домашний адрес", keyword="дом", text="Первая строка\nВторая строка\n")[1]
        t.ok("local snippet CRUD creates both languages", len(snippets()) == 2)

        for query, title in [(";home", "Mailing address"), ("Mailing address", "Mailing address"),
                             (";ДОМ", "Домашний адрес"), ("ДОМАШНИЙ АДРЕС", "Домашний адрес")]:
            state = typed(query)
            t.ok(f"explicit field offer: {query}", bool(offered(state)) and state["rows"][0][0] == title, state)
            t.ok("snippet does not become a grey completion", state["ending"] == "", state)
            rows("close")

        state = typed(";home")
        rows("return")
        state = rows("answer")
        t.ok("no focused box copies exact multiline text", state["copied"] == english["text"] and not state["editing"], state)

        def fixture(html, focus):
            sv.ev(tab, "document.body.innerHTML = " + json.dumps(html) + "; " + focus)
            time.sleep(0.2)

        for html, value, query, text in [
            ("<textarea id='editor'>Start OLD end</textarea>", "document.querySelector('#editor').value", ";home", english["text"]),
            ("<div contenteditable='true' id='editor'>Start OLD end</div>", "document.querySelector('#editor').innerText", ";дом", russian["text"]),
        ]:
            if "textarea" in html:
                focus = "var el=document.querySelector('#editor'); el.focus(); el.setSelectionRange(6,9); true"
            else:
                focus = "var el=document.querySelector('#editor'); el.focus(); var r=document.createRange(); r.setStart(el.firstChild,6); r.setEnd(el.firstChild,9); var s=getSelection(); s.removeAllRanges(); s.addRange(r); true"
            fixture(html, focus)
            state = typed(query)
            t.ok("focused editor has a snippet offer", bool(offered(state)), state)
            rows("return")
            after = sv.ev(tab, value)
            t.ok("Return inserts multiline text at the saved selection", after.replace("\u00a0", " ") == "Start " + text + " end", after)
            sv.cmd({"do": "snippets", "action": "undo"})
            t.ok("one undo restores the entire previous entry", sv.ev(tab, value) == "Start OLD end", sv.ev(tab, value))

        fixture("<textarea id='editor'>Keep</textarea>", "document.querySelector('#editor').focus(); true")
        sv.ev(tab, "var el=document.querySelector('#editor');el.value += ';home';el.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'insertText',data:';home'}));true")
        t.ok("page input never expands a snippet automatically", sv.ev(tab, "document.querySelector('#editor').value").endswith(";home"))

        private_fields = [
            "<input type='password' id='editor'>",
            "<input name='api_key' id='editor'>",
            "<input autocomplete='one-time-code' id='editor'>",
            "<input autocomplete='current-password' id='editor'>",
            "<input autocomplete='cc-number' id='editor'>",
            "<input title='API key' id='editor'>",
            "<label for='editor'>Password</label><input id='editor'>",
            "<label for='editor'>Пароль</label><input id='editor'>",
            "<label for='editor'>Номер карты</label><input id='editor'>",
            "<label for='editor'>Код подтверждения</label><input id='editor'>",
            "<label for='editor'>Одноразовый код</label><input id='editor'>",
            "<div contenteditable='true' id='editor' aria-label='Secret'></div>",
            "<div contenteditable='true' id='editor' aria-label='Секретный токен'></div>",
        ]
        for html in private_fields:
            fixture(html, "document.querySelector('#editor').focus(); true")
            state = typed(";home")
            t.ok("no snippets in secret field: " + html, not offered(state), state)
            rows("close")

        fixture("<div id='host' aria-label='API key'></div>", "var root=document.querySelector('#host').attachShadow({mode:'open'}); root.innerHTML='<input>'; root.querySelector('input').focus(); true")
        state = typed(";home")
        t.ok("secret metadata on a shadow host suppresses snippets", not offered(state), state)
        rows("close")

        fixture("<div id='host' title='Secret'></div>", "var root=document.querySelector('#host').attachShadow({mode:'open'}); root.innerHTML='<input>'; root.querySelector('input').focus(); true")
        state = typed(";home")
        t.ok("a secret title on a shadow host suppresses snippets", not offered(state), state)
        rows("close")

        for caption in ["API key", "Пароль", "Почтовый адрес"]:
            fixture("<div id='host'></div>", "var root=document.querySelector('#host').attachShadow({mode:'open'});root.innerHTML='<span id=caption></span><input aria-labelledby=caption value=Keep>';root.querySelector('span').textContent=" + json.dumps(caption) + ";root.querySelector('input').focus();true")
            state = typed(";home")
            t.ok("shadow-local label controls snippet availability: " + caption, bool(offered(state)) == (caption == "Почтовый адрес"), state)
            if caption == "Почтовый адрес":
                copied = rows("answer")["copied"]
                sv.ev(tab, "document.querySelector('#host').shadowRoot.querySelector('span').textContent='API key';true")
                rows("return")
                t.ok("acceptance rechecks a changed shadow-local label", sv.ev(tab, "document.querySelector('#host').shadowRoot.querySelector('input').value") == "Keep" and rows("answer")["copied"] == copied, rows("answer"))
            rows("close")

        fixture("<secret-editor id='host'></secret-editor>", "var h=document.querySelector('#host');var r=h.attachShadow({mode:'closed'});r.innerHTML='<input type=password>';r.querySelector('input').focus();true")
        state = typed(";home")
        t.ok("an opaque shadow editor never offers snippets", not offered(state), state)
        rows("close")

        for tag in ["div", "span"]:
            fixture("<" + tag + " id='host'></" + tag + ">", "var h=document.querySelector('#host');var r=h.attachShadow({mode:'closed'});r.innerHTML='<input type=password>';r.querySelector('input').focus();true")
            state = typed(";home")
            t.ok("an ordinary " + tag + " closed-shadow host never offers snippets", not offered(state), state)
            rows("close")

        fixture("<input type='password' id='editor'>", "var el=document.querySelector('#editor');el.focus();el.type='text';true")
        state = typed(";home")
        t.ok("a password revealed before opening the field stays protected", not offered(state), state)
        rows("close")

        fixture("<input type='password' id='editor'>", "document.querySelector('#editor').focus(); true")
        typed(";home")
        sv.ev(tab, "document.querySelector('#editor').type='text'; true")
        state = typed(";home")
        t.ok("showing a password does not allow snippets", not offered(state), state)
        rows("close")

        fixture("<textarea id='editor'>Keep</textarea><input type='password' id='secret'>", "document.querySelector('#editor').focus(); true")
        state = typed(";home")
        sv.ev(tab, "document.querySelector('#secret').focus(); true")
        time.sleep(0.25)
        t.ok("focus moving into a password removes existing offers", not offered(rows("answer")), rows("answer"))
        rows("close")

        fixture("<iframe id='frame' srcdoc='<textarea id=editor>Before</textarea>'></iframe>", "true")
        ready = False
        for _ in range(60):
            ready = sv.cmd({"do": "eval", "id": tab, "world": "search", "js": "Boolean(document.querySelector('#frame').contentWindow.__broadwayFields)"}).get("value")
            if ready:
                break
            time.sleep(0.05)
        t.ok("the frame privacy script is ready before fixture focus", ready)
        sv.ev(tab, "var el=document.querySelector('#frame').contentDocument.querySelector('#editor'); el.focus(); el.setSelectionRange(6,6); true")
        frame_state = {}
        for _ in range(40):
            frame_state = sv.cmd({"do": "snippets", "action": "inspect"})
            if frame_state["frame"]:
                break
            time.sleep(0.05)
        t.ok("the focused frame reaches the privacy relay", frame_state.get("frame"), frame_state)
        state = typed(";home")
        t.ok("a framed editor offers snippets", bool(offered(state)), state)
        if not offered(state):
            raise AssertionError(sv.cmd({"do": "snippets", "action": "inspect"}))
        rows("return")
        framed = "document.querySelector('#frame').contentDocument.querySelector('#editor').value"
        t.ok("Return inserts into the focused frame", sv.ev(tab, framed) == "Before" + english["text"], sv.ev(tab, framed))
        sv.cmd({"do": "snippets", "action": "undo"})
        t.ok("frame insertion has one undo", sv.ev(tab, framed) == "Before", sv.ev(tab, framed))

        updated = snippets("save", id=english["id"], title="Postal address", keyword="post", text="Updated")[0]
        t.ok("edit retains identity and persists all fields", updated["id"] == english["id"] and updated["keyword"] == "post" and updated["text"] == "Updated", updated)
        state = typed(";home")
        t.ok("old keyword no longer offers the edited snippet", not offered(state), state)
        rows("close")
        snippets("delete", id=english["id"])
        snippets("delete", id=russian["id"])
        t.ok("delete removes both local snippets", snippets() == [])
        t.ok("the real clipboard is untouched", clipboard() == before)
    finally:
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()

WORDS = ["harbour", "ledger", "copper", "lantern", "meadow", "quarry", "saddle", "timber", "willow", "beacon", "cinder", "orchard",
         "parcel", "ribbon", "summit", "thistle", "velvet", "anchor", "bramble", "cobalt"]


def sentence(n, length=14):
    words = [WORDS[(n * 7 + i * 3) % len(WORDS)] for i in range(length)]
    return " ".join(words).capitalize() + "."


def form():
    fields = "".join(f"<label>{label} <input name='{name}' type='{kind}' autocomplete='{auto}'></label>"
                     for label, name, kind, auto in [("Full name", "name", "text", "name"), ("Email", "email", "email", "email"),
                                                     ("Phone", "phone", "tel", "tel"), ("Street", "street", "text", "address-line1"),
                                                     ("City", "city", "text", "address-level2"), ("Postcode", "postcode", "text", "postal-code")])
    country = "<label>Country <select name='country'>" + "".join(f"<option>{c}</option>" for c in ["Ireland", "Norway", "Portugal", "Spain", "Wales"]) + "</select></label>"
    plans = "<fieldset><legend>Plan</legend>" + "".join(f"<label><input type='radio' name='plan' value='{p}'> {p}</label>" for p in ["Basic", "Team", "Business"]) + "</fieldset>"
    return ("<!doctype html><html lang='en'><title>Sign up</title><main><h1>Create your account</h1><form onsubmit='event.preventDefault(); document.title = \"Sent\"'>"
            + fields + country + plans + "<label><input type='checkbox' name='news'> Send me the newsletter</label>"
            + "<label>Notes <textarea name='notes'></textarea></label><button type='submit'>Create account</button></form></main>")


def article():
    parts = ["<!doctype html><html lang='en'><title>The long road north</title><header><nav><a href='/'>Home</a> <a href='/archive'>Archive</a> <a href='/about'>About</a></nav></header><main><article><h1>The long road north</h1><p>By Ada Fenwick</p>"]
    for section in range(12):
        parts.append(f"<h2>Part {section + 1}: {WORDS[section].capitalize()}</h2>")
        for paragraph in range(5):
            parts.append("<p>" + " ".join(sentence(section * 50 + paragraph * 5 + k) for k in range(5)) + f" <a href='/notes/{section}-{paragraph}'>note {section + 1}.{paragraph + 1}</a></p>")
    parts.append("</article><button type='button' onclick='document.title = \"Shared\"'>Share</button></main><footer><p>Written in 2026</p></footer>")
    return "".join(parts)


def table():
    rows = []
    for n in range(200):
        rows.append(f"<tr><td>INV-{1000 + n}</td><td>{WORDS[n % 20].capitalize()} {WORDS[(n * 3) % 20].capitalize()}</td><td>{(n * 37) % 900 + 10}.{(n * 13) % 100:02d}</td><td>{['Paid', 'Due', 'Held'][n % 3]}</td><td><button type='button'>Open</button></td></tr>")
    script = ("<script>function sortBy(i){var b=document.querySelector('tbody');var r=[].slice.call(b.rows);"
              "r.sort(function(x,y){return parseFloat(y.cells[i].textContent)-parseFloat(x.cells[i].textContent)});"
              "r.forEach(function(x){b.appendChild(x)});document.title='Sorted'}</script>")
    return ("<!doctype html><html lang='en'><title>Invoices</title><main><h1>Invoices</h1><table><thead><tr><th>Number</th><th>Customer</th>"
            "<th><button type='button' onclick='sortBy(2)'>Sort by amount</button></th><th>Status</th><th></th></tr></thead><tbody>"
            + "".join(rows) + "</tbody></table></main>" + script)


def dashboard():
    cards = []
    for n in range(12):
        cards.append(f"<section class='card'><h2>{WORDS[n].capitalize()} {['sales', 'orders', 'visits', 'returns'][n % 4]}</h2>"
                     f"<p class='figure' data-n='{n}'>{(n * 113) % 1000}</p><p>{sentence(n, 8)}</p><button type='button'>Details</button></section>")
    nav = "<nav><ul>" + "".join(f"<li><a href='/{w}'>{w.capitalize()}</a></li>" for w in WORDS[:8]) + "</ul></nav>"
    script = ("<script>function refresh(){document.querySelectorAll('.figure').forEach(function(p){p.textContent=String(parseInt(p.textContent)+1)});"
              "document.title='Refreshed'}</script>")
    return ("<!doctype html><html lang='en'><title>Dashboard</title><header><h1>Dashboard</h1><button type='button' onclick='refresh()'>Refresh</button></header>"
            + nav + "<main>" + "".join(cards) + "</main>" + script)


def shop():
    items = []
    for n in range(24):
        name = f"{WORDS[n % 20].capitalize()} {['mug', 'lamp', 'bowl', 'chair', 'rug', 'vase'][n % 6]}"
        items.append(f"<li><h3>{name}</h3><p>{(n * 17) % 90 + 9}.00 EUR</p><button type='button' onclick='add()'>Add to basket</button></li>")
    filters = "<aside><h2>Filter</h2>" + "".join(f"<label><input type='checkbox'> {k}</label>" for k in ["Mugs", "Lamps", "Bowls", "Chairs", "Rugs", "Vases"]) + "</aside>"
    return ("<!doctype html><html lang='en'><title>Shop</title><header><h1>Homeware</h1><a href='/basket'>Basket <span id='count'>0</span></a>"
            "<input type='search' aria-label='Search the shop'></header>" + filters + "<main><ul>" + "".join(items) + "</ul></main>"
            "<script>function add(){var c=document.getElementById('count');c.textContent=String(parseInt(c.textContent)+1);document.title='Added'}</script>")


PAGES = {"/form": form(), "/article": article(), "/table": table(), "/dashboard": dashboard(), "/shop": shop()}

ACTS = {
    "form": ["type", "Full name", "Sam Example"],
    "article": ["scroll", "down"],
    "table": ["click", "Sort by amount"],
    "dashboard": ["click", "Refresh"],
    "shop": ["click", "Add to basket", "--nth", "2"],
}

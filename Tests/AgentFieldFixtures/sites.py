import html
import json
import random
import secrets
import string
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, quote, urlsplit

CUSTOMERS = ["Marlow Tansy", "Iver Holm", "Juno Abbet", "Pell Okoro", "Wren Calloway", "Tamsin Ruel", "Odo Fairweather",
             "Lise Moreau", "Ansel Brack", "Petra Vosk", "Hollis Grane", "Nell Ashdown", "Bram Ellery", "Suki Thorne"]
WAREHOUSES = ["Aldermoor", "Ashby Fen", "Barrowgate", "Bellhaven", "Brackwater", "Brindle Cross", "Carrowmore", "Cinder Hill",
              "Corrin Bay", "Dunmere", "Eastwick Yard", "Elmsford", "Fallowmead", "Fenwick Quay", "Garrow", "Glenhollow",
              "Harrowfield", "Hythe Lane", "Ivydale", "Kestrel Point", "Larkhill", "Lowmoor", "Marrowby", "Mistlecombe",
              "Northam Docks", "Oakhurst", "Pellham", "Quarry End", "Redwater", "Rookley", "Ruthven", "Saltmarsh",
              "Southby", "Stonebridge", "Thornbury", "Upwell", "Vale Royal", "Westerly", "Whitcombe", "Yarrowby"]
WANTED_WAREHOUSES = {"Aldermoor", "Brackwater", "Ruthven"}
CAMPAIGNS = ["Autumn clearance", "Back to school", "Spring promo", "Spring refill", "Summer samples", "Winter stock-up",
             "Loyalty week", "New office bundle"]
ASSIGNEES = ["Unassigned", "Bram Ellery", "Hollis Grane", "Lise Moreau", "Nell Ashdown", "Odile Varga", "Odile Vance",
             "Pell Okoro", "Suki Thorne", "Tamsin Ruel"]
ITEMS = ["A3 paper", "A4 paper", "A4 paper, recycled", "C5 envelopes", "Toner, black", "Toner, colour", "Staples", "Sticky notes"]
SUPPLIERS = [("ashgrove-mills", "Ashgrove Mills"), ("bellcote-print", "Bellcote Print"), ("corvid-office", "Corvid Office"),
             ("dunlin-paper", "Dunlin Paper"), ("halden-oak", "Halden Oak"), ("halden-oakes", "Halden Oakes Trading"),
             ("juniper-supply", "Juniper Supply"), ("kittiwake-stationers", "Kittiwake Stationers"),
             ("larch-and-co", "Larch and Co"), ("merrow-goods", "Merrow Goods"), ("nettle-box", "Nettle Box"),
             ("osprey-inks", "Osprey Inks"), ("plover-packaging", "Plover Packaging"), ("quill-street", "Quill Street"),
             ("rowan-depot", "Rowan Depot"), ("sedge-office", "Sedge Office"), ("teasel-trade", "Teasel Trade"),
             ("umber-supplies", "Umber Supplies"), ("vetch-wholesale", "Vetch Wholesale"), ("wagtail-paper", "Wagtail Paper")]
SETTING_GROUPS = ["Notifications", "Orders", "Invoices", "Shipping", "Returns", "Stock alerts", "Team", "Security",
                  "Reports", "Integrations", "Printing", "Labels", "Customers", "Taxes", "Currencies", "Regions",
                  "Calendar", "Exports", "Imports", "Archive", "Accessibility", "Language", "Sounds", "Advanced"]
SETTING_WORDS = ["Show a badge", "Email the owner", "Keep a copy", "Round to whole units", "Use the short format",
                 "Ask before changing", "Group by week", "Include drafts", "Send a summary", "Hide closed items"]
PEOPLE_EMAIL = "sam@example.com"


def words(seed, count):
    pool = ["ledger", "carton", "pallet", "invoice", "margin", "dispatch", "parcel", "bundle", "voucher", "freight",
            "quota", "manifest", "rebate", "tariff", "batch", "docket", "crate", "label", "rota", "tally"]
    chooser = random.Random(seed)
    return " ".join(chooser.choice(pool) for _ in range(count)).capitalize()


class Field:
    def __init__(self, seed=None):
        chooser = random.Random(seed) if seed is not None else random.SystemRandom()
        token = lambda n: "".join(chooser.choice(string.ascii_uppercase + string.digits) for _ in range(n))
        self.lock = threading.Lock()
        self.hits = []
        self.orders = {}
        for index, number in enumerate(range(4401, 4476)):
            self.orders[f"CL-{number}"] = {"customer": CUSTOMERS[(index * 5) % len(CUSTOMERS)],
                                           "total": f"{(index * 37) % 900 + 40}.{(index * 13) % 100:02d}",
                                           "status": ["Paid", "Unpaid", "Packed", "Sent"][index % 4],
                                           "note": "" if index % 6 else "Ring the bell"}
        self.settings_defaults = {}
        for group_index, group in enumerate(SETTING_GROUPS):
            for word_index in range(3):
                key = f"{group.lower().replace(' ', '-')}-{word_index}"
                self.settings_defaults[key] = (group_index + word_index) % 3 == 0
        self.settings_defaults["digest"] = False
        self.settings = dict(self.settings_defaults)
        self.settings_saves = 0
        self.warehouses_saved = None
        self.tracking = {f"SH-{n}": f"TRK-{token(6)}" for n in range(201, 216)}
        self.recorded_codes = []
        self.campaigns = {name: False for name in CAMPAIGNS}
        self.questions = []
        self.tickets = {f"T-{n}": "Unassigned" for n in range(381, 397)}
        self.tickets["T-386"] = "Odile Vance"
        self.reorders = []
        self.stock_csv = "sku,item,count\n" + "".join(f"{100 + n},{ITEMS[n % len(ITEMS)]},{(n * 7) % 60}\n" for n in range(18)) + f"check,{token(10)},0\n"
        self.imports = []
        self.directory = {slug: f"{word}-{token(4).lower()}@{slug.replace('-', '')}.example"
                          for slug, word in zip([s for s, _ in SUPPLIERS], ["orders", "trade", "hello", "sales", "trade", "orders",
                                                                           "office", "orders", "trade", "sales", "hello", "orders",
                                                                           "trade", "orders", "sales", "hello", "office", "trade",
                                                                           "orders", "sales"])}
        self.suppliers = {slug: {"name": name, "email": f"old-{slug}@{slug.replace('-', '')}.example"} for slug, name in SUPPLIERS}
        self.password = f"{token(5).lower()}-{token(5).lower()}-{token(3)}"
        self.sessions = set()
        self.signins = []
        self.invoices = {f"FW-{n}": False for n in range(1088, 1100)}
        self.approvals = []
        self.downloads = []

    def note(self, site, method, path):
        with self.lock:
            self.hits.append({"t": time.time(), "site": site, "method": method, "path": path})

    def state(self):
        with self.lock:
            return {
                "orders": json.loads(json.dumps(self.orders)),
                "settings": dict(self.settings),
                "settings_defaults": dict(self.settings_defaults),
                "settings_saves": self.settings_saves,
                "warehouses_saved": None if self.warehouses_saved is None else sorted(self.warehouses_saved),
                "tracking": dict(self.tracking),
                "recorded_codes": list(self.recorded_codes),
                "campaigns": dict(self.campaigns),
                "questions": list(self.questions),
                "tickets": dict(self.tickets),
                "reorders": list(self.reorders),
                "stock_csv": self.stock_csv,
                "imports": list(self.imports),
                "directory": dict(self.directory),
                "suppliers": json.loads(json.dumps(self.suppliers)),
                "signins": list(self.signins),
                "invoices": dict(self.invoices),
                "approvals": list(self.approvals),
                "downloads": list(self.downloads),
                "hits": len(self.hits),
            }


STYLE = """<style>
body{font:15px/1.45 -apple-system,Helvetica,sans-serif;margin:0;color:#1d2330;background:#f6f5f1}
header{background:#24323f;color:#fff;padding:10px 20px;display:flex;gap:18px;align-items:center;flex-wrap:wrap}
header a{color:#dfe8ef;text-decoration:none}header strong{margin-right:12px}
main{max-width:960px;margin:0 auto;padding:20px}
table{border-collapse:collapse;width:100%;background:#fff}td,th{border-bottom:1px solid #ddd;padding:6px 8px;text-align:left}
section{background:#fff;margin:18px 0;padding:14px 18px;border-radius:8px}
button{font:inherit;padding:6px 14px}.muted{color:#6a7380}.ok{color:#1d7a3a}
[role=switch]{border-radius:14px;border:1px solid #889;background:#eee}[role=switch][aria-checked=true]{background:#3a8f5c;color:#fff}
</style>"""


def page(title, brand, nav, body):
    links = "".join(f'<a href="{href}">{html.escape(name)}</a>' for href, name in nav)
    return f"""<!doctype html><html lang="en"><head><meta charset="utf-8"><title>{html.escape(title)}</title>{STYLE}</head>
<body><header><strong>{html.escape(brand)}</strong>{links}</header><main>{body}</main></body></html>"""


COPPER_NAV = [("/", "Dashboard"), ("/orders", "Orders"), ("/shipments", "Shipments"), ("/warehouses", "Warehouses"),
              ("/campaigns", "Campaigns"), ("/support", "Support"), ("/suppliers", "Suppliers"), ("/stock", "Stock"),
              ("/reorder", "Reorder"), ("/settings", "Settings")]
FERN_NAV = [("/", "Home"), ("/directory", "Supplier directory"), ("/import", "Stock import"), ("/account/invoices", "Invoices")]


def copper(title, body):
    return page(f"{title} · Copperline", "Copperline", COPPER_NAV, body)


def fern(title, body):
    return page(f"{title} · Fernway", "Fernway", FERN_NAV, body)


SAVE_SCRIPT = """<script>
function send(path, body, done) {
  fetch(path, {method: 'POST', headers: {'content-type': 'application/json'}, body: JSON.stringify(body)})
    .then(function (r) { return r.json() }).then(function (answer) { done(answer) })
}
</script>"""


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    site = ""

    @property
    def field(self):
        return self.server.field

    def log_message(self, *_):
        pass

    def reply(self, status, body, kind="text/html; charset=utf-8", headers=()):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(status)
        self.send_header("content-type", kind)
        self.send_header("content-length", str(len(data)))
        self.send_header("cache-control", "no-store")
        for name, value in headers:
            self.send_header(name, value)
        self.end_headers()
        try:
            self.wfile.write(data)
        except OSError:
            pass

    def json(self, body, status=200):
        self.reply(status, json.dumps(body), "application/json")

    def redirect(self, where, headers=()):
        self.reply(303, "", headers=[("location", where), *headers])

    def body(self):
        length = int(self.headers.get("content-length") or 0)
        return self.rfile.read(length) if length else b""

    def posted(self):
        raw = self.body()
        kind = self.headers.get("content-type", "")
        if kind.startswith("application/json"):
            try:
                return json.loads(raw or b"{}")
            except ValueError:
                return {}
        return {key: values[-1] for key, values in parse_qs(raw.decode(errors="replace")).items()}

    def route(self, method):
        parts = urlsplit(self.path)
        self.field.note(self.site, method, parts.path)
        query = {key: values[-1] for key, values in parse_qs(parts.query).items()}
        handler = getattr(self, f"{method.lower()}_page", None)
        if handler is None or handler(parts.path, query) is False:
            self.reply(404, self.missing(), "text/html; charset=utf-8")

    def do_GET(self):
        self.route("GET")

    def do_POST(self):
        self.route("POST")

    def missing(self):
        return "<!doctype html><title>Not found</title><p>Not found</p>"


class Copperline(Handler):
    site = "copperline"

    def missing(self):
        return copper("Not found", "<h1>Not found</h1><p>There is no page here.</p>")

    def get_page(self, path, query):
        field = self.field
        if path == "/":
            rows = "".join(f"<tr><td>{words(n, 3)}</td><td>{(n * 17) % 300}</td><td>{(n * 7) % 40}%</td></tr>" for n in range(14))
            body = f"""<h1>Dashboard</h1><p class="muted">Good morning. Here is how the week looks.</p>
<section><h2>This week</h2><table><tr><th>Measure</th><th>Count</th><th>Change</th></tr>{rows}</table></section>
<section><h2>Shortcuts</h2><p><a href="/orders">Find an order</a> · <a href="/support">Support queue</a> · <a href="/stock">Stock sheet</a></p></section>"""
            return self.reply(200, copper("Dashboard", body))
        if path == "/orders":
            return self.orders(query)
        if path.startswith("/orders/") and path.endswith("/note"):
            return self.order_note(path.split("/")[2])
        if path.startswith("/orders/"):
            return self.order(path.split("/")[2])
        if path == "/shipments":
            rows = "".join(f'<tr><td><a href="/shipments/{s}">{s}</a></td><td>{CUSTOMERS[i % len(CUSTOMERS)]}</td><td>In transit</td></tr>'
                           for i, s in enumerate(field.tracking))
            return self.reply(200, copper("Shipments", f"<h1>Shipments</h1><table><tr><th>Shipment</th><th>Customer</th><th>State</th></tr>{rows}</table>"))
        if path.startswith("/shipments/"):
            return self.shipment(path.split("/")[2])
        if path.startswith("/api/shipments/"):
            time.sleep(2.5)
            shipment = path.split("/")[3]
            if shipment not in field.tracking:
                return self.json({"error": "none"}, 404)
            return self.json({"shipment": shipment, "code": field.tracking[shipment], "carrier": "Gullwing Freight", "boxes": 4})
        if path == "/api/ping":
            return self.json({"t": time.time()})
        if path == "/warehouses":
            return self.warehouses()
        if path == "/campaigns":
            return self.campaigns()
        if path == "/support":
            return self.support()
        if path.startswith("/support/"):
            return self.ticket(path.split("/")[2])
        if path == "/help":
            return self.help()
        if path == "/suppliers":
            rows = "".join(f'<tr><td><a href="/suppliers/{slug}">{html.escape(s["name"])}</a></td><td>{html.escape(s["email"])}</td></tr>'
                           for slug, s in field.suppliers.items())
            return self.reply(200, copper("Suppliers", f"<h1>Suppliers</h1><table><tr><th>Supplier</th><th>Contact email</th></tr>{rows}</table>"))
        if path.startswith("/suppliers/"):
            return self.supplier(path.split("/")[2])
        if path == "/stock":
            body = """<h1>Stock</h1><p>The stock sheet is made every Monday from the counts in every warehouse.</p>
<section><h2>Week 46</h2><p><a href="/files/stock-week-46.csv">Download the stock sheet</a> <span class="muted">CSV, 1 KB</span></p></section>
<section><h2>Earlier weeks</h2><p class="muted">Sheets older than a week are kept by the finance team.</p></section>"""
            return self.reply(200, copper("Stock", body))
        if path == "/files/stock-week-46.csv":
            with field.lock:
                field.downloads.append(path)
            return self.reply(200, field.stock_csv, "text/csv", headers=[("content-disposition", 'attachment; filename="stock-week-46.csv"')])
        if path == "/reorder":
            return self.reorder()
        if path == "/reorder/review":
            return self.review(query)
        if path == "/settings":
            return self.settings()
        return False

    def orders(self, query):
        field = self.field
        wanted = query.get("q", "").strip().lower()
        rows = [(oid, o) for oid, o in field.orders.items() if not wanted or wanted in oid.lower() or wanted in o["customer"].lower()]
        size = 25
        count = max(1, (len(rows) + size - 1) // size)
        number = min(max(1, int(query.get("page", "1") or 1) if query.get("page", "1").isdigit() else 1), count)
        shown = rows[(number - 1) * size:number * size]
        lines = "".join(f'<tr><td><a href="/orders/{oid}">{oid}</a></td><td>{html.escape(o["customer"])}</td><td>{o["total"]}</td><td>{o["status"]}</td></tr>'
                        for oid, o in shown)
        search = f'&q={quote(wanted)}' if wanted else ""
        pager = " ".join(f'<a href="/orders?page={n}{search}">{"Page " + str(n) if n != number else "<b>Page " + str(n) + "</b>"}</a>' for n in range(1, count + 1))
        after = f' <a href="/orders?page={number + 1}{search}">Next page</a>' if number < count else ""
        body = f"""<h1>Orders</h1><form role="search" action="/orders" method="get"><input name="q" placeholder="Order or customer" aria-label="Search orders" value="{html.escape(wanted)}"> <button>Search</button></form>
<p class="muted">{len(rows)} orders, page {number} of {count}</p>
<table><tr><th>Order</th><th>Customer</th><th>Total</th><th>Status</th></tr>{lines}</table><p>{pager}{after}</p>"""
        return self.reply(200, copper("Orders", body))

    def order(self, oid):
        order = self.field.orders.get(oid)
        if not order:
            return False
        note = html.escape(order["note"]) or '<span class="muted">No note</span>'
        body = f"""<p><a href="/orders">All orders</a></p><h1>Order {oid}</h1>
<section><table><tr><th>Customer</th><td>{html.escape(order["customer"])}</td></tr><tr><th>Total</th><td>{order["total"]}</td></tr>
<tr><th>Status</th><td>{order["status"]}</td></tr><tr><th>Delivery note</th><td id="note">{note}</td></tr></table></section>
<section><h2>Lines</h2><table>{"".join(f"<tr><td>{words(oid + str(n), 2)}</td><td>{n + 1}</td></tr>" for n in range(6))}</table></section>
<p><a href="/orders/{oid}/note">Edit delivery note</a></p>"""
        return self.reply(200, copper(f"Order {oid}", body))

    def order_note(self, oid):
        order = self.field.orders.get(oid)
        if not order:
            return False
        body = f"""{SAVE_SCRIPT}<p><a href="/orders/{oid}">Back to order {oid}</a></p><h1>Delivery note for {oid}</h1>
<label for="note">Delivery note</label><br><textarea id="note" rows="3" cols="50">{html.escape(order["note"])}</textarea><br>
<button type="button" id="save" onclick="send('/api/orders/{oid}/note', {{note: document.getElementById('note').value}}, function () {{ document.getElementById('said').textContent = 'Note saved' }})">Save note</button>
<p id="said" role="status" class="ok"></p>"""
        return self.reply(200, copper(f"Note for {oid}", body))

    def shipment(self, sid):
        if sid not in self.field.tracking:
            return False
        body = f"""{SAVE_SCRIPT}<p><a href="/shipments">All shipments</a></p><h1>Shipment {sid}</h1>
<div id="spinner" role="progressbar" aria-label="Loading">Loading shipment details…</div><div id="details"></div>
<script>
var bar = document.getElementById('spinner'), step = 0
function spin() {{ step = (step + 1) % 40; bar.style.opacity = 0.4 + step / 80; requestAnimationFrame(spin) }}
spin()
setInterval(function () {{ fetch('/api/ping').catch(function () {{}}) }}, 700)
setTimeout(function () {{
  fetch('/api/shipments/{sid}').then(function (r) {{ return r.json() }}).then(function (s) {{
    document.getElementById('details').innerHTML =
      '<section><table><tr><th>Carrier</th><td>' + s.carrier + '</td></tr><tr><th>Boxes</th><td>' + s.boxes + '</td></tr>' +
      '<tr><th>Tracking code</th><td id="code">' + s.code + '</td></tr></table></section>' +
      '<section><h2>Confirm receipt</h2><label for="typed">Tracking code on the boxes</label> <input id="typed"> ' +
      '<button type="button" id="record">Record code</button><p id="said" role="status" class="ok"></p></section>'
    document.getElementById('record').onclick = function () {{
      send('/api/shipments/{sid}/receipt', {{code: document.getElementById('typed').value}}, function (a) {{
        document.getElementById('said').textContent = a.ok ? 'Receipt recorded' : 'That code does not match'
      }})
    }}
  }})
}}, 3000)
</script>"""
        return self.reply(200, copper(f"Shipment {sid}", body))

    def warehouses(self):
        saved = set(self.field.warehouses_saved or [])
        boxes = "".join(f'<li><label><input type="checkbox" name="w" value="{html.escape(name)}"{" checked" if name in saved else ""}> {html.escape(name)}</label></li>' for name in WAREHOUSES)
        body = f"""{SAVE_SCRIPT}<h1>Warehouses</h1><p>Tick the warehouses that take part in the winter count.</p>
<section><ul style="columns:3;list-style:none;padding:0">{boxes}</ul>
<button type="button" onclick="send('/api/warehouses', {{ticked: Array.from(document.querySelectorAll('input[name=w]:checked')).map(function (b) {{ return b.value }})}}, function () {{ document.getElementById('said').textContent = 'Selection saved' }})">Save selection</button>
<p id="said" role="status" class="ok"></p></section>"""
        return self.reply(200, copper("Warehouses", body))

    def campaigns(self):
        rows = []
        for index, (name, archived) in enumerate(self.field.campaigns.items()):
            state = "Archived" if archived else "Running"
            action = "" if archived else f'<button type="button" data-name="{html.escape(name)}" onclick="archive(this)">Archive</button>'
            rows.append(f"<tr><td>{html.escape(name)}</td><td>{(index * 311) % 4000 + 200} people</td><td>{state}</td><td>{action}</td></tr>")
        body = f"""{SAVE_SCRIPT}<h1>Campaigns</h1><table><tr><th>Campaign</th><th>List</th><th>State</th><th></th></tr>{"".join(rows)}</table>
<p id="said" role="status" class="ok"></p>
<script>
function archive(button) {{
  var name = button.getAttribute('data-name')
  if (!confirm('Archive the campaign ' + name + '? People on its list stop getting it.')) return
  send('/api/campaigns/archive', {{name: name}}, function () {{ location.reload() }})
}}
</script>"""
        return self.reply(200, copper("Campaigns", body))

    def support(self):
        rows = "".join(f'<tr><td><a href="/support/{tid}">{tid}</a></td><td>{words(tid, 4)}</td><td>{html.escape(who)}</td></tr>'
                       for tid, who in self.field.tickets.items())
        body = f"""<h1>Support queue</h1><p>Questions about the product itself go to the help centre. <a href="/help" target="_blank">Ask the help centre</a></p>
<table><tr><th>Ticket</th><th>Subject</th><th>Assignee</th></tr>{rows}</table>"""
        return self.reply(200, copper("Support", body))

    def ticket(self, tid):
        if tid not in self.field.tickets:
            return False
        options = "".join(f'<option{" selected" if who == self.field.tickets[tid] else ""}>{html.escape(who)}</option>' for who in ASSIGNEES)
        body = f"""{SAVE_SCRIPT}<p><a href="/support">Support queue</a></p><h1>Ticket {tid}</h1><section><p>{words(tid, 30)}.</p></section>
<label for="who">Assignee</label> <select id="who">{options}</select>
<button type="button" onclick="send('/api/tickets/{tid}', {{assignee: document.getElementById('who').value}}, function () {{ document.getElementById('said').textContent = 'Ticket saved' }})">Save ticket</button>
<p id="said" role="status" class="ok"></p>"""
        return self.reply(200, copper(f"Ticket {tid}", body))

    def help(self):
        body = f"""{SAVE_SCRIPT}<h1>Help centre</h1><p>Ask the Copperline team about the product. Answers come by email within a day.</p>
<label for="q">Your question</label><br><textarea id="q" rows="4" cols="60"></textarea><br>
<button type="button" onclick="send('/api/help', {{question: document.getElementById('q').value}}, function () {{ document.getElementById('said').textContent = 'Thanks, the team has your question' }})">Ask the team</button>
<p id="said" role="status" class="ok"></p>"""
        return self.reply(200, copper("Help centre", body))

    def supplier(self, slug):
        supplier = self.field.suppliers.get(slug)
        if not supplier:
            return False
        body = f"""{SAVE_SCRIPT}<p><a href="/suppliers">All suppliers</a></p><h1>{html.escape(supplier["name"])}</h1>
<label for="email">Contact email</label> <input id="email" type="email" size="40" value="{html.escape(supplier["email"])}">
<button type="button" onclick="send('/api/suppliers/{slug}', {{email: document.getElementById('email').value}}, function () {{ document.getElementById('said').textContent = 'Supplier saved' }})">Save supplier</button>
<p id="said" role="status" class="ok"></p>"""
        return self.reply(200, copper(supplier["name"], body))

    def reorder(self):
        options = "".join(f"<option>{html.escape(item)}</option>" for item in ITEMS)
        body = f"""<h1>Reorder supplies</h1><p>Step 1 of 2</p><form action="/reorder/review" method="get">
<label for="item">Item</label> <select id="item" name="item"><option value="">Choose an item</option>{options}</select><br><br>
<label for="qty">Boxes</label> <input id="qty" name="qty" type="number" min="1" max="99"><br><br>
<button type="submit">Continue</button></form>"""
        return self.reply(200, copper("Reorder", body))

    def review(self, query):
        item, qty = query.get("item", ""), query.get("qty", "")
        if item not in ITEMS or not qty.isdigit():
            return self.reply(200, copper("Reorder", '<h1>Reorder supplies</h1><p>Choose an item and a number of boxes first. <a href="/reorder">Back</a></p>'))
        body = f"""<h1>Reorder supplies</h1><p>Step 2 of 2. Check the request, then send it to the buying team.</p>
<section><table><tr><th>Item</th><td>{html.escape(item)}</td></tr><tr><th>Boxes</th><td>{qty}</td></tr></table></section>
<form action="/reorder/send" method="post"><input type="hidden" name="item" value="{html.escape(item)}"><input type="hidden" name="qty" value="{qty}">
<a href="/reorder">Change</a> <button type="submit">Send request</button></form>"""
        return self.reply(200, copper("Reorder review", body))

    def settings(self):
        values = self.field.settings
        parts = [SAVE_SCRIPT, "<h1>Settings</h1><p>Changes take effect once saved at the foot of the page.</p>"]
        for group_index, group in enumerate(SETTING_GROUPS):
            boxes = []
            for word_index in range(3):
                key = f"{group.lower().replace(' ', '-')}-{word_index}"
                label = SETTING_WORDS[(group_index + word_index * 3) % len(SETTING_WORDS)]
                boxes.append(f'<p><label><input type="checkbox" data-key="{key}"{" checked" if values[key] else ""}> {label} ({group.lower()})</label></p>')
            parts.append(f"<section><h2>{group}</h2><p>{words(group, 40)}.</p><p>{words(group + 'x', 35)}.</p>{''.join(boxes)}</section>")
        on = "true" if values["digest"] else "false"
        parts.append(f"""<section><h2>Email</h2><p>{words("email", 30)}.</p>
<p><button type="button" role="switch" id="digest" aria-checked="{on}" onclick="this.setAttribute('aria-checked', this.getAttribute('aria-checked') === 'true' ? 'false' : 'true')">Weekly digest emails</button></p></section>
<p><button type="button" id="save" onclick="save()">Save settings</button></p><p id="said" role="status" class="ok"></p>
<script>
function save() {{
  var all = {{}}
  document.querySelectorAll('input[data-key]').forEach(function (b) {{ all[b.getAttribute('data-key')] = b.checked }})
  all.digest = document.getElementById('digest').getAttribute('aria-checked') === 'true'
  send('/api/settings', all, function () {{ document.getElementById('said').textContent = 'Settings saved' }})
}}
</script>""")
        return self.reply(200, copper("Settings", "".join(parts)))

    def post_page(self, path, query):
        field = self.field
        if path.startswith("/api/orders/") and path.endswith("/note"):
            oid = path.split("/")[3]
            data = self.posted()
            with field.lock:
                if oid not in field.orders:
                    return False
                field.orders[oid]["note"] = str(data.get("note", ""))
            return self.json({"ok": True})
        if path.startswith("/api/shipments/") and path.endswith("/receipt"):
            sid = path.split("/")[3]
            code = str(self.posted().get("code", "")).strip()
            with field.lock:
                field.recorded_codes.append({"shipment": sid, "code": code})
            return self.json({"ok": field.tracking.get(sid) == code})
        if path == "/api/warehouses":
            ticked = self.posted().get("ticked", [])
            with field.lock:
                field.warehouses_saved = [str(name) for name in ticked]
            return self.json({"ok": True})
        if path == "/api/campaigns/archive":
            name = str(self.posted().get("name", ""))
            with field.lock:
                if name in field.campaigns:
                    field.campaigns[name] = True
            return self.json({"ok": True})
        if path.startswith("/api/tickets/"):
            tid = path.split("/")[3]
            who = str(self.posted().get("assignee", ""))
            with field.lock:
                if tid in field.tickets and who in ASSIGNEES:
                    field.tickets[tid] = who
            return self.json({"ok": True})
        if path == "/api/help":
            with field.lock:
                field.questions.append(str(self.posted().get("question", "")))
            return self.json({"ok": True})
        if path.startswith("/api/suppliers/"):
            slug = path.split("/")[3]
            with field.lock:
                if slug in field.suppliers:
                    field.suppliers[slug]["email"] = str(self.posted().get("email", "")).strip()
            return self.json({"ok": True})
        if path == "/api/settings":
            data = self.posted()
            with field.lock:
                for key in field.settings:
                    if key in data:
                        field.settings[key] = bool(data[key])
                field.settings_saves += 1
            return self.json({"ok": True})
        if path == "/reorder/send":
            data = self.posted()
            with field.lock:
                field.reorders.append({"item": data.get("item", ""), "qty": int(data["qty"]) if str(data.get("qty", "")).isdigit() else 0})
            return self.reply(200, copper("Request sent", "<h1>Request sent</h1><p>The buying team has your request.</p>"))
        return False


class Fernway(Handler):
    site = "fernway"

    def missing(self):
        return fern("Not found", "<h1>Not found</h1>")

    def signed_in(self):
        cookies = self.headers.get("cookie", "")
        for part in cookies.split(";"):
            name, _, value = part.strip().partition("=")
            if name == "fw_session" and value in self.field.sessions:
                return True
        return False

    def get_page(self, path, query):
        field = self.field
        if path == "/":
            body = """<h1>Fernway supplier portal</h1><p>Find suppliers, send stock counts and look after invoices.</p>
<ul><li><a href="/directory">Supplier directory</a></li><li><a href="/import">Import a stock sheet</a></li><li><a href="/account/invoices">Your invoices</a> <span class="muted">(sign in)</span></li></ul>"""
            return self.reply(200, fern("Home", body))
        if path == "/directory":
            rows = "".join(f"<tr><td>{html.escape(name)}</td><td>{html.escape(field.directory[slug])}</td><td>{words(slug, 2)}</td></tr>"
                           for slug, name in SUPPLIERS)
            return self.reply(200, fern("Directory", f"<h1>Supplier directory</h1><table><tr><th>Supplier</th><th>Contact email</th><th>Trade</th></tr>{rows}</table>"))
        if path == "/import":
            body = """<h1>Import a stock sheet</h1><p>Send this week's stock sheet as a CSV file.</p>
<form action="/import" method="post" enctype="multipart/form-data"><label for="sheet">Stock sheet</label> <input id="sheet" type="file" name="sheet" accept=".csv"><br><br>
<button type="submit">Import sheet</button></form>"""
            return self.reply(200, fern("Import", body))
        if path == "/signin":
            return self.signin_page(query.get("next", "/account/invoices"), "")
        if path.startswith("/account"):
            if not self.signed_in():
                return self.redirect(f"/signin?next={quote(path)}")
            if path == "/account/invoices":
                rows = "".join(f'<tr><td><a href="/account/invoices/{iid}">{iid}</a></td><td>{(i * 173) % 2000 + 90}.00</td><td>{"Approved" if ok else "Waiting"}</td></tr>'
                               for i, (iid, ok) in enumerate(field.invoices.items()))
                return self.reply(200, fern("Invoices", f"<h1>Invoices</h1><table><tr><th>Invoice</th><th>Amount</th><th>State</th></tr>{rows}</table>"))
            if path.startswith("/account/invoices/"):
                iid = path.split("/")[3]
                if iid not in field.invoices:
                    return False
                state = "Approved" if field.invoices[iid] else "Waiting for approval"
                body = f"""<p><a href="/account/invoices">All invoices</a></p><h1>Invoice {iid}</h1><p>{state}</p>
<section><p>{words(iid, 25)}.</p></section>
<form action="/account/invoices/{iid}/approve" method="post"><button type="submit">Approve invoice</button></form>"""
                return self.reply(200, fern(f"Invoice {iid}", body))
        return False

    def signin_page(self, after, message):
        warning = f'<p role="alert">{html.escape(message)}</p>' if message else ""
        body = f"""<h1>Sign in to Fernway</h1>{warning}<form action="/signin" method="post"><input type="hidden" name="next" value="{html.escape(after)}">
<label for="email">Email</label><br><input id="email" name="email" type="email" autocomplete="username"><br>
<label for="password">Password</label><br><input id="password" name="password" type="password" autocomplete="current-password"><br><br>
<button type="submit">Sign in</button></form>"""
        return self.reply(200, fern("Sign in", body))

    def post_page(self, path, query):
        field = self.field
        if path == "/signin":
            data = self.posted()
            good = data.get("email", "").strip().lower() == PEOPLE_EMAIL and data.get("password", "") == field.password
            with field.lock:
                field.signins.append({"ok": good})
            if not good:
                return self.signin_page(data.get("next", "/account/invoices"), "That email and password don't match")
            token = secrets.token_hex(12)
            field.sessions.add(token)
            after = data.get("next", "/account/invoices")
            return self.redirect(after if after.startswith("/") else "/account/invoices", headers=[("set-cookie", f"fw_session={token}; Path=/; HttpOnly")])
        if path.startswith("/account/invoices/") and path.endswith("/approve"):
            if not self.signed_in():
                return self.redirect("/signin")
            iid = path.split("/")[3]
            with field.lock:
                if iid in field.invoices:
                    field.invoices[iid] = True
                    field.approvals.append(iid)
            return self.redirect(f"/account/invoices/{iid}")
        if path == "/import":
            kind = self.headers.get("content-type", "")
            files = multipart(self.body(), kind)
            with field.lock:
                for name, data in files:
                    field.imports.append({"name": name, "bytes": len(data), "same": data.decode(errors="replace") == field.stock_csv})
            said = "Sheet imported" if files else "Choose a file first"
            return self.reply(200, fern("Import", f"<h1>Import a stock sheet</h1><p role=\"status\">{said}</p>"))
        return False


def multipart(raw, kind):
    marker = "boundary="
    if marker not in kind:
        return []
    boundary = kind.split(marker, 1)[1].split(";")[0].strip().strip('"').encode()
    found = []
    for part in raw.split(b"--" + boundary):
        head, _, body = part.partition(b"\r\n\r\n")
        if b"filename=" not in head:
            continue
        name = head.split(b"filename=", 1)[1].split(b"\r\n")[0].strip().strip(b'"').decode(errors="replace")
        if body.endswith(b"\r\n"):
            body = body[:-2]
        if name:
            found.append((name, body))
    return found


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, handler, field, port=0):
        self.field = field
        super().__init__(("127.0.0.1", port), handler)


def serve(field):
    servers = []
    for handler in (Copperline, Fernway):
        server = Server(handler, field)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        servers.append(server)
    copperline, fernway = servers
    return servers, f"http://127.0.0.1:{copperline.server_port}", f"http://localhost:{fernway.server_port}"

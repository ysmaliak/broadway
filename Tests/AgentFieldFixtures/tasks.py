import re

from sites import WANTED_WAREHOUSES


def plain(text):
    return re.sub(r"[\s.!]+$", "", re.sub(r"\s+", " ", str(text).strip().lower()))


class Task:
    def __init__(self, name, sentence, check, needs=()):
        self.name = name
        self.sentence = sentence
        self.check = check
        self.needs = set(needs)

    def say(self, copperline, fernway):
        return self.sentence.format(copperline=copperline, fernway=fernway)


def order_note(state):
    note = state["orders"]["CL-4471"]["note"]
    others = [oid for oid, order in state["orders"].items() if oid != "CL-4471" and order["note"] not in ("", "Ring the bell")]
    if others:
        return False, f"other orders changed: {', '.join(others)}"
    return plain(note) == "leave at the side door", f"note is {note!r}"


def digest(state):
    if not state["settings_saves"]:
        return False, "settings never saved"
    changed = [key for key, value in state["settings"].items() if key != "digest" and value != state["settings_defaults"][key]]
    if changed:
        return False, f"other settings changed: {', '.join(changed)}"
    return state["settings"]["digest"] is True, f"digest is {state['settings']['digest']}"


def warehouses(state):
    saved = state["warehouses_saved"]
    if saved is None:
        return False, "selection never saved"
    return set(saved) == WANTED_WAREHOUSES, f"saved {sorted(saved)}"


def tracking(state):
    wanted = state["tracking"]["SH-208"]
    tries = [row["code"] for row in state["recorded_codes"] if row["shipment"] == "SH-208"]
    if not tries:
        return False, "no code recorded"
    return tries[-1] == wanted, f"recorded {tries}"


def archive(state):
    archived = sorted(name for name, gone in state["campaigns"].items() if gone)
    return archived == ["Spring promo"], f"archived {archived}"


def help_question(state):
    asked = [question for question in state["questions"] if "invoice" in question.lower() and "export" in question.lower()]
    return bool(asked), f"questions {state['questions']}"


def reorder(state):
    sent = state["reorders"]
    return sent == [{"item": "A4 paper", "qty": 12}], f"sent {sent}"


def approve(state):
    approved = sorted(iid for iid, ok in state["invoices"].items() if ok)
    signed = any(row["ok"] for row in state["signins"])
    if not signed:
        return False, "never signed in"
    return approved == ["FW-1093"], f"approved {approved}"


def stock_import(state):
    same = [row for row in state["imports"] if row["same"]]
    return bool(same), f"imports {state['imports']}, downloads {len(state['downloads'])}"


def supplier_email(state):
    wanted = state["directory"]["halden-oak"]
    email = state["suppliers"]["halden-oak"]["email"]
    others = [slug for slug, row in state["suppliers"].items() if slug != "halden-oak" and not row["email"].startswith("old-")]
    if others:
        return False, f"other suppliers changed: {', '.join(others)}"
    return email.strip().lower() == wanted, f"email is {email!r}"


def assign(state):
    changed = {tid: who for tid, who in state["tickets"].items() if who != ("Odile Vance" if tid == "T-386" else "Unassigned")}
    return changed == {"T-388": "Odile Varga"}, f"changed {changed}"


TASKS = [
    Task("order_note", "In the Copperline console at {copperline}, change the delivery note on order CL-4471 to \"Leave at the side door\".", order_note),
    Task("digest", "Turn on weekly digest emails in Copperline's settings at {copperline} and save.", digest),
    Task("warehouses", "On Copperline's warehouses page at {copperline}, tick Aldermoor, Brackwater and Ruthven, nothing else, and save.", warehouses),
    Task("tracking", "Copperline shipment SH-208 at {copperline} has arrived. Record its tracking code as received on the shipment's page.", tracking),
    Task("archive", "Archive the Spring promo campaign in Copperline at {copperline}.", archive),
    Task("help_question", "From Copperline's support page at {copperline}, ask the help centre which format the invoice export uses.", help_question),
    Task("reorder", "Send a reorder request for 12 boxes of A4 paper on Copperline at {copperline}.", reorder),
    Task("approve", "Sign in to Fernway at {fernway} with my saved login and approve invoice FW-1093.", approve, needs=["login"]),
    Task("stock_import", "Download this week's stock sheet from Copperline at {copperline} and import it on Fernway's stock import page at {fernway}.", stock_import),
    Task("supplier_email", "Copy Halden Oak's contact email from Fernway's supplier directory at {fernway} into Halden Oak's supplier record in Copperline at {copperline}.", supplier_email),
    Task("assign", "Assign Copperline support ticket T-388 at {copperline} to Odile Varga.", assign),
]

BY_NAME = {task.name: task for task in TASKS}

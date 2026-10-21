#!/usr/bin/env python3
"""
Simulador de webhooks Zeffy para pruebas manuales.

Uso:
    python3 simulate_zeffy_webhook.py [--count N] [--scenario NOMBRE] [--secret TOKEN]

Escenarios disponibles:
  new_donor       — donante nuevo, sin match en SF (genera ticket Pending Review)
  known_donor     — donante con email real de la org (auto-match alto)
  corporate       — donación corporativa
  recurring       — donación recurrente
  refunded        — pago con refund
  dispute         — pago en disputa
  tribute         — donación en honor de alguien
  bad_json        — payload malformado (prueba manejo de error)
  no_tx_id        — payload sin ID de transacción
  wrong_type      — evento que no es payment.completed (debe ignorarse)
  mixed           — envía uno de cada escenario
"""

import argparse
import json
import random
import string
import time
import urllib.request
import urllib.error
from datetime import datetime, timezone

# ─── CONFIGURACIÓN ────────────────────────────────────────────────────────────
# URL del Site Zeffy Connect en sandbox AEBEQ
SITE_BASE    = "https://aebeq3--partialae.sandbox.my.salesforce-sites.com"
WEBHOOK_PATH = "/ZeffyConnect/services/apexrest/zeffy-connect/webhook/"
WEBHOOK_URL  = SITE_BASE + WEBHOOK_PATH

# Webhook secret — cópialo de Settings → Zeffy Connection → Webhook Secret
# Si el campo está en blanco en Salesforce, dejar esto vacío también (acepta todo)
DEFAULT_SECRET = ""

# Campañas de ejemplo (IDs ficticios para pruebas)
CAMPAIGN_IDS = [
    "camp_abc123", "camp_def456", "camp_ghi789",
    "camp_jkl012", "camp_mno345",
]

# Nombres y emails de prueba
FIRST_NAMES = ["Marie", "Jean", "Sophie", "Pierre", "Isabelle", "François",
               "Catherine", "Michel", "Anne", "Robert", "Laura", "David"]
LAST_NAMES  = ["Tremblay", "Gagnon", "Roy", "Côté", "Bouchard", "Fortin",
               "Gauthier", "Morin", "Lavoie", "Ouellet", "Martin", "Lévesque"]
CITIES      = ["Montréal", "Québec", "Laval", "Sherbrooke", "Longueuil", "Gatineau"]


# ─── HELPERS ──────────────────────────────────────────────────────────────────

def rand_id(prefix="tx_"):
    return prefix + "".join(random.choices(string.ascii_lowercase + string.digits, k=12))

def rand_amount(min_cents=500, max_cents=50000):
    return random.randint(min_cents, max_cents)

def rand_name():
    return random.choice(FIRST_NAMES), random.choice(LAST_NAMES)

def rand_email(first, last):
    domains = ["gmail.com", "hotmail.com", "outlook.com", "yahoo.ca", "icloud.com"]
    return f"{first.lower()}.{last.lower()}{random.randint(1,99)}@{random.choice(domains)}"

def unix_now():
    return int(time.time())

def build_payment_base(tx_id=None, first=None, last=None, email=None, amount_cents=None):
    f, l = rand_name()
    first = first or f
    last  = last  or l
    email = email or rand_email(first, last)
    amount_cents = amount_cents or rand_amount()

    return {
        "id": tx_id or rand_id("tx_"),
        "status": "completed",
        "type": "online",
        "created": unix_now(),
        "amount": amount_cents,
        "eligible_amount": amount_cents,
        "currency": "CAD",
        "refund_status": None,
        "campaign_id": random.choice(CAMPAIGN_IDS),
        "campaign_type": "donation_campaign",
        "campaign_category": "fundraising",
        "description": f"Campagne de dons {datetime.now().year}",
        "occurrence_id": None,
        "receipt_url": f"https://zeffy.com/receipt/{rand_id('rec_')}",
        "contact": rand_id("zc_"),
        "buyer": {
            "email": email,
            "first_name": first,
            "last_name": last,
            "is_corporate": False,
            "company_name": None,
            "address": {
                "line1": f"{random.randint(100, 9999)} rue des Tests",
                "city": random.choice(CITIES),
                "state": "QC",
                "postal_code": f"H{random.randint(1,9)}{random.choice('ABCDEFGHJKLMNPRSTUVWXYZ')} {random.randint(1,9)}{random.choice('ABCDEFGHJKLMNPRSTUVWXYZ')}{random.randint(1,9)}",
                "country": "CA"
            }
        },
        "payment_method": {
            "type": "card",
            "brand": random.choice(["visa", "mastercard", "amex"]),
            "last4": str(random.randint(1000, 9999))
        },
        "fund": None,
        "dispute": None,
        "recurring": {"is_recurring": False, "status": None, "interval": None,
                      "subscription_id": None, "current_period_start": None, "current_period_end": None},
        "discount": None,
        "refunds": [],
        "items": [
            {
                "id": rand_id("item_"),
                "type": "donation",
                "amount": amount_cents,
                "rate_title": "Don unique",
                "contact_id": rand_id("ci_"),
                "questions": [],
                "tribute": None
            }
        ],
        "buyer_questions": []
    }

def wrap_event(payment, event_type="payment.completed"):
    return {
        "id": rand_id("evt_"),
        "type": event_type,
        "version": 1,
        "dispatchedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z"),
        "data": payment
    }


# ─── ESCENARIOS ───────────────────────────────────────────────────────────────

def scenario_new_donor():
    """Donante completamente nuevo — creará ticket Pending Review."""
    p = build_payment_base()
    return wrap_event(p), f"Nuevo donante: {p['buyer']['first_name']} {p['buyer']['last_name']} — {p['amount']/100:.2f} CAD"

def scenario_known_donor(email=None):
    """Donante con email que puede existir en la org."""
    p = build_payment_base(email=email)
    return wrap_event(p), f"Donante conocido ({p['buyer']['email']})"

def scenario_corporate():
    """Donación corporativa."""
    f, l = rand_name()
    p = build_payment_base(first=f, last=l, amount_cents=random.randint(10000, 200000))
    p["buyer"]["is_corporate"] = True
    p["buyer"]["company_name"] = f"Entreprise {l} & Associés Inc."
    p["campaign_category"] = "corporate_giving"
    return wrap_event(p), f"Don corporatif: {p['buyer']['company_name']} — {p['amount']/100:.2f} CAD"

def scenario_recurring():
    """Donación recurrente mensual."""
    p = build_payment_base(amount_cents=random.randint(1000, 5000))
    sub_id = rand_id("sub_")
    p["recurring"] = {
        "is_recurring": True,
        "status": "active",
        "interval": "monthly",
        "subscription_id": sub_id,
        "current_period_start": unix_now() - 86400,
        "current_period_end":   unix_now() + 86400 * 29
    }
    p["type"] = "online"
    return wrap_event(p), f"Don récurrent mensuel (sub={sub_id})"

def scenario_refunded():
    """Pago con reembolso parcial."""
    p = build_payment_base(amount_cents=random.randint(5000, 20000))
    refund_amt = p["amount"] // 2
    p["refund_status"] = "partial"
    p["refunds"] = [{
        "id": rand_id("ref_"),
        "amount": refund_amt,
        "status": "succeeded",
        "created": unix_now() - 3600
    }]
    return wrap_event(p), f"Pago con reembolso parcial ({refund_amt/100:.2f} CAD remboursé)"

def scenario_dispute():
    """Pago en disputa."""
    p = build_payment_base(amount_cents=random.randint(5000, 15000))
    p["dispute"] = {
        "id": rand_id("dis_"),
        "amount": p["amount"],
        "status": "needs_response",
        "reason": "fraudulent",
        "created": unix_now() - 7200
    }
    return wrap_event(p), "Pago en disputa (fraudulent)"

def scenario_tribute():
    """Donación en honor/memoria de alguien."""
    f2, l2 = rand_name()
    p = build_payment_base()
    p["items"][0]["tribute"] = {
        "type": "in_honor_of",
        "honouree_name": f"{f2} {l2}"
    }
    return wrap_event(p), f"Don en hommage à {f2} {l2}"

def scenario_bad_json():
    """Payload malformado — debe crear log INVALID_JSON."""
    return None, "BAD_JSON (payload malformado)"

def scenario_no_tx_id():
    """Sin ID de transacción — debe crear log MISSING_TX_ID."""
    p = build_payment_base()
    p["id"] = ""  # vacío
    return wrap_event(p), "Sin transaction ID"

def scenario_wrong_type():
    """Evento que no es payment.completed — debe ignorarse."""
    p = build_payment_base()
    return wrap_event(p, event_type="subscription.created"), "Evento subscription.created (debe ignorarse)"

SCENARIOS = {
    "new_donor":   scenario_new_donor,
    "known_donor": scenario_known_donor,
    "corporate":   scenario_corporate,
    "recurring":   scenario_recurring,
    "refunded":    scenario_refunded,
    "dispute":     scenario_dispute,
    "tribute":     scenario_tribute,
    "bad_json":    scenario_bad_json,
    "no_tx_id":    scenario_no_tx_id,
    "wrong_type":  scenario_wrong_type,
}


# ─── HTTP ─────────────────────────────────────────────────────────────────────

def send_webhook(payload_dict_or_none, secret, label, dry_run=False):
    if payload_dict_or_none is None:
        raw_body = b"{ this is not valid json !!!"
    else:
        raw_body = json.dumps(payload_dict_or_none, ensure_ascii=False).encode("utf-8")

    print(f"\n  → {label}")

    if dry_run:
        print(f"     [DRY RUN] Body ({len(raw_body)} bytes):")
        print("     " + json.dumps(payload_dict_or_none, indent=2, ensure_ascii=False)[:500] if payload_dict_or_none else "     " + raw_body.decode())
        return

    headers = {
        "Content-Type":      "application/json; charset=utf-8",
        "X-Zeffy-Signature": secret,
        "User-Agent":        "ZeffyWebhookSimulator/1.0"
    }

    req = urllib.request.Request(WEBHOOK_URL, data=raw_body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            body = resp.read().decode("utf-8")
            print(f"     ✓ HTTP {resp.status}  →  {body}")
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8") if e.fp else ""
        print(f"     ✗ HTTP {e.code}  →  {body}")
    except urllib.error.URLError as e:
        print(f"     ✗ URL error: {e.reason}")
    except Exception as e:
        print(f"     ✗ Error: {e}")


# ─── MAIN ─────────────────────────────────────────────────────────────────────

def main():
    global WEBHOOK_URL
    parser = argparse.ArgumentParser(description="Simulador de webhooks Zeffy")
    parser.add_argument("--scenario", default="new_donor",
                        choices=list(SCENARIOS.keys()) + ["mixed"],
                        help="Escenario a enviar (default: new_donor)")
    parser.add_argument("--count",  type=int, default=1,
                        help="Número de webhooks a enviar (default: 1)")
    parser.add_argument("--secret", default=DEFAULT_SECRET,
                        help="Webhook secret (X-Zeffy-Signature)")
    parser.add_argument("--url",    default=WEBHOOK_URL,
                        help="URL del endpoint")
    parser.add_argument("--dry-run", action="store_true",
                        help="Imprimir payload sin enviar")
    parser.add_argument("--delay", type=float, default=0.3,
                        help="Segundos entre envíos (default: 0.3)")
    args = parser.parse_args()

    WEBHOOK_URL = args.url

    if not args.secret:
        print("ℹ️  Sin secret configurado — el endpoint acepta todo (modo abierto)")
        print(f"   URL destino: {WEBHOOK_URL}\n")
    elif args.secret == "PONER_SECRET_AQUI":
        print("⚠️  Usa --secret TOKEN o pon el Webhook Secret en DEFAULT_SECRET")
        print(f"   URL destino: {WEBHOOK_URL}\n")

    print(f"Simulando {args.count}x '{args.scenario}' → {WEBHOOK_URL}")
    print("=" * 60)

    for i in range(args.count):
        if args.scenario == "mixed":
            # Un webhook de cada escenario no-error, rotando
            sc_keys = ["new_donor", "corporate", "recurring", "refunded", "dispute", "tribute", "wrong_type"]
            sc_name = sc_keys[i % len(sc_keys)]
        else:
            sc_name = args.scenario

        fn = SCENARIOS[sc_name]
        payload, label = fn()
        label = f"[{i+1}/{args.count}] [{sc_name}] {label}"

        send_webhook(payload, args.secret, label, dry_run=args.dry_run)

        if args.count > 1 and i < args.count - 1:
            time.sleep(args.delay)

    print("\n✓ Listo.")

if __name__ == "__main__":
    main()

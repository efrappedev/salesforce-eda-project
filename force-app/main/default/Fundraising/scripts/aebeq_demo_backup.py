#!/usr/bin/env python3
"""
aebeq_demo_backup.py
Exporta todos los objetos del sandbox AEBEQ partialae a CSV.
Guarda en Demo SF Aebeq/ sobreescribiendo los archivos existentes.
"""

import subprocess, json, csv, os, sys
from datetime import datetime

SANDBOX  = "e.frappe@aebeq.qc.ca.partialae"
BASE_DIR = os.path.join(os.path.dirname(__file__), "..", "Demo SF Aebeq")

# Orden de exportación respetando dependencias padre → hijo
OBJECTS = [
    ("01", "Account"),
    ("02", "Contact"),
    ("03", "Campaign"),
    ("04", "Opportunity"),
    ("05", "OutreachSourceCode"),
    ("06", "PaymentInstrument"),
    ("07", "PartyPhilanthropicRsrchPrfl"),
    ("08", "PlannedGift"),
    ("09", "GiftDesignation"),
    ("10", "GiftBatch"),
    ("11", "GiftCommitment"),
    ("12", "GiftCommitmentSchedule"),
    ("13", "GiftTransaction"),
    ("14", "GiftDefaultDesignation"),
    ("15", "GiftRefund"),
    ("16", "GiftSoftCredit"),
    ("17", "DonorGiftSummary"),
    ("18", "FundraisingConfig"),
]

def get_all_fields(obj):
    r = subprocess.run(
        ["sf", "sobject", "describe", "--sobject", obj, "--target-org", SANDBOX, "--json"],
        capture_output=True, text=True, timeout=60
    )
    data = json.loads(r.stdout)
    fields = data["result"]["fields"]
    # Incluir todos los campos excepto compuestos (address, location)
    return [f["name"] for f in fields
            if f.get("type") not in ("address", "location")
            and "." not in f["name"]]

def export_object(num, obj):
    print(f"  [{num}] {obj}...", end=" ", flush=True)

    try:
        fields = get_all_fields(obj)
        fields_str = ", ".join(fields)
        query = f"SELECT {fields_str} FROM {obj}"

        cmd = ["sf", "data", "query", "--query", query, "--target-org", SANDBOX, "--json"]

        r = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
        data = json.loads(r.stdout)

        if data.get("status") != 0:
            print(f"❌ ERROR: {data.get('message', '')[:100]}")
            return 0

        records = data["result"]["records"]
        if not records:
            print(f"0 registros (vacío)")
            return 0

        # Eliminar campo 'attributes' que agrega Salesforce
        clean = []
        for rec in records:
            row = {k: v for k, v in rec.items() if k != "attributes" and not isinstance(v, dict)}
            clean.append(row)

        all_keys = list(clean[0].keys())
        fname = f"{num}_{obj}_Demo.csv"
        fpath = os.path.join(BASE_DIR, fname)

        with open(fpath, "w", newline="", encoding="utf-8") as f:
            writer = csv.DictWriter(f, fieldnames=all_keys, extrasaction="ignore")
            writer.writeheader()
            writer.writerows(clean)

        print(f"✅ {len(clean)} registros → {fname}")
        return len(clean)

    except Exception as e:
        print(f"❌ {e}")
        return 0

if __name__ == "__main__":
    print("AEBEQ Demo Backup — exportando sandbox completo a CSV")
    print(f"Fuente:  {SANDBOX}")
    print(f"Destino: {os.path.abspath(BASE_DIR)}")
    print(f"Inicio:  {datetime.now().strftime('%Y-%m-%d %H:%M')}")
    print()

    os.makedirs(BASE_DIR, exist_ok=True)
    total = 0

    for num, obj in OBJECTS:
        count = export_object(num, obj)
        total += count

    print(f"\n✅ Backup completado — {total:,} registros totales")
    print(f"Fin: {datetime.now().strftime('%Y-%m-%d %H:%M')}")

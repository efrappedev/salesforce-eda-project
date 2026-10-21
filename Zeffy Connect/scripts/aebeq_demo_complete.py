#!/usr/bin/env python3
"""
aebeq_demo_complete.py
Copia los registros faltantes de AEBEQ producción → sandbox partialae.
Solo trabaja con los objetos que tienen diferencia de conteo.
"""

import subprocess, json, csv, io, sys, tempfile, os

PROD    = "e.frappe@aebeq.qc.ca"
SANDBOX = "e.frappe@aebeq.qc.ca.partialae"

# Objetos a completar con sus conteos esperados
OBJECTS = {
    "GiftTransaction":  11211,
    "GiftRefund":       400,
    "GiftSoftCredit":   800,
}

def soql(query, org):
    cmd = ["sf", "data", "query", "--query", query, "--target-org", org, "--json"]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    data = json.loads(r.stdout)
    if data.get("status") != 0:
        raise RuntimeError(data.get("message", r.stderr))
    return data["result"]

def get_ids(obj, org):
    print(f"  Obteniendo IDs de {obj} en {'prod' if org == PROD else 'sandbox'}...")
    result = soql(f"SELECT Id FROM {obj} ORDER BY Id", org)
    return {r["Id"] for r in result["records"]}

def get_creatable_fields(obj, org):
    """Obtiene solo los campos que se pueden insertar (isCreateable=true, no fórmulas)."""
    r = subprocess.run(
        ["sf", "sobject", "describe", "--sobject", obj, "--target-org", org, "--json"],
        capture_output=True, text=True, timeout=60
    )
    data = json.loads(r.stdout)
    fields = data["result"]["fields"]
    creatable = []
    for f in fields:
        if f.get("createable") and not f.get("calculated") and f["name"] != "Id":
            creatable.append(f["name"])
    return creatable

def export_all_records(obj, insert_fields, org):
    """Exporta TODOS los registros del objeto desde el org.
    Siempre incluye Id en el SELECT para comparar, aunque no se inserte.
    Evita WHERE Id IN (...) que genera URI 414 con muchos IDs."""
    # Siempre incluir Id para poder comparar con sandbox_ids
    select_fields = ["Id"] + [f for f in insert_fields if f != "Id"]
    fields_str = ", ".join(select_fields)
    q = f"SELECT {fields_str} FROM {obj}"
    print(f"    Consultando todos los registros de {obj} en {'prod' if org == PROD else 'sandbox'}...")
    result = soql(q, org)
    records = result["records"]
    print(f"    {len(records)} registros obtenidos.")
    return records

def insert_records(obj, records, fields, org):
    """Inserta registros en el sandbox via CSV temporal."""
    if not records:
        return

    # Limpiar campos __type que agrega Salesforce en el JSON
    clean = []
    for r in records:
        row = {}
        for f in fields:
            val = r.get(f)
            if val is None:
                val = ""
            elif isinstance(val, bool):
                val = str(val).lower()
            elif isinstance(val, dict):
                val = ""  # skip compound fields
            row[f] = val
        clean.append(row)

    # Escribir CSV temporal con LF (requerido por Salesforce Bulk API)
    tmp = tempfile.NamedTemporaryFile(mode='w', suffix='.csv', delete=False, newline='\n')
    writer = csv.DictWriter(tmp, fieldnames=fields, lineterminator='\n')
    writer.writeheader()
    writer.writerows(clean)
    tmp.close()

    try:
        r = subprocess.run(
            ["sf", "data", "import", "bulk",
             "--sobject", obj,
             "--file", tmp.name,
             "--target-org", org,
             "--line-ending", "LF",
             "--wait", "15"],
            capture_output=True, text=True, timeout=300
        )
        output = r.stdout.strip()
        if "Failed" in output or r.returncode != 0:
            print(f"    ❌ Insert falló")
            print(f"    {output[-300:]}")
            print(f"    STDERR: {r.stderr.strip()[-200:]}", file=sys.stderr)
        else:
            print(f"    ✅ Insert exitoso")
    finally:
        os.unlink(tmp.name)

def complete_object(obj):
    print(f"\n{'='*50}")
    print(f"Procesando: {obj}")
    print(f"{'='*50}")

    sandbox_ids = get_ids(obj, SANDBOX)
    print(f"  Sandbox actual: {len(sandbox_ids)} registros")

    print(f"  Obteniendo campos insertables...")
    fields = get_creatable_fields(obj, PROD)
    print(f"  Campos insertables: {len(fields)}")

    # Exportar todos desde prod y filtrar client-side (evita URI 414 con WHERE Id IN)
    # Id se incluye en SELECT solo para comparar — insert_records no lo usa
    all_prod_records = export_all_records(obj, fields, PROD)
    missing_records = [r for r in all_prod_records if r.get("Id") not in sandbox_ids]
    print(f"  (IDs en sandbox: {len(sandbox_ids)} | IDs en prod: {len(all_prod_records)} | Match: {len(all_prod_records) - len(missing_records)})")

    print(f"  Producción: {len(all_prod_records)} | Sandbox: {len(sandbox_ids)} | Faltantes: {len(missing_records)}")

    if not missing_records:
        print(f"  ✅ {obj} ya está completo.")
        return

    print(f"  Insertando {len(missing_records)} registros en sandbox...")
    insert_records(obj, missing_records, fields, SANDBOX)
    print(f"  ✅ {obj} procesado.")

if __name__ == "__main__":
    print("AEBEQ Demo Complete — copia registros faltantes prod → sandbox")
    print(f"Prod:    {PROD}")
    print(f"Sandbox: {SANDBOX}")

    for obj in OBJECTS:
        try:
            complete_object(obj)
        except Exception as e:
            print(f"  ❌ Error en {obj}: {e}", file=sys.stderr)

    print("\n✅ Proceso completado.")

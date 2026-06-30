#!/usr/bin/env python3
"""
aebeq_sandbox_cleanup_today.py
Borra todos los registros creados HOY en el sandbox por el usuario actual.
Úsalo para deshacer inserts erróneos del script de complete.
"""

import subprocess, json, csv, os, sys, tempfile
from datetime import datetime

SANDBOX = "e.frappe@aebeq.qc.ca.partialae"

# Objetos a limpiar — en orden inverso de dependencia (hijos primero)
OBJECTS = [
    "GiftSoftCredit",
    "GiftRefund",
    "GiftTransaction",
]

def soql(query, org):
    cmd = ["sf", "data", "query", "--query", query, "--target-org", org, "--json"]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    data = json.loads(r.stdout)
    if data.get("status") != 0:
        raise RuntimeError(data.get("message", r.stderr[:200]))
    return data["result"]["records"]

def get_current_user_id(org):
    records = soql("SELECT Id, Name FROM User WHERE Username = '" + org + "'", org)
    if records:
        return records[0]["Id"], records[0]["Name"]
    # fallback: buscar por username parcial
    records = soql("SELECT Id, Name FROM User WHERE IsActive = true ORDER BY CreatedDate DESC LIMIT 1", org)
    return records[0]["Id"], records[0]["Name"]

def delete_records(obj, ids, org):
    if not ids:
        print(f"  Nada que borrar.")
        return

    # Escribir CSV con IDs
    tmp = tempfile.NamedTemporaryFile(mode="w", suffix=".csv", delete=False,
                                      newline="\n", encoding="utf-8")
    writer = csv.DictWriter(tmp, fieldnames=["Id"], lineterminator="\n")
    writer.writeheader()
    for rid in ids:
        writer.writerow({"Id": rid})
    tmp.close()

    print(f"  Borrando {len(ids)} registros...", end=" ", flush=True)
    try:
        r = subprocess.run(
            ["sf", "data", "delete", "bulk",
             "--sobject", obj,
             "--file", tmp.name,
             "--target-org", org,
             "--line-ending", "LF",
             "--wait", "15"],
            capture_output=True, text=True, timeout=300
        )
        output = r.stdout.strip()
        if "Failed" in output and "Successful records: 0" in output:
            print(f"❌ Falló")
            print(f"    {output[-300:]}")
        else:
            # Extraer conteo de éxitos del output
            for line in output.split("\n"):
                if "Successful" in line or "Failed" in line:
                    print(line.strip(), end=" ")
            print()
    finally:
        os.unlink(tmp.name)

def cleanup_object(obj, user_id):
    print(f"\n[{obj}]")
    try:
        # Buscar registros creados HOY por este usuario
        records = soql(
            f"SELECT Id FROM {obj} WHERE CreatedDate = TODAY AND CreatedById = '{user_id}'",
            SANDBOX
        )
        ids = [r["Id"] for r in records]
        print(f"  Encontrados hoy por este usuario: {len(ids)}")
        delete_records(obj, ids, SANDBOX)
    except Exception as e:
        print(f"  ❌ Error: {e}")

if __name__ == "__main__":
    print("AEBEQ Sandbox Cleanup — borrando registros creados HOY")
    print(f"Sandbox: {SANDBOX}")
    print(f"Fecha:   {datetime.now().strftime('%Y-%m-%d')}")
    print()

    print("Identificando usuario actual...")
    try:
        user_id, user_name = get_current_user_id(SANDBOX)
        print(f"Usuario: {user_name} ({user_id})")
    except Exception as e:
        print(f"❌ No se pudo obtener el usuario: {e}")
        sys.exit(1)

    print()
    for obj in OBJECTS:
        cleanup_object(obj, user_id)

    print("\n✅ Limpieza completada.")
    print("Verifica los conteos con: python3 aebeq_demo_complete.py --dry-run")

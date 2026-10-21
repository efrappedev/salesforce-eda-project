#!/usr/bin/env python3
"""Micro prueba: borra un Account específico en producción y verifica que desapareció."""

import subprocess, csv, json, os, tempfile

PROD = "e.frappe@aebeq.qc.ca"
TEST_ID = "001OH00000yFgSfYAK"

def run():
    print(f"Borrando Account {TEST_ID} en PRODUCCIÓN...")

    # Verificar que existe
    r = subprocess.run(
        ["sf", "data", "query", "--query", f"SELECT Id, Name FROM Account WHERE Id = '{TEST_ID}'",
         "--target-org", PROD, "--json"],
        capture_output=True, text=True
    )
    data = json.loads(r.stdout)
    records = data["result"]["records"]
    if not records:
        print("❌ El registro no existe o ya fue borrado.")
        return
    print(f"  Encontrado: {records[0]['Name']}")

    # Borrar vía Bulk API
    tmp = tempfile.NamedTemporaryFile(mode="w", suffix=".csv", delete=False, newline="\n")
    writer = csv.DictWriter(tmp, fieldnames=["Id"], lineterminator="\n")
    writer.writeheader()
    writer.writerow({"Id": TEST_ID})
    tmp.close()

    try:
        r = subprocess.run(
            ["sf", "data", "delete", "bulk", "--sobject", "Account",
             "--file", tmp.name, "--target-org", PROD, "--line-ending", "LF", "--wait", "10"],
            capture_output=True, text=True
        )
        print(r.stdout.strip())
    finally:
        os.unlink(tmp.name)

    # Verificar que ya no existe
    r = subprocess.run(
        ["sf", "data", "query", "--query", f"SELECT Id FROM Account WHERE Id = '{TEST_ID}'",
         "--target-org", PROD, "--json"],
        capture_output=True, text=True
    )
    data = json.loads(r.stdout)
    if not data["result"]["records"]:
        print("✅ Confirmado: registro eliminado correctamente.")
    else:
        print("⚠️  El registro sigue existiendo — revisar permisos.")

if __name__ == "__main__":
    run()

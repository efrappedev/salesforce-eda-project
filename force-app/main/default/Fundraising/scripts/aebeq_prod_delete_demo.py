#!/usr/bin/env python3
"""
aebeq_prod_delete_demo.py
Borra TODOS los registros demo de AEBEQ PRODUCCIÓN.
Orden: hijos primero para respetar referencias.

⚠️  DESTRUCTIVO — solo correr cuando estés listo para poblar con datos reales.
"""

import subprocess, json, csv, os, sys, tempfile
from datetime import datetime

PROD    = "e.frappe@aebeq.qc.ca"
SANDBOX = "e.frappe@aebeq.qc.ca.partialae"

# Orden de borrado: hijos primero, padres al final
OBJECTS = [
    "GiftTransactionDesignation",   # hijo de GiftTransaction + GiftDesignation
    "GiftSoftCredit",
    "GiftRefund",
    "GiftDefaultDesignation",
    "GiftTransaction",
    "GiftCommitmentSchedule",
    "GiftCommitment",
    "DonorGiftSummary",
    "GiftBatch",
    "GiftDesignation",              # especial: desactivar antes de borrar (ver abajo)
    "PaymentInstrument",
    "OutreachSourceCode",
    "PartyPhilanthropicRsrchPrfl",
    "PlannedGift",
    "CampaignMember",               # hijo de Campaign y Contact
    "Opportunity",
    "Campaign",                     # especial: borrado vía Apex (bulk API no funciona)
    "Contact",
    "Account",
    # FundraisingConfig: NO se borra — es configuración, no demo
    # CampaignMemberStatus: cascade-delete al borrar Campaign (no borrar directamente)
]

def soql_ids(obj, org, extra_where=""):
    where = f"WHERE {extra_where}" if extra_where else ""
    q = f"SELECT Id FROM {obj} {where}"
    r = subprocess.run(
        ["sf", "data", "query", "--query", q, "--target-org", org, "--json"],
        capture_output=True, text=True, timeout=120
    )
    data = json.loads(r.stdout)
    if data.get("status") != 0:
        raise RuntimeError(data.get("message", "")[:200])
    return [rec["Id"] for rec in data["result"]["records"]]

def bulk_delete(obj, ids, org, verbose=False):
    if not ids:
        print(f"  Sin registros — omitido.")
        return True

    tmp = tempfile.NamedTemporaryFile(mode="w", suffix=".csv", delete=False,
                                      newline="\n", encoding="utf-8")
    writer = csv.DictWriter(tmp, fieldnames=["Id"], lineterminator="\n")
    writer.writeheader()
    for rid in ids:
        writer.writerow({"Id": rid})
    tmp.close()

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
        out = r.stdout
        success = fail = 0
        for line in out.split("\n"):
            if "Successful records:" in line:
                try: success = int(''.join(filter(str.isdigit, line.split(":")[-1])))
                except: pass
            if "Failed records:" in line:
                try: fail = int(''.join(filter(str.isdigit, line.split(":")[-1])))
                except: pass

        if verbose or (success == 0 and fail == 0 and r.returncode != 0):
            if r.stdout.strip(): print(f"\n  [stdout] {r.stdout.strip()[:400]}")
            if r.stderr.strip(): print(f"\n  [stderr] {r.stderr.strip()[:400]}")

        if fail > 0:
            print(f"  ⚠️  {success} borrados, {fail} fallaron")
            return False
        elif success == 0 and fail == 0:
            # Posible fallo silencioso — mostrar output crudo para diagnóstico
            print(f"  ⚠️  0 borrados / 0 fallaron — revisar output:")
            if r.stdout.strip(): print(f"     stdout: {r.stdout.strip()[:300]}")
            if r.stderr.strip(): print(f"     stderr: {r.stderr.strip()[:300]}")
            return False
        else:
            print(f"  ✅ {success} borrados")
            return True
    finally:
        os.unlink(tmp.name)

def bulk_update(obj, rows, fieldnames, org):
    """Actualiza registros vía Bulk API. rows = lista de dicts."""
    if not rows:
        return True
    tmp = tempfile.NamedTemporaryFile(mode="w", suffix=".csv", delete=False,
                                      newline="\n", encoding="utf-8")
    writer = csv.DictWriter(tmp, fieldnames=fieldnames, lineterminator="\n")
    writer.writeheader()
    for row in rows:
        writer.writerow(row)
    tmp.close()
    try:
        r = subprocess.run(
            ["sf", "data", "update", "bulk",
             "--sobject", obj,
             "--file", tmp.name,
             "--target-org", org,
             "--line-ending", "LF",
             "--wait", "10"],
            capture_output=True, text=True, timeout=180
        )
        out = r.stdout
        success = fail = 0
        for line in out.split("\n"):
            if "Successful records:" in line:
                try: success = int(''.join(filter(str.isdigit, line.split(":")[-1])))
                except: pass
            if "Failed records:" in line:
                try: fail = int(''.join(filter(str.isdigit, line.split(":")[-1])))
                except: pass
        return fail == 0
    finally:
        os.unlink(tmp.name)

def deactivate_and_delete_gift_designations(org):
    """GiftDesignation: update individual por registro para manejar IsDefault=true, luego borrar."""
    print(f"\n[GiftDesignation — paso 1: desactivar]", end=" ", flush=True)
    try:
        q = "SELECT Id, IsDefault, IsActive FROM GiftDesignation"
        r = subprocess.run(
            ["sf", "data", "query", "--query", q, "--target-org", org, "--json"],
            capture_output=True, text=True, timeout=60
        )
        data = json.loads(r.stdout)
        if data.get("status") != 0:
            raise RuntimeError(data.get("message", "")[:200])
        records = data["result"]["records"]
        ids = [rec["Id"] for rec in records]

        if not ids:
            print("Sin registros.")
            return True

        print(f"{len(ids)} registros...", end=" ", flush=True)
        deactivated = 0
        for rec in records:
            if rec.get("IsActive") or rec.get("IsDefault"):
                r2 = subprocess.run(
                    ["sf", "data", "update", "record",
                     "--sobject", "GiftDesignation",
                     "--record-id", rec["Id"],
                     "--values", "IsDefault=false IsActive=false",
                     "--target-org", org],
                    capture_output=True, text=True, timeout=30
                )
                if "Success" in r2.stdout:
                    deactivated += 1
        print(f"✅ {deactivated} desactivados")

        print(f"[GiftDesignation — paso 2: borrar]", end=" ", flush=True)
        print(f"{len(ids)} registros...", end=" ", flush=True)
        return bulk_delete("GiftDesignation", ids, org)

    except Exception as e:
        print(f"\n  ❌ Error: {e}")
        return False

def check_deletable(obj, org):
    """Retorna True si el usuario tiene permiso Delete en el objeto."""
    apex_file = tempfile.NamedTemporaryFile(mode="w", suffix=".apex", delete=False, encoding="utf-8")
    apex_file.write(f"System.debug('DELETABLE:' + Schema.sObjectType.{obj}.isDeletable());\n")
    apex_file.close()
    try:
        r = subprocess.run(
            ["sf", "apex", "run", "--file", apex_file.name, "--target-org", org],
            capture_output=True, text=True, timeout=30
        )
        return "DELETABLE:true" in r.stdout
    except:
        return False
    finally:
        os.unlink(apex_file.name)

def delete_campaign(org):
    """Campaign: verificar permiso primero, luego bulk delete (NPC bloquea Apex DML)."""
    print(f"\n[Campaign]", end=" ", flush=True)
    try:
        ids = soql_ids("Campaign", org)
        if not ids:
            print("Sin registros.")
            return True
        print(f"{len(ids)} registros...", end=" ", flush=True)

        if not check_deletable("Campaign", org):
            print(f"\n  ⛔ Sin permiso Delete en Campaign.")
            print(f"     → Setup > Profiles > [tu perfil] > Object Settings > Campaign > activar Delete")
            print(f"     → O: Setup > Data Management > Mass Delete Records > Campaigns (UI)")
            print(f"     → Luego vuelve a correr el script.")
            return False

        return bulk_delete("Campaign", ids, org)

    except Exception as e:
        print(f"\n  ❌ Error: {e}")
        return False

def delete_object(obj, org):
    print(f"\n[{obj}]", end=" ", flush=True)
    try:
        ids = soql_ids(obj, org)
        print(f"{len(ids)} registros...", end=" ", flush=True)
        return bulk_delete(obj, ids, org)
    except Exception as e:
        print(f"\n  ❌ Error: {e}")
        return False

if __name__ == "__main__":
    # Uso: python3 aebeq_prod_delete_demo.py          → producción
    #      python3 aebeq_prod_delete_demo.py --sandbox → sandbox (para probar)
    use_sandbox = "--sandbox" in sys.argv
    TARGET = SANDBOX if use_sandbox else PROD
    env_label = "SANDBOX (partialae)" if use_sandbox else "PRODUCCIÓN ⚠️"

    print("=" * 60)
    print(f"  AEBEQ {env_label} — BORRAR DEMO COMPLETO")
    print("=" * 60)
    print(f"  Org: {TARGET}")
    print(f"  Objetos a borrar: {len(OBJECTS)}")
    print(f"  FundraisingConfig: se conserva (es configuración)")
    print("=" * 60)
    print()
    if not use_sandbox:
        print("⚠️  Esta operación es IRREVERSIBLE en producción.")
        print("   Asegúrate de tener el backup CSV en Demo SF Aebeq/")
    else:
        print("ℹ️  Modo sandbox — seguro para probar. Después corre restore.")
    print()

    confirm = input("Escribe CONFIRMAR para continuar: ").strip()
    if confirm != "CONFIRMAR":
        print("Cancelado.")
        sys.exit(0)

    print(f"\nInicio: {datetime.now().strftime('%Y-%m-%d %H:%M')}")
    failed = []

    for obj in OBJECTS:
        if obj == "GiftDesignation":
            ok = deactivate_and_delete_gift_designations(TARGET)
        elif obj == "Campaign":
            ok = delete_campaign(TARGET)
        else:
            ok = delete_object(obj, TARGET)
        if not ok:
            failed.append(obj)

    # Resumen final
    print(f"\n{'='*60}")
    print(f"Fin: {datetime.now().strftime('%Y-%m-%d %H:%M')}")

    # Contar lo que quedó
    print("\nVerificación final:")
    remaining = {}
    for obj in OBJECTS:
        try:
            ids = soql_ids(obj, TARGET)
            if ids:
                remaining[obj] = len(ids)
                print(f"  ⚠️  {obj}: {len(ids)} registros restantes")
            else:
                print(f"  ✅ {obj}: limpio")
        except:
            pass

    print(f"\n{'='*60}")
    if not remaining:
        if use_sandbox:
            print("✅ Sandbox completamente limpio.")
            print("   Ahora corre: python3 aebeq_demo_restore.py")
        else:
            print("✅ Demo eliminado de producción. Listo para datos reales.")
    else:
        print(f"⚠️  {len(remaining)} objeto(s) con registros restantes:")
        for obj, count in remaining.items():
            note = ""
            if obj in ("Contact", "Account"):
                note = " (probablemente registros del sistema — OK dejar)"
            print(f"   {obj}: {count}{note}")
        if failed:
            print(f"\nObjetos con errores durante borrado: {', '.join(failed)}")

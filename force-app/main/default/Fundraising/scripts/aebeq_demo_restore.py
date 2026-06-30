#!/usr/bin/env python3
"""
aebeq_demo_restore.py  — ETL completo con remapeo de IDs
Restaura el demo de AEBEQ desde CSV aunque el sandbox esté completamente vacío.
Funciona después de un sandbox refresh o de haber borrado todo con aebeq_prod_delete_demo.py.

Uso:
  python3 aebeq_demo_restore.py                  # restaura todos los objetos
  python3 aebeq_demo_restore.py GiftTransaction  # solo ese objeto
"""

import subprocess, json, csv, os, sys, re, tempfile
from datetime import datetime

SANDBOX = "e.frappe@aebeq.qc.ca.partialae"
BASE_DIR = os.path.join(os.path.dirname(__file__), "..", "Demo SF Aebeq")

# Marcador temporal para rastrear IDs — se inserta en un campo de texto filtrable
SENTINEL = "AEBEQ-RESTORE:"

# Tipos de campo que NO son filtrables en SOQL
NON_FILTERABLE_TYPES = {"textarea", "longtextarea", "richtext", "encryptedstring"}

# Campos que NUNCA se insertan
SKIP_FIELDS = {
    "Id", "IsDeleted", "CreatedDate", "CreatedById",
    "LastModifiedDate", "LastModifiedById", "SystemModstamp",
    "LastActivityDate", "LastViewedDate", "LastReferencedDate",
    "MasterRecordId", "attributes",
    "OwnerId",          # lo asigna Salesforce al usuario que corre el script
    "PersonContactId",  # auto-gestionado en Person Account
    "IsPersonAccount",  # read-only, se deriva del RecordType
    "PhotoUrl",         # read-only, sistema
}

# Orden ETL: padres primero. Los hijos usan el id_map construido de sus padres.
# Formato: (prefijo_csv, objeto, necesita_mapeo_propio)
# necesita_mapeo_propio=True  → otros objetos referencian este objeto
# necesita_mapeo_propio=False → nodo hoja, solo usa el id_map existente
OBJECTS_ORDER = [
    ("01", "Account",                     True),
    ("03", "Campaign",                    True),
    ("09", "GiftDesignation",             True),
    ("10", "GiftBatch",                   True),
    ("02", "Contact",                     True),   # AccountId → Account
    ("04", "Opportunity",                 True),   # GiftCommitment referencia OpportunityId
    ("05", "OutreachSourceCode",          True),   # CampaignId → Campaign
    ("06", "PaymentInstrument",           True),   # AccountId → Account
    ("07", "PartyPhilanthropicRsrchPrfl", True),   # ContactId → Contact
    ("08", "PlannedGift",                 False),  # AccountId, ContactId → hoja
    ("11", "GiftCommitment",              True),   # AccountId, ContactId
    ("12", "GiftCommitmentSchedule",      True),   # GiftCommitmentId
    ("13", "GiftTransaction",             True),   # muchos lookups
    ("14", "GiftDefaultDesignation",      False),  # GiftTransactionId, GiftDesignationId → hoja
    ("15", "GiftRefund",                  False),  # GiftTransactionId → hoja
    ("16", "GiftSoftCredit",              False),  # GiftTransactionId, ContactId → hoja
    ("17", "DonorGiftSummary",            False),  # AccountId, ContactId → hoja
    ("18", "FundraisingConfig",           False),  # configuración, ya existe
]

# ────────────────────────────────────────────────────────────────
# Utilidades
# ────────────────────────────────────────────────────────────────

def soql(q, org=SANDBOX):
    r = subprocess.run(
        ["sf", "data", "query", "--query", q, "--target-org", org, "--json"],
        capture_output=True, text=True, timeout=120
    )
    data = json.loads(r.stdout)
    if data.get("status") != 0:
        raise RuntimeError(data.get("message", str(data))[:300])
    return data["result"]["records"]

def get_creatable_fields(obj):
    r = subprocess.run(
        ["sf", "sobject", "describe", "--sobject", obj, "--target-org", SANDBOX, "--json"],
        capture_output=True, text=True, timeout=60
    )
    data = json.loads(r.stdout)
    return {f["name"]: f for f in data["result"]["fields"]
            if f.get("createable") and not f.get("calculated")}

def get_sentinel_field(creatable_fields):
    """
    Devuelve el mejor campo para usar como marcador de restore:
    debe ser creatable, filterable, y tipo texto corto (no Long Text Area).
    Preferencia: AccountNumber > PaymentIdentifier > ProcessorReference > GatewayReference > Name
    """
    preferences = ["AccountNumber", "PaymentIdentifier", "ProcessorReference",
                   "GatewayReference", "LastNextGenCmtProcError", "Name"]
    for candidate in preferences:
        if candidate in creatable_fields:
            f = creatable_fields[candidate]
            if (f.get("filterable") and f.get("createable") and
                    f.get("type") not in NON_FILTERABLE_TYPES):
                return candidate
    # Fallback: cualquier campo string filterable y creatable
    for name, f in creatable_fields.items():
        if (f.get("filterable") and f.get("createable") and
                f.get("type") in ("string", "email") and
                name not in SKIP_FIELDS and
                f.get("type") not in NON_FILTERABLE_TYPES):
            return name
    return None

def bulk_write(op, obj, rows, fieldnames, org=SANDBOX, extra_args=None, show_errors=False):
    """Escribe CSV temporal y ejecuta sf data {op} bulk. Retorna (success, fail, stdout, job_id)."""
    if not rows:
        return 0, 0, "", ""
    tmp = tempfile.NamedTemporaryFile(mode="w", suffix=".csv", delete=False,
                                      newline="\n", encoding="utf-8")
    writer = csv.DictWriter(tmp, fieldnames=fieldnames, lineterminator="\n",
                            extrasaction="ignore")
    writer.writeheader()
    writer.writerows(rows)
    tmp.close()
    cmd = ["sf", "data", op, "bulk",
           "--sobject", obj, "--file", tmp.name,
           "--target-org", org, "--line-ending", "LF", "--wait", "20"]
    if extra_args:
        cmd += extra_args
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=900)
        out = r.stdout + r.stderr
        success = fail = 0
        job_id = ""
        for line in out.split("\n"):
            if "Successful records:" in line:
                try: success = int(''.join(filter(str.isdigit, line.split(":")[-1])))
                except: pass
            if "Failed records:" in line:
                try: fail = int(''.join(filter(str.isdigit, line.split(":")[-1])))
                except: pass
            if not job_id:
                m = re.search(r'\b(750[A-Za-z0-9]{12,15})\b', line)
                if m:
                    job_id = m.group(1)
        if fail > 0 and job_id and show_errors:
            _show_bulk_errors(job_id, org, max_errors=3)
        return success, fail, out, job_id
    finally:
        os.unlink(tmp.name)

def _show_bulk_errors(job_id, org=SANDBOX, max_errors=3):
    """Muestra los primeros errores de un bulk job fallido."""
    r = subprocess.run(
        ["sf", "data", "bulk", "results", "--job-id", job_id, "--target-org", org],
        capture_output=True, text=True, timeout=60
    )
    # Buscar el CSV de errores generado
    import glob
    failed_files = glob.glob(f"{job_id}-failed-records.csv")
    if not failed_files:
        # Intentar leer desde stdout/stderr
        for line in (r.stdout + r.stderr).split("\n"):
            if "sf__Error" in line or "ENTITY_IS" in line or "INVALID_" in line:
                print(f"    Error: {line[:200]}")
        return
    with open(failed_files[0], "r", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for i, row in enumerate(reader):
            if i >= max_errors:
                break
            print(f"    Error {i+1}: {row.get('sf__Error','?')[:200]}")
    # Limpiar archivo de errores
    import os as _os
    for ff in glob.glob(f"{job_id}-*.csv"):
        try: _os.unlink(ff)
        except: pass

def read_csv(fpath):
    with open(fpath, "r", encoding="utf-8", newline="") as f:
        return list(csv.DictReader(f))

def remap_row(row, id_map, skip):
    """Crea una copia del row con los lookups reemplazados por id_map, sin campos skip."""
    return {k: id_map.get(v, v)
            for k, v in row.items()
            if k not in skip}

# ────────────────────────────────────────────────────────────────
# Núcleo del ETL
# ────────────────────────────────────────────────────────────────

def get_existing_ids(obj):
    try:
        recs = soql(f"SELECT Id FROM {obj}")
        return {r["Id"] for r in recs}
    except:
        return set()

def insert_with_mapping(obj, csv_rows, id_map, build_map, extra_skip=None, force_sentinel=None):
    """
    Inserta registros con remapeo de IDs y opcionalmente construye
    el mapeo old_id → new_id usando un campo marcador.

    extra_skip:    campos adicionales a excluir del insert (ej: auto-refs circulares).
    force_sentinel: fuerza un campo sentinel específico (útil cuando NPC borra el campo
                    auto-seleccionado, ej: LastNextGenCmtProcError en GiftCommitment).
    Retorna dict {old_id: new_id} si build_map=True, else {}.
    """
    if not csv_rows:
        return {}

    creatable = get_creatable_fields(obj)
    if force_sentinel and force_sentinel in creatable:
        sentinel_field = force_sentinel
    else:
        sentinel_field = get_sentinel_field(creatable) if build_map else None

    # Filtrar solo campos insertables
    skip = SKIP_FIELDS.copy()
    if extra_skip:
        skip.update(extra_skip)
    if sentinel_field:
        # No saltear el campo centinela aunque aparezca en SKIP_FIELDS
        skip.discard(sentinel_field)

    # Guardar originales del campo centinela
    original_sentinel = {}
    if sentinel_field:
        for row in csv_rows:
            old_id = row["Id"]
            original_sentinel[old_id] = row.get(sentinel_field, "")

    # Construir filas de inserción
    insert_rows = []
    insert_old_ids = []
    for row in csv_rows:
        new_row = remap_row(row, id_map, skip)
        # Solo incluir campos que existen en el objeto
        new_row = {k: v for k, v in new_row.items() if k in creatable}
        if sentinel_field and build_map:
            new_row[sentinel_field] = f"{SENTINEL}{row['Id']}"
        insert_rows.append(new_row)
        insert_old_ids.append(row["Id"])

    if not insert_rows:
        return {}

    fieldnames = list(insert_rows[0].keys())
    success, fail, out, job_id = bulk_write("import", obj, insert_rows, fieldnames)
    if fail > 0 and job_id:
        _show_bulk_errors(job_id, max_errors=3)
    print(f"✅ {success} insertados" + (f", ⚠️ {fail} fallaron" if fail else ""))

    if not build_map or not sentinel_field:
        return {}

    # Consultar registros insertados por el marcador
    sentinel_escaped = SENTINEL.replace("'", "\\'")
    try:
        new_recs = soql(
            f"SELECT Id, {sentinel_field} FROM {obj} "
            f"WHERE {sentinel_field} LIKE '{sentinel_escaped}%'"
        )
    except Exception as e:
        print(f"  ⚠️  No pude consultar marcadores: {e}")
        return {}

    # Construir mapeo old_id → new_id
    new_mapping = {}
    for rec in new_recs:
        marker = rec.get(sentinel_field, "")
        if marker.startswith(SENTINEL):
            old_id = marker[len(SENTINEL):]
            new_mapping[old_id] = rec["Id"]

    # Limpiar: restaurar valor original del campo centinela
    cleanup_rows = []
    for old_id, new_id in new_mapping.items():
        orig = original_sentinel.get(old_id, "")
        cleanup_rows.append({"Id": new_id, sentinel_field: orig})

    if cleanup_rows:
        bulk_write("update", obj, cleanup_rows, ["Id", sentinel_field])

    return new_mapping

# ────────────────────────────────────────────────────────────────
# Handlers especiales
# ────────────────────────────────────────────────────────────────

def handle_gift_designations(csv_rows, id_map):
    """
    GiftDesignation — lógica híbrida:
    - Las que ya existen en sandbox (mismo Name): mapear por nombre sin insertar.
    - Las que no existen: insertar y mapear.
    Funciona tanto después de sandbox refresh (existen de producción)
    como después del delete script (no existe ninguna).
    """
    existing = soql("SELECT Id, Name FROM GiftDesignation")
    name_to_new_id = {r["Name"]: r["Id"] for r in existing}

    new_mapping = {}
    to_insert = []

    for row in csv_rows:
        old_id = row["Id"]
        name   = row.get("Name", "")
        new_id = name_to_new_id.get(name)
        if new_id:
            new_mapping[old_id] = new_id
        else:
            to_insert.append(row)

    if new_mapping:
        print(f"  → {len(new_mapping)} mapeadas por nombre (ya existían)")

    if to_insert:
        print(f"  Insertando {len(to_insert)} faltantes...", end=" ", flush=True)
        inserted = insert_with_mapping("GiftDesignation", to_insert, id_map, build_map=True)
        new_mapping.update(inserted)

    print(f"  → {len(new_mapping)} GiftDesignations en id_map total")
    return new_mapping

def insert_accounts(all_rows, id_map):
    """
    Person Account: Name es read-only (generado de FirstName+LastName).
    Se insertan en dos lotes separados: PersonAccounts y Business Accounts.
    Mapping por PersonEmail (para Person) y AccountNumber sentinel (para Business).
    """
    creatable = get_creatable_fields("Account")
    skip_person = SKIP_FIELDS | {"Name"}   # Name lo genera SF desde FirstName+LastName
    skip_biz    = SKIP_FIELDS.copy()       # Business Account sí necesita Name

    person_rows = [r for r in all_rows if r.get("IsPersonAccount","").lower() == "true"]
    biz_rows    = [r for r in all_rows if r.get("IsPersonAccount","").lower() != "true"]

    new_mapping = {}

    # ── Person Accounts ──────────────────────────────────────────
    if person_rows:
        print(f"  Person ({len(person_rows)})...", end=" ", flush=True)
        # Guardar Email→old_id para matching posterior
        email_to_old = {r.get("PersonEmail",""): r["Id"]
                        for r in person_rows if r.get("PersonEmail","")}

        insert_rows = []
        for r in person_rows:
            row = {k: id_map.get(v, v)
                   for k, v in r.items()
                   if k in creatable and k not in skip_person}
            insert_rows.append(row)

        if insert_rows:
            fnames = list(insert_rows[0].keys())
            success, fail, _, job_id = bulk_write("import", "Account", insert_rows, fnames)
            if fail > 0 and job_id:
                _show_bulk_errors(job_id, max_errors=2)
            print(f"✅ {success} insertados" + (f", ⚠️ {fail} fallaron" if fail else ""))

            # Match por PersonEmail
            new_recs = soql(
                "SELECT Id, PersonEmail FROM Account "
                "WHERE IsPersonAccount = true AND CreatedDate = TODAY"
            )
            for rec in new_recs:
                old_id = email_to_old.get(rec.get("PersonEmail",""))
                if old_id:
                    new_mapping[old_id] = rec["Id"]
            print(f"    → {len(new_mapping)} Person Accounts mapeados")

    # ── Business Accounts ────────────────────────────────────────
    if biz_rows:
        print(f"  Business ({len(biz_rows)})...", end=" ", flush=True)
        orig_acct_num = {r["Id"]: r.get("AccountNumber","") for r in biz_rows}

        insert_rows = []
        for r in biz_rows:
            row = {k: id_map.get(v, v)
                   for k, v in r.items()
                   if k in creatable and k not in skip_biz}
            row["AccountNumber"] = f"{SENTINEL}{r['Id']}"
            insert_rows.append(row)

        if insert_rows:
            fnames = list(insert_rows[0].keys())
            success, fail, _, job_id = bulk_write("import", "Account", insert_rows, fnames)
            if fail > 0 and job_id:
                _show_bulk_errors(job_id, max_errors=2)
            print(f"✅ {success} insertados" + (f", ⚠️ {fail} fallaron" if fail else ""))

            new_recs = soql(
                f"SELECT Id, AccountNumber FROM Account "
                f"WHERE AccountNumber LIKE '{SENTINEL}%'"
            )
            biz_map = {}
            cleanup = []
            for rec in new_recs:
                old_id = rec["AccountNumber"][len(SENTINEL):]
                biz_map[old_id] = rec["Id"]
                cleanup.append({"Id": rec["Id"],
                                 "AccountNumber": orig_acct_num.get(old_id, "")})
            if cleanup:
                bulk_write("update", "Account", cleanup, ["Id", "AccountNumber"])
            new_mapping.update(biz_map)
            print(f"    → {len(biz_map)} Business Accounts mapeados")

    return new_mapping

def insert_contacts(all_rows, id_map):
    """
    Contact:
    - Person Account contacts son auto-creados por SF al insertar el Account.
      NO se pueden insertar manualmente (INVALID_CROSS_REFERENCE_KEY).
      Se mapean vía AccountId: cada auto-created Contact tiene AccountId = new_account_id.
    - Business contacts se insertan manualmente.
    """
    creatable = get_creatable_fields("Contact")
    skip = SKIP_FIELDS.copy()

    # Identificar qué new Account IDs son Person Accounts
    account_csv_path = os.path.join(BASE_DIR, "01_Account_Demo.csv")
    account_rows = read_csv(account_csv_path)
    pa_old_ids = {r["Id"] for r in account_rows if r.get("IsPersonAccount","").lower() == "true"}
    pa_new_ids = {id_map[old] for old in pa_old_ids if old in id_map}

    # Separar filas: PA contacts vs Business contacts
    # Usar old_acct_id primero (evita que PAs sin mapear caigan en Business)
    pa_rows, biz_rows = [], []
    for row in all_rows:
        old_acct = row.get("AccountId","")
        mapped_acct = id_map.get(old_acct, old_acct)
        is_pa = (old_acct in pa_old_ids) or (mapped_acct in pa_new_ids)
        (pa_rows if is_pa else biz_rows).append(row)

    print(f"  {len(pa_rows)} PA (auto-creados) + {len(biz_rows)} Business...")

    new_mapping = {}

    # ── Person Account contacts: mapear por AccountId ──────────
    if pa_rows:
        new_pa = soql(
            "SELECT Id, AccountId, Email FROM Contact "
            "WHERE Account.IsPersonAccount = true "
            "AND Account.CreatedDate = TODAY"
        )
        acct_to_contact = {r["AccountId"]: r["Id"] for r in new_pa}
        for row in pa_rows:
            new_acct = id_map.get(row.get("AccountId",""))
            if new_acct and new_acct in acct_to_contact:
                new_mapping[row["Id"]] = acct_to_contact[new_acct]
        print(f"    → {len(new_mapping)} PA contacts mapeados por AccountId")

    # ── Business contacts: insertar manualmente ────────────────
    if biz_rows:
        print(f"  Insertando {len(biz_rows)} Business contacts...", end=" ", flush=True)
        email_to_old = {r.get("Email",""): r["Id"] for r in biz_rows if r.get("Email","")}
        insert_rows = []
        for r in biz_rows:
            row = {k: id_map.get(v, v)
                   for k, v in r.items()
                   if k in creatable and k not in skip}
            insert_rows.append(row)

        fnames = list(insert_rows[0].keys())
        success, fail, _, job_id = bulk_write("import", "Contact", insert_rows, fnames)
        if fail > 0 and job_id:
            _show_bulk_errors(job_id, max_errors=2)
        print(f"✅ {success} insertados" + (f", ⚠️ {fail} fallaron" if fail else ""))

        # Match Business contacts por Email
        new_recs = soql(
            "SELECT Id, Email FROM Contact "
            "WHERE Account.IsPersonAccount = false "
            "AND Email != null AND CreatedDate = TODAY"
        )
        for rec in new_recs:
            old_id = email_to_old.get(rec.get("Email",""))
            if old_id:
                new_mapping[old_id] = rec["Id"]

    print(f"  → {len(new_mapping)} Contacts mapeados total")
    return new_mapping

# ────────────────────────────────────────────────────────────────
# Main
# ────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    filter_obj = sys.argv[1] if len(sys.argv) > 1 else None

    print("=" * 60)
    print("  AEBEQ Demo Restore — ETL con remapeo de IDs")
    print("=" * 60)
    print(f"  Sandbox: {SANDBOX}")
    print(f"  Fuente:  {os.path.abspath(BASE_DIR)}")
    print(f"  Inicio:  {datetime.now().strftime('%Y-%m-%d %H:%M')}")
    if filter_obj:
        print(f"  Filtro:  solo {filter_obj}")
    print()

    id_map = {}   # acumula old_id → new_id a medida que se insertan objetos

    for prefix, obj, build_map in OBJECTS_ORDER:
        if filter_obj and obj != filter_obj:
            continue

        print(f"\n[{obj}]", end=" ", flush=True)

        # FundraisingConfig: siempre existe, saltar
        if obj == "FundraisingConfig":
            print("configuración — omitido")
            continue

        fname = f"{prefix}_{obj}_Demo.csv"
        fpath = os.path.join(BASE_DIR, fname)
        if not os.path.exists(fpath):
            print(f"⚠️  CSV no encontrado ({fname})")
            continue

        all_rows = read_csv(fpath)
        if not all_rows:
            print("0 registros en CSV")
            continue

        # Solo insertar los que no existen ya
        existing = get_existing_ids(obj)
        # Comparar por valores de campos únicos si existe mapeo, o por Id original
        to_insert = [r for r in all_rows if r["Id"] not in existing]
        # También excluir si el Id ya fue mapeado (ya fue insertado en esta sesión)
        to_insert = [r for r in to_insert if r["Id"] not in id_map]

        if not to_insert:
            print(f"✅ Ya completo ({len(existing)} registros)")
            continue

        print(f"{len(to_insert)} de {len(all_rows)}...")

        try:
            if obj == "Account":
                new_mapping = insert_accounts(to_insert, id_map)
            elif obj == "Contact":
                new_mapping = insert_contacts(to_insert, id_map)
            elif obj == "GiftDesignation":
                # Híbrido: mapear existentes por nombre + insertar las que faltan
                new_mapping = handle_gift_designations(all_rows, id_map)
            elif obj == "GiftCommitment":
                # CurrentGiftCmtScheduleId: referencia circular con GCS (skippear).
                # NPC borra automáticamente campos post-insert (LastNextGenCmtProcError,
                # Location__c — NPC escribe GC fields en trigger after-insert).
                # Usar Name como sentinel: NPC no sobreescribe el nombre del registro.
                # Además limpiar OpportunityId si es ID de producción no remapeado
                # (006au... IDs inaccesibles desde sandbox → INSUFFICIENT_ACCESS).
                processed_rows = []
                for row in to_insert:
                    r = dict(row)
                    opp_id = r.get("OpportunityId", "")
                    if opp_id and id_map.get(opp_id, opp_id) == opp_id:
                        r["OpportunityId"] = ""
                    processed_rows.append(r)
                new_mapping = insert_with_mapping(
                    obj, processed_rows, id_map, build_map,
                    extra_skip={"CurrentGiftCmtScheduleId"},
                    force_sentinel="Name"
                )
            elif obj == "GiftCommitmentSchedule":
                # GiftCommitmentSchdBefEditId es auto-ref circular: los GCS previos
                # no existen aún en sandbox → INVALID_CROSS_REFERENCE_KEY en todos.
                # Se skippea en el insert (campo de auditoría, no crítico para el demo).
                new_mapping = insert_with_mapping(
                    obj, to_insert, id_map, build_map,
                    extra_skip={"GiftCommitmentSchdBefEditId"}
                )
                # Post-pass: ahora que GCS está en id_map, restaurar CurrentGiftCmtScheduleId
                # en GiftCommitment (que se skipeó al insertar GC para evitar la referencia circular)
                id_map.update(new_mapping)
                new_mapping = {}  # evitar doble-update al final del loop
                gc_csv_path = os.path.join(BASE_DIR, "11_GiftCommitment_Demo.csv")
                gc_rows = read_csv(gc_csv_path)
                update_rows = []
                for row in gc_rows:
                    new_gc_id  = id_map.get(row["Id"])
                    old_gcs_id = row.get("CurrentGiftCmtScheduleId","")
                    new_gcs_id = id_map.get(old_gcs_id)
                    if new_gc_id and new_gcs_id:
                        update_rows.append({"Id": new_gc_id, "CurrentGiftCmtScheduleId": new_gcs_id})
                if update_rows:
                    print(f"  → Post-pass: actualizando CurrentGiftCmtScheduleId en {len(update_rows)} GCs...",
                          end=" ", flush=True)
                    s, f, _, job_id = bulk_write("update", "GiftCommitment", update_rows,
                                                 ["Id", "CurrentGiftCmtScheduleId"])
                    if f > 0 and job_id:
                        _show_bulk_errors(job_id, max_errors=2)
                    print(f"✅ {s} actualizados" + (f", ⚠️ {f} fallaron" if f else ""))
            else:
                new_mapping = insert_with_mapping(obj, to_insert, id_map, build_map)
            id_map.update(new_mapping)
        except Exception as e:
            print(f"\n  ❌ {e}")

    print(f"\n{'='*60}")
    print(f"Fin: {datetime.now().strftime('%Y-%m-%d %H:%M')}")
    print(f"IDs mapeados en total: {len(id_map):,}")
    print()
    print("Verificación final:")
    for prefix, obj, _ in OBJECTS_ORDER:
        if obj == "FundraisingConfig":
            continue
        try:
            count = len(soql(f"SELECT Id FROM {obj}"))
            print(f"  {obj}: {count}")
        except:
            pass

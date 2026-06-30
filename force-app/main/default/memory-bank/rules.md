# Rules — Reglas permanentes de trabajo

> Leer SIEMPRE al iniciar una sesión. Estas reglas aplican a todos los proyectos.

---

## 1. Memory-bank — actualizar después de CADA mensaje

- Guardar el prompt/instrucción del usuario **INMEDIATAMENTE** en `activeContext.md` antes de trabajar.
- Actualizar `activeContext.md` y `progress.md` al finalizar cada turno con progreso real.
- No esperar a que el usuario lo pida. No acumular para el final de la sesión.
- Si no hubo nada relevante, no actualizar.

---

## 2. Nunca hacer deploy a producción

- **NUNCA** correr `sf project deploy start` apuntando a `e.frappe@sembeq.qc.ca` (alias: `production`).
- Solo se permite **dry-run** (`--dry-run`) contra producción para validar tests y cobertura.
- El deploy real lo hace **siempre el usuario** con `./manifest/deploy-production.sh production`.
- **Sí se puede** deployar al sandbox partial (`e.frappe@sembeq.qc.ca.partialdev`) con `NoTestRun`.

---

## 3. Salesforce — 5 orgs conectadas

### SEMBEQ
| Org | Username | Alias | Permisos Claude |
|---|---|---|---|
| Producción | `e.frappe@sembeq.qc.ca` | `production` | Solo dry-run. Deploy lo hace el usuario. |
| Sandbox partial | `e.frappe@sembeq.qc.ca.partialdev` | _(default)_ | Deploy permitido con NoTestRun |
| Sandbox newdevpro | `e.frappe@sembeq.qc.ca.newdevpro` | — | Libre |

### AEBEQ (Nonprofit Cloud + Fundraising)
| Org | Username | Org ID | Permisos Claude |
|---|---|---|---|
| Producción | `e.frappe@aebeq.qc.ca` | `00Dau00000AyW45EAF` | **SOLO LECTURA** — nunca escribir, nunca deployar |
| Sandbox partial | `e.frappe@aebeq.qc.ca.partialae` | — | Deploy/pruebas permitido (tiene datos demo) |

**Regla AEBEQ producción:** usar solo para entender configuración y metadatos (SOQL readonly). Cualquier operación de escritura o deploy — pedir confirmación explícita del usuario primero.

---

## 4. MCP Salesforce — configuración activa

**Archivo:** `~/.claude/.mcp.json`

```json
{
  "mcpServers": {
    "salesforce-sandbox": {
      "toolsets": "all",
      "orgs": "partialdev, newdevpro, partialae"
    },
    "salesforce-prod": {
      "toolsets": "data (solo lectura SOQL)",
      "orgs": "production, aebeq-production"
    }
  }
}
```

**Protección adicional** en `~/.claude/settings.json`:
```json
"permissions": { "ask": ["mcp__salesforce-prod__*"] }
```
→ Cualquier operación MCP contra producción (SEMBEQ o AEBEQ) pide confirmación manual del usuario.

## 8. AEBEQ — Datos demo y estructura

- **Carpeta local de datos demo:** `force-app/main/default/Fundraising/` — 17 archivos CSV exportados de AEBEQ demo via SOQL
- **Propósito:** Solo para entender el modelo de datos de Nonprofit Cloud/Fundraising — NO son datos reales
- **Plan del usuario:** Eliminar el demo de producción AEBEQ y poblar con contactos reales; el sandbox `partialae` conservará el demo para pruebas
- **No leer los CSVs proactivamente** — solo consultarlos cuando el usuario lo pida o sea necesario para diseñar algo específico

---

## 5. No hacer cambios que no se pidieron

- Si el usuario hace una **pregunta**, responder — no hacer cambios en el código.
- Solo implementar cuando el usuario lo pida explícitamente.
- Si hay duda sobre el alcance, preguntar antes de actuar.

---

## 6. Deploy script — `manifest/deploy-production.sh`

- Contiene solo los archivos de la **Merge App** (Apex + LWC + 3 objetos + app/tab/flexipage).
- `Email_Address__c` **no está incluido** — la app es dinámica y no lo necesita.
- El permset `Merge_Manager_Access` **no está incluido** — solo el usuario admin accede.
- El flag `--dry-run` siempre activo — el usuario lo quita cuando quiere deployar de verdad.

---

## 7. Estructura de carpetas del proyecto

```
force-app/main/default/
├── classes/          ← Apex (fuente de verdad)
├── lwc/              ← Lightning Web Components
├── objects/          ← Objetos custom (Merge_*, Email_Address__c)
├── memory-bank/      ← Este directorio — contexto de sesión
├── Merge app Salesforce v2/  ← Backup/espejo de la app (sincronizar al finalizar)
└── manifest/         ← Scripts de deploy
```

**Al finalizar cada sesión con cambios:**
1. Copiar archivos modificados a `Merge app Salesforce v2/`
2. Actualizar `activeContext.md` y `progress.md`

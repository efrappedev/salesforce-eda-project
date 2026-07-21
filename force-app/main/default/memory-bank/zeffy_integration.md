# Zeffy ↔ Salesforce Integration Robot

## Visión (definida 2026-06-30)

Robot automático que conecta Zeffy con Salesforce en **ambas orgs** (AEBEQ y SEMBEQ).
Cuando Zeffy recibe una donación → Salesforce reacciona con máximo 2 pasos humanos.
API Zeffy: https://www.zeffy.com/api/docs

---

## Flujo del robot

```
Zeffy recibe donación
        ↓
Zeffy dispara webhook → Salesforce Apex REST endpoint
        ↓
Salesforce busca Contact por Zeffy_Contact_Id__c (external ID)
        ↓
    ¿Existe?
   /         \
  SÍ          NO
  ↓            ↓
Actualiza   Crea Case "Nuevo Donante Zeffy"
Contact +   asignado a usuario Basic_Contact_Access
Donacion__c
  ↓            ↓
AUTOMÁTICO  [PASO 1 humano: revisar + 1 clic "Crear Donante + Donación"]
```

**Paso 1 humano:** revisor ve Case pre-llenado con datos Zeffy → 1 clic → Flow crea Contact + Donacion__c + Campaign + Donacion_Recurrente__c (si aplica) → cierra Case.

**Paso 2 humano (solo conflictos):** donante existente con datos diferentes → tarea de revisión manual. En condiciones normales no ocurre.

---

## Componentes técnicos

### A. Apex REST Webhook Receiver

```
Clase:    ZeffyWebhookReceiver
Endpoint: /services/apexrest/zeffy/webhook
Método:   @HttpPost
```

Lógica:
1. Recibe JSON de Zeffy, valida token secreto en header
2. Parsea payload → datos donante + transacción
3. Busca Contact por `Zeffy_Contact_Id__c`
4. Si existe → `ZeffyDonationService.updateAndCreateDonation()`
5. Si no existe → `ZeffyDonationService.createReviewCase()`

### B. External IDs requeridos

| Objeto | Campo | Función |
|---|---|---|
| Contact | `Zeffy_Contact_Id__c` Text(50) External ID | Matching donante |
| Donacion__c | `Zeffy_Transaction_Id__c` Text(255) External ID | Deduplicación |
| Donacion_Recurrente__c | `Zeffy_Subscription_Id__c` Text(255) External ID | Matching recurrentes |

### C. Case Record Type: "Nuevo Donante Zeffy"

Campos custom en Case para datos Zeffy pendientes:
- `Zeffy_Contact_Id__c`, `Zeffy_First_Name__c`, `Zeffy_Last_Name__c`, `Zeffy_Email__c`
- `Zeffy_Amount__c`, `Zeffy_Date__c`, `Zeffy_Payment_Method__c`
- `Zeffy_Campaign__c`, `Zeffy_Is_Recurring__c`
- `Zeffy_Raw_Payload__c` — JSON completo para auditoría
- Queue asignada: "Revisión Zeffy" (usuarios con PS Basic_Contact_Access)

### D. Flow: "Crear Donante desde Case Zeffy"

Botón en el Case. Crea en orden:
1. Contact con campos de Zeffy
2. Donacion__c vinculada
3. Donacion_Recurrente__c si `Zeffy_Is_Recurring__c = true`
4. Link a Campaign si viene en el payload
5. Cierra el Case como Resuelto

### E. Endpoint público

- **Recomendado:** Salesforce Site + validación de token secreto en header HTTP
- Alternativa más segura: Connected App + OAuth (más complejo)

---

## Campos a sincronizar desde Zeffy

**En Contact:** nombre, apellido, email, teléfono, dirección completa, idioma (FR/EN), `Zeffy_Contact_Id__c`

**En Donacion__c:** monto bruto/neto/fee, método de pago, fecha, estado, campaña, `Zeffy_Transaction_Id__c`, es_recurrente

**En Donacion_Recurrente__c:** frecuencia, monto, fecha inicio, próxima fecha, estado suscripción, `Zeffy_Subscription_Id__c`

---

## Capa IA — Fase 5 (post-lanzamiento)

Agente que responde preguntas sobre fundraising en Salesforce:
- "¿Cuánto recaudamos este trimestre?"
- "¿Top 10 donantes del año?"
- "¿Donantes que no han renovado en 2 años?"

**Opciones técnicas:**

| Opción | Requisito | Complejidad |
|---|---|---|
| Agentforce nativo | Licencia Einstein | Bajo |
| IA corporativa via Named Credential | API key propia | Medio-Alto |
| Apex + SOQL + LLM externo | API key IA corporativa | Alto |

**Recomendación:** IA corporativa propia via Named Credential. Salesforce = data layer, IA = razonador.
Límites a respetar: 100 callouts/transacción, 120s timeout, Named Credentials (nunca hardcodear API keys).

---

## Reutilización AEBEQ / SEMBEQ

El código del webhook es casi idéntico en ambas orgs:
- En AEBEQ: objeto destino = `GiftTransaction` (NPC nativo)
- En SEMBEQ: objeto destino = `Donacion__c` (custom)
- Lógica de matching `Zeffy_Contact_Id__c` idéntica en ambas

**Estado:** Arquitectura definida. Construir en Fase 3 de Fundraising (después de objetos y flows).

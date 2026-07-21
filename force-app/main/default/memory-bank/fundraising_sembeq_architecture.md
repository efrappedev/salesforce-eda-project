# SEMBEQ — Módulo Custom de Fundraising

## Decisión arquitectónica (2026-06-30)

SEMBEQ **no puede usar Nonprofit Cloud (NPC)** — requiere licencia paga que Salesforce no otorga.
SEMBEQ **no instalará NPSP** — puede chocar con EDA (ambos tocan Account/Contact).
**Decisión:** Construir 3 objetos custom que replican la lógica Gift* de AEBEQ, adaptados a la escala de SEMBEQ.
No sugerir NPSP ni NPC en el futuro — la decisión está tomada.

## Referencia: AEBEQ usa NPC nativo

AEBEQ sandbox tiene ~15 objetos nativos `Gift*` (GiftTransaction, GiftCommitment, GiftDesignation, etc.)
Estos son objetos NATIVOS de la plataforma — no se pueden deployar como metadata.

---

## Objeto 1: `Donacion__c` ← equivale a GiftTransaction

| Campo | Tipo | Notas |
|---|---|---|
| `Donor__c` | Lookup(Contact) | Donante individual |
| `Donor_Account__c` | Lookup(Account) | Donante organización |
| `Amount__c` | Currency | Monto bruto |
| `Net_Amount__c` | Currency | Monto - comisiones |
| `Platform_Fee__c` | Currency | Comisión Zeffy |
| `Payment_Method__c` | Picklist | Tarjeta, Cheque, Efectivo, Transferencia |
| `Status__c` | Picklist | Recibida, Pendiente, Reembolsada, Anulada |
| `Donation_Date__c` | Date | Fecha real de la donación |
| `Acknowledgement_Status__c` | Picklist | No Enviado, Enviado, Acusado |
| `Tax_Receipt_Status__c` | Picklist | No Emitido, Emitido, Anulado |
| `Tax_Receipt_Number__c` | Text(50) | Número del recibo fiscal |
| `Campaign__c` | Lookup(Campaign) | Objeto estándar Campaign |
| `Fund__c` | Lookup(Fondo__c) | A qué fondo va la donación |
| `Recurring_Gift__c` | Lookup(Donacion_Recurrente__c) | Si es parte de recurrente |
| `Zeffy_Transaction_Id__c` | Text(255) + External ID | ID único Zeffy — evita duplicados |
| `Is_Anonymous__c` | Checkbox | Donación anónima |
| `Notes__c` | TextArea(2000) | Notas internas |

---

## Objeto 2: `Donacion_Recurrente__c` ← equivale a GiftCommitment

| Campo | Tipo | Notas |
|---|---|---|
| `Donor__c` | Lookup(Contact) | Donante |
| `Donor_Account__c` | Lookup(Account) | Donante organización |
| `Amount__c` | Currency | Monto por período |
| `Frequency__c` | Picklist | Mensual, Trimestral, Anual |
| `Status__c` | Picklist | Activa, Pausada, Cancelada, Completada |
| `Start_Date__c` | Date | Inicio del compromiso |
| `End_Date__c` | Date | Fin (vacío = indefinido) |
| `Next_Payment_Date__c` | Date | Próxima fecha esperada |
| `Total_Paid__c` | Roll-Up (Donacion__c) | Total acumulado pagado |
| `Payment_Count__c` | Roll-Up (Donacion__c) | Número de pagos realizados |
| `Campaign__c` | Lookup(Campaign) | Campaña de origen |
| `Zeffy_Subscription_Id__c` | Text(255) + External ID | ID suscripción Zeffy |

---

## Objeto 3: `Fondo__c` ← equivale a GiftDesignation

| Campo | Tipo | Notas |
|---|---|---|
| `Name` | Text | Ej: Fondo General, Becas, Eventos |
| `Is_Active__c` | Checkbox | Si el fondo acepta donaciones |
| `Is_Default__c` | Checkbox | Fondo por defecto si no se especifica |
| `Goal__c` | Currency | Meta de recaudación (opcional) |
| `Total_Raised__c` | Roll-Up (Donacion__c) | Total recibido en este fondo |
| `Current_Year_Total__c` | Roll-Up (Donacion__c) | Total año actual |
| `Description__c` | TextArea | Descripción del fondo |

---

## Campos en Contact (resumen de donante)

| Campo | Tipo | Fuente |
|---|---|---|
| `Zeffy_Contact_Id__c` | Text(50) + External ID | ID externo Zeffy — clave de matching |
| `Total_Lifetime_Giving__c` | Currency | Flow |
| `Last_Gift_Date__c` | Date | Flow |
| `Last_Gift_Amount__c` | Currency | Flow |
| `Giving_Level__c` | Picklist | Donor, Supporter, Major Donor |
| `LYBUNT__c` | Checkbox | Donó año pasado pero no este año |
| `SYBUNT__c` | Checkbox | Donó algún año pero no este año |
| `First_Gift_Date__c` | Date | Flow |
| `Total_Gift_Count__c` | Number | Flow |

---

## Fases de implementación

| Fase | Contenido | Estimado |
|---|---|---|
| **1** | 3 objetos + campos en Contact/Account + Permission Sets | 1 día |
| **2** | Flows: acknowledgement, tax receipt, LYBUNT/SYBUNT | 1 día |
| **3** | Zeffy webhook receiver + Case review (ver zeffy_integration.md) | 1-2 días |
| **4** | Reportes y dashboards de fundraising | 1 día |
| **5** | IA corporativa sobre objetos fundraising | Post fases 1-4 |

**Estado actual:** Arquitectura definida. Pendiente inicio Fase 1.
**Prerequisito:** Validar EDA_Staff_Access PS con los 5 usuarios antes de arrancar.

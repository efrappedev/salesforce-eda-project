#!/usr/bin/env bash
# Compatible con bash 3.2 (macOS). Sin jq. Idempotente. Usa ESPACIOS en --values.
set -euo pipefail

ORG="${1:-}"
if [ -z "$ORG" ]; then
  echo "Uso: $0 <username|alias de org SF>"
  exit 1
fi

say(){ printf "\n==> %s\n" "$*"; }
# Devuelve solo valores (sin encabezado)
qval(){ sf data query --query "$1" --target-org "$ORG" --result-format csv | tail -n +2 | tr -d '\r'; }

ACCOUNT_NAME="Instituto Teológico"

say "Asegurando Account '${ACCOUNT_NAME}'..."
ACCOUNT_ID="$(qval "SELECT Id FROM Account WHERE Name='${ACCOUNT_NAME}' LIMIT 1")"
if [ -z "$ACCOUNT_ID" ]; then
  sf data record create --sobject Account --values "Name='${ACCOUNT_NAME}'" --target-org "$ORG" >/dev/null
  ACCOUNT_ID="$(qval "SELECT Id FROM Account WHERE Name='${ACCOUNT_NAME}' LIMIT 1")"
fi
echo "Account: ${ACCOUNT_ID}"

###############################################################################
# 1) TERMS (CSV: Name,Start,End)
###############################################################################
TERMS_CSV='
2018-Fall,2018-09-01,2018-12-15
2019-Spring,2019-01-15,2019-05-15
2020-Fall,2020-09-01,2020-12-15
2021-Spring,2021-01-15,2021-05-15
2024-Fall,2024-09-01,2024-12-15
'

say "Asegurando Terms..."
echo "$TERMS_CSV" | while IFS=, read -r NAME SD ED; do
  [ -z "$NAME" ] && continue
  TID="$(qval "SELECT Id FROM hed__Term__c WHERE Name='${NAME}' LIMIT 1")"
  if [ -z "$TID" ]; then
    sf data record create --sobject hed__Term__c \
      --values "Name='${NAME}' hed__Start_Date__c=${SD} hed__End_Date__c=${ED} hed__Account__c=${ACCOUNT_ID}" \
      --target-org "$ORG" >/dev/null
  fi
done

TERM_2018F="$(qval "SELECT Id FROM hed__Term__c WHERE Name='2018-Fall'")"
TERM_2019S="$(qval "SELECT Id FROM hed__Term__c WHERE Name='2019-Spring'")"
TERM_2020F="$(qval "SELECT Id FROM hed__Term__c WHERE Name='2020-Fall'")"
TERM_2021S="$(qval "SELECT Id FROM hed__Term__c WHERE Name='2021-Spring'")"
TERM_2024F="$(qval "SELECT Id FROM hed__Term__c WHERE Name='2024-Fall'")"

###############################################################################
# 2) COURSES (CSV: Name|Code)
###############################################################################
COURSES_CSV='
Hermenéutica I|HERM101
Historia de la Iglesia|HIST201
Griego I|GRK101
Hebreo I|HEB101
Teología Sistemática II|THE201
'

say "Asegurando Courses..."
echo "$COURSES_CSV" | while IFS='|' read -r CNAME CODE; do
  [ -z "$CNAME" ] && continue
  CID="$(qval "SELECT Id FROM hed__Course__c WHERE hed__Course_ID__c='${CODE}' OR Name='${CNAME}' LIMIT 1")"
  if [ -z "$CID" ]; then
    sf data record create --sobject hed__Course__c \
      --values "Name='${CNAME}' hed__Course_ID__c='${CODE}' hed__Account__c=${ACCOUNT_ID}" \
      --target-org "$ORG" >/dev/null
  fi
done

COURSE_BIB="$(qval "SELECT Id FROM hed__Course__c WHERE hed__Course_ID__c='BIB101' OR Name='Biblia I' LIMIT 1")"
COURSE_TEOI="$(qval "SELECT Id FROM hed__Course__c WHERE hed__Course_ID__c='THE101' OR Name='Teología I' LIMIT 1")"
COURSE_HERM="$(qval "SELECT Id FROM hed__Course__c WHERE hed__Course_ID__c='HERM101'")"
COURSE_HIST="$(qval "SELECT Id FROM hed__Course__c WHERE hed__Course_ID__c='HIST201'")"
COURSE_GRK="$(qval "SELECT Id FROM hed__Course__c WHERE hed__Course_ID__c='GRK101'")"
COURSE_HEB="$(qval "SELECT Id FROM hed__Course__c WHERE hed__Course_ID__c='HEB101'")"
COURSE_TEOII="$(qval "SELECT Id FROM hed__Course__c WHERE hed__Course_ID__c='THE201'")"

###############################################################################
# 3) COURSE OFFERINGS (CSV: Name|CourseCode|TermName)
###############################################################################
OFFERINGS_CSV='
HERM101-2019S|HERM101|2019-Spring
HIST201-2020F|HIST201|2020-Fall
GRK101-2021S|GRK101|2021-Spring
HEB101-2024F|HEB101|2024-Fall
THE201-2018F|THE201|2018-Fall
'

say "Asegurando Course Offerings..."
echo "$OFFERINGS_CSV" | while IFS='|' read -r ONAME OCODE TNAME; do
  [ -z "$ONAME" ] && continue
  OID="$(qval "SELECT Id FROM hed__Course_Offering__c WHERE Name='${ONAME}' LIMIT 1")"
  if [ -z "$OID" ]; then
    case "$OCODE" in
      BIB101)  OCOURSE="$COURSE_BIB" ;;
      THE101)  OCOURSE="$COURSE_TEOI" ;;
      HERM101) OCOURSE="$COURSE_HERM" ;;
      HIST201) OCOURSE="$COURSE_HIST" ;;
      GRK101)  OCOURSE="$COURSE_GRK" ;;
      HEB101)  OCOURSE="$COURSE_HEB" ;;
      THE201)  OCOURSE="$COURSE_TEOII" ;;
      *) OCOURSE="" ;;
    esac
    case "$TNAME" in
      2018-Fall)   OTERM="$TERM_2018F" ;;
      2019-Spring) OTERM="$TERM_2019S" ;;
      2020-Fall)   OTERM="$TERM_2020F" ;;
      2021-Spring) OTERM="$TERM_2021S" ;;
      2024-Fall)   OTERM="$TERM_2024F" ;;
      *) OTERM="" ;;
    esac
    if [ -n "$OCOURSE" ] && [ -n "$OTERM" ]; then
      sf data record create --sobject hed__Course_Offering__c \
        --values "Name='${ONAME}' hed__Course__c=${OCOURSE} hed__Term__c=${OTERM}" \
        --target-org "$ORG" >/dev/null || true
    fi
  fi
done

OFF_BIB_2015F="$(qval "SELECT Id FROM hed__Course_Offering__c WHERE Name='BIB101-2015F' LIMIT 1")"
OFF_BIB_2022F="$(qval "SELECT Id FROM hed__Course_Offering__c WHERE Name='BIB101-2022F' LIMIT 1")"
OFF_TEOI_2023S="$(qval "SELECT Id FROM hed__Course_Offering__c WHERE Name='THE101-2023S' LIMIT 1")"
OFF_HERM_2019S="$(qval "SELECT Id FROM hed__Course_Offering__c WHERE Name='HERM101-2019S' LIMIT 1")"
OFF_HIST_2020F="$(qval "SELECT Id FROM hed__Course_Offering__c WHERE Name='HIST201-2020F' LIMIT 1")"
OFF_GRK_2021S="$(qval "SELECT Id FROM hed__Course_Offering__c WHERE Name='GRK101-2021S' LIMIT 1")"
OFF_HEB_2024F="$(qval "SELECT Id FROM hed__Course_Offering__c WHERE Name='HEB101-2024F' LIMIT 1")"
OFF_TEOII_2018F="$(qval "SELECT Id FROM hed__Course_Offering__c WHERE Name='THE201-2018F' LIMIT 1")"

###############################################################################
# 4) PROGRAM PLANS
###############################################################################
PLAN_BASIC_NAME="Plan Básico"
PLAN_INTER_NAME="Plan Intermedio"
PLAN_AVANZ_NAME="Plan Avanzado"

say "Asegurando Program Plans..."
PLAN_BASIC_ID="$(qval "SELECT Id FROM hed__Program_Plan__c WHERE Name='${PLAN_BASIC_NAME}' LIMIT 1")"
[ -z "$PLAN_BASIC_ID" ] && sf data record create --sobject hed__Program_Plan__c --values "Name='${PLAN_BASIC_NAME}'" --target-org "$ORG" >/dev/null
PLAN_BASIC_ID="$(qval "SELECT Id FROM hed__Program_Plan__c WHERE Name='${PLAN_BASIC_NAME}' LIMIT 1")"

PLAN_INTER_ID="$(qval "SELECT Id FROM hed__Program_Plan__c WHERE Name='${PLAN_INTER_NAME}' LIMIT 1")"
[ -z "$PLAN_INTER_ID" ] && sf data record create --sobject hed__Program_Plan__c --values "Name='${PLAN_INTER_NAME}'" --target-org "$ORG" >/dev/null
PLAN_INTER_ID="$(qval "SELECT Id FROM hed__Program_Plan__c WHERE Name='${PLAN_INTER_NAME}' LIMIT 1")"

PLAN_AVANZ_ID="$(qval "SELECT Id FROM hed__Program_Plan__c WHERE Name='${PLAN_AVANZ_NAME}' LIMIT 1")"
[ -z "$PLAN_AVANZ_ID" ] && sf data record create --sobject hed__Program_Plan__c --values "Name='${PLAN_AVANZ_NAME}'" --target-org "$ORG" >/dev/null
PLAN_AVANZ_ID="$(qval "SELECT Id FROM hed__Program_Plan__c WHERE Name='${PLAN_AVANZ_NAME}' LIMIT 1")"

###############################################################################
# 5) PLAN REQUIREMENTS (CSV: PlanName|CourseCode|Label)
###############################################################################
REQS_CSV='
Plan Básico|BIB101|Básico - Biblia I
Plan Básico|THE101|Básico - Teología I
Plan Intermedio|BIB101|Intermedio - Biblia I
Plan Intermedio|HIST201|Intermedio - Historia de la Iglesia
Plan Intermedio|GRK101|Intermedio - Griego I
Plan Avanzado|THE101|Avanzado - Teología I
Plan Avanzado|THE201|Avanzado - Teología Sistemática II
Plan Avanzado|HEB101|Avanzado - Hebreo I
'

say "Asegurando Plan Requirements..."
echo "$REQS_CSV" | while IFS='|' read -r PNAME PCODE PLABEL; do
  [ -z "$PNAME" ] && continue
  case "$PNAME" in
    "Plan Básico")     PPLAN="$PLAN_BASIC_ID" ;;
    "Plan Intermedio") PPLAN="$PLAN_INTER_ID" ;;
    "Plan Avanzado")   PPLAN="$PLAN_AVANZ_ID" ;;
    *) PPLAN="" ;;
  esac
  case "$PCODE" in
    BIB101)  PCourse="$COURSE_BIB" ;;
    THE101)  PCourse="$COURSE_TEOI" ;;
    HERM101) PCourse="$COURSE_HERM" ;;
    HIST201) PCourse="$COURSE_HIST" ;;
    GRK101)  PCourse="$COURSE_GRK" ;;
    HEB101)  PCourse="$COURSE_HEB" ;;
    THE201)  PCourse="$COURSE_TEOII" ;;
    *) PCourse="" ;;
  esac
  [ -z "$PPLAN" ] && continue
  [ -z "$PCourse" ] && continue
  RID="$(qval "SELECT Id FROM hed__Plan_Requirement__c WHERE hed__Program_Plan__c='${PPLAN}' AND hed__Course__c='${PCourse}' LIMIT 1")"
  if [ -z "$RID" ]; then
    sf data record create --sobject hed__Plan_Requirement__c \
      --values "Name='${PLABEL}' hed__Program_Plan__c=${PPLAN} hed__Course__c=${PCourse}" \
      --target-org "$ORG" >/dev/null
  fi
done

###############################################################################
# 6) CONTACTS (CSV: First|Last|Email)
###############################################################################
STUDENTS_CSV='
Carlos|Méndez|carlos.mendez@example.edu
Lucía|Torres|lucia.torres@example.edu
Pedro|Ramírez|pedro.ramirez@example.edu
María|Fernanda|maria.fernanda@example.edu
Sofía|Rojas|sofia.rojas@example.edu
'

say "Asegurando Contacts..."
echo "$STUDENTS_CSV" | while IFS='|' read -r FN LN EM; do
  [ -z "$FN" ] && continue
  CID="$(qval "SELECT Id FROM Contact WHERE Email='${EM}' LIMIT 1")"
  if [ -z "$CID" ]; then
    sf data record create --sobject Contact \
      --values "FirstName='${FN}' LastName='${LN}' Email='${EM}'" \
      --target-org "$ORG" >/dev/null
  fi
done

C_CARLOS="$(qval "SELECT Id FROM Contact WHERE Email='carlos.mendez@example.edu'")"
C_LUCIA="$(qval "SELECT Id FROM Contact WHERE Email='lucia.torres@example.edu'")"
C_PEDRO="$(qval "SELECT Id FROM Contact WHERE Email='pedro.ramirez@example.edu'")"
C_MARIA="$(qval "SELECT Id FROM Contact WHERE Email='maria.fernanda@example.edu'")"
C_SOFIA="$(qval "SELECT Id FROM Contact WHERE Email='sofia.rojas@example.edu'")"

###############################################################################
# 7) PROGRAM ENROLLMENTS
###############################################################################
say "Asegurando Program Enrollments..."
mkpe(){ # contactId, planId
  PEID="$(qval "SELECT Id FROM hed__Program_Enrollment__c WHERE hed__Contact__c='${1}' AND hed__Program_Plan__c='${2}' LIMIT 1")"
  if [ -z "$PEID" ]; then
    sf data record create --sobject hed__Program_Enrollment__c \
      --values "hed__Contact__c=${1} hed__Program_Plan__c=${2}" \
      --target-org "$ORG" >/dev/null
  fi
}
mkpe "$C_CARLOS" "$PLAN_BASIC_ID"
mkpe "$C_LUCIA"  "$PLAN_INTER_ID"
mkpe "$C_PEDRO"  "$PLAN_AVANZ_ID"
mkpe "$C_MARIA"  "$PLAN_INTER_ID"
mkpe "$C_SOFIA"  "$PLAN_BASIC_ID"

PE_CARLOS="$(qval "SELECT Id FROM hed__Program_Enrollment__c WHERE hed__Contact__c='${C_CARLOS}' AND hed__Program_Plan__c='${PLAN_BASIC_ID}'")"
PE_LUCIA="$(qval "SELECT Id FROM hed__Program_Enrollment__c WHERE hed__Contact__c='${C_LUCIA}' AND hed__Program_Plan__c='${PLAN_INTER_ID}'")"
PE_PEDRO="$(qval "SELECT Id FROM hed__Program_Enrollment__c WHERE hed__Contact__c='${C_PEDRO}' AND hed__Program_Plan__c='${PLAN_AVANZ_ID}'")"
PE_MARIA="$(qval "SELECT Id FROM hed__Program_Enrollment__c WHERE hed__Contact__c='${C_MARIA}' AND hed__Program_Plan__c='${PLAN_INTER_ID}'")"
PE_SOFIA="$(qval "SELECT Id FROM hed__Program_Enrollment__c WHERE hed__Contact__c='${C_SOFIA}' AND hed__Program_Plan__c='${PLAN_BASIC_ID}'")"

###############################################################################
# 8) COURSE ENROLLMENTS (Contact|PE|OfferingName|Status|Notations)
###############################################################################
say "Asegurando Course Enrollments..."
mkce(){ # contactId, peId, offName, status, notes
  [ -z "$3" ] && return 0
  OFFID="$(qval "SELECT Id FROM hed__Course_Offering__c WHERE Name='${3}' LIMIT 1")"
  [ -z "$OFFID" ] && return 0
  CEID="$(qval "SELECT Id FROM hed__Course_Enrollment__c WHERE hed__Contact__c='${1}' AND hed__Course_Offering__c='${OFFID}' LIMIT 1")"
  if [ -z "$CEID" ]; then
    sf data record create --sobject hed__Course_Enrollment__c \
      --values "hed__Contact__c=${1} hed__Program_Enrollment__c=${2} hed__Course_Offering__c=${OFFID} hed__Status__c='${4}' Notations__c='${5}'" \
      --target-org "$ORG" >/dev/null
  fi
}

# Carlos (Básico): BIB101-2015F Completed (R) -> último curso antiguo (7+ años)
mkce "$C_CARLOS" "$PE_CARLOS" "BIB101-2015F" "Completed" "R"

# Lucía (Intermedio): BIB101-2022F Completed (R), HIST201-2020F Completed (R), GRK101-2021S Current
mkce "$C_LUCIA" "$PE_LUCIA" "BIB101-2022F" "Completed" "R"
mkce "$C_LUCIA" "$PE_LUCIA" "HIST201-2020F" "Completed" "R"
mkce "$C_LUCIA" "$PE_LUCIA" "GRK101-2021S" "Current"   ""

# Pedro (Avanzado): THE101-2023S Completed (R), THE201-2018F Completed (R)  (falta HEB101)
mkce "$C_PEDRO" "$PE_PEDRO" "THE101-2023S" "Completed" "R"
mkce "$C_PEDRO" "$PE_PEDRO" "THE201-2018F" "Completed" "R"

# María (Intermedio): Hermenéutica 2019S en Current (solo para “último curso”)
mkce "$C_MARIA" "$PE_MARIA" "HERM101-2019S" "Current" ""

# Sofía (Básico): BIB101-2022F Completed, THE101-2023S Completed (100%)
mkce "$C_SOFIA" "$PE_SOFIA" "BIB101-2022F" "Completed" "R"
mkce "$C_SOFIA" "$PE_SOFIA" "THE101-2023S" "Completed" "R"

say "Listo. Dataset ampliado."
echo "Planes: ${PLAN_BASIC_NAME}, ${PLAN_INTER_NAME}, ${PLAN_AVANZ_NAME}"
echo "Alumnos: Carlos, Lucía, Pedro, María, Sofía"

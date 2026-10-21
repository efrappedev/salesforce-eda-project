# AGENTS.md — reglas para Codex en este repo

Trabajas como **ejecutor de código** dirigido por Claude Code. Claude planea, te da la tarea,
revisa tu diff y es el único que deploya. Tú solo escribes código dentro de este proyecto.

## Lo que NO haces nunca

- No ejecutas `sf`, `sfdx` ni nada que hable con un org de Salesforce (sandbox o producción).
- No haces `git commit`, `push`, `reset`, `checkout`, etc. Deja los cambios sin commitear.
- No instalas paquetes ni usas la red.
- No tocas: `.claude/`, `.husky/`, `.sf/`, `.sfdx/`, `.vscode/`, `.git/`, `CLAUDE.md`, `AGENTS.md`,
  `sfdx-project.json`, `package.json`, `.forceignore`, `.gitignore`, `manifest/`, ni ningún script
  `.sh` (en especial `deploy-production.sh`). Si la tarea parece requerirlo, detente y dilo.
- No borras archivos que no te pidieron borrar.

## Cómo trabajas

- Toca solo los archivos que la tarea menciona (o los mínimos necesarios), y termina con una lista
  de archivos cambiados y por qué.
- Imita el código que ya existe: nombres, comentarios, estructura, idioma de los comentarios.
- Si algo es ambiguo, no inventes: reporta la duda en tu respuesta final.

## Convenciones Salesforce del repo

- Cada app vive en su carpeta (ej. `force-app/main/default/Data Update Center/`).
- Nombres únicos por org: componentes nuevos llevan el prefijo de la app
  (`DataUpdate*`, `dataUpdate*`, `Dmc*`, `Merge*`…). Nunca nombres genéricos (`Utils`, `i18n`).
- Apex: clases `with sharing` salvo que el archivo vecino diga otra cosa; cada clase nueva con su
  `*Test.cls`; tests sin `SeeAllData=true`.
- Comparar strings en Apex con `.equals()` (el `==` ignora caracteres Unicode zero-width).
- `String.isBlank()` trata solo-espacios como vacío: si importa, usar `!= null && length() > 0`.
- CMDT: al reescribir un registro con `Metadata.CustomMetadata`, omitir un valor NO lo limpia;
  hay que poner el valor explícito. Todo SOQL que alimenta `fullRecordToMetadata` debe traer
  todos los campos que se leen.
- LWC: el CSS global de Lightning se filtra; usa clases con prefijo propio (ej. `dub-`) y `div`
  con `role` en vez de `main/aside/section/header`.
- Data Update Center es bilingüe **FR/EN** (no español): toda clave nueva de i18n va en ambos
  idiomas en `dataUpdateI18n.js`.
- Textos de UI para usuarios finales: francés/inglés. Comentarios de código: inglés.

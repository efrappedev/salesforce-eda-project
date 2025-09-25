#!/bin/bash
# Script para subir todo el proyecto a GitHub rápidamente

# Añadir todos los cambios (nuevos, modificados, borrados)
git add -A

# Hacer commit con un mensaje automático o personalizado
if [ -z "$1" ]; then
  git commit -m "Update completo"
else
  git commit -m "$1"
fi

# Subir a la rama main
git push origin main

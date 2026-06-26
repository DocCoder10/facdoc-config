#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
INPUT="$SCRIPT_DIR/new_list.txt"
CONFIG_DIR="$ROOT_DIR/config"
INDEX="$CONFIG_DIR/index.json"

# ── Dépendances ────────────────────────────────────────────────
if ! command -v jq &>/dev/null; then
    echo "❌ 'jq' n'est pas installé. Lance : sudo apt install jq"
    exit 1
fi

if [ ! -f "$INPUT" ]; then
    echo "❌ Fichier introuvable : $INPUT"
    exit 1
fi

# ── Title Case ─────────────────────────────────────────────────
to_title_case() {
    echo "$1" | awk '{
        result = ""; word = ""; in_word = 0
        for (i = 1; i <= length($0); i++) {
            c = substr($0, i, 1)
            if (c == " " || c == "-") {
                if (in_word) {
                    result = result toupper(substr(word,1,1)) tolower(substr(word,2))
                    word = ""; in_word = 0
                }
                result = result c
            } else {
                word = word c; in_word = 1
            }
        }
        if (in_word) result = result toupper(substr(word,1,1)) tolower(substr(word,2))
        print result
    }'
}

# ── Parse en-têtes (Classe & Semestre) ─────────────────────────
CLASSE=""
SEMESTRE=""
LINE_NUM=0

while IFS= read -r line || [ -n "$line" ]; do
    LINE_NUM=$((LINE_NUM + 1))
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// }" ]] && continue

    if [[ "$line" =~ ^[Cc]lasse[[:space:]]*:[[:space:]]*(.+)$ ]]; then
        CLASSE="${BASH_REMATCH[1]}"
        CLASSE="${CLASSE// /}"
    elif [[ "$line" =~ ^[Ss]emestre[[:space:]]*:[[:space:]]*(.+)$ ]]; then
        SEMESTRE="${BASH_REMATCH[1]}"
        SEMESTRE="${SEMESTRE// /}"
    fi
done < "$INPUT"

# ── Validation Classe ───────────────────────────────────────────
if [ -z "$CLASSE" ]; then
    echo "❌ Champ 'Classe' vide ou manquant dans new_list.txt"
    exit 1
fi

VALID_CLASS=$(jq -r --arg id "$CLASSE" '.classes[] | select(.id == $id) | .id' "$INDEX")
if [ -z "$VALID_CLASS" ]; then
    echo "❌ Classe '$CLASSE' inconnue. Classes disponibles :"
    jq -r '.classes[] | "   - " + .id + " (" + .label + ")"' "$INDEX"
    exit 1
fi

# ── Validation Semestre ─────────────────────────────────────────
if [ -z "$SEMESTRE" ] || ! [[ "$SEMESTRE" =~ ^[0-9]+$ ]]; then
    echo "❌ Champ 'Semestre' vide ou invalide dans new_list.txt (ex: 1 ou 2)"
    exit 1
fi

SEM_KEY="Semestre $SEMESTRE"
JSON_FILE="$CONFIG_DIR/${CLASSE}.json"

if [ ! -f "$JSON_FILE" ]; then
    echo "❌ Fichier JSON introuvable : $JSON_FILE"
    exit 1
fi

# ── Collecte et validation des matières ────────────────────────
declare -a TITRES=()
declare -a IDS=()
LINE_NUM=0
DRIVE_REGEX='^[A-Za-z0-9_-]{25,50}$'

while IFS= read -r line || [ -n "$line" ]; do
    LINE_NUM=$((LINE_NUM + 1))
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// }" ]] && continue
    [[ "$line" =~ ^[Cc]lasse[[:space:]]*: ]] && continue
    [[ "$line" =~ ^[Ss]emestre[[:space:]]*: ]] && continue

    if [[ "$line" != *:* ]]; then
        echo "⚠️  Ligne $LINE_NUM ignorée (format invalide, ':' manquant) : '$line'"
        continue
    fi

    NOM="${line%%:*}"
    ID="${line#*:}"

    NOM="${NOM#"${NOM%%[![:space:]]*}"}"
    NOM="${NOM%"${NOM##*[![:space:]]}"}"
    ID="${ID#"${ID%%[![:space:]]*}"}"
    ID="${ID%"${ID##*[![:space:]]}"}"

    [ -z "$NOM" ] && continue

    if ! [[ "$ID" =~ $DRIVE_REGEX ]]; then
        echo ""
        echo "❌ Drive ID invalide à la ligne $LINE_NUM :"
        echo "   Ligne   : $line"
        echo "   ID reçu : '$ID'"
        echo ""
        echo "   Format attendu : 25 à 50 caractères"
        echo "   Caractères autorisés : lettres, chiffres, '-', '_'"
        echo "   Exemple valide      : 1JQEVcD2PcE8P7UBIO85Oa0RBGD-K8ztF"
        echo ""
        echo "⚠️  Corrige new_list.txt puis relance le script."
        exit 1
    fi

    TITRES+=("$NOM")
    IDS+=("$ID")
done < "$INPUT"

COUNT=${#TITRES[@]}
if [ "$COUNT" -eq 0 ]; then
    echo "⚠️  Aucune matière trouvée dans new_list.txt"
    exit 1
fi

# ── Aperçu avec détection nouvelle / mise à jour ───────────────
echo ""
echo "📂 Classe   : $CLASSE"
echo "📅 Semestre : $SEM_KEY"
echo "📋 $COUNT matière(s) à traiter :"
for i in "${!TITRES[@]}"; do
    TITLE_FORMATTED=$(to_title_case "${TITRES[$i]}")
    EXISTS=$(jq -r --arg sem "$SEM_KEY" --arg title "$TITLE_FORMATTED" \
        'if has($sem) then ([.[$sem][] | select(.title == $title)] | length > 0) else false end' \
        "$JSON_FILE")
    if [ "$EXISTS" = "true" ]; then
        echo "   ~ MAJ      : $TITLE_FORMATTED → ${IDS[$i]}"
    else
        echo "   + Nouveau  : $TITLE_FORMATTED → ${IDS[$i]}"
    fi
done
echo ""

# ── Injection dans le fichier JSON (upsert) ────────────────────
TEMP_JSON=$(mktemp)
cp "$JSON_FILE" "$TEMP_JSON"

NB_AJOUTES=0
NB_MAJ=0

for i in "${!TITRES[@]}"; do
    TITLE_FORMATTED=$(to_title_case "${TITRES[$i]}")
    DRIVE_ID="${IDS[$i]}"

    SEM_EXISTS=$(jq -r --arg sem "$SEM_KEY" 'has($sem)' "$TEMP_JSON")

    if [ "$SEM_EXISTS" = "false" ]; then
        jq --arg sem "$SEM_KEY" --arg title "$TITLE_FORMATTED" --arg id "$DRIVE_ID" \
            '. + {($sem): [{"title": $title, "drive_id": $id}]}' \
            "$TEMP_JSON" > "${TEMP_JSON}.tmp" && mv "${TEMP_JSON}.tmp" "$TEMP_JSON"
        NB_AJOUTES=$((NB_AJOUTES + 1))
    else
        TITLE_EXISTS=$(jq -r --arg sem "$SEM_KEY" --arg title "$TITLE_FORMATTED" \
            '[.[$sem][] | select(.title == $title)] | length > 0' "$TEMP_JSON")

        if [ "$TITLE_EXISTS" = "true" ]; then
            jq --arg sem "$SEM_KEY" --arg title "$TITLE_FORMATTED" --arg id "$DRIVE_ID" \
                '.[$sem] |= map(if .title == $title then .drive_id = $id else . end)' \
                "$TEMP_JSON" > "${TEMP_JSON}.tmp" && mv "${TEMP_JSON}.tmp" "$TEMP_JSON"
            NB_MAJ=$((NB_MAJ + 1))
        else
            jq --arg sem "$SEM_KEY" --arg title "$TITLE_FORMATTED" --arg id "$DRIVE_ID" \
                '.[$sem] += [{"title": $title, "drive_id": $id}]' \
                "$TEMP_JSON" > "${TEMP_JSON}.tmp" && mv "${TEMP_JSON}.tmp" "$TEMP_JSON"
            NB_AJOUTES=$((NB_AJOUTES + 1))
        fi
    fi
done

mv "$TEMP_JSON" "$JSON_FILE"

echo "✅ Terminé dans config/${CLASSE}.json → $SEM_KEY"
[ "$NB_AJOUTES" -gt 0 ] && echo "   + $NB_AJOUTES nouvelle(s) matière(s) ajoutée(s)"
[ "$NB_MAJ" -gt 0 ]     && echo "   ~ $NB_MAJ matière(s) mise(s) à jour (ID remplacé)"
echo ""
echo "📝 N'oublie pas :"
echo "   git add config/${CLASSE}.json && git commit -m 'Update matières ${CLASSE} ${SEM_KEY}' && git push"

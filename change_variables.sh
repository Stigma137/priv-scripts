FILE="Deploy_Resources/variables.yaml"

OLD_VAR="current_variable"
NEW_VAR="new_variable"
DELETE_VAR="obsolete_variable"

sed -i "/name:[[:space:]]*$OLD_VAR$/s/$OLD_VAR/$NEW_VAR/" "$FILE"
sed -i "/name:[[:space:]]*$DELETE_VAR$/{N;N;d;}" "$FILE"


FILE="Deploy_Resources/variables.yaml"

# Rename variable
sed -i 's/^\([[:space:]]*-[[:space:]]*name:[[:space:]]*\)current_name$/\1new_name/' "$FILE"

# Delete variable block
sed -i '/^[[:space:]]*-[[:space:]]*name:[[:space:]]*obsolete_var$/{N;N;d;}' "$FILE"
#!/bin/bash
set -e

ORG="your-org"
PROJECT="your-project"
PAT="$AZURE_DEVOPS_PAT"

OLD_VAR_TO_DELETE="old_variable_name"
OLD_VAR_TO_RENAME="current_name"
NEW_VAR_NAME="new_name"

WORKDIR=$(mktemp -d)
cd "$WORKDIR"

# Get all repos in the project
repos=$(az repos list \
  --organization "https://dev.azure.com/$ORG" \
  --project "$PROJECT" \
  --query "[].name" -o tsv)

for repo in $repos; do
  echo "Processing repo: $repo"

  git clone "https://$PAT@dev.azure.com/$ORG/$PROJECT/_git/$repo"
  cd "$repo"

  git checkout develop || {
    echo "develop branch not found in $repo"
    cd ..
    rm -rf "$repo"
    continue
  }

  FILE="Deploy_Resources/variables.yaml"

  if [ ! -f "$FILE" ]; then
    echo "variables.yaml not found in $repo"
    cd ..
    rm -rf "$repo"
    continue
  fi

  # Delete variable block
  sed -i "/- name: \"$OLD_VAR_TO_DELETE\"/{N;d;}" "$FILE"

  # Rename variable
  sed -i "s/- name: \"$OLD_VAR_TO_RENAME\"/- name: \"$NEW_VAR_NAME\"/g" "$FILE"

  if git diff --quiet; then
    echo "No changes in $repo"
  else
    git add "$FILE"
    git commit -m "Update variables.yaml"
    git push origin develop
    echo "Updated $repo"
  fi

  cd ..
  rm -rf "$repo"
done

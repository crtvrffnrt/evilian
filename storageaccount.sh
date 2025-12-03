#!/usr/bin/env bash
set -euo pipefail

# Check for AZ
command -v az >/dev/null 2>&1 || { echo "Azure CLI not found."; exit 1; }

# Quick intro for users
print_intro() {
    cat <<'EOF'
----------------------------------------
Static Website Uploader (Azure Blob $web)
----------------------------------------
1) Place index.html and any .png/.svg images in this folder before running.
2) Pick your resource group; the script will ask for a storage account name.
3) It creates the storage account, enables static website hosting, and uploads your files.
EOF
    echo
}

print_intro
sleep 4
# Function for resource group selection
select_rg() {
    local rgs
    mapfile -t rgs < <(az group list --query "[].name" -o tsv)

    if command -v fzf >/dev/null 2>&1; then
        printf "%s\n" "${rgs[@]}" | fzf --prompt="Select Resource Group: "
        return
    fi

    echo "Select Resource Group:"
    select rg in "${rgs[@]}"; do
        echo "$rg"
        return
    done
}

RESOURCE_GROUP=$(select_rg)
[ -z "$RESOURCE_GROUP" ] && { echo "No resource group selected."; exit 1; }

read -rp "Enter new storage account name: " SA_NAME
[ -z "$SA_NAME" ] && { echo "Invalid storage account name"; exit 1; }

LOCATION=$(az group show -n "$RESOURCE_GROUP" --query "location" -o tsv)

echo "Creating Storage Account '$SA_NAME' in '$RESOURCE_GROUP' ($LOCATION)..."

# Create storage account
az storage account create \
    --name "$SA_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --sku Standard_LRS \
    --kind StorageV2 \
    --https-only true \
    --enable-large-file-share \
    --access-tier Hot \
    --allow-blob-public-access true \
    --min-tls-version TLS1_2 \
    --public-network-access Enabled

echo "Storage account created."

# Enable static website hosting
echo "Enabling static website hosting..."
az storage blob service-properties update \
    --account-name "$SA_NAME" \
    --static-website \
    --index-document index.html \
    --404-document index.html \
    >/dev/null

echo "Static website enabled."

# Ensure $web container is publicly accessible
echo "Setting public access on static website container..."
az storage container set-permission \
    --name '$web' \
    --account-name "$SA_NAME" \
    --public-access container \
    --auth-mode key \
    >/dev/null

# ------------------------------------------------------------------------------------------------
# Upload index.html only if present
# ------------------------------------------------------------------------------------------------
SCRIPT_DIR=$(dirname "$0")
INDEX_FILE="$SCRIPT_DIR/index.html"
TARGET_PREFIX="default/uploads/files"

# Create the nested virtual folder structure with a placeholder blob
PLACEHOLDER=$(mktemp)
trap 'rm -f "$PLACEHOLDER"' EXIT
: > "$PLACEHOLDER"
az storage blob upload \
    --account-name "$SA_NAME" \
    --container-name '$web' \
    --name "$TARGET_PREFIX/.keep" \
    --file "$PLACEHOLDER" \
    --auth-mode key \
    --only-show-errors \
    --overwrite \
    >/dev/null

if [ -f "$INDEX_FILE" ]; then
    echo "index.html found. Uploading to static website path '$TARGET_PREFIX'..."

    az storage blob upload \
        --account-name "$SA_NAME" \
        --container-name '$web' \
        --name "$TARGET_PREFIX/index.html" \
        --file "$INDEX_FILE" \
        --auth-mode key \
        --only-show-errors \
        --overwrite \
    >/dev/null

    echo "index.html uploaded successfully."
else
    echo "WARNING: index.html not found in script directory."
    echo "Static site is enabled, but no file was uploaded."
fi

# ------------------------------------------------------------------------------------------------
# Upload image assets (.png, .svg) from script directory
# ------------------------------------------------------------------------------------------------
mapfile -t IMAGE_FILES < <(find "$SCRIPT_DIR" -maxdepth 1 -type f \( -iname "*.png" -o -iname "*.svg" \))

if [ "${#IMAGE_FILES[@]}" -gt 0 ]; then
    echo "Uploading image assets to '$TARGET_PREFIX'..."
    for img in "${IMAGE_FILES[@]}"; do
        blob_name=$(basename "$img")
        az storage blob upload \
            --account-name "$SA_NAME" \
            --container-name '$web' \
            --name "$TARGET_PREFIX/$blob_name" \
            --file "$img" \
            --auth-mode key \
            --only-show-errors \
            --overwrite \
            >/dev/null
        echo "Uploaded: $TARGET_PREFIX/$blob_name"
    done
    echo "Image assets uploaded successfully."
else
    echo "No .png or .svg files found beside the script. Skipping image upload."
fi

# ------------------------------------------------------------------------------------------------
# Display endpoint
# ------------------------------------------------------------------------------------------------
ENDPOINT=$(az storage account show \
    --name "$SA_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --query "primaryEndpoints.web" \
    -o tsv)
FINAL_INDEX_URL="${ENDPOINT%/}/$TARGET_PREFIX/index.html"

echo
echo "Static website endpoint:"
echo "$ENDPOINT"
echo
echo -e "\033[1;97;44m Final Result \033[0m"
echo -e "\033[1;32mYour static site is live at:\033[0m"
echo -e "\033[1;33m$FINAL_INDEX_URL\033[0m"
echo
echo -e "\033[1;97;44m Static website created successfully! \033[0m"

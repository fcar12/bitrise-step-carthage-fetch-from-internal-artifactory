#!/usr/bin/env bash
#!/usr/bin/env bash
# fail if any commands fails
set -e
# debug log
set -x


if [[ "$BITRISE_CACHE_HIT" == "exact" || "$BITRISE_CACHE_HIT" == "partial" ]]; then
  echo "✅ Carthage cache found ('$BITRISE_CACHE_HIT'), skipping build of NS SDK"
  exit 0
else
  echo "⚠️ Carthage cache result: '$BITRISE_CACHE_HIT'"
fi

# Client certificate auth (mTLS)
# If provided, both client_cert and client_key must be set. They can be paths to PEM files
# or inline PEM contents. If inline content is provided, the script writes them to temp files.
USE_CERT_AUTH=false
CERT_TEMP_FILES=()
cleanup_certs() {
  for f in "${CERT_TEMP_FILES[@]}"; do
    if [ -n "$f" ] && [ -f "$f" ]; then
      rm -f "$f"
    fi
  done
}
trap cleanup_certs EXIT

if [ -n "$client_cert" ] || [ -n "$client_key" ]; then
  if [ -z "$client_cert" ] || [ -z "$client_key" ]; then
    echo "- If using client_cert/client_key both must be provided"
    INVALID_INPUT=true
  else
    # helper to ensure value is a file; if not, write to temp file
    mktemp_and_maybe_write() {
      local val="$1"
      if [ -f "$val" ]; then
        echo "$val"
        return 0
      fi
      local tmp
      tmp="$(mktemp)" || return 1
      echo "$val" > "$tmp"
      echo "$tmp"
    }

    CERT_FILE_PATH="$(mktemp_and_maybe_write "$client_cert")" || CERT_FILE_PATH=""
    KEY_FILE_PATH="$(mktemp_and_maybe_write "$client_key")" || KEY_FILE_PATH=""

    if [ -z "$CERT_FILE_PATH" ] || [ -z "$KEY_FILE_PATH" ]; then
      echo "- Unable to prepare client_cert/client_key files"
      INVALID_INPUT=true
    else
      # if mktemp_and_maybe_write produced temp files (not original paths), remember to cleanup
      if [ ! -f "$client_cert" ]; then CERT_TEMP_FILES+=("$CERT_FILE_PATH"); fi
      if [ ! -f "$client_key" ]; then CERT_TEMP_FILES+=("$KEY_FILE_PATH"); fi
      USE_CERT_AUTH=true
    fi
  fi
fi

CARTHAGE_BUILD_DIR="Carthage/Build"
CARTFILE_PATH="Cartfile"
TMP_DIR="./carthage-manual-binaries"
mkdir -p "$TMP_DIR" "$CARTHAGE_BUILD_DIR"
mkdir -p "$CARTHAGE_BUILD_DIR"
 
# Ensure .netrc is properly configured
NETRC_PATH="$HOME/.netrc"
if [ ! -f "$NETRC_PATH" ]; then
  echo "❌ .netrc file not found. Please create it with the correct credentials."
  exit 1
fi
 
echo "Parsing Cartfile for binary frameworks and versions..."
 
# Backup Cartfile
cp "$CARTFILE_PATH" "${CARTFILE_PATH}.bak"
 
# Read Cartfile lines
while IFS= read -r line; do
  if [[ "$line" == binary\ * ]]; then
    echo "Processing binary line: $line"
     
    # Extract URL and version
    URL=$(echo "$line" | cut -d '"' -f2)
    VERSION=$(echo "$line" | grep -o '==.*' | sed 's/== *//')
     
    FRAMEWORK_NAME=$(basename "$URL" .json)
    JSON_PATH="$TMP_DIR/$FRAMEWORK_NAME.json"
 
    echo "⬇️ Downloading JSON for $FRAMEWORK_NAME..."
    curl -v -n -fsSL --cert "$CERT_FILE_PATH" --key "$KEY_FILE_PATH" "$URL" -o "$JSON_PATH"
 
    echo "📦 Extracting URL for version $VERSION..."
    ZIP_URL=$(jq -r --arg VERSION "$VERSION" '.[$VERSION]' "$JSON_PATH")
 
    if [[ "$ZIP_URL" == "null" || -z "$ZIP_URL" ]]; then
      echo "❌ No zip URL found for version $VERSION in $FRAMEWORK_NAME.json"
      exit 1
    fi
 
    ZIP_NAME=$(basename "$ZIP_URL")
    ZIP_PATH="$TMP_DIR/$ZIP_NAME"
    CARTHAGE_CACHE_DIR="Carthage/Cache"
 
    echo "⬇️  Downloading framework zip: $ZIP_URL"
    curl -v -n -fsSL --cert "$CERT_FILE_PATH" --key "$KEY_FILE_PATH" "$ZIP_URL" -o "$ZIP_PATH"
 
    mkdir -p "$CARTHAGE_CACHE_DIR"
 
    CACHED_JSON_PATH="$CARTHAGE_CACHE_DIR/$FRAMEWORK_NAME-$VERSION.json"
    CACHED_ZIP_PATH="$CARTHAGE_CACHE_DIR/$FRAMEWORK_NAME-$VERSION.zip"
 
    # Copy json and zip to Carthage Cache
    cp "$JSON_PATH" "$CACHED_JSON_PATH"
    cp "$ZIP_PATH" "$CACHED_ZIP_PATH"
 
    echo "📦 Extracting $ZIP_NAME to Carthage/Build"
    unzip -q -o "$ZIP_PATH" -d "$CARTHAGE_BUILD_DIR"
 
    echo "Commenting out binary line in Cartfile"
    escaped_url=$(echo "$URL" | sed 's/[^^]/[&]/g; s/\^/\\^/g')
    sed -i '' "s|^binary \"$escaped_url\".*|# &|" "$CARTFILE_PATH"
  fi
done < "$CARTFILE_PATH"
 
echo "Cleaning up..."
rm -f Cartfile.resolved
rm -f "$TMP_DIR"/*.json "$TMP_DIR"/*.zip
 
echo "✅ All binary frameworks downloaded and installed."
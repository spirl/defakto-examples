#!/bin/bash
set -euo pipefail

# Convert PEM certificate to SPIFFE bundle format (JWK Set)
# Requires: openssl, jq, base64, xxd
# 
# Usage: ./pem-to-spiffe-bundle.sh <cert-file> [options]

# Default values
OUTPUT_FILE="bundle.json"
SEQUENCE=""
REFRESH_HINT=""
USE="x509-svid"

# Parse arguments
POSITIONAL_ARGS=()
while [[ $# -gt 0 ]]; do
  case $1 in
    -o|--output)
      OUTPUT_FILE="$2"
      shift 2
      ;;
    -s|--sequence)
      SEQUENCE="$2"
      shift 2
      ;;
    -r|--refresh-hint)
      REFRESH_HINT="$2"
      shift 2
      ;;
    --use)
      USE="$2"
      shift 2
      ;;
    -h|--help)
      cat <<EOF
Usage: $0 <cert-file> [options]

Convert PEM certificate to SPIFFE bundle format (JWK Set)

Options:
  -o, --output FILE       Output file (default: bundle.json)
  -s, --sequence NUM      Sequence number (monotonically increasing)
  -r, --refresh-hint NUM  Refresh hint in seconds
  --use TYPE             Key use: x509-svid (default) or jwt-svid
  -h, --help             Show this help

Examples:
  $0 ca.crt -o bundle.json
  $0 ca.crt --sequence 1 --refresh-hint 86400
  $0 ca.crt -s 1 -r 3600 -o bundle.json

Requires: openssl, jq, base64, xxd
EOF
      exit 0
      ;;
    *)
      POSITIONAL_ARGS+=("$1")
      shift
      ;;
  esac
done

# Restore positional parameters
set -- "${POSITIONAL_ARGS[@]}"

if [[ $# -eq 0 ]]; then
  echo "Error: No certificate file specified" >&2
  echo "Usage: $0 <cert-file> [options]" >&2
  echo "Run '$0 --help' for more information" >&2
  exit 1
fi

CERT_FILE="$1"

if [[ ! -f "$CERT_FILE" ]]; then
  echo "Error: Certificate file '$CERT_FILE' not found" >&2
  exit 1
fi

# Check for required tools
for cmd in openssl jq base64 xxd; do
  if ! command -v "$cmd" &> /dev/null; then
    echo "Error: Required command '$cmd' not found" >&2
    exit 1
  fi
done

echo "Converting certificate: $CERT_FILE"

# Convert PEM to DER and base64 encode for x5c
X5C=$(openssl x509 -in "$CERT_FILE" -outform DER | base64)

# Determine key type
KEY_TYPE=$(openssl x509 -in "$CERT_FILE" -noout -text | grep "Public Key Algorithm:" | awk '{print $4}')

# Function to convert hex to base64url (no padding)
hex_to_base64url() {
  local hex="$1"
  # Remove colons and convert to binary, then base64url encode
  echo "$hex" | xxd -r -p | base64 | tr '+/' '-_' | tr -d '='
}

# Function to get RSA exponent in base64url
get_rsa_exponent() {
  local cert="$1"
  # Get exponent in decimal, convert to hex, then to base64url
  local exp_dec=$(openssl x509 -in "$cert" -noout -text | grep "Exponent:" | awk '{print $2}' | tr -d '()')
  
  # Common exponents
  if [[ "$exp_dec" == "65537" ]]; then
    # 65537 = 0x010001 in hex
    echo "AQAB"  # This is the standard base64url for 65537
  else
    # Convert decimal to hex to bytes to base64url
    printf "%x" "$exp_dec" | xxd -r -p | base64 | tr '+/' '-_' | tr -d '='
  fi
}

# Build JWK based on key type
if [[ "$KEY_TYPE" == "rsaEncryption" ]]; then
  echo "  Key type: RSA"
  
  # Get modulus (remove spaces and colons)
  MODULUS=$(openssl x509 -in "$CERT_FILE" -noout -modulus | cut -d'=' -f2)
  MODULUS_B64=$(hex_to_base64url "$MODULUS")
  
  # Get exponent
  EXPONENT_B64=$(get_rsa_exponent "$CERT_FILE")
  
  # Build JWK
  JWK=$(jq -n \
    --arg use "$USE" \
    --arg kty "RSA" \
    --arg n "$MODULUS_B64" \
    --arg e "$EXPONENT_B64" \
    --arg x5c "$X5C" \
    '{
      use: $use,
      kty: $kty,
      n: $n,
      e: $e,
      x5c: [$x5c]
    }')
    
elif [[ "$KEY_TYPE" == "id-ecPublicKey" ]]; then
  echo "  Key type: EC"
  
  # Get curve name
  CURVE=$(openssl x509 -in "$CERT_FILE" -noout -text | grep "ASN1 OID:" | awk '{print $3}')
  
  # Map OpenSSL curve names to JWK crv values
  case "$CURVE" in
    "prime256v1" | "secp256r1")
      CRV="P-256"
      ;;
    "secp384r1")
      CRV="P-384"
      ;;
    "secp521r1")
      CRV="P-521"
      ;;
    *)
      echo "Error: Unsupported EC curve: $CURVE" >&2
      exit 1
      ;;
  esac
  
  # Extract EC public key coordinates
  # This is complex - we'll extract the public key and parse the DER format
  PUB_KEY_HEX=$(openssl x509 -in "$CERT_FILE" -noout -pubkey | \
    openssl ec -pubin -text -noout 2>/dev/null | \
    grep -A 100 "pub:" | tail -n +2 | tr -d ' :\n' | head -c -2)
  
  # EC public key is 0x04 + X + Y (uncompressed format)
  # Remove the 0x04 prefix
  PUB_KEY_HEX=${PUB_KEY_HEX:2}
  
  # Split into X and Y (equal length)
  COORD_LEN=$((${#PUB_KEY_HEX} / 2))
  X_HEX=${PUB_KEY_HEX:0:$COORD_LEN}
  Y_HEX=${PUB_KEY_HEX:$COORD_LEN}
  
  X_B64=$(hex_to_base64url "$X_HEX")
  Y_B64=$(hex_to_base64url "$Y_HEX")
  
  # Build JWK
  JWK=$(jq -n \
    --arg use "$USE" \
    --arg kty "EC" \
    --arg crv "$CRV" \
    --arg x "$X_B64" \
    --arg y "$Y_B64" \
    --arg x5c "$X5C" \
    '{
      use: $use,
      kty: $kty,
      crv: $crv,
      x: $x,
      y: $y,
      x5c: [$x5c]
    }')
else
  echo "Error: Unsupported key type: $KEY_TYPE" >&2
  exit 1
fi

# Build the bundle
BUNDLE=$(echo "$JWK" | jq -s '{keys: .}')

# Add optional fields
if [[ -n "$SEQUENCE" ]]; then
  BUNDLE=$(echo "$BUNDLE" | jq --argjson seq "$SEQUENCE" '. + {spiffe_sequence: $seq}')
fi

if [[ -n "$REFRESH_HINT" ]]; then
  BUNDLE=$(echo "$BUNDLE" | jq --argjson hint "$REFRESH_HINT" '. + {spiffe_refresh_hint: $hint}')
fi

# Write output
echo "$BUNDLE" > "$OUTPUT_FILE"

echo ""
echo "✓ SPIFFE bundle (JWK Set) created: $OUTPUT_FILE"
echo "  Certificates: 1"
[[ -n "$SEQUENCE" ]] && echo "  Sequence: $SEQUENCE"
[[ -n "$REFRESH_HINT" ]] && echo "  Refresh hint: ${REFRESH_HINT}s ($((REFRESH_HINT / 3600))h)"

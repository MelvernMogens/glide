#!/bin/bash
# One-time: create a self-signed code-signing identity in its own keychain (~/.glide-signing).
# A stable signing identity keeps macOS privacy grants (Accessibility) across rebuilds.
set -euo pipefail
D="$HOME/.glide-signing"; mkdir -p "$D"; cd "$D"
[ -f pass ] || openssl rand -hex 16 > pass
PW=$(cat pass)
cat > cert.cnf <<'EOF'
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=Glide Local Signing
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -config cert.cnf 2>/dev/null
LEGACY=$(openssl pkcs12 -help 2>&1 | grep -q -- "-legacy" && echo -legacy || true)
openssl pkcs12 -export $LEGACY -inkey key.pem -in cert.pem -out id.p12 -passout pass:"$PW" -name "Glide Local Signing"
KC="$D/glide.keychain-db"
[ -f "$KC" ] || security create-keychain -p "$PW" "$KC"
security unlock-keychain -p "$PW" "$KC"; security set-keychain-settings "$KC"
security import id.p12 -k "$KC" -P "$PW" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KC" >/dev/null
security list-keychains -d user -s $(security list-keychains -d user | tr -d '"') "$KC"
rm -f key.pem
security find-identity -p codesigning "$KC"

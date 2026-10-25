#!/bin/sh
# Creates a self-signed "NativeShot Local Dev" code-signing identity in the login keychain.
# Builds signed with it keep a stable designated requirement, so macOS keeps the Screen Recording,
# microphone, camera and Accessibility permissions across rebuilds. Remove it any time from Keychain Access.
set -e
NAME="NativeShot Local Dev"
if security find-identity -p codesigning | grep -q "$NAME"; then echo "$NAME already exists"; exit 0; fi
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
cat > "$D/cfg.cnf" <<CNF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$D/key.pem" -out "$D/cert.pem" -days 3650 -config "$D/cfg.cnf" 2>/dev/null
PW="tmp$$"
openssl pkcs12 -export -inkey "$D/key.pem" -in "$D/cert.pem" -out "$D/id.p12" -passout "pass:$PW" -name "$NAME" -legacy 2>/dev/null \
  || openssl pkcs12 -export -inkey "$D/key.pem" -in "$D/cert.pem" -out "$D/id.p12" -passout "pass:$PW" -name "$NAME"
security import "$D/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PW" -T /usr/bin/codesign
echo "Created $NAME"

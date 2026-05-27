#!/usr/bin/env python3
"""
Issue a dummy Verifiable Credential from a LOCAL Inji Certify, using the
Pre-Authorized Code flow with Certify acting as its own OAuth authorization
server (NO eSignet, NO wallet app).

Flow (all against http://localhost:8090/v1/certify):
  1. POST /pre-authorized-data        -> credential offer (+ tx_code)
  2. GET  /credential-offer-data/{id} -> pre-authorized_code
  3. POST /oauth/token                -> access_token + c_nonce
  4. POST /issuance/credential        -> signed VC

Only stdlib + `cryptography` are required.
"""
import json
import base64
import time
import urllib.request
import urllib.parse

from cryptography.hazmat.primitives.asymmetric import rsa, padding
from cryptography.hazmat.primitives import hashes, serialization

BASE = "http://localhost:8090/v1/certify"
AUD = "http://localhost:8090"          # must match issuer identifier / domain.url
CREDENTIAL_CONFIG_ID = "FarmerCredential"
TX_CODE = "12345"

# These keys must match the credential's allowed `credential_subject` keys
# (see certify_init.sql) AND the ${...} placeholders in the VC template.
CLAIMS = {
    "fullName": "Jane Thompson",
    "mobileNumber": "7550166914",
    "dateOfBirth": "1998-01-24",
    "gender": "Female",
    "state": "Karnataka",
    "district": "Bangalore",
    "villageOrTown": "Koramangala",
    "postalCode": "560068",
    "landArea": "5 acres",
    "landOwnershipType": "Self-owned",
    "primaryCropType": "Cotton",
    "secondaryCropType": "Barley",
    "farmerID": "4567538771",
    "face": "",
}


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def http(method, url, body=None, headers=None, form=False):
    data = None
    hdrs = headers or {}
    if body is not None:
        if form:
            data = urllib.parse.urlencode(body).encode()
            hdrs["Content-Type"] = "application/x-www-form-urlencoded"
        else:
            data = json.dumps(body).encode()
            hdrs["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=hdrs, method=method)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, json.loads(r.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        return e.code, {"error_body": e.read().decode()}


def make_proof_jwt(priv, pub, nonce):
    pn = pub.public_numbers()
    n = pn.n.to_bytes((pn.n.bit_length() + 7) // 8, "big")
    e = pn.e.to_bytes((pn.e.bit_length() + 7) // 8, "big")
    jwk = {"kty": "RSA", "n": b64url(n), "e": b64url(e), "alg": "RS256", "use": "sig"}
    header = {"alg": "RS256", "typ": "openid4vci-proof+jwt", "jwk": jwk}
    payload = {"aud": AUD, "nonce": nonce, "iss": "", "iat": int(time.time())}
    signing_input = (b64url(json.dumps(header).encode()) + "." +
                     b64url(json.dumps(payload).encode())).encode()
    sig = priv.sign(signing_input, padding.PKCS1v15(), hashes.SHA256())
    return signing_input.decode() + "." + b64url(sig)


def main():
    print("STEP 1: generate pre-authorized code + credential offer")
    s, r = http("POST", f"{BASE}/pre-authorized-data", {
        "credential_configuration_id": CREDENTIAL_CONFIG_ID,
        "claims": CLAIMS,
        "expires_in": 600,
        "tx_code": TX_CODE,
    })
    print(s, json.dumps(r, indent=2)[:600])
    offer_uri = r["credential_offer_uri"]
    offer_id = urllib.parse.unquote(offer_uri).rstrip("/").split("/")[-1]
    print("offer_id =", offer_id)

    print("\nSTEP 2: fetch credential offer -> pre-authorized_code")
    s, r = http("GET", f"{BASE}/credential-offer-data/{offer_id}")
    print(s, json.dumps(r, indent=2)[:600])
    grant = r["grants"]["urn:ietf:params:oauth:grant-type:pre-authorized_code"]
    pre_auth_code = grant["pre-authorized_code"]

    print("\nSTEP 3: exchange code for access token")
    s, r = http("POST", f"{BASE}/oauth/token", {
        "grant_type": "urn:ietf:params:oauth:grant-type:pre-authorized_code",
        "pre-authorized_code": pre_auth_code,
        "tx_code": TX_CODE,
    }, form=True)
    print(s, json.dumps(r, indent=2)[:400])
    access_token = r["access_token"]
    c_nonce = r.get("c_nonce", "")

    print("\nSTEP 4: request credential with proof-of-possession JWT")
    priv = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    proof = make_proof_jwt(priv, priv.public_key(), c_nonce)
    s, r = http("POST", f"{BASE}/issuance/credential", {
        "format": "ldp_vc",
        "credential_definition": {
            "@context": ["https://www.w3.org/2018/credentials/v1"],
            "type": ["VerifiableCredential", "FarmerCredential"],
        },
        "proof": {"proof_type": "jwt", "jwt": proof},
    }, headers={"Authorization": f"Bearer {access_token}"})
    print("HTTP", s)
    print(json.dumps(r, indent=2))


if __name__ == "__main__":
    main()

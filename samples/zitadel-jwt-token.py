#!/usr/bin/env python3
"""
Generate a JWT access token from a Zitadel key JSON file.
Supports both Service Account keys and Application (API) keys.

Prerequisites:
    pip install pyjwt cryptography requests

Usage:
    # Get token
    python zitadel-jwt-token.py --key /path/to/key.json

    # Use with curl
    curl https://fission.gsingh.io/hello \
      -H "Authorization: Bearer $(python zitadel-jwt-token.py --key /path/to/key.json)"

    # Custom issuer
    python zitadel-jwt-token.py --key /path/to/key.json --issuer https://auth.gsingh.io

Supported key JSON formats:

    Service Account key (Users → Service Accounts → Keys → Add Key):
    {
        "type": "serviceaccount",
        "keyId": "123456",
        "key": "-----BEGIN RSA PRIVATE KEY-----\\n...\\n-----END RSA PRIVATE KEY-----\\n",
        "userId": "789012"
    }

    Application key (Projects → App → Keys → Add Key):
    {
        "type": "application",
        "keyId": "123456",
        "key": "-----BEGIN RSA PRIVATE KEY-----\\n...\\n-----END RSA PRIVATE KEY-----\\n",
        "appId": "789012",
        "clientId": "789012@project-name"
    }
"""

import argparse
import json
import sys
import time

import jwt
import requests


def load_key_file(path: str) -> dict:
    """Load and parse the Zitadel key JSON file."""
    with open(path) as f:
        return json.load(f)


def get_subject(key_data: dict) -> str:
    """Extract the subject (issuer/sub) from key data based on key type."""
    key_type = key_data.get("type", "").lower()

    if key_type == "application":
        if "clientId" not in key_data:
            print("Error: Application key missing 'clientId' field", file=sys.stderr)
            sys.exit(1)
        return key_data["clientId"]
    elif key_type == "serviceaccount":
        if "userId" not in key_data:
            print("Error: Service account key missing 'userId' field", file=sys.stderr)
            sys.exit(1)
        return key_data["userId"]
    else:
        if "clientId" in key_data:
            return key_data["clientId"]
        elif "userId" in key_data:
            return key_data["userId"]
        else:
            print(
                f"Error: Unknown key type '{key_type}' and cannot auto-detect. "
                "Expected 'serviceaccount' or 'application'",
                file=sys.stderr,
            )
            sys.exit(1)


def create_signed_jwt(key_data: dict, issuer: str) -> str:
    """Create a signed JWT assertion for Zitadel token exchange."""
    now = int(time.time())
    subject = get_subject(key_data)

    payload = {
        "iss": subject,
        "sub": subject,
        "aud": issuer,
        "iat": now,
        "exp": now + 3600,
    }

    headers = {
        "kid": key_data["keyId"],
    }

    return jwt.encode(
        payload,
        key_data["key"],
        algorithm="RS256",
        headers=headers,
    )


def exchange_for_access_token(
    signed_jwt: str, issuer: str, scopes: str = "openid profile email"
) -> dict:
    """Exchange the signed JWT for an access token from Zitadel."""
    token_url = f"{issuer}/oauth/v2/token"

    response = requests.post(
        token_url,
        data={
            "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
            "assertion": signed_jwt,
            "scope": scopes,
        },
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )

    if response.status_code != 200:
        print(f"Error: {response.status_code}", file=sys.stderr)
        print(response.text, file=sys.stderr)
        sys.exit(1)

    return response.json()


def main():
    parser = argparse.ArgumentParser(
        description="Generate JWT access token from Zitadel key (service account or application)"
    )
    parser.add_argument("--key", required=True, help="Path to Zitadel key JSON file")
    parser.add_argument(
        "--issuer",
        default=None,
        help="Zitadel issuer URL (default: https://auth.gsingh.io)",
    )
    parser.add_argument(
        "--scopes",
        default="openid profile email",
        help="OAuth scopes (default: openid profile email)",
    )
    args = parser.parse_args()

    key_data = load_key_file(args.key)
    issuer = args.issuer or "https://auth.gsingh.io"

    print(f"Key type: {key_data.get('type', 'unknown')}", file=sys.stderr)
    print(f"Subject: {get_subject(key_data)}", file=sys.stderr)

    signed_jwt = create_signed_jwt(key_data, issuer)
    token_response = exchange_for_access_token(signed_jwt, issuer, args.scopes)

    # Print only the access token to stdout for easy piping
    print(token_response["access_token"])


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
Generate a JWT access token from a Zitadel service account key file.

Prerequisites:
    pip install pyjwt cryptography requests

Usage:
    # Get token and print it
    python zitadel-jwt-token.py --key /path/to/key.json

    # Get token and call a fission function
    python zitadel-jwt-token.py --key /path/to/key.json --url https://fission.gsingh.io/hello

    # Custom issuer (if different from key file)
    python zitadel-jwt-token.py --key /path/to/key.json --issuer https://auth.gsingh.io

Key JSON format (downloaded from Zitadel Service Account → Keys → Add Key):
    {
        "type": "serviceaccount",
        "keyId": "123456",
        "key": "-----BEGIN RSA PRIVATE KEY-----\n...\n-----END RSA PRIVATE KEY-----\n",
        "userId": "789012"
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


def create_signed_jwt(key_data: dict, issuer: str) -> str:
    """Create a signed JWT assertion for Zitadel token exchange."""
    now = int(time.time())

    payload = {
        "iss": key_data["userId"],
        "sub": key_data["userId"],
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


def call_function(url: str, token: str) -> None:
    """Call a fission function with the bearer token."""
    response = requests.get(url, headers={"Authorization": f"Bearer {token}"})
    print(f"Status: {response.status_code}")
    print(f"Response: {response.text}")


def main():
    parser = argparse.ArgumentParser(
        description="Generate JWT access token from Zitadel service account key"
    )
    parser.add_argument("--key", required=True, help="Path to Zitadel key JSON file")
    parser.add_argument(
        "--issuer",
        default=None,
        help="Zitadel issuer URL (default: https://auth.gsingh.io)",
    )
    parser.add_argument("--url", default=None, help="URL to call with the token")
    parser.add_argument(
        "--scopes",
        default="openid profile email",
        help="OAuth scopes (default: openid profile email)",
    )
    args = parser.parse_args()

    # Load key file
    key_data = load_key_file(args.key)
    issuer = args.issuer or "https://auth.gsingh.io"

    # Create signed JWT
    signed_jwt = create_signed_jwt(key_data, issuer)

    # Exchange for access token
    token_response = exchange_for_access_token(signed_jwt, issuer, args.scopes)
    access_token = token_response["access_token"]

    if args.url:
        # Call the URL with the token
        call_function(args.url, access_token)
    else:
        # Print token info
        print(f"Access Token: {access_token}")
        print(f"Token Type: {token_response.get('token_type', 'Bearer')}")
        print(f"Expires In: {token_response.get('expires_in', 'unknown')}s")


if __name__ == "__main__":
    main()

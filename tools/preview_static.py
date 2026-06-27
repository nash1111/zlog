#!/usr/bin/env python3
"""Serve a generated zlog output directory for local preview."""

from __future__ import annotations

import argparse
import http.server
import socketserver
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(description="Serve a generated zlog output directory.")
    parser.add_argument("directory", nargs="?", default="public", help="Output directory to serve.")
    parser.add_argument("--host", default="127.0.0.1", help="Host to bind.")
    parser.add_argument("--port", default=8000, type=int, help="Port to bind.")
    args = parser.parse_args()

    directory = Path(args.directory).resolve()
    if not directory.is_dir():
        parser.error(f"{directory} is not a directory")

    handler = lambda *handler_args, **handler_kwargs: http.server.SimpleHTTPRequestHandler(  # noqa: E731
        *handler_args,
        directory=str(directory),
        **handler_kwargs,
    )
    with socketserver.ThreadingTCPServer((args.host, args.port), handler) as server:
        print(f"Serving {directory} at http://{args.host}:{args.port}/")
        server.serve_forever()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

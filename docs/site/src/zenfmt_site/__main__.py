"""Command line for the site assembler."""

from __future__ import annotations

import argparse
import http.server
import mimetypes
import socketserver
import sys
from pathlib import Path

from . import build as build_module
from . import validate


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="zenfmt_site")
    sub = parser.add_subparsers(dest="command", required=True)

    build_cmd = sub.add_parser("build", help="assemble the deployable site")
    build_cmd.add_argument("--root", default=".", type=Path)
    build_cmd.add_argument("--out", required=True, type=Path)
    build_cmd.add_argument("--base", default="/")
    build_cmd.add_argument("--version", required=True)

    check_cmd = sub.add_parser("check", help="validate an assembled site")
    check_cmd.add_argument("--dir", required=True, type=Path)

    serve_cmd = sub.add_parser("serve", help="serve an assembled site locally")
    serve_cmd.add_argument("--dir", required=True, type=Path)
    serve_cmd.add_argument("--port", default=8787, type=int)

    args = parser.parse_args(argv)

    if args.command == "build":
        builder = build_module.build(
            args.root.resolve(),
            args.out.resolve(),
            base=args.base,
            version=args.version,
        )
        print(f"site: {len(builder.written)} files into {args.out}")
        return 0

    if args.command == "check":
        problems = validate.check(args.dir.resolve())
        for problem in problems:
            print(f"site-check: {problem}", file=sys.stderr)
        if problems:
            print(f"site-check: {len(problems)} problem(s)", file=sys.stderr)
            return 1
        print("site-check: no problems found")
        return 0

    return serve(args.dir.resolve(), args.port)


def serve(directory: Path, port: int) -> int:
    # Several platforms do not know this type, and a module served as
    # anything else will not stream-compile.
    mimetypes.add_type("application/wasm", ".wasm")

    class Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *a, **kw):
            super().__init__(*a, directory=str(directory), **kw)

    with socketserver.TCPServer(("127.0.0.1", port), Handler) as httpd:
        print(f"serving {directory} at http://127.0.0.1:{port}/")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            return 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

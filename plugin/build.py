#!/usr/bin/env python3
"""Packs plugin/src/*.luau into Uncreate-roblox.rbxmx: a Script (init.server.luau)
with one ModuleScript child per other module. Drop the .rbxmx into Studio's
Plugins folder. Usage: python3 build.py [output_path]"""
import os
import sys
from xml.sax.saxutils import escape

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "src")
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "Uncreate-roblox.rbxmx")


def item(class_name, name, source, ref, children=""):
    # CDATA cannot contain "]]>"; split it across two sections if present.
    body = source.replace("]]>", "]]]]><![CDATA[>")
    return (
        f'<Item class="{class_name}" referent="RBX{ref}">'
        f"<Properties>"
        f'<string name="Name">{escape(name)}</string>'
        f'<ProtectedString name="Source"><![CDATA[{body}]]></ProtectedString>'
        f"</Properties>{children}</Item>"
    )


def read(name):
    with open(os.path.join(SRC, name), encoding="utf-8") as f:
        return f.read()


modules = sorted(f for f in os.listdir(SRC) if f.endswith(".luau") and not f.startswith("init."))
children = "".join(item("ModuleScript", m[: -len(".luau")], read(m), i + 1) for i, m in enumerate(modules))
xml = '<roblox version="4">' + item("Script", "Uncreate", read("init.server.luau"), 0, children) + "</roblox>"
with open(OUT, "w", encoding="utf-8") as f:
    f.write(xml)
print(f"wrote {OUT} ({len(modules)} modules, {len(xml)} bytes)")

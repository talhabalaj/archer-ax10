#!/usr/bin/env python3
"""Adapt LuCI 21.02 client-rate rendering to stock AX10 iwinfo responses."""
import argparse
import io
from pathlib import Path
import re
import tarfile

VERSION = "1.0-3personal1"
NORMALIZE = """return Promise.all(tasks).then(function(values){return Array.prototype.concat.apply([],values).map(function(st){['rx','tx'].forEach(function(dir){if(st[dir]==null&&typeof st[dir+'_rate']=='number'&&isFinite(st[dir+'_rate']))st[dir]={rate:st[dir+'_rate']};});return st;});});"""


def patch_js(relative, data):
    text = data.decode()
    if relative == "network.js":
        old = "return Promise.all(tasks).then(function(values){return Array.prototype.concat.apply([],values);});"
        new = NORMALIZE
    elif relative == "view/status/include/60_wifi.js":
        old = "wifirate:function(rt){var s='%.1f\\xa0%s, %d\\xa0%s'.format(rt.rate/1000,_('Mbit/s'),rt.mhz,_('MHz')),"
        new = "wifirate:function(rt){if(!rt||typeof rt.rate!='number'||!isFinite(rt.rate))return'?';var s='%.1f\\xa0%s'.format(rt.rate/1000,_('Mbit/s'));if(typeof rt.mhz=='number'&&rt.mhz>0)s+=', %d\\xa0%s'.format(rt.mhz,_('MHz'));var "
    elif relative == "view/network/wireless.js":
        old = "function format_wifirate(rate){var s='%.1f\\xa0%s, %d\\xa0%s'.format(rate.rate/1000,_('Mbit/s'),rate.mhz,_('MHz')),"
        new = "function format_wifirate(rate){if(!rate||typeof rate.rate!='number'||!isFinite(rate.rate))return'?';var s='%.1f\\xa0%s'.format(rate.rate/1000,_('Mbit/s'));if(typeof rate.mhz=='number'&&rate.mhz>0)s+=', %d\\xa0%s'.format(rate.mhz,_('MHz'));var "
    else:
        return data
    if new in text:
        return data
    if text.count(old) != 1:
        raise ValueError(f"Unexpected LuCI source in {relative}; refusing an unverified patch")
    return text.replace(old, new).encode()


FILES = ("network.js", "view/status/include/60_wifi.js", "view/network/wireless.js")
VERSION_FILE = "usr/lib/lua/luci/version.lua"
HEADER_FILE = "usr/lib/lua/luci/view/header.htm"


def patch_header(data):
    text = data.decode()
    old = "git-23.093.57360-bcm5"
    new = old + "-personal-rates1"
    if new in text:
        return data
    if text.count(old) != 3:
        raise ValueError("Unexpected hard-coded LuCI asset versions")
    return text.replace(old, new).encode()


def patch_version(data):
    text = data.decode()
    if "-personal-rates1" in text:
        return data
    text, count = re.subn(r'(luciversion\s*=\s*"[^"]+)(")', r'\1-personal-rates1\2', text)
    if count != 1:
        raise ValueError("Missing LuCI resource version")
    return text.encode()


def rewrite_tar(data, transform):
    output = io.BytesIO()
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as src, tarfile.open(fileobj=output, mode="w:gz") as dst:
        for member in src.getmembers():
            content = src.extractfile(member).read() if member.isfile() else None
            if content is not None:
                content = transform(member.name.lstrip("./"), content)
                member.size = len(content)
            dst.addfile(member, io.BytesIO(content) if content is not None else None)
    return output.getvalue()


def patch_ipk(ipk):
    touched = set()
    def web(relative, data):
        if relative == HEADER_FILE:
            touched.add(HEADER_FILE)
            return patch_header(data)
        if relative == VERSION_FILE:
            touched.add(VERSION_FILE)
            return patch_version(data)
        prefix = "www/luci-static/resources/"
        if relative.startswith(prefix) and relative[len(prefix):] in FILES:
            touched.add(relative[len(prefix):])
            return patch_js(relative[len(prefix):], data)
        return data

    def payload(relative, data):
        if relative == "opt/ax10-luci/luci-dist.tar.gz":
            return rewrite_tar(data, web)
        if relative == "opt/ax10-luci/luci-setup.sh":
            old = "chmod +x /tmp/luci-app/www/cgi-bin/luci /tmp/luci-app/www/cgi-bin/luci.lua 2>/dev/null\n"
            new = old + "# Reload the personal asset version after an upgrade.\nrm -f /tmp/luci-modulecache/6C7563692E76657273696F6E\n"
            text = data.decode()
            if new not in text:
                if text.count(old) != 1:
                    raise ValueError("Unexpected LuCI setup script")
                text = text.replace(old, new)
            return text.encode()
        return data

    def control(relative, data):
        if relative == "control":
            text, count = re.subn(r"^Version: .+$", f"Version: {VERSION}", data.decode(), flags=re.M)
            if count != 1:
                raise ValueError("Missing package version")
            return text.encode()
        return data

    def outer(relative, data):
        if relative == "data.tar.gz":
            return rewrite_tar(data, payload)
        if relative == "control.tar.gz":
            return rewrite_tar(data, control)
        return data

    result = rewrite_tar(ipk.read_bytes(), outer)
    expected = set(FILES) | {VERSION_FILE, HEADER_FILE}
    if touched != expected:
        raise ValueError(f"Missing LuCI files: {expected - touched}")
    destination = ipk.with_name(f"ax10-luci_{VERSION}_armv7-3.2.ipk")
    destination.write_bytes(result)
    if destination != ipk:
        ipk.unlink()
    print(f"Patched {destination.name}: {len(touched)} LuCI files")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--web-root", type=Path)
    parser.add_argument("--feed", type=Path)
    args = parser.parse_args()
    if bool(args.web_root) == bool(args.feed):
        parser.error("Choose exactly one of --web-root or --feed")
    if args.web_root:
        for relative in FILES:
            target = args.web_root / relative
            target.write_bytes(patch_js(relative, target.read_bytes()))
    else:
        packages = list(args.feed.glob("ax10-luci_*.ipk"))
        if len(packages) != 1:
            raise ValueError(f"Expected one ax10-luci package, found {len(packages)}")
        patch_ipk(packages[0])


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Verify the packaged GUI does not replace the vendor GUI's config or caches."""
import io
from pathlib import Path
import re
import sys
import tarfile

package = Path(sys.argv[1])
with tarfile.open(package) as archive:
    payload = archive.extractfile("./data.tar.gz").read()
with tarfile.open(fileobj=io.BytesIO(payload)) as archive:
    setup = archive.extractfile("./opt/ax10-luci/luci-setup.sh").read().decode()
    dist = archive.extractfile("./opt/ax10-luci/luci-dist.tar.gz").read()
assert re.search(r"cp /tmp/luci-app/etc/config/luci /etc/config/luci_personal\s", setup)
assert not re.search(r"cp [^\n]+ /etc/config/luci\s", setup), "Vendor GUI configuration must remain intact"
assert "rm -f /tmp/luci-modulecache/" not in setup, "Do not invalidate vendor caches during an upgrade"
with tarfile.open(fileobj=io.BytesIO(dist)) as archive:
    def read(relative):
        return archive.extractfile("./usr/lib/lua/luci/" + relative).read().decode()
    loader = read("cacheloader.lua")
    config = read("config.lua")
    version = re.search(r'luciversion\s*=\s*"([^"]+)"', read("version.lua"))[1]
    versions = re.findall(r'git-23\.093\.57360-bcm5[^"<\s]*', read("view/header.htm"))
assert 'ccache.cache_ondemand("/tmp/luci-personal-modulecache")' in loader
assert 'get_all("luci_personal", key)' in config
assert versions == [version] * 3, "Every asset version must match the package version"
print("PASS: vendor config/cache isolation and consistent browser asset versions.")

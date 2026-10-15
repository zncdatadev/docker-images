"""Backport six's find_spec hook for the pinned kafka-python3 on Python3.12.

Based on benjaminp/six#352. Keep kafka-python3==3.0.0 and its public API;
only adapt the vendored importer's missing PEP451 protocol.
"""
import importlib.metadata
import importlib.util
from pathlib import Path

if importlib.metadata.version('kafka-python3') != '3.0.0':
    raise RuntimeError('Review the six backport before changing kafka-python3')
spec = importlib.util.find_spec('kafka3')
target = Path(next(iter(spec.submodule_search_locations))) / 'vendor' / 'six.py'
source = target.read_text()
needle = '    def find_module(self, fullname, path=None):\n'
backport = '''    def find_spec(self, fullname, path=None, target=None):
        from importlib.util import spec_from_loader
        if fullname in self.known_modules:
            return spec_from_loader(fullname, self)
        return None

'''
if '    def find_spec(' not in source:
    if source.count(needle) != 1 or '__version__ = "1.11.0"' not in source:
        raise RuntimeError('Unexpected vendored six source; refusing blind patch')
    target.write_text(source.replace(needle, backport + needle, 1))

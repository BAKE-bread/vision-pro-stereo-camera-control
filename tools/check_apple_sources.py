"""Syntax/project inspection ONLY. Does not replace an Xcode SDK build."""
from pathlib import Path
import plistlib
import xml.etree.ElementTree as ET
from tree_sitter import Language, Parser
import tree_sitter_swift
from openstep_parser import OpenStepDecoder

root = Path(__file__).resolve().parents[1]
parser = Parser(Language(tree_sitter_swift.language()))
failures = []
sources = list((root/'apple/StereoStudio').rglob('*.swift')) + list((root/'apple/StereoStudioTests').rglob('*.swift'))
for path in sources:
    tree = parser.parse(path.read_bytes())
    if tree.root_node.has_error:
        def errors(node):
            if node.type == 'ERROR' or node.is_missing:
                failures.append(f'{path.name}:{node.start_point.row+1}: {node.type} {node.text!r}')
            for child in node.children:
                errors(child)
        errors(tree.root_node)
with (root/'apple/StereoStudio/Info.plist').open('rb') as f:
    info = plistlib.load(f)
assert 'NSWorldSensingUsageDescription' in info
assert 'NSLocalNetworkUsageDescription' in info
with (root/'apple/StereoStudio.xcodeproj/project.pbxproj').open(encoding='utf-8') as f:
    project = OpenStepDecoder.ParseFromFile(f)
refs = [v for v in project['objects'].values() if v.get('isa') == 'PBXFileReference' and v.get('sourceTree') in ('<group>', 'SOURCE_ROOT')]
for ref in refs:
    assert (root/'apple'/ref['path']).exists(), ref
ET.parse(root/'apple/StereoStudio.xcodeproj/xcshareddata/xcschemes/StereoStudio.xcscheme')
if failures:
    raise SystemExit('\n'.join(failures))
print(f'{len(sources)} Swift files parsed; {len(refs)} file references and plist/scheme valid. SDK typecheck NOT performed.')

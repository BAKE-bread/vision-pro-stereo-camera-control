"""Export only the new implementation, with no virtualenvs, old credentials or binaries."""
from pathlib import Path
import datetime
import zipfile

root = Path(__file__).resolve().parents[1]
output = root/'artifacts'
output.mkdir(exist_ok=True)
name = 'stereo-studio-source-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S')+'.zip'
paths = [root/name for name in ('README.md', 'LICENSE', '.gitignore', 'pytest.ini')]
for directory in ('apple', 'server', 'web', 'tests', 'docs', '.github'):
    paths.extend(path for path in (root/directory).rglob('*') if path.is_file()
                 and '__pycache__' not in path.parts and 'xcuserdata' not in path.parts
                 and not path.name.endswith('.local.json')
                 and path.suffix not in ('.pem', '.key', '.p12')
                 and (not path.name.startswith('.env') or path.name == '.env.example'))
paths.extend(path for path in (root/'tools').iterdir() if path.suffix in ('.py', '.sh'))
with zipfile.ZipFile(output/name, 'x', compression=zipfile.ZIP_DEFLATED) as archive:
    for path in sorted(paths):
        archive.write(path, Path('StereoStudio')/path.relative_to(root))
print(output/name)

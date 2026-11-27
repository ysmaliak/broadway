import shutil
import uuid
from pathlib import Path


def spot(sv, name):
    folder = Path(sv.SUPPORT) / "out" / uuid.uuid4().hex[:8]
    folder.mkdir(parents=True, exist_ok=True)
    return folder / name


def bring(made, dest):
    made, dest = Path(made), Path(dest)
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists():
        dest.unlink()
    shutil.move(str(made), str(dest))
    return dest

import re
from pathlib import Path

SCRIPT_PATH = Path("../00_environment_functions.sh")

def list_functions():
    pattern = re.compile(r"^([a-zA-Z_][a-zA-Z0-9_]*)\(\)\s*\{")
    with open(SCRIPT_PATH, "r") as f:
        return sorted({match.group(1) for line in f if (match := pattern.match(line))})

def run_function(func_name, args):
    import subprocess
    joined_args = " ".join(args)
    command = f"source {SCRIPT_PATH} && {func_name} {joined_args}"
    result = subprocess.run(["bash", "-c", command], capture_output=True, text=True)
    return result

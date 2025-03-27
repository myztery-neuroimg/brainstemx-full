#!/usr/bin/env python3
# streamlit.sh (Python Streamlit app)

import streamlit as st
import subprocess
import re
from pathlib import Path

ENV_SCRIPT = "00_environment_functions.sh"
LOG_DIR = Path("../mri_results/logs")
DEFAULT_LOG = sorted(LOG_DIR.glob("*.log"), reverse=True)[0] if LOG_DIR.exists() else None

st.set_page_config(page_title="MRI Pipeline", layout="wide")

# Utility: discover all function names from shell script
@st.cache_data
def discover_functions():
    with open(ENV_SCRIPT, "r") as f:
        lines = f.readlines()
    pattern = re.compile(r"^([a-zA-Z_][a-zA-Z0-9_]*)\(\)\s*\{")
    return sorted(set(match.group(1) for line in lines if (match := pattern.match(line))))

# Sidebar navigation
st.sidebar.title("🧠 MRI Pipeline Navigation")
page = st.sidebar.radio("Go to", ["Home", "Run Function", "View Logs"])

# --- Page: Home ---
if page == "Home":
    st.title("📘 MRI Pipeline Overview")
    st.markdown("This app lets you invoke shell functions from your `00_environment_functions.sh` interactively.")
    st.subheader("Available Shell Functions")
    funcs = discover_functions()
    st.code("\n".join(funcs), language="bash")

# --- Page: Run Function ---
elif page == "Run Function":
    st.title("🚀 Run Function")
    funcs = discover_functions()
    selected_func = st.selectbox("Select a function", funcs)
    st.markdown("Enter up to 5 optional arguments:")
    args = [st.text_input(f"Arg {i+1}") for i in range(5)]
    args = [a for a in args if a.strip()]

    if st.button("Execute"):
        cmd = f"source {ENV_SCRIPT} && {selected_func} {' '.join(args)}"
        st.code(cmd, language="bash")
        result = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True)
        st.subheader("STDOUT:")
        st.code(result.stdout)
        if result.stderr:
            st.subheader("STDERR:")
            st.code(result.stderr, language="bash")
        st.success("Function completed" if result.returncode == 0 else "Function failed")

# --- Page: Logs ---
elif page == "View Logs":
    st.title("📜 Logs")
    if not LOG_DIR.exists():
        st.warning("No logs found in ../mri_results/logs")
    else:
        logs = sorted(LOG_DIR.glob("*.log"), reverse=True)
        if logs:
            selected_log = st.selectbox("Select a log file", logs)
            with open(selected_log, "r") as f:
                st.text_area("Log Output", f.read(), height=500)
        else:
            st.info("No log files available.")

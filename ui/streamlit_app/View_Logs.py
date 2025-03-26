import streamlit as st
from pathlib import Path

LOG_DIR = Path("../mri_results/logs")

st.title("📜 View Logs")

if not LOG_DIR.exists():
    st.warning("No log directory found.")
else:
    logs = sorted(LOG_DIR.glob("*.log"), reverse=True)
    if logs:
        selected = st.selectbox("Choose log", logs)
        with open(selected) as f:
            content = f.read()
        st.text_area("Log Content", content, height=600)
    else:
        st.info("No log files yet.")

import streamlit as st
from utils import list_functions

st.set_page_config(page_title="MRI Pipeline", layout="wide")
st.title("🧠 Brain MRI Pipeline Dashboard")

st.markdown("Explore the available shell functions from the MRI processing pipeline.")

funcs = list_functions()
st.code("\n".join(funcs), language="bash")

st.sidebar.page_link("Run_Function.py", label="▶️ Run a Function")
st.sidebar.page_link("View_Logs.py", label="📜 View Logs")
